# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Retrieval.Engine do
  @moduledoc """
  Runs retrieval strategies under one deadline, fuses their ranks, and optionally reranks.

  Seed strategies run first. Their interleaved, bounded ids feed expansion strategies; this
  chooses the expansion frontier, not the final order. Weighted reciprocal-rank fusion orders all
  candidates, then a model may rerank the fused head.

  The budget includes profile resolution, strategies, and reranking. Timeouts are killed without
  retry and reported as dropped, as is a strategy whose dependency was unavailable; reranker
  failure preserves fusion order. Strategies normally run concurrently; tests may run them
  serially against one sandbox connection.

  Every response separates three per-strategy outcomes: contributed, empty, and dropped. A
  strategy that ran and found nothing is not degradation, but it is also not a contribution, and
  a caller cannot tell a ranked answer from a recency dump without seeing the difference.

  Each strategy runs in its own Account transaction and must filter scope, lifecycle, and
  provisional subjects before returning candidates. This module does no post-filtering.
  """

  alias Cartulary.DataLayer
  alias Cartulary.Model.Gateway
  alias Cartulary.Retrieval.{Budget, Candidate, Fusion, Profile}

  @doc """
  Executes one retrieval request and returns the response map.

  `query` has an authorized Account, actor, and scopes. `profile_name` selects the posture.
  Options:

  * `:deadline?` (default true) — set false to remove the time budget; only for
    evaluation runs and dream-time rebuilds, never a live request.
  * `:concurrent?` — overrides the application-level concurrency setting; the
    test sandbox turns it off because it owns a single database connection.
  * `:internal?` and `:strategies` — naming strategies explicitly is restricted
    to server-side and evaluation callers; profile resolution raises otherwise.
  * `:inherit?` — set false to ignore any stored per-scope profile override.

  Returns profile metadata, latency in milliseconds, contributed, empty, and dropped
  strategies, pre-fusion disagreement, and ranked records with `rrf_score` and contributing
  strategies.

  Raises `ArgumentError` for an unknown profile or strategy name, or for a
  strategy list from a non-internal caller. A strategy killed by the deadline
  never raises, nor does one that reported itself unable to run; both are
  reported as dropped. On the concurrent path an exception
  inside a strategy is likewise reported as a dropped strategy, because the
  task exit is indistinguishable from a timeout; on the serial path it
  propagates to the caller.
  """
  def retrieve(query, profile_name, opts \\ []) do
    # Include profile resolution in the request deadline.
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

    # Interleave before fusion for a diverse, bounded expansion frontier. Taking before `uniq`
    # keeps the frontier bounded even when strategies agree.
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

    # Running to completion is not contributing. A strategy that returned nothing is reported
    # separately, because collapsing it into either other set hides the run that ranked the
    # scope instead of the query.
    {contributing_lists, empty_lists} =
      Enum.split_with(lists, fn {_strategy, candidates} -> candidates != [] end)

    # Include disabled, timed-out, and failed work so callers can distinguish degradation.
    dropped =
      profile.disabled_strategies ++
        seed_dropped ++ expand_dropped ++ if(rerank_dropped?, do: [:reranker], else: [])

    query_dependent =
      for module <- profile.strategy_modules, module.query_dependent?(), do: module.name()

    %{
      query: query.text,
      profile: Atom.to_string(profile.name),
      profile_version: profile.version,
      deadline: if(deadline?, do: "enabled", else: "disabled"),
      latency_ms: Cartulary.Clock.monotonic_ms() - started_at,
      contributed_strategies: strategy_names(contributing_lists),
      empty_strategies: strategy_names(empty_lists),
      dropped_strategies: dropped |> Enum.uniq() |> Enum.map(&Atom.to_string/1),
      # Fusion destroys evidence of strategy disagreement.
      disagreement: Fusion.disagreement(seed_lists, query_dependent),
      candidates: Enum.map(ranked, &candidate_map/1)
    }
  end

  defp strategy_names(lists) do
    lists
    |> Enum.map(fn {strategy, _candidates} -> Atom.to_string(strategy) end)
    |> Enum.uniq()
  end

  # Inapplicable strategies are skipped, not reported as degraded.
  defp run_phase([], _query, _budget, _concurrent?), do: {[], []}

  defp run_phase(modules, query, budget, concurrent?) do
    applicable = Enum.filter(modules, & &1.applicable?(query))
    timeout = Budget.remaining_ms(budget)

    if timeout == 0 do
      # Report applicable work that the exhausted budget prevented.
      {[], Enum.map(applicable, & &1.name())}
    else
      results = execute_modules(applicable, query, budget, timeout, concurrent?)

      completed =
        for {:ok, {strategy, candidates}} <- results,
            is_list(candidates),
            do: {strategy, candidates}

      # A strategy that could not run at all — an unavailable embedder, say — is
      # degradation, not absence, so it joins the dropped list rather than
      # contributing an empty result the caller would read as "nothing matched".
      unavailable =
        for {:ok, {strategy, {:error, _reason}}} <- results, do: strategy

      # Task exits lack strategy names. Ordered results make this positional lookup safe; changing
      # result order would misattribute drops. Concurrent crashes are also reported as dropped.
      timed_out =
        results
        |> Enum.with_index()
        |> Enum.flat_map(fn
          {{:ok, _value}, _index} -> []
          {{:exit, _reason}, index} -> [Enum.at(applicable, index).name()]
        end)

      {completed, unavailable ++ timed_out}
    end
  end

  defp execute_modules(modules, query, budget, timeout, concurrent?) do
    run = fn module ->
      # Pin the database session to the Account and validate lazily read records inside it.
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
      # Ordering maps task exits to strategies; timed-out work is killed without retry.
      Task.async_stream(modules, run,
        ordered: true,
        max_concurrency: max(length(modules), 1),
        timeout: timeout,
        on_timeout: :kill_task
      )
      |> Enum.to_list()
    else
      # The single-connection test path can enforce deadlines only between strategies.
      Enum.map(modules, fn module ->
        if Budget.remaining_ms(budget) == 0 do
          {:exit, :timeout}
        else
          {:ok, run.(module)}
        end
      end)
    end
  end

  # Reranker failure preserves fusion order and reports degradation.
  defp maybe_rerank(candidates, _query, %{rerank: false}, _budget, _concurrent?),
    do: {candidates, false}

  defp maybe_rerank([], _query, _profile, _budget, _concurrent?), do: {[], false}

  defp maybe_rerank(candidates, query, _profile, budget, concurrent?) do
    remaining = Budget.remaining_ms(budget)

    if remaining == 0 do
      {candidates, true}
    else
      # Rerank only the visible head to bound model cost and latency.
      head_size = retrieval_config(:rerank_head)
      {head, tail} = Enum.split(candidates, head_size)
      documents = Enum.map(head, & &1.record["statement"])

      # The model layer scopes its own reads and usage writes; do not hold a database connection
      # during the external call.
      call = fn ->
        Gateway.rerank(query.text, documents, %{
          account_id: query.account_id,
          actor: query.actor
        })
      end

      case deadline_call(call, remaining, concurrent?) do
        {:ok, rankings, _provenance} ->
          # Ignore invalid positions and keep final ranks dense and 1-based.
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

  # Disabled deadlines and the single-connection test path run inline.
  defp deadline_call(call, :infinity, _concurrent?), do: call.()

  defp deadline_call(call, timeout, concurrent?) do
    if concurrent? do
      task = Task.async(call)

      # Abandon an overdue rerank without waiting or retrying.
      case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} -> result
        nil -> {:error, :timeout}
      end
    else
      call.()
    end
  end

  # Accept provider key variants; a missing index selects the first head entry.
  defp ranking_index(ranking), do: ranking[:index] || ranking["index"] || 0

  defp ranking_score(ranking),
    do: ranking[:relevance_score] || ranking["relevance_score"] || ranking[:score] || 0.0

  # Do not expose incomparable strategy-local scores.
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
