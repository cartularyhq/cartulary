# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Retrieval.Engine do
  @moduledoc "Two-phase, deadline-bounded strategy fan-out with RRF and optional rerank."

  alias Cartulary.DataLayer
  alias Cartulary.Model.Gateway
  alias Cartulary.Retrieval.{Budget, Candidate, Fusion, Profile}

  def retrieve(query, profile_name, opts \\ []) do
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
      disagreement: Fusion.disagreement(seed_lists),
      candidates: Enum.map(ranked, &candidate_map/1)
    }
  end

  defp run_phase([], _query, _budget, _concurrent?), do: {[], []}

  defp run_phase(modules, query, budget, concurrent?) do
    applicable = Enum.filter(modules, & &1.applicable?(query))
    timeout = Budget.remaining_ms(budget)

    if timeout == 0 do
      {[], Enum.map(applicable, & &1.name())}
    else
      results = execute_modules(applicable, query, budget, timeout, concurrent?)

      completed =
        for {:ok, {strategy, candidates}} <- results,
            do: {strategy, candidates}

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
      Task.async_stream(modules, run,
        ordered: true,
        max_concurrency: max(length(modules), 1),
        timeout: timeout,
        on_timeout: :kill_task
      )
      |> Enum.to_list()
    else
      Enum.map(modules, fn module ->
        if Budget.remaining_ms(budget) == 0 do
          {:exit, :timeout}
        else
          {:ok, run.(module)}
        end
      end)
    end
  end

  defp maybe_rerank(candidates, _query, %{rerank: false}, _budget, _concurrent?),
    do: {candidates, false}

  defp maybe_rerank([], _query, _profile, _budget, _concurrent?), do: {[], false}

  defp maybe_rerank(candidates, query, _profile, budget, concurrent?) do
    remaining = Budget.remaining_ms(budget)

    if remaining == 0 do
      {candidates, true}
    else
      head_size = retrieval_config(:rerank_head)
      {head, tail} = Enum.split(candidates, head_size)
      documents = Enum.map(head, & &1.record["statement"])

      call = fn ->
        DataLayer.with_actor(query.actor, fn _account, actor ->
          context = %{account_id: query.account_id, actor: actor}
          Gateway.rerank(query.text, documents, context)
        end)
      end

      case deadline_call(call, remaining, concurrent?) do
        {:ok, rankings, _provenance} ->
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

  defp deadline_call(call, :infinity, _concurrent?), do: call.()

  defp deadline_call(call, timeout, concurrent?) do
    if concurrent? do
      task = Task.async(call)

      case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} -> result
        nil -> {:error, :timeout}
      end
    else
      call.()
    end
  end

  defp ranking_index(ranking), do: ranking[:index] || ranking["index"] || 0

  defp ranking_score(ranking),
    do: ranking[:relevance_score] || ranking["relevance_score"] || ranking[:score] || 0.0

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
