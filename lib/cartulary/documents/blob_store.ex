# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Documents.BlobStore do
  @moduledoc """
  Infrastructure port for immutable document bytes.

  Blob references are durable, but adapters only decide where bytes live.
  Product behavior, hashes, versioning, and erasure remain in the document
  domain.
  """

  @callback put(Ecto.UUID.t(), String.t(), binary(), keyword()) ::
              {:ok, String.t()} | {:error, term()}
  @callback get(String.t(), keyword()) :: {:ok, binary()} | {:error, term()}
  @callback delete(String.t(), keyword()) :: :ok | {:error, term()}
  @callback signed_url(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}

  def put(account_id, content_hash, bytes, opts \\ []) do
    adapter().put(account_id, content_hash, bytes, opts)
  end

  def get(blob_ref, opts \\ [])
  def get("legacy-db://" <> _rest, _opts), do: {:error, :legacy_blob_requires_version_content}
  def get(blob_ref, opts), do: adapter_for(blob_ref).get(blob_ref, opts)

  def delete(blob_ref, opts \\ [])
  def delete("legacy-db://" <> _rest, _opts), do: :ok
  def delete(blob_ref, opts), do: adapter_for(blob_ref).delete(blob_ref, opts)
  def signed_url(blob_ref, opts \\ []), do: adapter_for(blob_ref).signed_url(blob_ref, opts)

  defp adapter do
    :cartulary
    |> Application.fetch_env!(:documents)
    |> Keyword.fetch!(:blob_adapter)
  end

  defp adapter_for("local://" <> _rest), do: Cartulary.Documents.BlobStore.Local
  defp adapter_for("s3://" <> _rest), do: Cartulary.Documents.BlobStore.S3
  defp adapter_for(_blob_ref), do: adapter()
end

defmodule Cartulary.Documents.BlobStore.Local do
  @moduledoc "Content-addressed local filesystem blob adapter for free core."

  @behaviour Cartulary.Documents.BlobStore

  @hash_regex ~r/\A[0-9a-f]{64}\z/

  @impl true
  # Account and hash path segments are validated as UUID/hex below.
  # sobelow_skip ["Traversal.FileModule"]
  def put(account_id, content_hash, bytes, _opts)
      when is_binary(account_id) and is_binary(content_hash) and is_binary(bytes) do
    with :ok <- validate_account_id(account_id),
         :ok <- validate_hash(content_hash),
         path = path(account_id, content_hash),
         :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- put_if_missing(path, bytes) do
      {:ok, "local://#{account_id}/#{content_hash}"}
    end
  end

  @impl true
  # The durable reference parser accepts validated UUID/hex segments only.
  # sobelow_skip ["Traversal.FileModule"]
  def get(blob_ref, _opts) do
    with {:ok, account_id, content_hash} <- parse_ref(blob_ref) do
      File.read(path(account_id, content_hash))
    end
  end

  @impl true
  # The durable reference parser accepts validated UUID/hex segments only.
  # sobelow_skip ["Traversal.FileModule"]
  def delete(blob_ref, _opts) do
    with {:ok, account_id, content_hash} <- parse_ref(blob_ref) do
      case File.rm(path(account_id, content_hash)) do
        :ok -> :ok
        {:error, :enoent} -> :ok
        error -> error
      end
    end
  end

  @impl true
  def signed_url(blob_ref, _opts) do
    with {:ok, _account_id, _content_hash} <- parse_ref(blob_ref) do
      {:error, :local_blob_urls_are_not_exposed}
    end
  end

  # Only the private validated content-addressed path reaches this helper.
  # sobelow_skip ["Traversal.FileModule"]
  defp put_if_missing(path, bytes) do
    case File.open(path, [:write, :binary, :exclusive]) do
      {:ok, io} ->
        result = IO.binwrite(io, bytes)
        :ok = File.close(io)
        result

      {:error, :eexist} ->
        :ok

      error ->
        error
    end
  end

  defp parse_ref("local://" <> rest) do
    case String.split(rest, "/", parts: 2) do
      [account_id, content_hash] ->
        with :ok <- validate_account_id(account_id),
             :ok <- validate_hash(content_hash) do
          {:ok, account_id, content_hash}
        end

      _other ->
        {:error, :invalid_blob_ref}
    end
  end

  defp parse_ref(_blob_ref), do: {:error, :invalid_blob_ref}

  defp validate_account_id(account_id) do
    case Ecto.UUID.cast(account_id) do
      {:ok, ^account_id} -> :ok
      _other -> {:error, :invalid_account_id}
    end
  end

  defp validate_hash(content_hash) do
    if Regex.match?(@hash_regex, content_hash), do: :ok, else: {:error, :invalid_content_hash}
  end

  defp path(account_id, content_hash) do
    root =
      :cartulary
      |> Application.fetch_env!(:documents)
      |> Keyword.fetch!(:blob_root)

    Path.join([root, account_id, String.slice(content_hash, 0, 2), content_hash])
  end
end

defmodule Cartulary.Documents.BlobStore.S3 do
  @moduledoc "S3-compatible ExAws blob adapter selected only by runtime configuration."

  @behaviour Cartulary.Documents.BlobStore

  @impl true
  def put(account_id, content_hash, bytes, opts)
      when is_binary(account_id) and is_binary(content_hash) and is_binary(bytes) do
    with {:ok, bucket} <- bucket(opts),
         key = key(account_id, content_hash, opts),
         {:ok, _response} <- ExAws.S3.put_object(bucket, key, bytes) |> ExAws.request() do
      {:ok, "s3://#{bucket}/#{key}"}
    end
  end

  @impl true
  def get(blob_ref, _opts) do
    with {:ok, bucket, key} <- parse_ref(blob_ref),
         {:ok, response} <- ExAws.S3.get_object(bucket, key) |> ExAws.request() do
      {:ok, Map.fetch!(response, :body)}
    end
  end

  @impl true
  def delete(blob_ref, _opts) do
    with {:ok, bucket, key} <- parse_ref(blob_ref),
         {:ok, _response} <- ExAws.S3.delete_object(bucket, key) |> ExAws.request() do
      :ok
    end
  end

  @impl true
  def signed_url(blob_ref, opts) do
    with {:ok, bucket, key} <- parse_ref(blob_ref) do
      config = ExAws.Config.new(:s3)
      ExAws.S3.presigned_url(config, :get, bucket, key, expires_in: opts[:expires_in] || 300)
    end
  end

  defp bucket(opts) do
    value = opts[:bucket] || document_config()[:s3_bucket]
    if is_binary(value) and value != "", do: {:ok, value}, else: {:error, :s3_bucket_missing}
  end

  defp key(account_id, content_hash, opts) do
    prefix = opts[:prefix] || document_config()[:s3_prefix] || "cartulary"
    Enum.join([String.trim(prefix, "/"), account_id, content_hash], "/")
  end

  defp parse_ref("s3://" <> rest) do
    case String.split(rest, "/", parts: 2) do
      [bucket, key] when bucket != "" and key != "" -> {:ok, bucket, key}
      _other -> {:error, :invalid_blob_ref}
    end
  end

  defp parse_ref(_blob_ref), do: {:error, :invalid_blob_ref}
  defp document_config, do: Application.fetch_env!(:cartulary, :documents)
end
