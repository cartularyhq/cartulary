# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Retrieval.Engine do
  @moduledoc """
  Runs a retrieval request: resolve the profile, fan out to strategies in two
  phases under one shared deadline, merge by rank, and optionally rerank.

  ## The pipeline, in order

  1. **Resolve the profile.** Which strategies run, their fusion weights,
     whether to rerank, and the deadline all come from the profile, which may
     be overridden per scope.
  2. **Seed phase.** Every applicable strategy whose stage is `:seed` runs
     against the query text.
  3. **Choose seed ids.** The seed lists are interleaved by their
     strategy-local rank, truncated to the candidate cap, and reduced to ids.
     That ordering picks *what to expand from*; it is not the answer order,
     which only fusion decides.
  4. **Expand phase.** Strategies whose stage is `:expand` walk outwards from
     those seed ids.
  5. **Fuse.** All lists merge through weighted reciprocal-rank fusion.
  6. **Rerank (optional).** Only a profile with reranking enabled — of the
     shipped ones, `:thorough` — pays for a model-backed reordering of the
     fused head.

  ## Deadline behaviour

  One budget, started before any work, covers strategies *and* reranking. A
  phase that finds no time left reports every applicable strategy as dropped
  without running it. A strategy that overruns is killed, not retried, and
  named in `dropped_strategies`. A rerank that overruns or errors leaves the
  fusion order intact and adds `reranker` to the dropped list. Callers
  therefore always get a usable answer plus an honest account of what was
  skipped; a shrinking contributed list is the signal that the deadline is too
  tight, not an error.

  ## Concurrency

  Strategies normally run concurrently. Serial execution exists because the
  test SQL sandbox gives the whole test one database connection, and parallel
  tasks would each need their own. The serial path runs the identical strategy
  contracts and checks the budget between strategies, so behaviour matches
  apart from wall-clock time.

  ## Authorization

  Each strategy runs inside its own Account-scoped transaction, which pins the
  database session to that Account. The strategies then apply scope, lifecycle,
  and provisional-subject filters themselves. Nothing in this module filters
  results afterwards, so a strategy that skips those filters leaks data
  straight to the caller.
  """

  alias Cartulary.DataLayer
  alias Cartulary.Model.Gateway
  alias Cartulary.Retrieval.{Budget, Candidate, Fusion, Profile}

  @doc """
  Executes one retrieval request and returns the response map.

  `query` is a `Cartulary.Retrieval.Query` whose Account, actor, and scope ids
  are already authorized. `profile_name` selects the posture. Options:

  * `:deadline?` (default true) — set false to remove the time budget; only for
    evaluation runs and dream-time rebuilds, never a live request.
  * `:concurrent?` — overrides the application-level concurrency setting; the
    test sandbox turns it off because it owns a single database connection.
  * `:internal?` and `:strategies` — naming strategies explicitly is restricted
    to server-side and evaluation callers; profile resolution raises otherwise.
  * `:inherit?` — set false to ignore any stored per-scope profile override.

  The returned map reports the profile name and version, latency in
  milliseconds, whether the deadline was enabled, the strategies that ran to
  completion (a strategy that finished with no hits still counts as
  contributing), the strategies that were dropped, a disagreement summary
  computed before fusion, and the ranked candidate maps. Each candidate map is
  the database record plus `rrf_score` and the strategies that proposed it.

  Raises `ArgumentError` for an unknown profile or strategy name, or for a
  strategy list from a non-internal caller. A strategy killed by the deadline
  never raises; it is reported as dropped. On the concurrent path an exception
  inside a strategy is likewise reported as a dropped strategy, because the
  task exit is indistinguishable from a timeout; on the serial path it
  propagates to the caller.
  """
  def retrieve(query, profile_name, opts \\ []) do
    # Taken before profile resolution so the deadline covers the database read
    # that resolution may perform, not just the strategies.
    started_at = Cartulary.Clock.monotonic_ms()
    profile = Profile.resolve(profile_name, query, opts)
    deadline? = Keyword.get(opts, :deadline?, true)

    concurrent? =
      Keyword.get(
        opts,
        :concurrent?,
        Application.get_env(:cartulary, :retrieval_concurrency, true)
      )

    budget = %Budget{
      deadline_ms: profile.deadline_ms,
      started_at: started_at,
      max_candidates: query.max_candidates,
      deadline?: deadline?
    }

    {seed_lists, seed_dropped} =
      profile.strategy_modules
      |> Enum.filter(&(&1.stage() == :seed))
      |> run_phase(query, budget, concurrent?)

    # Expansion needs a starting set, and it needs it before fusion has run.
    # Interleaving the seed lists by strategy-local rank is a breadth choice,
    # not a relevance judgement: it takes each strategy's best hits so the walk
    # starts from a diverse frontier. The truncation happens before `uniq` so
    # the frontier stays bounded even when strategies agree heavily.
    seed_ids =
      seed_lists
      |> Enum.flat_map(fn {_strategy, candidates} -> candidates end)
      |> Enum.sort_by(& &1.rank)
      |> Enum.take(query.max_candidates)
      |> Enum.map(& &1.id)
      |> Enum.uniq()

    expanded_query = %{query | seed_ids: seed_ids}

    {expand_lists, expand_dropped} =
      profile.strategy_modules
      |> Enum.filter(&(&1.stage() == :expand))
      |> run_phase(expanded_query, budget, concurrent?)

    lists = seed_lists ++ expand_lists
    fused = Fusion.reciprocal_rank(lists, profile.weights, query.max_candidates)
    {ranked, rerank_dropped?} = maybe_rerank(fused, query, profile, budget, concurrent?)

    contributed = Enum.map(lists, fn {strategy, _candidates} -> strategy end)

    # Three different reasons a strategy is missing are reported the same way:
    # switched off by deployment configuration, out of time, or (for the
    # reranker) failed. Callers need the union to judge whether a thin answer
    # reflects thin memory or a degraded run.
    dropped =
      profile.disabled_strategies ++
        seed_dropped ++ expand_dropped ++ if(rerank_dropped?, do: [:reranker], else: [])

    %{
      query: query.text,
      profile: Atom.to_string(profile.name),
      profile_version: profile.version,
      deadline: if(deadline?, do: "enabled", else: "disabled"),
      latency_ms: Cartulary.Clock.monotonic_ms() - started_at,
      contributed_strategies: contributed |> Enum.uniq() |> Enum.map(&Atom.to_string/1),
      dropped_strategies: dropped |> Enum.uniq() |> Enum.map(&Atom.to_string/1),
      # Deliberately computed from the seed lists only, and before fusion:
      # once the lists are merged, the evidence that two strategies picked
      # completely different records is gone.
      disagreement: Fusion.disagreement(seed_lists),
      candidates: Enum.map(ranked, &candidate_map/1)
    }
  end

  # Runs one stage of strategies and returns {completed_lists, dropped_names}.
  # Strategies that report themselves inapplicable are silently skipped rather
  # than reported as dropped: "this query has no text" is not a degraded run.
  defp run_phase([], _query, _budget, _concurrent?), do: {[], []}

  defp run_phase(modules, query, budget, concurrent?) do
    applicable = Enum.filter(modules, & &1.applicable?(query))
    timeout = Budget.remaining_ms(budget)

    if timeout == 0 do
      # Out of time before the phase even starts, typically because the seed
      # phase consumed the whole budget. Report, do not run.
      {[], Enum.map(applicable, & &1.name())}
    else
      results = execute_modules(applicable, query, budget, timeout, concurrent?)

      completed =
        for {:ok, {strategy, candidates}} <- results,
            do: {strategy, candidates}

      # A killed task carries no reference to the strategy that owned it, so
      # the name is recovered positionally. This is only sound because the
      # concurrent path requests ordered results and the serial path builds the
      # list in module order; reordering either would misattribute drops. On
      # the concurrent path a crashing strategy also arrives here as an exit,
      # so it is reported as dropped rather than failing the whole request.
      timed_out =
        results
        |> Enum.with_index()
        |> Enum.flat_map(fn
          {{:ok, _value}, _index} -> []
          {{:exit, _reason}, index} -> [Enum.at(applicable, index).name()]
        end)

      {completed, timed_out}
    end
  end

  defp execute_modules(modules, query, budget, timeout, concurrent?) do
    run = fn module ->
      # Each strategy runs in its own Account-scoped transaction. That is what
      # pins the database session to this Account, so a strategy that somehow
      # omitted its own Account predicate still cannot read another tenant's
      # rows. Validation happens inside the same transaction because the
      # candidate records are read lazily from it.
      candidates =
        DataLayer.with_actor(query.actor, fn _account, actor ->
          scoped_query = %{query | actor: actor}
          candidates = module.candidates(scoped_query, budget)

          Cartulary.Retrieval.Strategy.validate!(
            module,
            candidates,
            min(query.max_candidates, budget.max_candidates)
          )
        end)

      {module.name(), candidates}
    end

    if concurrent? do
      # `ordered: true` is load-bearing: the caller identifies timed-out
      # strategies by position. `on_timeout: :kill_task` implements
      # drop-never-retry — a strategy past the deadline is abandoned outright.
      Task.async_stream(modules, run,
        ordered: true,
        max_concurrency: max(length(modules), 1),
        timeout: timeout,
        on_timeout: :kill_task
      )
      |> Enum.to_list()
    else
      # Serial fallback for the single-connection test sandbox. It cannot
      # interrupt a running strategy, so it can only enforce the deadline
      # between strategies; the shapes it returns match `Task.async_stream`.
      Enum.map(modules, fn module ->
        if Budget.remaining_ms(budget) == 0 do
          {:exit, :timeout}
        else
          {:ok, run.(module)}
        end
      end)
    end
  end

  # Returns {candidates, reranker_dropped?}. Every failure mode keeps the
  # fusion order and reports the reranker as dropped, so a slow or broken model
  # degrades answer ordering rather than the request.
  defp maybe_rerank(candidates, _query, %{rerank: false}, _budget, _concurrent?),
    do: {candidates, false}

  defp maybe_rerank([], _query, _profile, _budget, _concurrent?), do: {[], false}

  defp maybe_rerank(candidates, query, _profile, budget, concurrent?) do
    remaining = Budget.remaining_ms(budget)

    if remaining == 0 do
      {candidates, true}
    else
      # Only the head is reranked: the model call costs tokens and latency
      # proportional to the number of documents, and the tail keeps its fusion
      # order regardless, so paying for it would buy nothing the caller sees.
      head_size = retrieval_config(:rerank_head)
      {head, tail} = Enum.split(candidates, head_size)
      documents = Enum.map(head, & &1.record["statement"])

      # No transaction around the call. The model layer scopes its own configuration read and
      # its usage write to the Account, so nothing here needs one — and wrapping a model call
      # in a transaction would hold a pooled database connection for the whole of a request
      # that has already done all the reading it is going to do.
      call = fn ->
        Gateway.rerank(query.text, documents, %{
          account_id: query.account_id,
          actor: query.actor
        })
      end

      case deadline_call(call, remaining, concurrent?) do
        {:ok, rankings, _provenance} ->
          # The model answers with positions into the head, so a ranking that
          # names a position the head does not have is discarded rather than
          # trusted. Ranks are renumbered across head and tail together so the
          # final list stays dense and 1-based.
          reordered =
            rankings
            |> Enum.sort_by(&ranking_score/1, :desc)
            |> Enum.map(&Enum.at(head, ranking_index(&1)))
            |> Enum.reject(&is_nil/1)
            |> Kernel.++(tail)
            |> Enum.with_index(1)
            |> Enum.map(fn {candidate, rank} -> %{candidate | rank: rank} end)

          {reordered, false}

        {:error, _error} ->
          {candidates, true}
      end
    end
  end

  # Runs `call` under the remaining budget. With the deadline disabled, or on
  # the single-connection serial path where spawning a task would need a second
  # database connection, it simply runs inline and may exceed the nominal time.
  defp deadline_call(call, :infinity, _concurrent?), do: call.()

  defp deadline_call(call, timeout, concurrent?) do
    if concurrent? do
      task = Task.async(call)

      # `brutal_kill` after the yield window: an overrunning rerank is
      # abandoned, never awaited further and never retried.
      case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} -> result
        nil -> {:error, :timeout}
      end
    else
      call.()
    end
  end

  # Reranker responses may arrive with atom or string keys depending on how the
  # provider payload was decoded, and some providers name the field `score`
  # rather than `relevance_score`; all shapes are accepted. A missing position
  # falls back to 0, which points at the head's first entry.
  defp ranking_index(ranking), do: ranking[:index] || ranking["index"] || 0

  defp ranking_score(ranking),
    do: ranking[:relevance_score] || ranking["relevance_score"] || ranking[:score] || 0.0

  # Flattens a candidate into the caller-facing map. Only the database record,
  # the fused score, and the strategy names travel outwards — never the
  # strategy-local raw score, which callers would be tempted to compare across
  # strategies.
  defp candidate_map(%Candidate{} = candidate) do
    candidate.record
    |> Map.put("rrf_score", candidate.score)
    |> Map.put(
      "strategies",
      candidate.evidence
      |> Map.get("strategies", [])
      |> Enum.map(&Atom.to_string/1)
    )
  end

  defp retrieval_config(key) do
    :cartulary
    |> Application.fetch_env!(:retrieval_profiles)
    |> Keyword.fetch!(key)
  end
end
