# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Retrieval.Vector do
  @moduledoc """
  In-process cosine similarity between two embedding vectors.

  Its one caller is entity resolution, which holds the Account's entity vectors
  in memory and compares one surface form against each of them.

  It is not the search path. Ranking stored records goes through PostgreSQL's
  vector index, which stays fast as the corpus grows; this function is a
  straightforward computation over two vectors and would not.

  The failure modes it recognises return 0.0 rather than raising: a missing
  vector, a mismatched length, or a zero-magnitude vector all mean "no evidence
  of similarity", which is the useful answer for a caller ranking candidates
  and keeps a single unembedded row from aborting a whole comparison pass.
  """

  @doc """
  Returns the cosine similarity of two vectors as a float, normally in the
  range -1.0 to 1.0, where 1.0 means identical direction.

  Each argument may be a stored vector value or a plain list of numbers.
  Returns 0.0 when either side is empty or unusable, when the lengths differ —
  which is what happens if two different embedders produced them, and where a
  numeric answer would be meaningless — or when either vector has zero
  magnitude, which would otherwise divide by zero.
  """
  def cosine(left, right) do
    left = to_list(left)
    right = to_list(right)

    if left == [] or length(left) != length(right) do
      0.0
    else
      left_tensor = Nx.tensor(left, type: {:f, 32})
      right_tensor = Nx.tensor(right, type: {:f, 32})

      # `Nx.Tensor` is a plain struct outside a `defn` block, so Kernel's `*` and `/` would
      # raise on it rather than compute — the tensor ops below are not cosmetic.
      denominator = Nx.multiply(Nx.LinAlg.norm(left_tensor), Nx.LinAlg.norm(right_tensor))

      if Nx.to_number(denominator) == 0.0 do
        0.0
      else
        Nx.to_number(Nx.divide(Nx.dot(left_tensor, right_tensor), denominator))
      end
    end
  end

  @doc """
  Coerces a vector to a plain list of numbers.

  Accepts a stored vector value or a list. Anything else — most importantly
  `nil`, which is what a record that has never been embedded carries — becomes
  an empty list, so callers get 0.0 similarity instead of an exception.
  """
  def to_list(%Ash.Vector{} = vector), do: Ash.Vector.to_list(vector)
  def to_list(vector) when is_list(vector), do: vector
  def to_list(_vector), do: []
end
