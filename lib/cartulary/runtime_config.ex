# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.RuntimeConfig do
  @moduledoc """
  Checks the node's infrastructure settings at boot and refuses to start on a bad one.

  This runs before any child of the supervision tree, which is the whole point:
  a node with a missing database URL, an unreadable database binary, a relative
  blob path, or an incompletely configured model role should stop immediately
  with a message naming the setting, not start, accept traffic, and fail later
  against storage it should never have touched.

  Only node-local deployment settings are checked here — where the database
  lives, where blobs go, which model each role uses. Anything about who may do
  what belongs in the resources' own policies and is deliberately absent.

  Error messages name the thing an operator would go and edit — usually the
  environment variable, otherwise the role and key at fault — and never include
  a secret value.

  This module is also the read path for the few deployment questions the rest of
  the system legitimately asks: which database mode is in effect and whether the
  node migrates itself. Nothing else may branch on the database mode. Whether
  the release supervises its own PostgreSQL or connects to one an operator runs
  changes where the database lives, never what the product does.
  """

  # The only two supported answers to "where does PostgreSQL live". Both run the
  # same release, schema, queues, and guarantees.
  @database_modes ~w(pg0 external)

  # Blob storage backends for document bytes. An unknown module is rejected
  # rather than attempted, so a typo cannot end with documents written nowhere.
  @blob_adapters [Cartulary.Documents.BlobStore.Local, Cartulary.Documents.BlobStore.S3]
  import Bitwise, only: [band: 2]

  @doc """
  Validates every infrastructure setting this node needs, or raises.

  Called as the first statement of application startup, before the supervision
  tree exists. Returns `:ok` when the database settings for the active mode, the
  blob adapter, and every model role are structurally sound. Raises a
  `RuntimeError` naming the offending setting otherwise.

  Only the mode actually in use is checked, so leftover settings for the other
  database mode never block a boot.
  """
  def validate! do
    database = Application.fetch_env!(:cartulary, :database)
    mode = Keyword.fetch!(database, :mode)

    unless mode in @database_modes do
      raise "CARTULARY_DATABASE_MODE must be one of: #{Enum.join(@database_modes, ", ")}"
    end

    validate_database!(mode, database)
    validate_documents!()
    validate_models!()
    :ok
  end

  @doc """
  The configured database mode, `"pg0"` or `"external"`.

  Its only use today is behind `pg0?/0`, which decides whether this node starts
  and stops its own database. Do not use it to change product behaviour: the two
  modes exist to move the database, not to fork the system.
  """
  def database_mode do
    :cartulary
    |> Application.fetch_env!(:database)
    |> Keyword.fetch!(:mode)
  end

  @doc """
  True when this node supervises its own embedded PostgreSQL server.

  The single legitimate use is deciding whether to start and stop that server.
  """
  def pg0?, do: database_mode() == "pg0"

  @doc """
  True when the node should run pending migrations itself during startup.

  Turnkey installs migrate on boot; operators under change control turn this off
  and run migrations as a separate, reviewed step before deploying.
  """
  def auto_migrate? do
    :cartulary
    |> Application.fetch_env!(:database)
    |> Keyword.fetch!(:auto_migrate)
  end

  # Self-supervised mode: the release is about to launch a real database
  # process, so everything it needs must be present and usable *now*. Absolute
  # paths are required because the launcher's working directory is not something
  # an operator can reason about, and a relative path would resolve differently
  # depending on how the node was started.
  defp validate_database!("pg0", database) do
    pg0 = Keyword.fetch!(database, :pg0)
    binary = Keyword.fetch!(pg0, :binary)
    data_dir = Keyword.fetch!(pg0, :data_dir)
    port = Keyword.fetch!(pg0, :port)

    unless Path.type(binary) == :absolute do
      raise "CARTULARY_PG0_BINARY must be an absolute path"
    end

    unless File.regular?(binary) do
      raise "pinned pg0 binary is missing at #{binary}"
    end

    # Readable and executable by *someone*: `0o111` is the owner/group/other
    # execute bits, and any one of them set is enough to try. A packaged
    # release whose archive lost the execute bit is the failure this catches,
    # and catching it here beats a cryptic exec error mid-startup.
    case File.stat(binary) do
      {:ok, %{access: access, mode: mode}}
      when access in [:read_write, :read] and band(mode, 0o111) != 0 ->
        :ok

      _other ->
        raise "pinned pg0 binary is not readable and executable at #{binary}"
    end

    unless Path.type(data_dir) == :absolute do
      raise "CARTULARY_PG0_DATA_DIR must be an absolute path"
    end

    unless port in 1..65_535 do
      raise "CARTULARY_PG0_PORT must be between 1 and 65535"
    end
  end

  # Operator-run mode: only the connection URL matters here, and it is required
  # only where a missing one is unambiguously a mistake — a production release.
  # A source checkout or a Mix task legitimately runs without it against a
  # developer's own local database, so demanding it everywhere would break
  # ordinary tooling.
  defp validate_database!("external", database) do
    if Keyword.get(database, :database_url) in [nil, ""] and
         Application.get_env(:cartulary, :require_database_url, false) do
      raise "DATABASE_URL is required when CARTULARY_DATABASE_MODE=external"
    end
  end

  # Where document bytes go. Each adapter has one setting that cannot be
  # defaulted: a local root that must be absolute for the same reason the
  # database directory must be, and a bucket name that has no sensible default
  # at all. Checking them at boot means a document upload cannot be the thing
  # that discovers the storage was never configured.
  defp validate_documents! do
    documents = Application.fetch_env!(:cartulary, :documents)
    adapter = Keyword.fetch!(documents, :blob_adapter)

    unless adapter in @blob_adapters do
      raise "configured blob adapter is not supported"
    end

    case adapter do
      Cartulary.Documents.BlobStore.Local ->
        root = Keyword.fetch!(documents, :blob_root)

        unless Path.type(root) == :absolute do
          raise "CARTULARY_BLOB_ROOT must be an absolute path"
        end

      Cartulary.Documents.BlobStore.S3 ->
        if Keyword.get(documents, :s3_bucket) in [nil, ""] do
          raise "CARTULARY_S3_BUCKET is required when CARTULARY_BLOB_ADAPTER=s3"
        end
    end
  end

  # Every model role the system knows about must be configured, and each must
  # name a provider, a model, a model version, and a pipeline version. The two
  # version strings are not optional bookkeeping: they are stamped onto
  # everything the model produces, and an embedding whose identity does not
  # match the current one has to be regenerated rather than silently reused. A
  # role left blank here would produce output nobody can later attribute.
  #
  # Structure only — no credential is checked and no provider is contacted, so
  # this stays fast and offline.
  defp validate_models! do
    roles = Application.fetch_env!(:cartulary, :model_roles)
    expected = Cartulary.Model.Config.roles()

    missing = Enum.reject(expected, &Keyword.has_key?(roles, &1))
    if missing != [], do: raise("missing model role configuration: #{inspect(missing)}")

    Enum.each(expected, fn role ->
      config = roles |> Keyword.fetch!(role) |> Map.new()

      for key <- [:provider, :model, :model_version, :pipeline_version] do
        if Map.get(config, key) in [nil, ""] do
          raise "model role #{role} is missing #{key}"
        end
      end
    end)
  end
end
