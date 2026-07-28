# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.PostgrexVectorExtension do
  @moduledoc """
  Teaches the database driver how to send and receive pgvector `vector` values.

  Embeddings are stored in real vector columns so the database can index and
  search them; without this extension the driver would not know the type and
  would hand back an opaque value. Registering it here means a stored embedding
  crosses the wire in its binary form rather than being rendered as text and
  parsed back, which matters when every retrieval query moves thousands of
  floats.

  ## Why the bodies are quoted

  `encode/1` and `decode/1` are not called per value. They are called once,
  while the type module below is defined, to collect clauses that get spliced
  into it, so the per-row work is ordinary compiled pattern matching with no
  dispatch. That is why those two functions return quoted anonymous-function
  clauses rather than doing the work, and why the binary-modifier import at the
  top is needed even though nothing in this file appears to use it: `quote`
  carries this module's imports into the quoted clauses, which is what makes
  `int32()` resolve where they are spliced. Do not "simplify" these into plain
  function bodies; the driver would splice a function call where it expects
  clauses.

  ## Wire format

  A value is a four-byte big-endian byte count followed by that many bytes of
  pgvector payload. Encoding and decoding must stay mirror images: change one
  side alone and every embedding read back is garbage rather than an error.
  """

  import Postgrex.BinaryUtils, warn: false

  @doc """
  Chooses how decoded binaries are handled, from the driver's connection options.

  Returns `:copy` unless told otherwise. Copying matters here: without it, a
  decoded vector would be a slice of the much larger network receive buffer,
  and holding one small embedding would keep that whole buffer alive. Passing
  `:reference` avoids the copy and is only sensible when the value is consumed
  immediately and discarded.

  The return value is the state threaded into the other callbacks.
  """
  def init(opts), do: Keyword.get(opts, :decode_binary, :copy)

  @doc """
  Declares which PostgreSQL type this extension handles: the pgvector `vector` type.

  Matching by name rather than by numeric type id is required, because an
  extension type is assigned a different id in every database.
  """
  def matching(_state), do: [type: "vector"]

  @doc """
  Selects the binary wire format rather than the text one.
  """
  def format(_state), do: :binary

  @doc """
  Returns the quoted clause the generated type module uses to encode a vector.

  Accepts anything the vector type can be built from — a list of floats or an
  already-built vector — and emits the length-prefixed binary payload as iodata.
  The clause raises on a value that cannot be converted, which is the intended
  outcome: a malformed embedding must not reach the database.
  """
  def encode(_state) do
    quote do
      vector ->
        {:ok, vector} = Ash.Vector.new(vector)
        data = Ash.Vector.to_binary(vector)
        [<<IO.iodata_length(data)::int32()>>, data]
    end
  end

  @doc """
  Returns the quoted clause the generated type module uses to decode a vector.

  The two variants differ only in whether the payload is copied out of the
  connection's receive buffer first; see `init/1` for why the copying variant is
  the default. Both read the four-byte length prefix and rebuild a vector from
  exactly that many bytes.
  """
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

# Builds `Cartulary.PostgrexTypes`, the type module the repository is configured
# to use: the vector extension above plus everything Ecto's PostgreSQL adapter
# normally installs. Appending rather than replacing is essential — dropping the
# stock extensions would break every ordinary column type.
#
# This runs at compile time, in this file, because the driver's type module has
# to exist before a connection can reference it. That is also why the repository
# setting that names it is a compile-time configuration rather than a runtime one.
Postgrex.Types.define(
  Cartulary.PostgrexTypes,
  [Cartulary.PostgrexVectorExtension] ++ Ecto.Adapters.Postgres.extensions(),
  []
)
