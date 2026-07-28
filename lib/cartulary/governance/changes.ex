# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Governance.Changes.ClampAskPreference do
  @moduledoc """
  Ash change that lets a peer only tighten, never loosen, their own interruption limits.

  Backs the `:restrict` action on `Cartulary.Governance.PeerAskPreference`, which is the action
  a peer's own agent may call — including through the machine tool surface. Because the caller
  is the subject rather than an administrator, the change treats every argument as a request to
  reduce exposure and silently clamps it:

  * `max_per_session` and `max_per_day` are pinned to the range zero up to the value already
    stored, so a request for a higher ceiling lands on the existing one instead of raising it.
    Zero is allowed: it means "never interrupt me".
  * `paused_until` is written only when no pause is stored yet, or when it is strictly later
    than the one that is, so a peer can extend a quiet period but cannot shorten or cancel one.

  A non-integer or missing argument leaves the attribute untouched, so a partial update never
  resets the fields it did not mention.

  Raising a peer's limits again is an administrator operation and goes through the separate
  `:configure` action; do not reuse this change there, as it would make the raise a no-op.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> clamp(:max_per_session, 0, changeset.data.max_per_session)
    |> clamp(:max_per_day, 0, changeset.data.max_per_day)
    |> clamp_pause()
  end

  # The ceiling passed in is the value already on the row, which is what makes this
  # tighten-only. The action takes arguments rather than accepting attributes, so the clamped
  # value has to be written onto the attribute here.
  defp clamp(changeset, name, floor, ceiling) do
    case Ash.Changeset.get_argument(changeset, name) do
      value when is_integer(value) ->
        Ash.Changeset.force_change_attribute(changeset, name, value |> max(floor) |> min(ceiling))

      _other ->
        changeset
    end
  end

  # With no pause on the row, any supplied timestamp is written. With one already stored, only a
  # strictly later timestamp wins; an earlier one is discarded rather than shortening the peer's
  # quiet period.
  defp clamp_pause(changeset) do
    case Ash.Changeset.get_argument(changeset, :paused_until) do
      %DateTime{} = paused_until ->
        current = changeset.data.paused_until

        if is_nil(current) || DateTime.compare(paused_until, current) == :gt do
          Ash.Changeset.force_change_attribute(changeset, :paused_until, paused_until)
        else
          changeset
        end

      _other ->
        changeset
    end
  end
end
