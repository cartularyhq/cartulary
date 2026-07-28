# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule CartularyWeb.MemoryController do
  @moduledoc """
  The JSON surface for probes, observation ingest, retrieval, context, readiness, and
  operator cost reporting.

  Two actions here are anonymous: `health/2` and `ready/2` answer container and
  load-balancer probes before any credential exists. Everything else sits behind the
  bearer-token pipeline, which rejects the request with 401 before this module runs and
  leaves the resolved caller in `conn.assigns.current_actor`.

  ## Which credentials reach these actions

  Both kinds of authenticated identity — a human password sign-in token and an agent API
  key — may call every authenticated action below, except `costs/2`, which additionally
  demands the account-admin role. Treating humans and machines alike here is deliberate:
  an agent needs to record what it observed and to read governed memory, and neither of
  those grants any authority over what becomes knowledge.

  Accordingly there is no curator action in this controller and no route that writes
  knowledge. Approve, edit, reject, merge, defer, promotion, and gate-rule administration
  exist only in the human browser UI, which a machine credential cannot sign into. The
  single write path here is `ingest/2`, and it records a raw observation; the extraction
  pipeline is the only writer of knowledge, and everything it extracts still has to pass
  governance before anyone other than the submitting peer can see it. Do not add a
  knowledge-writing route to this controller — the absence of one is a load-bearing
  property, not an oversight.

  ## Account selection

  The Account is taken from the verified credential and installed as the tenant by the
  authentication plug. An `account_key` field in a request body and the legacy
  `x-cartulary-account-key` header are accepted and ignored, so an old client fails closed
  into its own Account rather than reaching into someone else's.

  ## Response shape and failures

  Domain actions answer `%{"data" => payload}`; the probes answer their payload
  unwrapped, because external probes consume it directly. Refusals from this module are
  `%{"error" => message}`. Every response carries an `x-trace-id` header for correlation.

  These actions deliberately do not rescue. Authorization, missing-parameter, and
  not-found failures raised by the domain propagate to Phoenix's error handling, which
  answers with an error status and the generic error body, instead of returning 200 with a
  hollow payload.
  """

  use CartularyWeb, :controller

  alias Cartulary.Memory
  alias Cartulary.Operations.Health

  @doc """
  Liveness probe. Unauthenticated, and touches no database or queue.

  Answers 200 with `%{"status" => "ok", "app" => "cartulary", "version" => "f5-1"}`.

  `"f5-1"` is the identity of the extraction-and-pipeline contract this build implements,
  not the application's semantic version; it tells a client which extraction behaviour it
  is talking to. A contract test pins the exact literal, so changing it is a deliberate
  contract transition that owes a changelog entry and refreshed contract evidence.

  Point orchestrator *liveness* probes here and *readiness* probes at `ready/2`. Wiring
  liveness to the readiness checks would have a database blip kill containers instead of
  draining them.
  """
  def health(conn, _params) do
    json(conn, %{status: "ok", app: "cartulary", version: "f5-1"})
  end

  @doc """
  Readiness probe. Unauthenticated.

  Runs the database, Oban, queue-depth, and model-role checks and answers 200 only when
  every one reports `"ok"`, otherwise 503 so a load balancer stops routing to this node.
  The body is the whole check map: per-component status, queue depths by queue and job
  state, an error class per failing component, and `"f10-1"` — the identity of the
  readiness payload shape, which an operator's tooling parses, so changing it is a
  versioned contract transition rather than a version bump.

  The payload is content-safe by construction. Component names, counts, model identities,
  versions, and error classes are allowed; credentials, secrets, and stored content are
  not, because anyone who can reach the port can read this without authenticating. Adding
  a field here is a disclosure decision.
  """
  def ready(conn, _params) do
    result = Health.readiness()
    status = if Health.ready?(result), do: 200, else: 503
    conn |> put_status(status) |> json(result)
  end

  @doc """
  Account-wide usage, storage, and estimated-cost summary for the operator.

  Guarded by a coarse Account-level role check rather than a scope policy, because the
  summary aggregates the entire Account instead of one scope. Any other role gets 403
  `%{"error" => "Forbidden"}`. The `:system` role never appears on a credential resolved
  from an HTTP request — role resolution only ever yields reader, member, curator, or
  account-admin — so that branch admits internal callers only.

  Returns `%{"data" => summary}` holding the exact recorded usage-event count, API request
  and ingest counts, input/output/embedding token totals overall and per model role,
  logical storage bytes, and an estimated model cost in USD.

  The cost figure is computed from operator-supplied rates over the local usage ledger. It
  is a self-host visibility aid, not a bill, and there is no hidden billing state behind
  it.
  """
  def costs(conn, _params) do
    actor = conn.assigns.current_actor

    if actor.role in [:account_admin, :system] do
      json(conn, %{data: Cartulary.Operations.Metering.summary(actor)})
    else
      conn |> put_status(:forbidden) |> json(%{error: "Forbidden"})
    end
  end

  @doc """
  Records one raw observation. This is the only write path an agent has.

  Body fields: `session_id` and `scope_path` and `content` are required; `role` defaults
  to `"user"`, and `occurred_at` and `sync_extract` are optional. Missing scopes, the
  session, and its scope/participant links are created on demand, so a client does not
  have to provision topology before speaking.

  The acting Peer comes from the credential. A `peer_key` in the body is honoured only for
  internal callers that carry no peer of their own, so an authenticated caller cannot
  attribute an observation to somebody else.

  Returns `%{"data" => message}`. Unless `sync_extract` is `false`, extraction runs inline
  and the message also carries a `knowledge` list of the items just proposed. Those items
  are pipeline output rather than caller input: nothing in the body can mint knowledge,
  and each item still has to clear governance before it is visible beyond its own peer.

  Raises when a required field is absent, which surfaces as a server-error status rather
  than a partially written session.
  """
  def ingest(conn, params) do
    {:ok, message} =
      params
      |> Memory.ingest_message(conn.assigns.current_actor)

    json(conn, %{data: message})
  end

  @doc """
  Ranked retrieval over governed memory, with no answer generation.

  Body fields, all optional: `query` (defaults to the empty string), `scope_path`
  (defaults to `"/poc"`), `profile` (defaults to `"balanced"`), `limit` (defaults to 12
  candidates), `include_cross_links`, `as_of`, `min_score`, `source_filters`, and
  `deadline` — send `"disabled"` to drop the retrieval time budget, which only makes sense
  offline.

  A scope path selects that scope together with its ancestors, because context flows
  downward: a child scope sees what its parents know, never the reverse.

  Returns `%{"data" => result}` carrying the profile name, the retrieval contract identity
  in `profile_version` (`"f7-1"` here, naming the retrieval and context behaviour a client
  is written against — bumping it is a versioned contract transition owing a changelog
  entry, not a cosmetic edit), the fused `candidates`, and which strategies contributed or
  were dropped. Account, authorized-scope, lifecycle, and source
  filtering all happen inside retrieval before candidates surface here, so this action
  never has to post-filter.

  Each strategy scores in its own space, so the returned order is the fused ranking —
  re-sorting candidates by a raw per-strategy score compares incomparable numbers and
  silently degrades results. A raw `strategies` override is refused for external callers;
  it is an internal and evaluation-only control.
  """
  def search(conn, params) do
    result =
      params
      |> Memory.search(conn.assigns.current_actor)

    json(conn, %{data: result})
  end

  @doc """
  Retrieves supporting memory and answers a natural-language question over it.

  Body: `question` is required; every `search/2` parameter is also accepted. `profile`
  defaults to `"thorough"` rather than `"balanced"`, because an answer justifies more
  latency than a bare search. Retrieval is restricted to knowledge items, so the citations
  are governed statements.

  Returns `%{"data" => result}`: the search payload merged with `answer`, `citations`, and
  `abstained`. The answer is grounded in the returned candidates — when nothing supports
  the question the action abstains instead of inventing one, so treat `abstained == true`
  as an ordinary outcome and not an error.

  A missing `question` raises rather than answering over an empty query.
  """
  def ask(conn, params) do
    result =
      params
      |> Memory.ask(conn.assigns.current_actor)

    json(conn, %{data: result})
  end

  @doc """
  Assembles the context projection for a scope, without reasoning.

  Body: `scope_path` (defaults to `"/poc"`), an optional `session_id` to pick the session
  summary, and an optional `budget_chars` that caps the assembled size.

  Returns `%{"data" => context}` with `knowledge`, `session_summary`, `scope_cards`,
  `peer_profile`, the context contract identity in `profile_version`, and two diagnostic
  flags: `projection_cache_hit` says a stored projection was reused, `fast_fallback` says
  the projection was missing and the fastest retrieval profile filled in live.

  No generation model is ever called here. Profiles, scope cards, and session summaries
  are projections of governed knowledge, which is what keeps this path cheap and
  repeatable; introducing a model call would turn a projection read into an inference and
  break that guarantee.
  """
  def context(conn, params) do
    result =
      params
      |> Memory.get_context(conn.assigns.current_actor)

    json(conn, %{data: result})
  end

  @doc """
  Reports whether a peer knows enough to run a named skill in a scope.

  Body: `skill` and `scope_path` are required. The peer defaults to the authenticated
  caller; `peer_id` or `peer_key` may name another peer the caller is allowed to read.

  Returns `%{"data" => report}` with the report contract identity in `report_version`
  (`"f9-1"`, naming the selector language and gap-report shape; changing it is a versioned
  contract transition), the resolved skill/peer/scope, a per-requirement `requirements`
  list, and the unsatisfied ones split into `blockers` and `warnings`. `ready` is true
  exactly when there are no blockers: required gaps block execution, preferred gaps warn.

  Requirement keys inherit down the scope tree with the nearest scope winning. Only
  authorized active knowledge, or provisional knowledge belonging to the calling peer,
  can satisfy a requirement; expired and revalidation-due items count as gaps immediately,
  without waiting for a background sweep.

  A gap is not permission to write the missing fact. The answer must come back through
  ordinary observation ingest and pass governance before readiness improves, and a client
  must never treat this report as advisory and proceed past a blocker.
  """
  def readiness(conn, params) do
    result =
      params
      |> Memory.check_readiness(conn.assigns.current_actor)

    json(conn, %{data: result})
  end

  @doc """
  Lists governed knowledge the caller is allowed to read.

  Query parameters: `scope_path` (defaults to `"/poc"`), `state` (defaults to `"active"`),
  and `limit` (defaults to 12 rows). Results cover the named scope plus the ancestors it
  inherits from, ordered by confidence and then recency, each row annotated with the
  `scope_path` it lives at.

  Returns `%{"data" => rows}`. This is a read-only view: there is deliberately no POST
  counterpart, so an agent that wants to record something has to go through observation
  ingest and let the pipeline and governance decide what becomes knowledge. Proposals
  awaiting a gate decision are not `"active"` and stay out of this list unless the caller
  asks for their state and is entitled to see them.
  """
  def knowledge(conn, params) do
    result =
      params
      |> Memory.query_knowledge(conn.assigns.current_actor)

    json(conn, %{data: result})
  end
end
