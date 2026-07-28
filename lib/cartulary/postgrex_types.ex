# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.PostgrexVectorExtension do
  @moduledoc false

  import Postgrex.BinaryUtils, warn: false

  def init(opts), do: Keyword.get(opts, :decode_binary, :copy)
  def matching(_state), do: [type: "vector"]
  def format(_state), do: :binary

  def encode(_state) do
    quote do
      vector ->
        {:ok, vector} = Ash.Vector.new(vector)
        data = Ash.Vector.to_binary(vector)
        [<<IO.iodata_length(data)::int32()>>, data]
    end
  end

  def decode(:copy) do
    quote do
      <<length::int32(), data::binary-size(length)>> ->
        data |> :binary.copy() |> Ash.Vector.from_binary()
    end
  end

  def decode(_state) do
    quote do
      <<length::int32(), data::binary-size(length)>> ->
        Ash.Vector.from_binary(data)
    end
  end
end

Postgrex.Types.define(
  Cartulary.PostgrexTypes,
  [Cartulary.PostgrexVectorExtension] ++ Ecto.Adapters.Postgres.extensions(),
  []
)
