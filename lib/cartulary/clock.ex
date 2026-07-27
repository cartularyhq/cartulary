# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Clock do
  @moduledoc """
  Runtime clock seam for temporal logic and deterministic evals.
  """

  @callback utc_now() :: DateTime.t()

  def utc_now do
    Application.get_env(:cartulary, :clock, __MODULE__.System).utc_now()
  end

  defmodule System do
    @moduledoc false
    @behaviour Cartulary.Clock

    @impl true
    def utc_now, do: DateTime.utc_now()
  end
end
