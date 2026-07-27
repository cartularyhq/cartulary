# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Governance.Audit do
  @moduledoc """
  Append-only, content-safe, per-Account audit chain.

  Event payloads reference durable records and content hashes. Raw messages,
  statements, prompts, answers, keys, and secrets are not accepted here.
  """

  alias Cartulary.Clock
  alias Cartulary.Governance.AuditEvent

  @categories ~w(
    lifecycle gate attribution deletion configuration governance observation
  )

  @spec categories() :: [String.t()]
  def categories, do: @categories

  @spec append(map(), Ecto.UUID.t(), map()) :: {:ok, AuditEvent.t()} | {:error, term()}
  def append(actor, account_id, attrs) when is_map(attrs) and is_binary(account_id) do
    actor = pipeline_actor(actor)

    attrs =
      attrs
      |> Map.new()
      |> Map.put_new(:occurred_at, Clock.utc_now())

    AuditEvent
    |> Ash.Changeset.new()
    |> Ash.Changeset.set_tenant(account_id)
    |> Ash.Changeset.set_context(%{audit_actor: actor})
    |> Ash.Changeset.for_create(:record, attrs)
    |> Ash.create(actor: actor)
  end

  @spec append!(map(), Ecto.UUID.t(), map()) :: AuditEvent.t()
  def append!(actor, account_id, attrs) do
    case append(actor, account_id, attrs) do
      {:ok, event} -> event
      {:error, error} -> raise "Audit append failed: #{inspect(error)}"
    end
  end

  @spec content_hash(term()) :: String.t()
  def content_hash(value) do
    value
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp pipeline_actor(%Cartulary.Actor{} = actor),
    do: %{actor | role: :system, pipeline?: true}

  defp pipeline_actor(actor) do
    actor
    |> Map.put(:role, :system)
    |> Map.put(:pipeline?, true)
  end
end

defmodule Cartulary.Governance.Changes.HashAuditEvent do
  @moduledoc false

  use Ash.Resource.Change

  alias Cartulary.Clock
  alias Cartulary.Governance.Audit
  alias Cartulary.Governance.AuditEvent
  alias Cartulary.Pipeline.Lock

  @impl true
  def change(changeset, _opts, context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      actor =
        context.actor || changeset.context[:audit_actor] ||
          get_in(changeset.context, [:private, :actor])

      account_id = changeset.tenant || context.tenant || actor.account_id
      Lock.acquire!(account_id, "audit-chain")

      previous =
        AuditEvent
        |> Ash.Query.sort(inserted_at: :desc, id: :desc)
        |> Ash.Query.limit(1)
        |> Ash.Query.set_tenant(account_id)
        |> Ash.read_one!(actor: actor)

      occurred_at = Ash.Changeset.get_attribute(changeset, :occurred_at) || Clock.utc_now()
      previous_hash = previous && previous.event_hash

      payload = %{
        account_id: account_id,
        category: Ash.Changeset.get_attribute(changeset, :category),
        action: Ash.Changeset.get_attribute(changeset, :action),
        resource_type: Ash.Changeset.get_attribute(changeset, :resource_type),
        resource_id: Ash.Changeset.get_attribute(changeset, :resource_id),
        content_hash: Ash.Changeset.get_attribute(changeset, :content_hash),
        metadata: Ash.Changeset.get_attribute(changeset, :metadata) || %{},
        occurred_at: DateTime.to_iso8601(occurred_at),
        previous_hash: previous_hash
      }

      changeset
      |> Ash.Changeset.force_change_attribute(:occurred_at, occurred_at)
      |> Ash.Changeset.force_change_attribute(:previous_hash, previous_hash)
      |> Ash.Changeset.force_change_attribute(:event_hash, Audit.content_hash(payload))
    end)
  end
end

defmodule Cartulary.Governance.Changes.AuditResource do
  @moduledoc false

  use Ash.Resource.Change

  alias Cartulary.Governance.Audit

  @impl true
  def change(changeset, opts, _context) do
    Ash.Changeset.after_action(changeset, fn changeset, result ->
      actor = get_in(changeset.context, [:private, :actor])
      fields = Keyword.get(opts, :content_fields, [])
      content_hash = Audit.content_hash(Map.take(result, fields))

      Audit.append(actor, result.account_id, %{
        scope_id: Map.get(result, :scope_id),
        actor_peer_id: Map.get(actor, :peer_id),
        category: Keyword.fetch!(opts, :category),
        action: Keyword.fetch!(opts, :action),
        resource_type: Keyword.fetch!(opts, :resource_type),
        resource_id: result.id,
        content_hash: content_hash,
        metadata: Keyword.get(opts, :metadata, %{})
      })
      |> case do
        {:ok, _event} -> {:ok, result}
        {:error, error} -> {:error, error}
      end
    end)
  end
end
