# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Skills.Authoring do
  @moduledoc "Transactional plain-version authoring for skill requirement cards."

  alias Cartulary.DataLayer
  alias Cartulary.Pipeline.Lock
  alias Cartulary.Skills.Selector
  alias Cartulary.Skills.SkillRequirementCard
  alias Cartulary.Topology.Scope

  require Ash.Query

  def publish(actor, attrs) when is_map(attrs) do
    attrs = stringify_keys(attrs)

    with {:ok, skill_key} <- skill_key(attrs["skill_key"]),
         {:ok, requirements} <- Selector.validate_requirements(attrs["requirements"]) do
      result =
        DataLayer.with_actor(actor, fn account, current_actor ->
          case scope(account.id, current_actor, attrs) do
            nil ->
              {:error, "scope not found or not authorized"}

            scope ->
              publish_in_scope!(account.id, current_actor, scope, skill_key, requirements, attrs)
          end
        end)

      case result do
        {:error, _message} = error -> error
        card -> {:ok, card}
      end
    end
  end

  defp publish_in_scope!(account_id, actor, scope, skill_key, requirements, attrs) do
    Lock.acquire!(account_id, "skill-card:#{scope.id}:#{skill_key}")

    existing =
      SkillRequirementCard
      |> Ash.Query.filter(scope_id == ^scope.id and skill_key == ^skill_key)
      |> Ash.Query.sort(version: :desc)
      |> Ash.Query.set_tenant(account_id)
      |> Ash.read!(actor: actor)

    Enum.each(Enum.filter(existing, & &1.active), fn card ->
      card
      |> Ash.Changeset.for_update(:deactivate, %{})
      |> Ash.Changeset.set_tenant(account_id)
      |> Ash.update!(actor: actor)
    end)

    next_version =
      case existing do
        [%{version: version} | _] -> version + 1
        [] -> 1
      end

    SkillRequirementCard
    |> Ash.Changeset.new()
    |> Ash.Changeset.set_tenant(account_id)
    |> Ash.Changeset.for_create(:create_version, %{
      scope_id: scope.id,
      skill_key: skill_key,
      description: blank_to_nil(attrs["description"]),
      requirement_schema_version: Selector.schema_version(),
      version: next_version,
      requirements: requirements,
      active: true
    })
    |> Ash.create!(actor: actor)
  end

  defp scope(account_id, actor, %{"scope_id" => scope_id}) when is_binary(scope_id) do
    Scope
    |> Ash.Query.filter(id == ^scope_id)
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read_one!(actor: actor)
  end

  defp scope(account_id, actor, %{"scope_path" => scope_path}) when is_binary(scope_path) do
    scope_path = normalize_path(scope_path)

    Scope
    |> Ash.Query.filter(path == ^scope_path)
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read_one!(actor: actor)
  end

  defp scope(_account_id, _actor, _attrs),
    do: raise(ArgumentError, "scope_id or scope_path is required")

  defp skill_key(value) when is_binary(value) do
    value = String.trim(value)

    if Regex.match?(~r/\A[a-z][a-z0-9]*(?:[-_][a-z0-9]+)*\z/, value) do
      {:ok, value}
    else
      {:error, "skill_key must be a lowercase slug"}
    end
  end

  defp skill_key(_value), do: {:error, "skill_key is required"}

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: value)

  defp blank_to_nil(value), do: to_string(value)

  defp normalize_path(path) do
    normalized = "/" <> (path |> String.trim() |> String.trim("/"))
    if normalized == "/", do: "/", else: normalized
  end

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end
