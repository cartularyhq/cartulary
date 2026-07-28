# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Retrieval.Vector do
  @moduledoc "Tiny-corpus Nx cosine baseline used by eval and entity resolution."

  def cosine(left, right) do
    left = to_list(left)
    right = to_list(right)

    if left == [] or length(left) != length(right) do
      0.0
    else
      left_tensor = Nx.tensor(left, type: {:f, 32})
      right_tensor = Nx.tensor(right, type: {:f, 32})
      denominator = Nx.LinAlg.norm(left_tensor) * Nx.LinAlg.norm(right_tensor)

      if Nx.to_number(denominator) == 0.0 do
        0.0
      else
        Nx.to_number(Nx.dot(left_tensor, right_tensor) / denominator)
      end
    end
  end

  def to_list(%Ash.Vector{} = vector), do: Ash.Vector.to_list(vector)
  def to_list(vector) when is_list(vector), do: vector
  def to_list(_vector), do: []
end
