# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Model do
  @moduledoc """
  Provider-neutral model capabilities and the Ash domain for versioned role
  configuration.

  All model calls enter through this module so provider selection, provenance,
  usage metering, and test injection have one boundary.
  """

  use Ash.Domain

  resources do
    resource Cartulary.Model.ModelRoleConfig
  end

  defdelegate role_config(role, context), to: Cartulary.Model.Config, as: :resolve

  defdelegate generate_structured(role, messages, schema, context, opts \\ []),
    to: Cartulary.Model.StructuredGenerator,
    as: :generate

  defdelegate chat(role, messages, context, opts \\ []), to: Cartulary.Model.Gateway
  defdelegate embed(texts, context, opts \\ []), to: Cartulary.Model.Embedding
  defdelegate rerank(query, documents, context, opts \\ []), to: Cartulary.Model.Gateway
end

defmodule Cartulary.Model.ValidateSecretReferences do
  @moduledoc false

  use Ash.Resource.Validation

  @raw_secret_keys ~w(apikey authorization password secret token accesstoken authtoken bearer)

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, _opts, _context) do
    options = Ash.Changeset.get_attribute(changeset, :options) || %{}

    if raw_secret_key?(options) do
      {:error, field: :options, message: "must contain secret references, never raw credentials"}
    else
      :ok
    end
  end

  defp raw_secret_key?(map) when is_map(map) do
    Enum.any?(map, fn {key, value} ->
      normalized =
        key
        |> to_string()
        |> String.downcase()
        |> String.replace(~r/[-_]/, "")

      normalized in @raw_secret_keys or raw_secret_key?(value)
    end)
  end

  defp raw_secret_key?(values) when is_list(values), do: Enum.any?(values, &raw_secret_key?/1)
  defp raw_secret_key?(_value), do: false
end

defmodule Cartulary.Model.ModelRoleConfig do
  @moduledoc false

  use Cartulary.Resource, domain: Cartulary.Model, table: "model_role_configs"

  multitenancy do
    strategy :attribute
    attribute :account_id
  end

  actions do
    defaults [:read]

    create :create do
      accept [
        :scope_id,
        :role,
        :provider,
        :model,
        :model_version,
        :prompt_version,
        :pipeline_version,
        :embedding_dimensions,
        :options,
        :version,
        :active
      ]

      validate attribute_in(:role, ~w(embedder ingest_extractor dream_reasoner dialectic_agent))
      validate Cartulary.Model.ValidateSecretReferences
    end

    update :update do
      require_atomic? false

      accept [
        :provider,
        :model,
        :model_version,
        :prompt_version,
        :pipeline_version,
        :embedding_dimensions,
        :options,
        :version,
        :active
      ]

      validate attribute_in(:role, ~w(embedder ingest_extractor dream_reasoner dialectic_agent))
      validate Cartulary.Model.ValidateSecretReferences
    end
  end

  policies do
    policy always() do
      authorize_if expr(account_id == ^actor(:account_id))
    end

    policy action_type([:create, :update, :destroy]) do
      authorize_if {Cartulary.Policy.RoleIn, roles: [:account_admin, :system]}
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :account_id, :uuid, allow_nil?: false
    attribute :scope_id, :uuid

    attribute :role, :string, allow_nil?: false, public?: true

    attribute :provider, :string, allow_nil?: false, public?: true
    attribute :model, :string, allow_nil?: false, public?: true
    attribute :model_version, :string, allow_nil?: false, default: "unversioned", public?: true
    attribute :prompt_version, :string, allow_nil?: false, default: "none", public?: true
    attribute :pipeline_version, :string, allow_nil?: false, default: "f5-1", public?: true
    attribute :embedding_dimensions, :integer, constraints: [min: 1], public?: true
    attribute :options, :map, allow_nil?: false, default: %{}
    attribute :version, :integer, allow_nil?: false, default: 1, public?: true
    attribute :active, :boolean, allow_nil?: false, default: true, public?: true
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :scope_role_version, [:scope_id, :role, :version]
  end
end
