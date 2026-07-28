# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule CartularyWeb.SelfGovernanceController do
  @moduledoc """
  What a person may do about knowledge that is *about them*: read it, dispute it, redact
  it, or demand its erasure.

  These are subject rights, not curator powers. The distinction runs through every action
  here:

  - the caller acts only on their own subject knowledge, and the peer is always taken from
    the credential, never from a parameter, so there is no way to spell another person's
    id into a request and act on their behalf;
  - nothing here approves, activates, promotes, merges, or edits anyone's knowledge.
    Contesting an item asks a human curator to look at it; it does not decide the outcome.

  ## Only a human password identity gets in

  The routes are mounted behind a plug that requires the credential to have come from a
  password sign-in. An agent API key is rejected with a 403 carrying the error message
  "Human identity required", even when the key belongs to the same peer, because disputing
  or erasing what the system believes about a person is a personal decision that a machine
  may not take for them. Do not relax that pipeline to "any authenticated caller" — it is
  the whole reason these actions can be trusted.

  ## Content safety

  Read responses are projected through the resource's public attributes only, so private
  and sensitive internals never reach the wire even when a new attribute is added to the
  resource later. Erasure answers with the request's id, mode, and state and nothing else:
  reporting what was removed would re-disclose the very content the subject asked to have
  destroyed.
  """

  use CartularyWeb, :controller

  alias Cartulary.Governance.Engine
  alias Cartulary.Governance.Erasure

  @doc """
  Lists the knowledge whose subject is the calling peer.

  Takes no parameters — the subject is the authenticated peer, always. Returns
  `%{"data" => rows}` newest first, skipping items already deleted, with each row reduced
  to the resource's public attributes.

  This is the person's view of their own record, including items that are still
  provisional or held and therefore invisible to ordinary retrieval. Seeing an item here
  does not mean anyone else can see it.
  """
  def index(conn, _params) do
    knowledge =
      conn.assigns.current_actor
      |> Engine.self_view()
      |> Enum.map(&public_map/1)

    json(conn, %{data: knowledge})
  end

  @doc """
  Disputes one item of knowledge about the calling peer.

  `id` is the knowledge id from the path. The item moves to a contested state marked as
  disputed by its subject, an immutable audit entry is written, and a validation item is
  queued for a human curator with a 24-hour deadline — long enough for a curator to answer
  during a working day, short enough that a disputed claim is not left standing for a
  week.

  Returns `%{"data" => item}` with the updated row. Raises not-found when the id is
  unknown *or* belongs to knowledge whose subject is somebody else; the two cases are
  deliberately indistinguishable, so this route cannot be used to probe for the existence
  of other people's records.

  Contesting states an objection. It does not delete or rewrite the claim, and only a
  human curator can resolve it.
  """
  def contest(conn, %{"id" => id}) do
    knowledge = Engine.contest(conn.assigns.current_actor, id, "contest")
    json(conn, %{data: public_map(knowledge)})
  end

  @doc """
  Withdraws one item of knowledge about the calling peer from use.

  `id` is the knowledge id from the path. The item moves to a redacted state marked as
  redacted by its subject and an audit entry is written. Unlike `contest/2` this does not
  queue curator review: the subject's decision stands on its own.

  Returns `%{"data" => item}`. Raises not-found for an unknown id or for knowledge about
  another peer, with no distinction between the two.

  Redaction is not erasure. The row survives in a redacted state so history and audit stay
  intact; use `erase/2` when the subject wants the content itself gone.
  """
  def redact(conn, %{"id" => id}) do
    knowledge = Engine.contest(conn.assigns.current_actor, id, "redact")
    json(conn, %{data: public_map(knowledge)})
  end

  @doc """
  Erases the calling peer's data, running the erasure immediately.

  Body: `mode` is `"proportionate"` (the default) or `"strict"`. Any other value raises.

  Proportionate mode removes the peer's observations and the knowledge they are the
  subject of, and scrubs their traces from provenance that other knowledge still depends
  on. Strict mode additionally removes knowledge that was only ever sourced through this
  peer. Neither mode retracts a claim that has surviving independent provenance — someone
  else's independently sourced statement is not the subject's to delete.

  Affected projections and entity derivations are recomputed or marked stale from the
  surviving record, and content-safe audit evidence — ids, hashes, actions, counts —
  deliberately survives, because proving that an erasure happened must not require keeping
  what was erased.

  The response carries only the erasure request's id, mode, and state. The target peer is
  the authenticated caller: it is read from the credential and cannot be supplied by the
  request, so this route can never erase somebody else.
  """
  def erase(conn, params) do
    mode = Map.get(params, "mode", "proportionate")

    request =
      Erasure.request(conn.assigns.current_actor, conn.assigns.current_actor.peer_id, mode)

    json(conn, %{data: %{id: request.id, mode: request.mode, state: request.state}})
  end

  # Projects a record to its resource-declared public attributes.
  #
  # This is the content-safety filter for every response in this module: whatever the
  # resource marks private stays private, and an attribute added to the resource later is
  # excluded by default rather than leaking the moment it is introduced. Never replace
  # this with Map.from_struct/1 or a hand-written key list.
  defp public_map(record) do
    record.__struct__
    |> Ash.Resource.Info.public_attributes()
    |> Map.new(fn attribute -> {attribute.name, Map.get(record, attribute.name)} end)
  end
end
