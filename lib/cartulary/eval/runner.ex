# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Eval.Runner do
  @moduledoc """
  Runs normalized eval cases through Cartulary's POC memory surface.
  """

  alias Cartulary.Clock
  alias Cartulary.Eval.Scorer
  alias Cartulary.Memory

  def run(dataset, opts \\ []) do
    profile = Keyword.get(opts, :profile, "balanced")
    account_key = Keyword.get(opts, :account_key, "eval-benchmark")
    run_id = Keyword.get_lazy(opts, :run_id, &default_run_id/0)
    benchmark = dataset.benchmark
    scope_root = "/bench/#{benchmark}/#{run_id}"

    cases =
      dataset.cases
      |> take_limit(Keyword.get(opts, :limit_cases))
      |> Enum.map(&run_case(&1, dataset, scope_root, account_key, profile, opts))

    question_results = Enum.flat_map(cases, & &1.question_results)

    %{
      "benchmark" => benchmark,
      "source_format" => dataset.source_format,
      "profile" => profile,
      "profile_version" => profile_version(question_results),
      "account_key" => account_key,
      "run_id" => run_id,
      "scope_root" => scope_root,
      "limits" => limits(opts),
      "messages_attempted" => cases |> Enum.map(& &1.messages_attempted) |> Enum.sum(),
      "messages_ingested" => cases |> Enum.map(& &1.messages_ingested) |> Enum.sum(),
      "questions_attempted" => length(question_results),
      "metrics" => Scorer.summarize(question_results),
      "cases" => Enum.map(cases, &case_report/1)
    }
  end

  defp run_case(case, dataset, scope_root, account_key, profile, opts) do
    scope_path = "#{scope_root}/#{slug(case.id)}"

    messages =
      case.messages
      |> take_limit(Keyword.get(opts, :limit_messages))

    ingested =
      messages
      |> Enum.map(fn message ->
        attrs =
          message
          |> Map.take([:peer_key, :session_id, :role, :content, :occurred_at])
          |> Map.update!(:session_id, &"#{scope_path}:#{&1}")
          |> Map.put(:scope_path, scope_path)
          |> Map.put(:account_key, account_key)
          |> Map.put(:sync_extract, true)

        {message, Memory.ingest_message(attrs)}
      end)

    ref_map = build_ref_map(ingested)

    questions =
      case.questions
      |> take_limit(Keyword.get(opts, :limit_questions))

    question_results =
      questions
      |> Enum.map(fn question ->
        {latency_ms, answer} =
          timed(fn ->
            Memory.ask(%{
              "account_key" => account_key,
              "scope_path" => scope_path,
              "question" => question.question,
              "profile" => profile,
              "deadline" => "disabled"
            })
          end)

        cited_refs = cited_refs(answer, ref_map, question.evidence_granularity)
        score = Scorer.score_question(question, answer, cited_refs)

        Map.merge(score, %{
          "benchmark" => dataset.benchmark,
          "case_id" => case.id,
          "id" => question.id,
          "question" => question.question,
          "expected" => question.expected,
          "category" => question.category || case.category,
          "scale" => case.scale,
          "answer" => Map.get(answer, "answer"),
          "citations" => Map.get(answer, "citations", []),
          "profile_version" => Map.get(answer, "profile_version"),
          "contributed_strategies" => Map.get(answer, "contributed_strategies", []),
          "dropped_strategies" => Map.get(answer, "dropped_strategies", []),
          "latency_ms" => latency_ms
        })
      end)

    %{
      id: case.id,
      category: case.category,
      scale: case.scale,
      scope_path: scope_path,
      messages_attempted: length(messages),
      messages_ingested:
        Enum.count(ingested, fn {_message, result} -> match?({:ok, _}, result) end),
      questions_attempted: length(questions),
      question_results: question_results
    }
  end

  defp build_ref_map(ingested) do
    ingested
    |> Enum.reduce(%{message_by_db_id: %{}, session_by_db_id: %{}}, fn
      {source, {:ok, %{"id" => db_id}}}, acc ->
        source_session_ref =
          source
          |> Map.get(:metadata, %{})
          |> Map.get("source_session_id", source.session_id)

        acc
        |> put_in([:message_by_db_id, db_id], source.id)
        |> put_in([:session_by_db_id, db_id], source_session_ref)

      {_source, _error}, acc ->
        acc
    end)
  end

  defp cited_refs(answer, ref_map, "session") do
    answer
    |> cited_source_message_ids()
    |> Enum.map(&Map.get(ref_map.session_by_db_id, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp cited_refs(answer, ref_map, _granularity) do
    answer
    |> cited_source_message_ids()
    |> Enum.map(&Map.get(ref_map.message_by_db_id, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp cited_source_message_ids(answer) do
    cited_ids = answer |> Map.get("citations", []) |> MapSet.new()

    answer
    |> Map.get("candidates", [])
    |> Enum.filter(&(Map.get(&1, "id") in cited_ids))
    |> Enum.flat_map(&Map.get(&1, "source_message_ids", []))
    |> Enum.uniq()
  end

  defp case_report(case) do
    %{
      "id" => case.id,
      "category" => case.category,
      "scale" => case.scale,
      "scope_path" => case.scope_path,
      "messages_attempted" => case.messages_attempted,
      "messages_ingested" => case.messages_ingested,
      "questions_attempted" => case.questions_attempted,
      "metrics" => Scorer.summarize(case.question_results)["overall"],
      "questions" => case.question_results
    }
  end

  defp profile_version([]), do: nil

  defp profile_version(results) do
    results
    |> Enum.map(&Map.get(&1, "profile_version"))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> case do
      [version] -> version
      versions -> versions
    end
  end

  defp timed(fun) do
    started_at = System.monotonic_time(:millisecond)
    result = fun.()
    {System.monotonic_time(:millisecond) - started_at, result}
  end

  defp take_limit(values, nil), do: values
  defp take_limit(values, ""), do: values

  defp take_limit(values, limit) when is_integer(limit) and limit > 0,
    do: Enum.take(values, limit)

  defp take_limit(values, limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {integer, ""} when integer > 0 -> Enum.take(values, integer)
      _other -> values
    end
  end

  defp take_limit(values, _limit), do: values

  defp limits(opts) do
    %{
      "cases" => Keyword.get(opts, :limit_cases),
      "messages_per_case" => Keyword.get(opts, :limit_messages),
      "questions_per_case" => Keyword.get(opts, :limit_questions)
    }
  end

  defp default_run_id do
    Clock.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
    |> String.replace(~r/[^0-9TZ]+/, "")
  end

  defp slug(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "case"
      slug -> slug
    end
  end
end
