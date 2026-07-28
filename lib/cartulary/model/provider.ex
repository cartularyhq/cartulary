# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Model.Provider do
  @moduledoc """
  Determinism seam for every remote or local model capability.

  Tests replace this behaviour once and thereby control extraction, reasoning,
  dialectic answers, embeddings, and reranking.
  """

  alias Cartulary.Model.Config.Role

  defmodule Result do
    @moduledoc false
    @type t :: %__MODULE__{value: term(), usage: map(), metadata: map()}
    defstruct [:value, usage: %{}, metadata: %{}]
  end

  @callback structured(Role.t(), [map()], map(), keyword()) ::
              {:ok, Result.t()} | {:error, term()}
  @callback chat(Role.t(), [map()], keyword()) :: {:ok, Result.t()} | {:error, term()}
  @callback embed(Role.t(), [String.t()], keyword()) ::
              {:ok, Result.t()} | {:error, term()}
  @callback rerank(Role.t(), String.t(), [String.t()], keyword()) ::
              {:ok, Result.t()} | {:error, term()}
end
