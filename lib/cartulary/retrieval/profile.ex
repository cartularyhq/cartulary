# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Retrieval.Profile do
  @moduledoc "Named, versioned retrieval profile resolution with nearest-scope inheritance."

  alias Cartulary.Retrieval.RetrievalProfile

  require Ash.Query

  @strategy_modules %{
    semantic: Cartulary.Retrieval.Strategies.Semantic,
    lexical: Cartulary.Retrieval.Strategies.Lexical,
    temporal: Cartulary.Retrieval.Strategies.Temporal,
    salience_recency: Cartulary.Retrieval.Strategies.SalienceRecency,
    entity_match: Cartulary.Retrieval.Strategies.EntityMatch,
    relation_expand: Cartulary.Retrieval.Strategies.RelationExpand
  }

  def resolve(name, query, opts \\ []) do
    name = normalize_name(name)
    base = runtime_profile(name)

    configured =
      if Keyword.get(opts, :inherit?, true) do
        inherited_profile(name, query)
      end

    profile = merge_persisted(base, configured)
    enabled = enabled_strategy_names()

    requested =
      case {Keyword.get(opts, :strategies), Keyword.get(opts, :internal?, false)} do
        {nil, _internal?} ->
          profile.strategies

        {strategies, true} ->
          Enum.map(strategies, &normalize_strategy!/1)

        {_strategies, false} ->
          raise ArgumentError, "raw retrieval strategies are restricted to internal/eval callers"
      end

    selected = Enum.filter(requested, &(&1 in enabled))
    disabled = requested -- selected

    Map.merge(profile, %{
      name: name,
      strategies: selected,
      strategy_modules: Enum.map(selected, &Map.fetch!(@strategy_modules, &1)),
      disabled_strategies: disabled
    })
  end

  def module(name), do: Map.fetch!(@strategy_modules, normalize_strategy!(name))
  def strategy_names, do: Map.keys(@strategy_modules)

  defp inherited_profile(name, query) do
    records =
      RetrievalProfile
      |> Ash.Query.filter(name == ^Atom.to_string(name) and active == true)
      |> Ash.Query.sort(version: :desc)
      |> Ash.Query.set_tenant(query.account_id)
      |> Ash.read!(actor: query.actor)

    Enum.find_value(query.scope_ids, fn scope_id ->
      Enum.find(records, &(&1.scope_id == scope_id))
    end) || Enum.find(records, &is_nil(&1.scope_id))
  end

  defp merge_persisted(base, nil), do: base

  defp merge_persisted(base, record) do
    config = stringify_keys(record.strategy_config)

    strategies =
      config
      |> Map.get("strategies", base.strategies)
      |> Enum.map(&normalize_strategy!/1)

    weights =
      config
      |> Map.get("weights", base.weights)
      |> Map.new(fn {key, value} -> {normalize_strategy!(key), value * 1.0} end)

    digest =
      :crypto.hash(:sha256, :erlang.term_to_binary({strategies, weights, config["rerank"]}))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 10)

    %{
      base
      | version: "f7-#{record.version}-#{digest}",
        strategies: strategies,
        weights: weights,
        rerank: Map.get(config, "rerank", base.rerank),
        deadline_ms: record.deadline_ms
    }
  end

  defp runtime_profile(name) do
    config = Application.fetch_env!(:cartulary, :retrieval_profiles)
    values = config |> Keyword.fetch!(name) |> Map.new()

    %{
      name: name,
      version: Map.fetch!(values, :version),
      strategies: Map.fetch!(values, :strategies),
      weights: Map.fetch!(values, :weights),
      rerank: Map.fetch!(values, :rerank),
      deadline_ms: Map.fetch!(values, :deadline_ms)
    }
  end

  defp enabled_strategy_names do
    :cartulary
    |> Application.fetch_env!(:retrieval_profiles)
    |> Keyword.fetch!(:enabled_strategies)
    |> Enum.map(&normalize_strategy!/1)
  end

  defp normalize_name(name) when name in [:fast, :balanced, :thorough], do: name

  defp normalize_name(name) when is_binary(name) do
    case name do
      "fast" -> :fast
      "balanced" -> :balanced
      "thorough" -> :thorough
      _other -> raise ArgumentError, "unknown retrieval profile: #{inspect(name)}"
    end
  end

  defp normalize_name(name),
    do: raise(ArgumentError, "unknown retrieval profile: #{inspect(name)}")

  defp normalize_strategy!(name) when is_atom(name) and is_map_key(@strategy_modules, name),
    do: name

  defp normalize_strategy!(name) when is_binary(name) do
    Enum.find(Map.keys(@strategy_modules), &(Atom.to_string(&1) == name)) ||
      raise ArgumentError, "unknown retrieval strategy: #{inspect(name)}"
  end

  defp normalize_strategy!(name),
    do: raise(ArgumentError, "unknown retrieval strategy: #{inspect(name)}")

  defp stringify_keys(map) do
    Map.new(map || %{}, fn {key, value} ->
      {to_string(key), if(is_map(value), do: stringify_keys(value), else: value)}
    end)
  end
end
