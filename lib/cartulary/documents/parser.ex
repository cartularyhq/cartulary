# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Documents.Parser do
  @moduledoc "Native F6 extraction through MDEx for Markdown and ExtractousEx otherwise."

  @markdown_types ~w(text/markdown text/x-markdown)
  @plain_types ~w(text/plain text/csv application/json)

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

  defp extract_native(bytes, media_type) do
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
  F6 RAG chunking strategy.

  TextChunker provides semantic boundaries and byte offsets; bitcrowd/rag's
  embedding stage attaches vectors from Cartulary's pinned F5 model role.
  """

  alias Cartulary.Model.Embedding
  alias Cartulary.Pipeline.Idempotency

  def chunk_and_embed(text, format, context)
      when is_binary(text) and format in [:markdown, :plaintext] and is_map(context) do
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

        with {:ok, embedding} <- Embedding.embed(texts, context),
             embedded <-
               Rag.Embedding.generate_embeddings_batch(
                 ingestions,
                 fn ^texts, [] -> {:ok, embedding.vectors} end,
                 text_key: :text,
                 embedding_key: :embedding
               ) do
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
