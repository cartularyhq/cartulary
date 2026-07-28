# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Pipeline.Extractor do
  @moduledoc """
  F5 structured extraction from raw observations into proposed knowledge.

  Provider selection is explicit. A configured provider failure is returned so
  AshOban retries the durable job; it never silently switches extractors.
  """

  alias Cartulary.Model
  alias Cartulary.Model.Schema.Extraction

  @pipeline_version "f5-1"
  @prompt_version "extract-1"

  def pipeline_version, do: @pipeline_version
  def prompt_version, do: @prompt_version

  def extract(message, context \\ %{}) do
    schema_context = schema_context(message, context)

    messages = [
      %{
        role: "system",
        content: """
        Extract durable agent-memory knowledge from exactly one raw observation.
        Return the supplied structured schema. Natural-language statements are
        the knowledge atom. Do not invent facts and return no item for content
        that is not durable memory.

        Resolve subject independently from source. A peer subject_ref must be
        one of the supplied known peer keys. Use the current scope path only for
        a scope subject. Mark third-party claims as hearsay; their confidence is
        discounted again by Cartulary. Propose sensitivity and the independent
        expiry, revalidation, and relevant-window timestamps. Use no_op by
        omitting the candidate rather than emitting an empty statement.
        """
      },
      %{
        role: "user",
        content: """
        Source peer key: #{schema_context.source_peer_key}
        Source role: #{Map.get(message, "role", "user")}
        Current scope: #{schema_context.scope_path}
        Known peer keys: #{Enum.join(schema_context.known_peer_keys, ", ")}

        Observation:
        #{Map.fetch!(message, "content")}
        """
      }
    ]

    opts = [
      task: :extraction,
      source_peer_key: schema_context.source_peer_key,
      observation: Map.fetch!(message, "content"),
      prompt_version: @prompt_version
    ]

    case Model.generate_structured(
           :ingest_extractor,
           messages,
           Extraction,
           schema_context,
           opts
         ) do
      {:ok, items, provenance} ->
        {:ok,
         items
         |> Enum.reject(&(&1.update_operation == "no_op"))
         |> Enum.map(&Map.merge(&1, provenance))}

      {:error, error} ->
        {:error, error}
    end
  end

  defp schema_context(message, context) do
    source_peer_key = Map.fetch!(message, "peer_key")

    context
    |> Map.put_new(:account_id, Map.get(message, "account_id", Ecto.UUID.generate()))
    |> Map.put_new(:scope_id, Map.get(message, "scope_id", Ecto.UUID.generate()))
    |> Map.put_new(:source_peer_id, Map.get(message, "peer_id", Ecto.UUID.generate()))
    |> Map.put_new(:message_id, Map.get(message, "id"))
    |> Map.put(:source_peer_key, source_peer_key)
    |> Map.put(:scope_path, Map.fetch!(message, "scope_path"))
    |> Map.put(
      :known_peer_keys,
      message
      |> Map.get("known_peer_keys", [source_peer_key])
      |> Kernel.++([source_peer_key])
      |> Enum.uniq()
    )
  end
end
