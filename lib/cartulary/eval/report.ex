# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Eval.Report do
  @moduledoc """
  Validates f11-1 evaluation reports and deterministic release thresholds.

  Public quality claims are valid only when the report identifies the exact
  Cartulary version, dataset digest and split, retrieval profile version,
  deadline setting, model-role versions, judge, and execution date.
  """

  @roles ~w(embedder ingest_extractor dream_reasoner dialectic_agent)
  @metric_keys ~w(
    accuracy
    abstention_accuracy
    citation_hit_rate
    mean_citation_recall
    mean_groundedness
    mean_context_relevance
    mean_answer_relevance
    mean_end_to_end_tokens
    mean_full_context_tokens
    mean_token_efficiency_ratio
  )

  def validate(report) when is_map(report) do
    []
    |> require_equal(report, "report_schema", "f11-1")
    |> require_semver(report, "cartulary_version")
    |> require_datetime(report, "generated_at")
    |> require_non_empty(report, "benchmark")
    |> require_non_empty(report, "profile")
    |> require_profile_version(report)
    |> require_member(report, "deadline", ~w(enabled disabled fixed))
    |> require_strategies(report)
    |> require_limits(report)
    |> require_dataset(report)
    |> require_model_roles(report)
    |> require_judge(report)
    |> require_metrics(report)
    |> Enum.reverse()
    |> case do
      [] -> :ok
      errors -> {:error, errors}
    end
  end

  def validate(_report), do: {:error, ["report must be an object"]}

  def validate!(report) do
    case validate(report) do
      :ok ->
        report

      {:error, errors} ->
        raise ArgumentError, "invalid f11-1 eval report: #{Enum.join(errors, "; ")}"
    end
  end

  def validate_suite!(%{"report_schema" => "f11-suite-1", "reports" => reports} = suite)
      when is_list(reports) and reports != [] do
    Enum.each(reports, &validate!/1)
    suite
  end

  def validate_suite!(_suite) do
    raise ArgumentError, "invalid F11 eval suite: expected non-empty f11-suite-1 reports"
  end

  def assert_thresholds!(report, thresholds) when is_map(thresholds) do
    benchmark = Map.fetch!(report, "benchmark")
    profile = Map.fetch!(report, "profile")
    metrics = get_in(report, ["metrics", "overall"]) || %{}

    expected =
      get_in(thresholds, ["benchmarks", benchmark, profile]) ||
        raise ArgumentError, "no deterministic threshold for #{benchmark}/#{profile}"

    failures =
      for {metric, minimum} <- expected,
          actual = Map.get(metrics, metric),
          not is_number(actual) or actual < minimum,
          do: "#{benchmark}/#{profile} #{metric}=#{inspect(actual)} is below #{minimum}"

    case failures do
      [] -> report
      _failures -> raise ArgumentError, "eval regression: #{Enum.join(failures, "; ")}"
    end
  end

  defp require_equal(errors, report, key, expected) do
    if Map.get(report, key) == expected,
      do: errors,
      else: ["#{key} must equal #{expected}" | errors]
  end

  defp require_semver(errors, report, key) do
    case Map.get(report, key) do
      value when is_binary(value) ->
        if Regex.match?(
             ~r/^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-[0-9A-Za-z.-]+)?$/,
             value
           ),
           do: errors,
           else: ["#{key} must be semantic version syntax" | errors]

      _value ->
        ["#{key} must be semantic version syntax" | errors]
    end
  end

  defp require_datetime(errors, report, key) do
    case Map.get(report, key) do
      value when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, _datetime, _offset} -> errors
          _error -> ["#{key} must be an ISO 8601 datetime" | errors]
        end

      _value ->
        ["#{key} must be an ISO 8601 datetime" | errors]
    end
  end

  defp require_non_empty(errors, report, key) do
    case Map.get(report, key) do
      value when is_binary(value) and value != "" -> errors
      _value -> ["#{key} must be a non-empty string" | errors]
    end
  end

  defp require_profile_version(errors, report) do
    case Map.get(report, "profile_version") do
      value when is_binary(value) and value != "" -> errors
      _value -> ["profile_version must identify exactly one profile version" | errors]
    end
  end

  defp require_member(errors, report, key, allowed) do
    if Map.get(report, key) in allowed,
      do: errors,
      else: ["#{key} must be one of #{Enum.join(allowed, ", ")}" | errors]
  end

  defp require_strategies(errors, %{"strategies" => nil}), do: errors

  defp require_strategies(errors, %{"strategies" => strategies})
       when is_list(strategies) and strategies != [] do
    if Enum.all?(strategies, &(is_binary(&1) and &1 != "")),
      do: errors,
      else: ["strategies must contain non-empty names" | errors]
  end

  defp require_strategies(errors, _report) do
    ["strategies must be null for a named profile or a non-empty internal override" | errors]
  end

  defp require_limits(errors, report) do
    case Map.get(report, "limits") do
      %{
        "cases" => cases,
        "messages_per_case" => messages,
        "questions_per_case" => questions
      } ->
        if Enum.all?([cases, messages, questions], &(is_nil(&1) or (is_integer(&1) and &1 > 0))),
          do: errors,
          else: ["limits must be null or positive integers" | errors]

      _limits ->
        ["limits must identify cases, messages_per_case, and questions_per_case" | errors]
    end
  end

  defp require_dataset(errors, report) do
    case Map.get(report, "dataset") do
      %{"id" => id, "sha256" => sha256, "split" => split}
      when is_binary(id) and id != "" and is_binary(sha256) and is_binary(split) and split != "" ->
        if Regex.match?(~r/^[0-9a-f]{64}$/, sha256),
          do: errors,
          else: ["dataset.sha256 must be a lowercase SHA-256" | errors]

      _dataset ->
        ["dataset must include non-empty id, lowercase sha256, and split" | errors]
    end
  end

  defp require_model_roles(errors, report) do
    roles = Map.get(report, "model_roles", %{})

    Enum.reduce(@roles, errors, fn role, acc ->
      case Map.get(roles, role) do
        %{
          "provider" => provider,
          "model" => model,
          "version" => version,
          "prompt_version" => prompt_version,
          "pipeline_version" => pipeline_version
        }
        when provider != "" and model != "" and version != "" and prompt_version != "" and
               pipeline_version != "" ->
          acc

        _role ->
          [
            "model_roles.#{role} must include exact provider/model/version/prompt/pipeline identity"
            | acc
          ]
      end
    end)
  end

  defp require_judge(errors, report) do
    case Map.get(report, "judge") do
      %{"kind" => "deterministic", "method" => method}
      when is_binary(method) and method != "" ->
        errors

      %{
        "kind" => "model",
        "method" => method,
        "provider" => provider,
        "model" => model,
        "model_version" => version
      }
      when method != "" and provider != "" and model != "" and version != "" ->
        errors

      _judge ->
        ["judge must identify method and exact provider/model/version when model-based" | errors]
    end
  end

  defp require_metrics(errors, report) do
    overall = get_in(report, ["metrics", "overall"]) || %{}

    Enum.reduce(@metric_keys, errors, fn key, acc ->
      value = Map.get(overall, key)

      if is_number(value) or (key == "abstention_accuracy" and is_nil(value)),
        do: acc,
        else: ["metrics.overall.#{key} must be numeric" | acc]
    end)
  end
end
