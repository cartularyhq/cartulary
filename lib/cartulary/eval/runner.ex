# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Eval.Runner do
  @moduledoc """
  Runs normalized eval cases through Cartulary's durable memory surface.
  """

  alias Cartulary.Clock
  alias Cartulary.Eval.{ModelJudge, Scorer}
  alias Cartulary.Memory

  def run(dataset, opts \\ []) do
    profile = Keyword.get(opts, :profile, "balanced")
    account_key = Keyword.get(opts, :account_key, "eval-benchmark")
    run_id = Keyword.get(opts, :run_id) || default_run_id()
    benchmark = dataset.benchmark
    scope_root = "/bench/#{benchmark}/#{run_id}"
    deadline = Keyword.get(opts, :deadline, "disabled")

    cases =
      dataset.cases
      |> take_limit(Keyword.get(opts, :limit_cases))
      |> Enum.map(&run_case(&1, dataset, scope_root, account_key, profile, deadline, opts))

    question_results = Enum.flat_map(cases, & &1.question_results)

    %{
      "report_schema" => "f11-1",
      "cartulary_version" => cartulary_version(),
      "generated_at" => Clock.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "benchmark" => benchmark,
      "source_format" => dataset.source_format,
      "dataset" => %{
        "id" => Map.get(dataset, :dataset_id, "#{benchmark}-in-memory"),
        "sha256" => Map.get(dataset, :dataset_sha256, in_memory_fingerprint(dataset)),
        "split" => Keyword.get(opts, :split, "evaluation")
      },
      "profile" => profile,
      "profile_version" => profile_version(question_results),
      "strategies" => Keyword.get(opts, :strategies),
      "deadline" => deadline,
      "model_roles" => model_role_versions(),
      "judge" => judge_identity(opts),
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

  defp run_case(case, dataset, scope_root, account_key, profile, deadline, opts) do
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

    full_context_tokens =
      messages
      |> Enum.map(&token_count(&1.content))
      |> Enum.sum()

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
              "deadline" => deadline,
              "strategies" => Keyword.get(opts, :strategies)
            })
          end)

        cited_refs = cited_refs(answer, ref_map, question.evidence_granularity)

        deterministic_score =
          Scorer.score_question(question, answer, cited_refs,
            full_context_tokens: full_context_tokens
          )

        score =
          if Keyword.get(opts, :judge, "deterministic") == "model" do
            Map.merge(
              deterministic_score,
              ModelJudge.score(
                question.question,
                Map.get(answer, "answer", ""),
                Map.get(answer, "candidates", [])
              )
            )
          else
            deterministic_score
          end

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

  defp cartulary_version do
    case Application.spec(:cartulary, :vsn) do
      nil -> "0.0.0"
      version -> to_string(version)
    end
  end

  defp model_role_versions do
    :cartulary
    |> Application.fetch_env!(:model_roles)
    |> Map.new(fn {role, config} ->
      {Atom.to_string(role),
       %{
         "provider" => to_string(config.provider),
         "model" => to_string(config.model),
         "version" => to_string(config.model_version),
         "prompt_version" => to_string(config.prompt_version),
         "pipeline_version" => to_string(config.pipeline_version)
       }}
    end)
  end

  defp judge_identity(opts) do
    if Keyword.get(opts, :judge, "deterministic") == "model" do
      ModelJudge.identity()
    else
      %{"kind" => "deterministic", "method" => "deterministic-lexical-f11-1"}
    end
  end

  defp in_memory_fingerprint(dataset) do
    dataset
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp token_count(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^[:alnum:]\s]+/u, " ")
    |> String.split(~r/\s+/, trim: true)
    |> length()
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
