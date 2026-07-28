# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Skills.Authoring do
  @moduledoc """
  Publishes new versions of skill requirement cards.

  Cards are human-authored procedural memory, so they are versioned in the plain way rather than
  passing through the approval gates that govern extracted knowledge: publishing inserts the
  next immutable version and retires the previous one, and the new contract is in force
  immediately.

  ## What one publish guarantees

  A publish is a single Account-scoped transaction that acquires a lock, retires every currently
  active version for the scope and skill, inserts the new version, and appends the audit entry.
  All of it commits together or none of it does — there is no moment at which a scope has two
  active cards for one skill, and no moment at which it has none because a retire succeeded and
  an insert failed.

  Concurrency is handled by a transaction-scoped advisory lock keyed on the Account, the scope,
  and the skill. Two people publishing the same card at the same time serialize; two people
  publishing different cards do not block each other.

  ## Version numbers

  The next version is one above the highest existing version, retired ones included, so numbers
  are never reused and a readiness report citing "version 3" always means the same card.

  ## Mistakes to avoid

  * Do not update a card in place. The whole point of a version is that a past readiness result
    remains explainable.
  * Do not offer this to machine credentials. The resource's policies already restrict authoring
    to Account administrators, curators, and the internal system actor, and an agent that could
    rewrite its own requirements could declare itself ready.
  * Do not put statement text or secrets into a requirement. Cards are configuration and are not
    covered by the erasure paths that clean up knowledge.
  """

  alias Cartulary.DataLayer
  alias Cartulary.Pipeline.Lock
  alias Cartulary.Skills.Selector
  alias Cartulary.Skills.SkillRequirementCard
  alias Cartulary.Topology.Scope

  require Ash.Query

  @doc """
  Publishes the next version of one skill requirement card.

  `actor` must be an authenticated actor holding an authoring role; the Account is derived from
  that identity and never from `attrs`. `attrs` may use string or atom keys and carries:

  * `"skill_key"` — the skill this card governs, as a lowercase slug. Required.
  * `"scope_id"` or `"scope_path"` — where the card is attached. Required.
  * `"requirements"` — the requirement list, which is validated and normalized before anything
    is written. Required.
  * `"description"` — optional free-text note for reviewers; blank strings become nil.

  Returns `{:ok, card}` with the newly created active version, or `{:error, message}` when the
  skill key is not a slug, the requirements do not validate, or the scope cannot be found or is
  not authorized for this actor.

  Raises `ArgumentError` when neither `"scope_id"` nor `"scope_path"` is present, and raises if
  the underlying transaction or an Ash write fails — including when the actor lacks an authoring
  role, which is an authorization failure rather than an error tuple.
  """
  def publish(actor, attrs) when is_map(attrs) do
    attrs = stringify_keys(attrs)

    # Validate before opening the transaction: a malformed card should cost nothing and should
    # never hold the advisory lock while it is being rejected.
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

  # Runs inside the caller's Account-scoped transaction. The order matters and must not change:
  # take the lock, read the existing versions, retire the active ones, then insert the new one.
  #
  # The lock is a transaction-scoped Postgres advisory lock, released automatically at commit or
  # rollback. It is keyed per Account, scope, and skill so that concurrent publishes of the same
  # card serialize while unrelated publishes proceed in parallel. Without it, two publishes
  # could read the same highest version and both try to insert it; the resource's uniqueness
  # constraint would then fail one of them after the retire had already happened.
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

    # Counted from the highest version that has ever existed for this scope and skill, not from
    # the highest active one, so retiring a card never lets its number be reused. `existing` is
    # sorted version-descending, so the head is that maximum.
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
      # Stamped from the running build rather than accepted from the caller, so a card can never
      # claim to be written in a grammar this code does not implement.
      requirement_schema_version: Selector.schema_version(),
      version: next_version,
      requirements: requirements,
      active: true
    })
    |> Ash.create!(actor: actor)
  end

  # Scope may be named by id or by path. Either way the lookup is Account-scoped and runs under
  # the caller's actor, so a scope in another Account, or one this actor may not reach, comes
  # back as nil and the publish fails with "scope not found or not authorized" rather than
  # attaching a card somewhere the author cannot see.
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

  # Skill keys are lowercase slugs, matching the grammar used for requirement keys. The key is
  # how cards at different scopes are recognized as governing the same skill, so a case or
  # whitespace variant would create a second, silently unrelated inheritance chain.
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

  # Canonical form: exactly one leading slash, no trailing slash, root stays "/". Scope paths are
  # matched as exact strings, so an unnormalized value would fail to find an existing scope
  # instead of reporting a malformed path.
  defp normalize_path(path) do
    normalized = "/" <> (path |> String.trim() |> String.trim("/"))
    if normalized == "/", do: "/", else: normalized
  end

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end
