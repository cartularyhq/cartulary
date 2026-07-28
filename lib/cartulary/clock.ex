# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Clock do
  @moduledoc """
  The one place the rest of the system asks what time it is.

  Time is not incidental here. When something was believed, when it stopped
  being true, when a statement is due for revalidation, and how much of a
  request's deadline is left are all load-bearing values. Routing them through
  one seam means a test or an evaluation run can pin the clock and get the same
  answer every time, instead of depending on the moment it happened to run.

  ## Two clocks, never interchangeable

  * Wall-clock time is what gets stored. It is comparable across machines and
    across restarts, and it is the only kind that belongs in a timestamp column.
    It can also jump — leap seconds, an operator correcting a drifting host, a
    virtual machine resuming.
  * Monotonic time only ever moves forward and is what deadlines and durations
    must use. It is meaningless as an absolute value and meaningless across
    nodes; subtract two readings from the same node or do not use it at all.

  Measuring elapsed time by subtracting two wall-clock readings can produce a
  negative duration when the host's clock is corrected mid-request, which turns
  a deadline check into an immediate timeout. Storing a monotonic reading
  produces a timestamp that means nothing after a restart. Both mistakes are
  easy and both are silent, so pick by which of the two properties you need.

  ## Swapping the implementation

  The implementation is looked up in application configuration on every call
  rather than captured at compile time, so a test can substitute a fixed or
  scripted clock while the system is running and remove it afterwards. Any
  replacement must implement both callbacks of this behaviour and must keep
  monotonic readings monotonic — a substitute that returns a constant for
  `monotonic_ms/0` makes every deadline infinite.

  Call these functions rather than `DateTime.utc_now/0` directly. A direct call
  is invisible to the seam and is exactly what makes a suite flaky at midnight
  or a fixture unreproducible.
  """

  @callback utc_now() :: DateTime.t()
  @callback monotonic_ms() :: integer()

  @doc """
  The current wall-clock time in UTC, for anything that will be stored or compared.

  Use this for belief times, valid times, decision timestamps, and expiry
  checks. Do not use it to measure how long something took.
  """
  def utc_now do
    Application.get_env(:cartulary, :clock, __MODULE__.System).utc_now()
  end

  @doc """
  A monotonically increasing millisecond reading, for durations and deadlines.

  The absolute number is arbitrary and only differences between two readings on
  the same node mean anything. Use this for remaining-deadline arithmetic and
  latency measurement; never store it as a timestamp.
  """
  def monotonic_ms do
    Application.get_env(:cartulary, :clock, __MODULE__.System).monotonic_ms()
  end

  defmodule System do
    @moduledoc """
    The real clock: the default implementation, backed by the host's system time.

    This is what runs unless configuration names something else. It holds no
    state and adds nothing to the underlying calls — the indirection exists for
    substitutability, not behaviour, so this module must stay a thin pass-through.
    """

    @behaviour Cartulary.Clock

    @impl true
    def utc_now, do: DateTime.utc_now()

    @impl true
    def monotonic_ms, do: :erlang.monotonic_time(:millisecond)
  end
end
