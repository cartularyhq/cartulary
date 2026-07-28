# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Model.Embedding do
  @moduledoc """
  Pinned embedder facade with explicit compatibility and re-embed planning.

  Vector consumers must provide the stored identity before reuse. A mismatch is
  an error carrying a versioned migration plan, never an automatic fallback.
  """

  alias Cartulary.Model.Config
  alias Cartulary.Model.Gateway

  defmodule Result do
    @moduledoc false
    defstruct [:vectors, :provider, :model, :version, :dimensions]
  end

  def embed(texts, context, opts \\ []) when is_list(texts) do
    config = Config.resolve(:embedder, context)
    current = Config.embedding_identity(config)

    with :ok <- ensure_compatible(Keyword.get(opts, :stored_identity), current),
         {:ok, vectors, ^config} <- Gateway.embed_with_config(config, texts, context, opts),
         :ok <- ensure_dimensions(vectors, current.dimensions) do
      {:ok,
       %Result{
         vectors: vectors,
         provider: current.provider,
         model: current.model,
         version: current.version,
         dimensions: current.dimensions
       }}
    end
  end

  def compatible?(nil, _current), do: true

  def compatible?(stored, current) when is_map(stored) and is_map(current) do
    identity(stored) == identity(current)
  end

  def ensure_compatible(nil, _current), do: :ok

  def ensure_compatible(stored, current) do
    if compatible?(stored, current) do
      :ok
    else
      {:error, {:reembed_required, reembed_plan(stored, current)}}
    end
  end

  def reembed_plan(stored, current) do
    %{
      pipeline_version: "f5-1",
      from: identity(stored),
      to: identity(current),
      operation: "reembed_all",
      reuse_existing_vectors: false
    }
  end

  defp ensure_dimensions(vectors, dimensions) when is_integer(dimensions) do
    if Enum.all?(vectors, &(is_list(&1) and length(&1) == dimensions)) do
      :ok
    else
      {:error, {:embedding_dimension_mismatch, dimensions}}
    end
  end

  defp ensure_dimensions(_vectors, nil), do: {:error, :embedding_dimensions_not_configured}

  defp identity(value) do
    %{
      provider: value[:provider] || value["provider"],
      model: value[:model] || value["model"],
      version: value[:version] || value["version"],
      dimensions: value[:dimensions] || value["dimensions"]
    }
  end
end
