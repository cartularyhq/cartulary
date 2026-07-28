# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Observations.Changes.HashContent do
  @moduledoc false

  use Ash.Resource.Change

  alias Cartulary.Pipeline.Idempotency

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :content) do
      content when is_binary(content) ->
        Ash.Changeset.force_change_attribute(
          changeset,
          :content_hash,
          Idempotency.content_hash(content)
        )

      _other ->
        changeset
    end
  end
end

defmodule Cartulary.Observations.Changes.HashContentIfMissing do
  @moduledoc false

  use Ash.Resource.Change

  alias Cartulary.Pipeline.Idempotency

  @impl true
  def change(changeset, _opts, _context) do
    case {
      Ash.Changeset.get_attribute(changeset, :content_hash),
      Ash.Changeset.get_attribute(changeset, :content)
    } do
      {hash, _content} when is_binary(hash) and hash != "" ->
        changeset

      {_hash, content} when is_binary(content) ->
        Ash.Changeset.force_change_attribute(
          changeset,
          :content_hash,
          Idempotency.content_hash(content)
        )

      _other ->
        changeset
    end
  end
end

defmodule Cartulary.Observations.Changes.AuditAndEnqueueMessage do
  @moduledoc false

  use Ash.Resource.Change

  alias Cartulary.Governance.Audit
  alias Cartulary.Pipeline

  @impl true
  def change(changeset, _opts, context) do
    Ash.Changeset.after_action(changeset, fn changeset, message ->
      actor =
        context.actor || changeset.context[:cartulary_actor] ||
          get_in(changeset.context, [:private, :actor])

      with {:ok, _audit} <-
             Audit.append(actor, message.account_id, %{
               scope_id: message.scope_id,
               actor_peer_id: message.peer_id,
               category: "observation",
               action: "message.ingested",
               resource_type: "message",
               resource_id: message.id,
               content_hash: message.content_hash,
               metadata: %{
                 "role" => message.role,
                 "session_id" => message.session_id
               }
             }),
           {:ok, _run} <- Pipeline.enqueue_message_extraction(message, actor),
           {:ok, _reconciler} <- Pipeline.enqueue_reconciler(message.account_id, actor),
           :ok <- maybe_fail(changeset) do
        {:ok, message}
      end
    end)
  end

  defp maybe_fail(changeset) do
    if get_in(changeset.context, [:private, :f2_force_rollback?]) do
      {:error, "forced F2 rollback"}
    else
      :ok
    end
  end
end

defmodule Cartulary.Observations.Changes.AuditAndEnqueueDocument do
  @moduledoc false

  use Ash.Resource.Change

  alias Cartulary.Governance.Audit
  alias Cartulary.Pipeline

  @impl true
  def change(changeset, _opts, context) do
    Ash.Changeset.after_action(changeset, fn changeset, version ->
      actor =
        context.actor || changeset.context[:cartulary_actor] ||
          get_in(changeset.context, [:private, :actor])

      with {:ok, _audit} <-
             Audit.append(actor, version.account_id, %{
               scope_id: version.scope_id,
               category: "observation",
               action: "document_version.ingested",
               resource_type: "document_version",
               resource_id: version.id,
               content_hash: version.content_hash,
               metadata: %{
                 "document_id" => version.document_id,
                 "version" => version.version,
                 "media_type" => version.media_type,
                 "byte_size" => version.byte_size
               }
             }),
           {:ok, _run} <- Pipeline.enqueue_document_extraction(version, actor),
           {:ok, _reconciler} <- Pipeline.enqueue_reconciler(version.account_id, actor) do
        {:ok, version}
      end
    end)
  end
end
