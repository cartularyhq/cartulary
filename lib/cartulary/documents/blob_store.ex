# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Documents.BlobStore do
  @moduledoc """
  Where original document bytes physically live, and the only door to them.

  This is an infrastructure seam, not a product decision. Swapping the local filesystem adapter
  for the S3-compatible one changes where objects are stored and nothing else: hashes, version
  numbering, supersession, tombstones, governance, and export semantics are identical either
  way. If a change here would alter any of those, it belongs in the document domain instead.

  ## Content addressing

  An object is named by the SHA-256 of its contents, under the owning Account. Three
  consequences follow, and code above this layer relies on all of them:

  - A put is idempotent. Storing the same bytes twice writes one object, so a retried ingest or
    a replayed connector page costs nothing.
  - A put can never overwrite different content, because different content has a different
    name. That is why ingest stores bytes *before* opening its database transaction: a rollback
    leaves at worst an unreferenced object, never a version row pointing at bytes that are
    absent or wrong.
  - Two documents with identical bytes share one object. Erasure must therefore delete an
    object only after confirming no other document still references it.

  ## Reference format

  A reference is a durable string stored on the version row, and its scheme decides which
  adapter can read it: `local://account-id/content-hash` or `s3://bucket/key`. References are
  resolved by scheme rather than by the currently configured adapter, so a deployment that
  migrates from local storage to S3 can still read everything it wrote before the switch.

  A third scheme, `legacy-db://`, marks versions written before bytes moved out of the database
  row. Those rows keep their payload inline; the reference exists only so the column can be
  non-null. Reading one through here fails on purpose, because the bytes are in the row and the
  version loader must take them from there.
  """

  @callback put(Ecto.UUID.t(), String.t(), binary(), keyword()) ::
              {:ok, String.t()} | {:error, term()}
  @callback get(String.t(), keyword()) :: {:ok, binary()} | {:error, term()}
  @callback delete(String.t(), keyword()) :: :ok | {:error, term()}
  @callback signed_url(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}

  @doc """
  Stores bytes under the Account and content hash, and returns their durable reference.

  The caller supplies the hash it already computed; this layer trusts it as the object's name
  and does not re-derive it. `opts` are passed through to the adapter; the S3 adapter reads
  `:bucket` and `:prefix`, and the local filesystem adapter ignores them.

  Always uses the *configured* adapter, since a new object has no reference to infer one from.
  Returns `{:ok, blob_ref}` or `{:error, reason}`. Storing bytes that are already present is a
  success, not a conflict.
  """
  def put(account_id, content_hash, bytes, opts \\ []) do
    adapter().put(account_id, content_hash, bytes, opts)
  end

  @doc """
  Reads the bytes behind a durable reference.

  Returns `{:ok, bytes}` or `{:error, reason}`. A pre-blob-store reference returns
  `{:error, :legacy_blob_requires_version_content}`: those bytes live in the version row and the
  caller must read them from there.
  """
  def get(blob_ref, opts \\ [])
  def get("legacy-db://" <> _rest, _opts), do: {:error, :legacy_blob_requires_version_content}
  def get(blob_ref, opts), do: adapter_for(blob_ref).get(blob_ref, opts)

  @doc """
  Deletes the object behind a reference, if it is still there.

  Deleting an object that is already gone is `:ok`, so erasure can be retried safely. A
  pre-blob-store reference is `:ok` with no work: there is no object to remove, only row
  content that goes when the row does.

  Callers must confirm no other document references these bytes before calling — content
  addressing means objects are shared.
  """
  def delete(blob_ref, opts \\ [])
  def delete("legacy-db://" <> _rest, _opts), do: :ok
  def delete(blob_ref, opts), do: adapter_for(blob_ref).delete(blob_ref, opts)

  @doc """
  Asks the owning adapter for a time-limited direct download URL.

  Returns `{:ok, url}` or `{:error, reason}`. The local filesystem adapter always refuses with
  `{:error, :local_blob_urls_are_not_exposed}`, because it has no way to hand out a link that
  expires. Callers must treat a URL as a capability: anyone holding it can read the document.
  """
  def signed_url(blob_ref, opts \\ []), do: adapter_for(blob_ref).signed_url(blob_ref, opts)

  defp adapter do
    :cartulary
    |> Application.fetch_env!(:documents)
    |> Keyword.fetch!(:blob_adapter)
  end

  # Reads follow the reference's own scheme rather than the current configuration, so objects
  # written before a storage migration stay readable afterwards. Only a reference with no
  # recognised scheme falls back to whatever is configured now.
  defp adapter_for("local://" <> _rest), do: Cartulary.Documents.BlobStore.Local
  defp adapter_for("s3://" <> _rest), do: Cartulary.Documents.BlobStore.S3
  defp adapter_for(_blob_ref), do: adapter()
end

defmodule Cartulary.Documents.BlobStore.Local do
  @moduledoc """
  Stores document bytes as content-addressed files on the local filesystem.

  This is the default adapter and the one that makes a single-node install fully self-contained:
  no object store, no cloud account, no credentials. Objects live under a configured root at
  `root/account-id/first-two-hash-chars/full-hash`. The two-character fan-out directory keeps
  any one directory from accumulating millions of entries, which some filesystems handle badly.

  ## Path safety

  Both path segments are derived from caller input, so both are validated before they are ever
  joined into a path: the Account must parse as a UUID and the hash must be exactly 64 lowercase
  hex characters. Nothing else can reach the filesystem, which is why the traversal warnings on
  these functions are suppressed. Loosening either check would turn a reference into an
  arbitrary path.

  ## Writes never clobber

  Files are created exclusively. An existing file with the same name already holds exactly the
  bytes being written — that is what content addressing guarantees — so an existing-file error
  is treated as success rather than an overwrite. The write is therefore idempotent, and two
  concurrent ingests of the same payload cannot corrupt each other.

  The blob root is a durable, backed-up location, not a cache. Deleting it loses original
  documents; the derived chunks and vectors in the database cannot reconstitute them.
  """

  @behaviour Cartulary.Documents.BlobStore

  # Exactly 64 lowercase hex characters: a SHA-256 digest and nothing else. This is a path
  # safety check as much as a format check.
  @hash_regex ~r/\A[0-9a-f]{64}\z/

  @doc """
  Writes bytes to the content-addressed path and returns a `local://` reference.

  Returns `{:ok, reference}`, or `{:error, :invalid_account_id | :invalid_content_hash}` when a
  segment fails validation, or a `File` error tuple when the directory or file cannot be
  created. An object that already exists is left untouched and reported as success.
  """
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

  @doc """
  Reads the file behind a `local://` reference.

  Returns `{:ok, bytes}`, `{:error, :invalid_blob_ref | :invalid_account_id |
  :invalid_content_hash}` for a malformed reference, or `{:error, :enoent}` when the object is
  missing from the blob root.
  """
  @impl true
  # The durable reference parser accepts validated UUID/hex segments only.
  # sobelow_skip ["Traversal.FileModule"]
  def get(blob_ref, _opts) do
    with {:ok, account_id, content_hash} <- parse_ref(blob_ref) do
      File.read(path(account_id, content_hash))
    end
  end

  @doc """
  Removes the file behind a `local://` reference.

  Returns `:ok`, including when the file is already gone, so a retried erasure converges instead
  of failing. Returns an error tuple for a malformed reference or an unreadable directory.
  """
  @impl true
  # The durable reference parser accepts validated UUID/hex segments only.
  # sobelow_skip ["Traversal.FileModule"]
  def delete(blob_ref, _opts) do
    with {:ok, account_id, content_hash} <- parse_ref(blob_ref) do
      # A missing file is the desired end state, not a failure.
      case File.rm(path(account_id, content_hash)) do
        :ok -> :ok
        {:error, :enoent} -> :ok
        error -> error
      end
    end
  end

  @doc """
  Always refuses: local files have no expiring URL to hand out.

  Returns `{:error, :local_blob_urls_are_not_exposed}` for a well-formed reference, or a parse
  error for a malformed one. Serving these files directly would mean an unauthenticated,
  non-expiring path to document content, so the adapter declines rather than improvising one.
  """
  @impl true
  def signed_url(blob_ref, _opts) do
    with {:ok, _account_id, _content_hash} <- parse_ref(blob_ref) do
      {:error, :local_blob_urls_are_not_exposed}
    end
  end

  # Exclusive create. Because the filename is the hash of the contents, a file that already
  # exists holds exactly these bytes, so :eexist is success and never an overwrite. Do not
  # "simplify" this to File.write/2 — that would truncate and rewrite an object another process
  # may be reading.
  #
  # Only the private, already-validated content-addressed path reaches this helper.
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

  # Splits and re-validates a stored reference. Validation is repeated on read and delete, not
  # only on write, because a reference read back from the database is still untrusted input as
  # far as the filesystem is concerned.
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

  # root/account/xx/full-hash. The Account segment keeps tenants physically separated on disk;
  # the two-character fan-out directory bounds how many entries land in one directory.
  # Both segments have already been validated by every caller of this helper.
  defp path(account_id, content_hash) do
    root =
      :cartulary
      |> Application.fetch_env!(:documents)
      |> Keyword.fetch!(:blob_root)

    Path.join([root, account_id, String.slice(content_hash, 0, 2), content_hash])
  end
end

defmodule Cartulary.Documents.BlobStore.S3 do
  @moduledoc """
  Stores document bytes in any S3-compatible object store.

  Selected purely by runtime configuration, and interchangeable with the local filesystem
  adapter: same content addressing, same reference contract, same idempotent put. Nothing about
  versioning, supersession, tombstones, or export changes because a deployment chose this one.
  It talks plain S3 through ExAws, so MinIO, Ceph, R2, and the like work as well as AWS.

  Objects are keyed `prefix/account-id/content-hash` and referenced as `s3://bucket/key`. The
  bucket is part of the stored reference, so moving buckets is a data migration, not a config
  change: existing references keep naming the old bucket.

  Credentials, region, and endpoint come from ExAws configuration rather than from anything
  stored in the database. The bucket must be private — these objects are original user
  documents, and the only intended way to hand one out is a short-lived presigned URL.
  """

  @behaviour Cartulary.Documents.BlobStore

  @doc """
  Uploads bytes under the content-addressed key and returns an `s3://` reference.

  `opts` may override `:bucket` and `:prefix`; otherwise both come from application
  configuration. Returns `{:ok, reference}`, `{:error, :s3_bucket_missing}` when no bucket is
  configured, or whatever error ExAws reports for the request. Re-uploading identical bytes
  rewrites the same key with the same content, so a retry is harmless.
  """
  @impl true
  def put(account_id, content_hash, bytes, opts)
      when is_binary(account_id) and is_binary(content_hash) and is_binary(bytes) do
    with {:ok, bucket} <- bucket(opts),
         key = key(account_id, content_hash, opts),
         {:ok, _response} <- ExAws.S3.put_object(bucket, key, bytes) |> ExAws.request() do
      {:ok, "s3://#{bucket}/#{key}"}
    end
  end

  @doc """
  Downloads the object behind an `s3://` reference.

  The bucket comes from the reference itself, not from configuration, so an object written
  before a bucket change is still readable. Returns `{:ok, bytes}`,
  `{:error, :invalid_blob_ref}`, or the ExAws error for the request.
  """
  @impl true
  def get(blob_ref, _opts) do
    with {:ok, bucket, key} <- parse_ref(blob_ref),
         {:ok, response} <- ExAws.S3.get_object(bucket, key) |> ExAws.request() do
      {:ok, Map.fetch!(response, :body)}
    end
  end

  @doc """
  Deletes the object behind an `s3://` reference.

  Returns `:ok`, `{:error, :invalid_blob_ref}`, or the ExAws error. S3 treats deleting an absent
  key as success, so a retried erasure converges.

  Callers must have confirmed no other document references these bytes: content addressing means
  an identical file uploaded twice is one shared object.
  """
  @impl true
  def delete(blob_ref, _opts) do
    with {:ok, bucket, key} <- parse_ref(blob_ref),
         {:ok, _response} <- ExAws.S3.delete_object(bucket, key) |> ExAws.request() do
      :ok
    end
  end

  @doc """
  Mints a short-lived presigned GET URL for the object.

  `opts[:expires_in]` is a lifetime in seconds and defaults to 300 (five minutes) — long enough
  for a browser to start a download, short enough that a leaked link stops working quickly.
  Returns `{:ok, url}` or an error tuple. Treat the URL as a bearer capability: it carries no
  further authorization check, so anyone who obtains it can read the document until it expires.
  """
  @impl true
  def signed_url(blob_ref, opts) do
    with {:ok, bucket, key} <- parse_ref(blob_ref) do
      config = ExAws.Config.new(:s3)
      ExAws.S3.presigned_url(config, :get, bucket, key, expires_in: opts[:expires_in] || 300)
    end
  end

  # Fails closed rather than inventing a default bucket name, which would silently scatter
  # documents into whatever bucket happened to match.
  defp bucket(opts) do
    value = opts[:bucket] || document_config()[:s3_bucket]
    if is_binary(value) and value != "", do: {:ok, value}, else: {:error, :s3_bucket_missing}
  end

  # prefix/account/hash. The prefix lets one bucket host more than just Cartulary, and the
  # Account segment keeps tenants separated in the key space. Surrounding slashes are trimmed so
  # a prefix written as "/files/" does not produce a doubled or leading separator.
  defp key(account_id, content_hash, opts) do
    prefix = opts[:prefix] || document_config()[:s3_prefix] || "cartulary"
    Enum.join([String.trim(prefix, "/"), account_id, content_hash], "/")
  end

  # Splits "s3://bucket/key". The key keeps every remaining slash, since object keys are allowed
  # to contain them.
  defp parse_ref("s3://" <> rest) do
    case String.split(rest, "/", parts: 2) do
      [bucket, key] when bucket != "" and key != "" -> {:ok, bucket, key}
      _other -> {:error, :invalid_blob_ref}
    end
  end

  defp parse_ref(_blob_ref), do: {:error, :invalid_blob_ref}
  defp document_config, do: Application.fetch_env!(:cartulary, :documents)
end
