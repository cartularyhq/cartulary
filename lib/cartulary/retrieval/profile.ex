# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Retrieval.Profile do
  @moduledoc """
  Decides which strategies run, how their votes are weighted, whether the
  result is reranked, and how long the whole request may take.

  A profile is a named trade-off between speed and thoroughness. Three ship:

  * `:fast` — the cheapest useful posture, used when a context cache misses and
    a caller is blocked;
  * `:balanced` — the default for search;
  * `:thorough` — every strategy plus expansion and a model-backed rerank, used
    for answering questions and for background rebuilds.

  ## Resolution order

  1. Start from the compiled-in defaults for the named profile.
  2. If a stored override exists, merge it. Overrides are looked up per scope,
     nearest first — the query's scope list is already ordered nearest-first —
     falling back to an Account-wide row. Only `active` rows count, and the
     highest authored version among them wins.
  3. Apply the deployment allowlist. A strategy absent from it never runs, no
     matter what the profile asks for, and is reported as dropped rather than
     silently omitted, so a lane an operator switched off stays visible to
     callers.

  ## Two things that must not slip

  **Hand-picked strategy lists are internal-only.** Letting a request choose
  its own strategies turns retrieval tuning into a request parameter and makes
  results impossible to reproduce or reason about, so an external caller
  passing one gets an exception rather than a quietly honoured override.

  **Every unknown name raises.** A misspelled profile or strategy is never
  skipped. Ignoring it would silently degrade recall with no visible symptom —
  the worst possible failure mode for a retrieval system, because the answer
  still looks like an answer.

  ## Reported version

  A resolved profile carries a version string used to reproduce a past result.
  The compiled defaults report `f7-1`, the identity of the retrieval and
  context contract; changing that value is a public contract transition
  requiring a changelog entry and updated contract evidence, not a routine
  bump. When a stored override is in force, the reported version instead
  combines the authored version number with a short digest of the strategies,
  weights, and rerank flag actually applied, so two differently tuned
  Accounts can never report the same identity.
  """

  alias Cartulary.Retrieval.RetrievalProfile

  require Ash.Query

  # The complete registry of runnable strategies. A strategy module that is not
  # listed here cannot be named by a profile, by an override, or by an internal
  # caller — adding one is a deliberate behaviour change.
  @strategy_modules %{
    semantic: Cartulary.Retrieval.Strategies.Semantic,
    lexical: Cartulary.Retrieval.Strategies.Lexical,
    temporal: Cartulary.Retrieval.Strategies.Temporal,
    salience_recency: Cartulary.Retrieval.Strategies.SalienceRecency,
    entity_match: Cartulary.Retrieval.Strategies.EntityMatch,
    relation_expand: Cartulary.Retrieval.Strategies.RelationExpand
  }

  @doc """
  Resolves a profile name into the concrete settings one request will use.

  `name` is `:fast`, `:balanced`, or `:thorough` (strings accepted). `query`
  supplies the Account and the nearest-first scope list used to find a stored
  override. Options:

  * `:inherit?` (default true) — set false to ignore stored overrides and use
    the compiled defaults, which is what makes evaluation runs reproducible
    across Accounts.
  * `:strategies` — an explicit strategy list, permitted only together with
    `internal?: true`.
  * `:internal?` (default false) — asserts the caller is server-side or an
    evaluation harness.

  Returns a map with the profile name, reported version, selected strategy
  names, their modules in the same order, fusion weights, the rerank flag, the
  deadline in milliseconds, and the strategies excluded by the deployment
  allowlist.

  Raises `ArgumentError` for an unknown profile name, an unknown strategy name,
  or a strategy list from a non-internal caller. Raises `KeyError` if the
  profile configuration is missing a key. The override lookup reads through
  the resource layer as the query's actor, so it is Account-scoped and
  authorization-checked like any other read.
  """
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

    # The deployment allowlist is the final word, above both the compiled
    # profile and any stored override. Anything it removes is kept in
    # `disabled_strategies` so the response can tell the caller the run was
    # narrowed by configuration rather than by a lack of matching memory.
    selected = Enum.filter(requested, &(&1 in enabled))
    disabled = requested -- selected

    Map.merge(profile, %{
      name: name,
      strategies: selected,
      strategy_modules: Enum.map(selected, &Map.fetch!(@strategy_modules, &1)),
      disabled_strategies: disabled
    })
  end

  @doc """
  Returns the module implementing a strategy name, accepting an atom or string.

  Raises `ArgumentError` for an unregistered name.
  """
  def module(name), do: Map.fetch!(@strategy_modules, normalize_strategy!(name))

  @doc "Returns every registered strategy name, for validation and reporting."
  def strategy_names, do: Map.keys(@strategy_modules)

  # Finds the stored override that applies here. Sorting by version descending
  # first means the per-scope search below naturally lands on the newest active
  # row for a scope. `scope_ids` arrives nearest-first, so the first scope with
  # a row wins — that is the nearest-scope rule. An Account-wide row (null
  # scope) is the fallback, never an addition: overrides replace, not layer.
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

  # Applies a stored override on top of the compiled defaults. Each of
  # strategies, weights, and rerank falls back to the base value when the
  # override omits it, so a row can retune one dimension without restating the
  # rest. The deadline is always taken from the row: it is a required column.
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

    # The authored version number alone would let two Accounts publish
    # different tunings under the same reported identity, making a recorded
    # result impossible to reproduce. Hashing the settings that actually change
    # ranking fixes that. 10 hex characters (40 bits) is short enough to read
    # in a response and far beyond collision risk for a handful of tunings.
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

  # The compiled defaults. Every key is fetched with a bang: a profile missing
  # a strategy list, a weight map, or a deadline is a deployment error that
  # must fail at the first request, not silently retrieve with a default.
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

  # Profile and strategy names arrive as atoms from internal callers and as
  # strings from request payloads. Both are normalised to a known atom, and
  # anything else raises rather than silently selecting a default profile or
  # dropping a strategy — a misspelling must be visible, not merely degrading.
  # Only the three shipped names are converted, so no request can create atoms.
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

  # A stored override's configuration is a free-form map that may come back
  # with atom or string keys depending on how it was written; normalising
  # recursively lets the merge read it one way.
  defp stringify_keys(map) do
    Map.new(map || %{}, fn {key, value} ->
      {to_string(key), if(is_map(value), do: stringify_keys(value), else: value)}
    end)
  end
end
