# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Model.Config do
  @moduledoc """
  Resolves one pinned Account-level configuration for each model role.

  Persisted Ash configuration wins over runtime defaults. Per-scope overrides
  are deliberately not selected in F5, matching `AD-MODEL-1`.
  """

  alias Cartulary.Model.ModelRoleConfig

  require Ash.Query

  @roles ~w(embedder ingest_extractor dream_reasoner dialectic_agent)a
  @aliases %{
    ingest: :ingest_extractor,
    dream: :dream_reasoner,
    ask: :dialectic_agent,
    reranker: :dream_reasoner
  }

  defmodule Role do
    @moduledoc false

    @enforce_keys [
      :role,
      :provider,
      :model,
      :model_version,
      :prompt_version,
      :pipeline_version,
      :config_version,
      :options
    ]
    @type t :: %__MODULE__{}
    defstruct [
      :role,
      :provider,
      :model,
      :model_version,
      :prompt_version,
      :pipeline_version,
      :embedding_dimensions,
      :config_version,
      :options
    ]
  end

  def roles, do: @roles

  def normalize_role(role) when role in @roles, do: role
  def normalize_role(role) when is_map_key(@aliases, role), do: Map.fetch!(@aliases, role)
  def normalize_role(role), do: raise(ArgumentError, "unknown model role: #{inspect(role)}")

  def resolve(role, context) when is_map(context) do
    role = normalize_role(role)

    case persisted(role, context) do
      nil -> runtime(role)
      record -> from_record(role, record)
    end
  end

  def local_fallback?(%Role{provider: "deterministic"}), do: true
  def local_fallback?(_config), do: false

  def provenance(%Role{} = config) do
    %{
      provider: config.provider,
      model: config.model,
      model_version: config.model_version,
      prompt_version: config.prompt_version,
      pipeline_version: config.pipeline_version
    }
  end

  def embedding_identity(%Role{role: :embedder} = config) do
    %{
      provider: config.provider,
      model: config.model,
      version: config.model_version,
      dimensions: config.embedding_dimensions
    }
  end

  defp persisted(role, %{account_id: account_id, actor: actor})
       when is_binary(account_id) and not is_nil(actor) do
    ModelRoleConfig
    |> Ash.Query.filter(role == ^Atom.to_string(role) and active == true and is_nil(scope_id))
    |> Ash.Query.sort(version: :desc)
    |> Ash.Query.limit(1)
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read_one!(actor: actor)
  end

  defp persisted(_role, _context), do: nil

  defp runtime(role) do
    roles = Application.fetch_env!(:cartulary, :model_roles)
    values = roles |> Keyword.fetch!(role) |> Map.new()

    %Role{
      role: role,
      provider: Map.fetch!(values, :provider),
      model: Map.fetch!(values, :model),
      model_version: Map.get(values, :model_version, "unversioned"),
      prompt_version: Map.get(values, :prompt_version, "none"),
      pipeline_version: Map.get(values, :pipeline_version, "f5-1"),
      embedding_dimensions: Map.get(values, :embedding_dimensions),
      config_version: Map.get(values, :config_version, 1),
      options: values |> Map.get(:options, %{}) |> stringify_keys()
    }
  end

  defp from_record(role, record) do
    %Role{
      role: role,
      provider: record.provider,
      model: record.model,
      model_version: record.model_version,
      prompt_version: record.prompt_version,
      pipeline_version: record.pipeline_version,
      embedding_dimensions: record.embedding_dimensions,
      config_version: record.version,
      options: stringify_keys(record.options)
    }
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end
end
