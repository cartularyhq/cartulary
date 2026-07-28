# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Pipeline.Extractor do
  @moduledoc """
  Turns exactly one raw observation into candidate knowledge items.

  This is the model-facing half of ingest: it builds the extraction prompt,
  hands it to the model gateway with the structured schema, and returns the
  validated candidates. It writes nothing. Persisting candidates, merging them
  with existing statements, and submitting them to governance all happen in the
  pipeline caller, which is the only writer of knowledge.

  ## What extraction constrains

  - **One observation at a time.** Statements are extracted from a single raw
    message or document version, never from a batch, so provenance stays exact.
  - **Subject is resolved independently of source.** Who spoke and who a claim
    is about are separate. A peer subject must be one of the supplied known peer
    keys and a scope subject must be the current scope path; the schema rejects
    anything else, so this is enforced rather than merely requested.
  - **Third-party claims are marked hearsay** and their confidence is discounted
    during validation; the model's own confidence is an input, not the final
    value.
  - **Declining is explicit.** A candidate emitted with the `no_op` operation is
    dropped here rather than becoming an empty statement that would later look
    like real knowledge.

  ## Failure behaviour

  A provider error is returned unchanged rather than being papered over. The
  caller leaves the observation unstamped, so the durable job retries and the
  reconciler can find it again. There is deliberately no fallback to a different
  extractor: silently swapping the model would produce knowledge whose recorded
  provenance is wrong.

  Nothing here activates knowledge. Every returned candidate is still a proposal
  that must pass governance before retrieval can see it.
  """

  alias Cartulary.Model
  alias Cartulary.Model.Schema.Extraction

  # Identity of the extraction-and-pipeline contract this build implements. The
  # same string is configured as every model role's `pipeline_version` — which
  # is what gets stamped onto knowledge, provenance rows, and usage events — and
  # is the version `GET /api/health` reports. Those copies must move together.
  #
  # Changing this string is a deliberate contract transition, not a tidy-up: it
  # obliges a maintainer to add a changelog entry and refresh the contract
  # regression evidence, because stored provenance and recorded evaluation
  # results are compared against it.
  @pipeline_version "f5-1"

  # Names the prompt text below, and is passed to the gateway as a call option.
  # The `prompt_version` actually stamped on provenance and usage rows comes
  # from the resolved `ingest_extractor` role, not from here; the two are kept
  # equal on purpose, so editing the prompt means bumping both.
  @prompt_version "extract-1"

  @doc """
  The identity of the extraction-and-pipeline contract this build implements.
  """
  def pipeline_version, do: @pipeline_version

  @doc """
  The identity of the prompt wording currently used for extraction.
  """
  def prompt_version, do: @prompt_version

  @doc """
  Extracts candidate knowledge from one raw observation.

  `message` is a string-keyed map of the raw observation. It must carry
  `"content"`, `"peer_key"` (who produced the observation) and `"scope_path"`
  (where it was said); `"known_peer_keys"` bounds which peers a statement may be
  about. `context` supplies the surrounding identifiers — Account, scope, source
  peer, and the message or document version id — which are used for validation
  and provenance rather than being shown to the model.

  Returns `{:ok, candidates}`, where each candidate is the validated schema
  value merged with the provider, model, and version provenance that produced
  it. Candidates the model declined (`no_op`) are already removed, so an empty
  list means "this observation contains no durable memory", not a failure.

  Returns the generator's `{:error, reason}` unchanged: a provider transport or
  credential failure, or `{:error, {:structured_validation_failed, errors}}`
  when the model could not produce schema-valid output within the repair
  budget. Either way the caller can leave the observation unprocessed and let
  the durable job retry.

  Raises `KeyError` when the observation is missing `"content"`, `"peer_key"`,
  or `"scope_path"` — those are required by the caller that assembled it, and a
  missing one means the observation was built incorrectly rather than that the
  content was unusable.
  """
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

    # `observation` hands the raw text to the gateway as a call option; the
    # deterministic local provider reads it instead of re-parsing the prompt.
    # It travels no further: gateway options are not persisted, and observation
    # text must never reach usage records, telemetry, or job arguments.
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
        # Declined candidates are dropped here rather than downstream, so an
        # explicit "nothing to record" never reaches the writer as a row. Every
        # surviving candidate carries the provider/model/version provenance of
        # the call that produced it.
        {:ok,
         items
         |> Enum.reject(&(&1.update_operation == "no_op"))
         |> Enum.map(&Map.merge(&1, provenance))}

      {:error, error} ->
        {:error, error}
    end
  end

  # Assembles the validation context the schema uses to police the model's
  # output. The generated ids in the `put_new` fallbacks only ever apply to
  # standalone callers that pass no context (tooling and tests); the pipeline
  # always supplies the real Account, scope, and peer.
  #
  # The source peer key is appended to the known-peer list unconditionally: a
  # speaker must always be nameable as a subject of their own statement, even if
  # the caller forgot to include them.
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
