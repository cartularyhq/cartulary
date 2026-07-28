# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Documents.Parser do
  @moduledoc """
  Turns raw document bytes into plain text that the chunker and the extractor can work on.

  Three routes, chosen by media type. All of them run in-process on the BEAM, using native
  libraries where real parsing is needed, rather than shelling out to a converter or calling a
  service. That is deliberate: a single-node install must be able to read a PDF offline.

  - **Markdown** is parsed to a CommonMark document tree and rendered back out as normalised
    Markdown. The round trip means chunking always sees a canonical form, and any parse or
    render problem surfaces here rather than as strange chunk boundaries later.
  - **Plain text, CSV, and JSON** are used as-is when they are valid UTF-8. There is nothing to
    extract, and re-encoding them could only lose fidelity.
  - **Everything else** — PDF, Office formats, email, HTML, and the rest — goes to a native
    text-extraction library that identifies the format itself.

  Every result reports which parser produced it, and that name is safe to record in telemetry.
  The extracted text itself is not: it is document content and must never reach spans, audit
  metadata, or job arguments.

  Parsing failures are ordinary error tuples. The caller marks the version failed and leaves the
  bytes, the audit entry, and the retryable job in place, so a parser fix makes the document
  processable without re-ingesting it.
  """

  @markdown_types ~w(text/markdown text/x-markdown)
  # Formats whose bytes already *are* their text. No extractor could improve on them, and
  # running one would risk mangling structure that later chunking depends on.
  @plain_types ~w(text/plain text/csv application/json)

  @doc """
  Extracts text from `bytes` according to `media_type`.

  Returns `{:ok, %{text: text, metadata: metadata, format: :markdown | :plaintext}}`. The
  `format` is what the chunker uses to pick boundary rules, and `metadata` always carries a
  `"parser"` key naming the route taken.

  Returns `{:error, :invalid_utf8_markdown}` for Markdown that is not valid UTF-8, the parser's
  own error for Markdown that will not parse or render, and
  `{:error, {:document_extraction_failed, reason}}` when the native extractor fails.

  Note that a declared plain-text type whose bytes are *not* valid UTF-8 does not fail here: it
  falls through to the native extractor, which is better placed to guess an encoding.
  """
  def extract(bytes, media_type) when is_binary(bytes) and is_binary(media_type) do
    cond do
      media_type in @markdown_types ->
        extract_markdown(bytes)

      media_type in @plain_types and String.valid?(bytes) ->
        {:ok, %{text: bytes, metadata: %{"parser" => "text"}, format: :plaintext}}

      true ->
        extract_native(bytes, media_type)
    end
  end

  # Parse to a document tree, then render it back. The round trip normalises the Markdown so the
  # chunker always sees one canonical form, and it surfaces a parse or render failure here
  # instead of downstream. The node count is a cheap, content-free structural size signal.
  defp extract_markdown(bytes) do
    with true <- String.valid?(bytes),
         {:ok, document} <- MDEx.parse_document(bytes),
         {:ok, markdown} <- MDEx.to_markdown(document) do
      {:ok,
       %{
         text: markdown,
         metadata: %{"parser" => "mdex", "ast_node_count" => length(document.nodes)},
         format: :markdown
       }}
    else
      false -> {:error, :invalid_utf8_markdown}
      {:error, error} -> {:error, error}
    end
  end

  # The catch-all route: a native extractor that sniffs the format itself, so PDFs, Office
  # documents, email, and HTML all arrive here.
  defp extract_native(bytes, media_type) do
    # Upper bound in characters on the text taken from one document, from configuration. It
    # guards the node against a single pathological file exhausting memory during parsing; text
    # beyond the limit is simply not extracted, so raising it raises peak memory use.
    max_length =
      :cartulary
      |> Application.fetch_env!(:documents)
      |> Keyword.fetch!(:max_extract_length)

    case ExtractousEx.extract_from_bytes(bytes, max_length: max_length) do
      {:ok, result} ->
        {:ok,
         %{
           text: result.content,
           metadata:
             result.metadata
             |> stringify_keys()
             |> Map.put("parser", "extractous_ex")
             |> Map.put("media_type", media_type),
           format: :plaintext
         }}

      {:error, error} ->
        {:error, {:document_extraction_failed, error}}
    end
  end

  # Extractor metadata is stored in a JSON-backed column, so it is flattened to string keys and
  # JSON-safe values here. Anything that is not a string, number, boolean, list, map, or nil is
  # inspected into a string rather than dropped or allowed to break serialisation.
  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), normalize_value(value)} end)
  end

  defp normalize_value(value) when is_map(value), do: stringify_keys(value)
  defp normalize_value(value) when is_list(value), do: Enum.map(value, &normalize_value/1)

  defp normalize_value(value) when is_binary(value) or is_number(value) or is_boolean(value),
    do: value

  defp normalize_value(nil), do: nil
  defp normalize_value(value), do: inspect(value)
end

defmodule Cartulary.Documents.Chunker do
  @moduledoc """
  Splits extracted document text into retrievable pieces and attaches an embedding to each.

  Chunking is format-aware: Markdown is split on structural boundaries, plain text on textual
  ones, and each piece records the byte range of the extracted text it covers.

  Everything produced here is a **rebuildable cache**. Boundaries, text, and vectors can all be
  regenerated from the version's stored bytes, which is why changing chunk geometry or the
  embedding model is a rebuild rather than a migration, and why chunks are left out of logical
  exports entirely.

  ## Embedding identity travels with the vector

  Vectors are produced through the model gateway's Account-level embedding role, never by
  calling a provider directly. Each returned chunk carries the provider, model, model version,
  and dimension count that made its vector, because vectors from different identities are not
  comparable. A caller that finds a mismatch must re-embed; it must never reuse or substitute a
  vector produced under a different identity.

  ## Failure

  Chunking and embedding failures are error tuples, not exceptions. Nothing durable has been
  written at that point: the version, its bytes, and its retryable job survive, so an embedding
  provider outage delays derivation without losing the document.
  """

  alias Cartulary.Model.Embedding
  alias Cartulary.Pipeline.Idempotency

  @doc """
  Splits `text` into chunks and embeds them in one batch.

  `format` is `:markdown` or `:plaintext`, as reported by the parser, and selects the boundary
  rules. `context` carries the Account, scope, and actor the embedding call is made under.

  Returns `{:ok, chunks}`, where each chunk is a map with `:position`, `:start_byte`,
  `:end_byte`, `:text`, `:content_hash`, `:embedding`, and the four embedding-identity fields —
  exactly the shape the chunk resource's upsert accepts. Text that yields no chunks returns
  `{:ok, []}`.

  Returns `{:error, {:chunking_failed, reason}}` when splitting fails, and passes through any
  error from the embedding call unchanged.
  """
  def chunk_and_embed(text, format, context)
      when is_binary(text) and format in [:markdown, :plaintext] and is_map(context) do
    # Chunk size and overlap are character counts from application configuration. The overlap
    # keeps a sentence straddling a boundary retrievable from either side. Changing them does
    # not rewrite existing rows: documents keep their old boundaries until they are rebuilt.
    config = Application.fetch_env!(:cartulary, :documents)

    chunks =
      TextChunker.split(text,
        chunk_size: Keyword.fetch!(config, :chunk_size),
        chunk_overlap: Keyword.fetch!(config, :chunk_overlap),
        format: format
      )

    case chunks do
      {:error, error} ->
        {:error, {:chunking_failed, error}}

      [] ->
        {:ok, []}

      chunks ->
        # Blank chunks are dropped before positions are assigned, so positions stay dense and
        # no vector is spent on whitespace. Positions are the upsert key, which is why they are
        # numbered after filtering rather than before.
        ingestions =
          chunks
          |> Enum.reject(&(String.trim(&1.text) == ""))
          |> Enum.with_index()
          |> Enum.map(fn {chunk, position} ->
            %{
              position: position,
              start_byte: chunk.start_byte,
              end_byte: chunk.end_byte,
              text: chunk.text,
              content_hash: Idempotency.content_hash(chunk.text)
            }
          end)

        texts = Enum.map(ingestions, & &1.text)

        # One batched embedding call for the whole document, then the RAG library zips the
        # vectors back onto the chunks. The pinned-match function head is a guard, not
        # indirection: the library is handed exactly the texts already embedded, so if it ever
        # asked for a different batch this would raise instead of silently pairing the wrong
        # vector with a chunk.
        with {:ok, embedding} <- Embedding.embed(texts, context),
             embedded <-
               Rag.Embedding.generate_embeddings_batch(
                 ingestions,
                 fn ^texts, [] -> {:ok, embedding.vectors} end,
                 text_key: :text,
                 embedding_key: :embedding
               ) do
          # Pin the identity that produced these vectors onto every chunk. Without it, a later
          # model change could not tell which rows still hold comparable vectors.
          {:ok,
           Enum.map(embedded, fn chunk ->
             Map.merge(chunk, %{
               embedding_provider: embedding.provider,
               embedding_model: embedding.model,
               embedding_version: embedding.version,
               embedding_dimensions: embedding.dimensions
             })
           end)}
        end
    end
  end
end
