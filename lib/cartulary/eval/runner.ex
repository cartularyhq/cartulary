# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Eval.Runner do
  @moduledoc """
  Executes a normalized evaluation dataset against the real memory surface and reports it.

  This is where a benchmark becomes evidence. Each case's messages are written through the
  ordinary durable ingest path, each question is asked through the ordinary answer path,
  and the answers are scored. The runner stubs nothing and takes no shortcut around the
  product code, so the numbers describe the system a user would actually get. An operator
  may still point the node at local deterministic models before starting, and the report
  says so, because it records the model-role identities that were actually in force.

  ## Side effects, and why isolation matters

  A run writes real rows — raw messages, extracted knowledge, lifecycle events, retrieval
  and answer activity — into the configured database, under the Account key it is given.
  Nothing is cleaned up afterwards. Every case is written beneath a scope root built from
  the benchmark name and the run id, and each case gets its own child scope under that.
  Knowledge inherits downward, so that two-level split is what keeps one case's conversation
  from answering another case's question, and one run's data from leaking into the next.
  Give concurrent runs distinct run ids: the default is a UTC timestamp compacted to digits,
  which two runs started in the same second would share.

  Messages are ingested with inline extraction requested. Deferring extraction to the
  background queue would let questions race the job that produces the knowledge they need,
  and the run would score a system that had not finished thinking yet.

  ## Report provenance

  The map returned here is the evaluation report, and its provenance fields are not
  decoration. A quality number means nothing unless a reader can tell which code, which
  data, and which configuration produced it, so every report records:

    * the application's semantic version and the UTC time it was generated;
    * the benchmark, the source layout it was parsed from, and the dataset's id, SHA-256,
      and split;
    * the retrieval profile by name and the exact profile version that actually ran;
    * the raw strategy override, if any, and the deadline setting;
    * provider, model, model version, prompt version, and pipeline version for all four
      model roles — including the roles a given run did not exercise, because the
      configuration as a whole is what was under test;
    * the judge identity, deterministic or model-based;
    * the case, message, and question limits applied, since a truncated run is not
      comparable with a full one;
    * ingest counts, aggregate metrics, and per-question evidence.

  `Cartulary.Eval.Report` re-checks all of that before a report may be published or gate a
  release. Dropping a field here does not simplify the report; it makes it unpublishable.

  The report carries the schema identity `"f11-1"`. That string versions the report format
  itself. Changing the shape of this map means changing that identity, which obliges a
  maintainer to add a changelog entry, regenerate the stored evaluation evidence, and note
  the change in the closest architecture document.

  ## Reading a report

  `"profile_version"` collapses to a single string when every question ran under the same
  retrieval profile version. If they disagree it stays a list, which fails report
  validation on purpose: a mixed-version run cannot be quoted as one measurement.

  `"messages_ingested"` counts only the writes that succeeded. Turns whose ingest did not
  return successfully are absent from the citation reference map, so they cannot be cited
  and their evidence is unreachable — compare it against `"messages_attempted"` before
  trusting a low citation rate.
  """

  alias Cartulary.Clock
  alias Cartulary.Eval.{ModelJudge, Scorer}
  alias Cartulary.Memory

  @doc """
  Runs every case in `dataset` and returns the complete evaluation report.

  `dataset` is the normalized structure produced by `Cartulary.Eval.Adapter`.

  Recognized options:

    * `:profile` — retrieval profile name to answer under. Defaults to `"balanced"`.
    * `:account_key` — Account that owns everything written. Defaults to
      `"eval-benchmark"`. Point it at a scratch Account; the run writes durable rows.
    * `:run_id` — identifies the run and seeds the scope root. Defaults to a UTC timestamp.
    * `:deadline` — `"disabled"` (the default here) removes the profile's latency bound so
      slow strategies still contribute, which is what makes ablations comparable. A run
      that is meant to measure production latency must set it otherwise.
    * `:strategies` — raw retrieval strategy override. Internal and evaluation use only;
      it is recorded in the report because it changes what is being measured.
    * `:split` — dataset split label, defaults to `"evaluation"`. Keeping tuning and
      published splits distinct is what prevents tuned weights from being validated
      against the same rows they were tuned on.
    * `:judge` — `"deterministic"` (default) or `"model"`. The model judge adds its own
      scores beside the deterministic ones and never replaces them.
    * `:limit_cases`, `:limit_messages`, `:limit_questions` — truncate the run. Accepts an
      integer or a numeric string; anything else is ignored and no limit applies.

  Returns the string-keyed report map. Failure modes come from the underlying memory path.
  An ingest that returns something other than a success tuple is counted as not ingested
  and its turn becomes uncitable, but the run continues; an ingest or answer that raises —
  the documented behaviour for an authorization or validation failure — aborts the run. A
  model judge that errors or returns an out-of-range score also raises, because a
  fabricated judge number would corrupt the evidence rather than merely lower it.
  """
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
    # Each case gets its own scope. Knowledge inherits downward, so two cases sharing a
    # scope would let one case's conversation answer another case's question and quietly
    # inflate the score.
    scope_path = "#{scope_root}/#{slug(case.id)}"

    messages =
      case.messages
      |> take_limit(Keyword.get(opts, :limit_messages))

    # Ingested strictly in list order, one at a time. Recency and belief-time both derive
    # from the order turns were written in, so parallelising this would change what the
    # system remembers, not just how fast the run goes.
    ingested =
      messages
      |> Enum.map(fn message ->
        attrs =
          message
          |> Map.take([:peer_key, :session_id, :role, :content, :occurred_at])
          # Session ids are namespaced by scope so that two cases reusing the same
          # benchmark session name do not land in one conversation.
          |> Map.update!(:session_id, &"#{scope_path}:#{&1}")
          |> Map.put(:scope_path, scope_path)
          |> Map.put(:account_key, account_key)
          # Extraction must finish before this case is questioned. Leaving it to the
          # background queue would race the questions against the knowledge they need.
          |> Map.put(:sync_extract, true)

        {message, Memory.ingest_message(attrs)}
      end)

    ref_map = build_ref_map(ingested)

    questions =
      case.questions
      |> take_limit(Keyword.get(opts, :limit_questions))

    # The denominator of the token-efficiency ratio: what a naive agent would have paid by
    # putting this case's entire conversation into the prompt instead of retrieving.
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

        # The model judge only ever adds "model_"-prefixed keys, so merging it over the
        # deterministic score cannot overwrite a reproducible measurement.
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

  # Citation scoring compares the benchmark's own evidence labels, but an answer cites
  # durable database ids. This builds the translation back: durable message id to the
  # benchmark's turn reference, and durable message id to the session that turn came from.
  # Only successful ingests are entered, so a turn that failed to write cannot be scored as
  # a citation hit for something that was never stored.
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

  # Fixtures label evidence at the granularity they were built with. LongMemEval names the
  # session that holds the answer, everything else names individual turns, so the same
  # citation is resolved through a different map depending on which vocabulary applies.
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

  # An answer cites retrieval candidates, and each candidate remembers which raw messages it
  # was derived from. Walking through that provenance is what lets a citation of derived
  # knowledge be checked against a fixture's turn-level or session-level evidence label.
  defp cited_source_message_ids(answer) do
    cited_ids = answer |> Map.get("citations", []) |> MapSet.new()

    answer
    |> Map.get("candidates", [])
    |> Enum.filter(&(Map.get(&1, "id") in cited_ids))
    |> Enum.flat_map(&Map.get(&1, "source_message_ids", []))
    |> Enum.uniq()
  end

  # Per-case detail, including the scope it wrote to, so a surprising number can be traced
  # back to the actual rows that produced it. The case's metrics are the same aggregate the
  # run-level summary computes, restricted to this case's questions.
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

  # Collapses to a single version string when every answer ran under the same retrieval
  # profile version. Disagreement deliberately leaves a list in place, which report
  # validation rejects: a run whose questions were answered by different profile versions
  # is not one measurement and must not be quoted as one.
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

  # Wall-clock milliseconds around the whole answer call — retrieval, fusion, reranking and
  # generation together. Monotonic time is used so a clock adjustment mid-run cannot
  # produce a negative or wildly inflated latency sample.
  defp timed(fun) do
    started_at = System.monotonic_time(:millisecond)
    result = fun.()
    {System.monotonic_time(:millisecond) - started_at, result}
  end

  # Limits arrive from command-line switches, so both integers and numeric strings are
  # accepted. Anything unparseable means "no limit" rather than an error, because the
  # applied limits are recorded in the report and a reader can see none was in force.
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

  # Recorded in every report: a truncated run is not comparable with a full one, and a
  # reader who cannot see the truncation will compare them anyway.
  defp limits(opts) do
    %{
      "cases" => Keyword.get(opts, :limit_cases),
      "messages_per_case" => Keyword.get(opts, :limit_messages),
      "questions_per_case" => Keyword.get(opts, :limit_questions)
    }
  end

  # A second-resolution UTC timestamp stripped to digits plus the date/zone separators, so
  # it is safe inside a scope path. Two runs started in the same second collide; pass an
  # explicit run id when running them concurrently.
  defp default_run_id do
    Clock.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
    |> String.replace(~r/[^0-9TZ]+/, "")
  end

  # The version of the code that produced the numbers. "0.0.0" only appears when the
  # application is not loaded, which means the report did not come from a real release
  # build and must not be published as one.
  defp cartulary_version do
    case Application.spec(:cartulary, :vsn) do
      nil -> "0.0.0"
      version -> to_string(version)
    end
  end

  # All four model roles are recorded, including the ones a given benchmark never invokes.
  # The configuration as a whole is what was under test, and a later reader comparing two
  # reports needs to see that an unused role was also unchanged.
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

  # Who scored the run. "deterministic-lexical-f11-1" names the version of the reproducible
  # lexical scoring method; if that method's formulas change, the identity must change with
  # them, which obliges a changelog entry, regenerated stored evidence, and a note in the
  # closest architecture document. The model branch resolves the live judge configuration
  # and raises if it shares a provider and model with the role that produced the answers.
  defp judge_identity(opts) do
    if Keyword.get(opts, :judge, "deterministic") == "model" do
      ModelJudge.identity()
    else
      %{"kind" => "deterministic", "method" => "deterministic-lexical-f11-1"}
    end
  end

  # A dataset built in memory has no file to hash, but a report must still carry a dataset
  # digest to be valid. Hashing the term encoding distinguishes different in-memory
  # datasets; it is not comparable with the digest the same content would get on disk.
  defp in_memory_fingerprint(dataset) do
    dataset
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  # Whitespace token count over the same normalization the scorer uses, so the full-context
  # size and the measured context size are counted the same way and their ratio is
  # meaningful. It is not a provider tokenizer and does not claim to match billed tokens.
  defp token_count(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^[:alnum:]\s]+/u, " ")
    |> String.split(~r/\s+/, trim: true)
    |> length()
  end

  # Case ids become a scope path segment, so they are reduced to lowercase alphanumerics
  # and dashes. An id that reduces to nothing still needs a segment, hence "case".
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
