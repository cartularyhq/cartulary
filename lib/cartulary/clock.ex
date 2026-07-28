# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Clock do
  @moduledoc """
  Runtime clock seam for temporal logic and deterministic evals.
  """

  @callback utc_now() :: DateTime.t()
  @callback monotonic_ms() :: integer()

  def utc_now do
    Application.get_env(:cartulary, :clock, __MODULE__.System).utc_now()
  end

  def monotonic_ms do
    Application.get_env(:cartulary, :clock, __MODULE__.System).monotonic_ms()
  end

  defmodule System do
    @moduledoc false
    @behaviour Cartulary.Clock

    @impl true
    def utc_now, do: DateTime.utc_now()

    @impl true
    def monotonic_ms, do: :erlang.monotonic_time(:millisecond)
  end
end
