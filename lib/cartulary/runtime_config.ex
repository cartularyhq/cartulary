# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.RuntimeConfig do
  @moduledoc """
  Fail-fast validation for F10 infrastructure configuration.

  Policy belongs in Ash resources. This module validates only node-local
  deployment settings before any durable service starts.
  """

  @database_modes ~w(pg0 external)
  @blob_adapters [Cartulary.Documents.BlobStore.Local, Cartulary.Documents.BlobStore.S3]
  import Bitwise, only: [band: 2]

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

  def database_mode do
    :cartulary
    |> Application.fetch_env!(:database)
    |> Keyword.fetch!(:mode)
  end

  def pg0?, do: database_mode() == "pg0"

  def auto_migrate? do
    :cartulary
    |> Application.fetch_env!(:database)
    |> Keyword.fetch!(:auto_migrate)
  end

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

  defp validate_database!("external", database) do
    if Keyword.get(database, :database_url) in [nil, ""] and
         Application.get_env(:cartulary, :require_database_url, false) do
      raise "DATABASE_URL is required when CARTULARY_DATABASE_MODE=external"
    end
  end

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
