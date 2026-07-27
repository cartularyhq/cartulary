# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Pipeline.Idempotency do
  @moduledoc """
  Deterministic F2 job keys.

  Keys include the lane and the immutable source identity or watermark so
  replay, reconciliation, and event coalescing converge on the same durable
  pipeline run.
  """

  @spec message_extraction(Ecto.UUID.t(), String.t()) :: String.t()
  def message_extraction(message_id, content_hash),
    do: key(:message_extraction, [message_id, content_hash])

  @spec document_extraction(Ecto.UUID.t(), String.t()) :: String.t()
  def document_extraction(document_version_id, content_hash),
    do: key(:document_extraction, [document_version_id, content_hash])

  @spec dream_time(Ecto.UUID.t(), term()) :: String.t()
  def dream_time(scope_id, watermark), do: key(:dream_time, [scope_id, watermark])

  @spec projection_refresh(Ecto.UUID.t(), term()) :: String.t()
  def projection_refresh(scope_id, watermark),
    do: key(:projection_refresh, [scope_id, watermark])

  @spec entity_resolution(Ecto.UUID.t(), term()) :: String.t()
  def entity_resolution(scope_id, watermark),
    do: key(:entity_resolution, [scope_id, watermark])

  @spec import_rebuild(String.t(), String.t()) :: String.t()
  def import_rebuild(import_id, manifest_hash),
    do: key(:import_rebuild, [import_id, manifest_hash])

  @spec validation_continuation(Ecto.UUID.t(), Ecto.UUID.t()) :: String.t()
  def validation_continuation(decision_id, knowledge_item_id),
    do: key(:validation_continuation, [decision_id, knowledge_item_id])

  @spec answer_correlation(Ecto.UUID.t(), Ecto.UUID.t()) :: String.t()
  def answer_correlation(question_id, session_id),
    do: key(:answer_correlation, [question_id, session_id])

  @spec reconciler(Ecto.UUID.t(), term()) :: String.t()
  def reconciler(account_id, watermark), do: key(:reconciler, [account_id, watermark])

  @spec content_hash(binary()) :: String.t()
  def content_hash(content) when is_binary(content) do
    :crypto.hash(:sha256, content)
    |> Base.encode16(case: :lower)
  end

  @spec key(atom(), list()) :: String.t()
  def key(kind, components) when is_atom(kind) and is_list(components) do
    digest =
      components
      |> :erlang.term_to_binary([:deterministic])
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.url_encode64(padding: false)

    "#{kind}:#{digest}"
  end
end
