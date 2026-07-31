# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Governance.Actions.McpIngest do
  @moduledoc """
  Implementation behind the `ingest` tool: records one raw observation from a machine caller.

  The caller writes only a message; extraction produces governed proposals. Actor and Account
  come from the credential, never arguments.
  """
  use Ash.Resource.Actions.Implementation

  @doc """
  Persists the observation carried by the tool call.

  `input.arguments` holds the declared tool arguments with atom keys; they are converted to
  string keys because the memory facade works in the same string-keyed shape as the HTTP body.
  `context.actor` supplies the Account and calling peer.

  Returns `{:ok, message}` where `message` is the stored message as a string-keyed map. Because
  the tool declares no `"sync_extract"` argument, the facade's inline-extraction default applies
  and the map also carries a `"knowledge"` list — whatever the gates made of the extracted
  items, which for a governed Account is usually a proposal rather than activated memory. The
  facade signals failure by raising, not by returning an error tuple: a missing required
  argument, an unauthorized write, or a failed extraction raises and the generic-action runner
  turns that into a tool error.
  """
  @impl true
  def run(input, _opts, context) do
    attrs = stringify(input.arguments)

    case Cartulary.Memory.ingest_message(attrs, context.actor) do
      {:ok, message} -> {:ok, message}
      {:error, error} -> {:error, error}
    end
  end

  # The memory facade is shared with the HTTP surface and keys everything by string, so tool
  # arguments (atoms, produced from the declared schema) have to be converted first.
  defp stringify(attrs), do: Map.new(attrs, fn {key, value} -> {to_string(key), value} end)
end

defmodule Cartulary.Governance.Actions.McpRead do
  @moduledoc """
  Shared read-tool implementation with optional inline validation.

  `:operation` selects `get_context`, `search`, `ask`, `query_knowledge`, or `check_readiness`.
  Reads use the actor's Account and authorization.

  After the read, it may attach one question for the calling peer. Attachment is deadline-bounded
  and best effort; failure, rate limits, or no match leave the read unchanged.

  The question contains frozen statement text. `resolve_validation` requires transcript proof
  before changing knowledge.
  """
  use Ash.Resource.Actions.Implementation

  @doc """
  Runs one governed read and, when one is waiting, attaches a single validation question.

  `opts` must contain `:operation`, one of `:get_context`, `:search`, `:ask`,
  `:query_knowledge`, or `:check_readiness`. A missing `:operation` raises `KeyError` and an
  unrecognised one raises `CaseClauseError`; either is a wiring bug rather than a caller error.
  `input.arguments` are converted to string keys for the memory facade, and `context.actor`
  carries Account, peer, and authorized scopes.

  Always returns `{:ok, result}`. `query_knowledge` returns a bare list from the facade and is
  wrapped as `%{"data" => list}` so that, like the other reads, it is a map able to carry the
  attachment. When a question is offered, it is added under the `"pending_validation"` key; the
  key is absent otherwise. The topic used to pick a relevant question is the `"query"` or
  `"question"` argument when present; with neither, any pending question matches and the one
  with the earliest deadline is offered.

  Any failure inside the underlying memory call propagates as a raise; the attachment step
  itself cannot fail the call.
  """
  @impl true
  def run(input, opts, context) do
    attrs = Map.new(input.arguments, fn {key, value} -> {to_string(key), value} end)
    operation = Keyword.fetch!(opts, :operation)

    result =
      case operation do
        :get_context -> Cartulary.Memory.get_context(attrs, context.actor)
        :search -> Cartulary.Memory.search(attrs, context.actor)
        :ask -> Cartulary.Memory.ask(attrs, context.actor)
        :query_knowledge -> %{"data" => Cartulary.Memory.query_knowledge(attrs, context.actor)}
        :check_readiness -> Cartulary.Memory.check_readiness(attrs, context.actor)
      end

    # Only a question that shares vocabulary with what the caller just asked about is offered,
    # so the interruption stays on topic. Reads with neither argument pass nil, which matches
    # any pending question.
    topic = attrs["query"] || attrs["question"]

    # Runs after the read on purpose: attachment is best effort and returns nil on timeout,
    # rate limit, pause, or no match, so it can never delay or break the answer.
    pending =
      Cartulary.Governance.PeerQueue.attach(
        context.actor,
        attrs["session_id"],
        Atom.to_string(operation),
        topic
      )

    result =
      if pending && is_map(result) do
        Map.put(result, "pending_validation", pending)
      else
        result
      end

    {:ok, result}
  end
end

defmodule Cartulary.Governance.Actions.ResolveValidation do
  @moduledoc """
  Implementation behind the `resolve_validation` tool: relays one peer's answer to one question.

  Confirmation or rejection binds only when the transcript shows the frozen text followed by a
  human turn. Unverified answers only defer revalidation.

  The queue accepts only questions addressed to the calling peer.
  """
  use Ash.Resource.Actions.Implementation

  @doc """
  Submits a verdict for the pending question identified by `arguments.id`.

  `verdict` is one of `"confirm"`, `"reject"`, `"unsure"`, or `"skip"`. `shown_text` is what the
  agent claims it displayed; it is not stored, only its hash and a flag set when it differs from
  the frozen statement after normalization. `correction_text` is not stored either — only the
  fact that a correction was offered — so a correction has to come back as an ordinary
  observation before it can become knowledge.

  Returns `{:ok, map}` describing the question id, the verdict, whether the channel was
  verified, and the effect that was actually applied. Returns `{:error, "not found"}` when no
  question with that id belongs to the calling peer, and `{:error, reason_string}` for any other
  refusal, such as an unrecognised verdict. Answering a question that has no outstanding
  delivery — nothing was ever shown, or it was already answered — raises a not-found error.
  """
  @impl true
  def run(input, _opts, context) do
    arguments = input.arguments

    case Cartulary.Governance.PeerQueue.resolve(
           context.actor,
           arguments.id,
           arguments.verdict,
           arguments.shown_text,
           arguments.correction_text
         ) do
      {:ok, result} -> {:ok, Map.new(result)}
      {:error, :not_found} -> {:error, "not found"}
      {:error, reason} -> {:error, to_string(reason)}
    end
  end
end

defmodule Cartulary.Governance.Actions.SetAskPreference do
  @moduledoc """
  Implementation behind the `set_ask_preference` tool: lets a peer turn their own interruptions
  down.

  The `:restrict` action may lower question limits or extend a pause, never loosen them.

  It only ever touches the calling peer's own row; there is no argument for choosing a peer.
  """
  use Ash.Resource.Actions.Implementation

  alias Cartulary.Clock

  @doc """
  Applies the requested reductions and returns the values that ended up stored.

  All three arguments are optional. `max_per_session` and `max_per_day` are counts of inline
  questions; zero means "never ask me". `pause_for_hours` is a duration in hours that is
  converted here into an absolute resume time, because a stored deadline keeps working across
  restarts while a duration would not.

  Returns `{:ok, map}` with the effective `:max_per_session`, `:max_per_day`, and
  `:paused_until` after clamping, which may be unchanged from before if the request would have
  loosened a limit. Raises if the preference row cannot be read or written.
  """
  @impl true
  def run(input, _opts, context) do
    args = input.arguments

    # A negative duration is floored at zero rather than rejected. It then resolves to "now",
    # which is either discarded for being no later than an existing pause or stored as one that
    # has already elapsed; neither outcome extends a peer's quiet period.
    attrs = %{
      max_per_session: args.max_per_session,
      max_per_day: args.max_per_day,
      paused_until:
        if(is_integer(args.pause_for_hours),
          do: DateTime.add(Clock.utc_now(), max(args.pause_for_hours, 0), :hour)
        )
    }

    preference = Cartulary.Governance.PeerQueue.restrict_preferences(context.actor, attrs)

    {:ok,
     %{
       max_per_session: preference.max_per_session,
       max_per_day: preference.max_per_day,
       paused_until: preference.paused_until
     }}
  end
end
