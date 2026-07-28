# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Eval.ReleaseSuite do
  @moduledoc """
  Runs the versioned f11-1 engine/product evaluation matrix through the real
  Cartulary memory surface.
  """

  alias Cartulary.Clock
  alias Cartulary.Eval.{Adapter, Report, Runner}

  def run(manifest_path, opts \\ []) do
    manifest = manifest_path |> read_local!() |> Jason.decode!()
    assert_manifest!(manifest)
    root = Path.dirname(manifest_path)
    run_id = Keyword.get(opts, :run_id) || default_run_id()
    account_key = Keyword.get(opts, :account_key, "eval-release")
    thresholds = load_thresholds(root, manifest, opts)
    judge = Keyword.get(opts, :judge, "deterministic")

    unless judge in ["deterministic", "model"] do
      raise ArgumentError, "eval judge must be deterministic or model"
    end

    reports =
      Enum.map(manifest["runs"], fn run ->
        dataset_path = resolve(root, Map.fetch!(run, "dataset"))
        dataset = Adapter.load!(dataset_path, benchmark: Map.fetch!(run, "benchmark"))

        report =
          Runner.run(dataset,
            profile: Map.fetch!(run, "profile"),
            strategies: Map.get(run, "strategies"),
            deadline: Map.get(run, "deadline", "disabled"),
            judge: judge,
            split: Map.fetch!(run, "split"),
            account_key: account_key,
            run_id: "#{run_id}-#{Map.fetch!(run, "id")}",
            limit_cases: Map.get(run, "limit_cases"),
            limit_messages: Map.get(run, "limit_messages"),
            limit_questions: Map.get(run, "limit_questions")
          )
          |> Map.put("matrix_id", Map.fetch!(run, "id"))
          |> Report.validate!()

        if Keyword.get(opts, :assert_thresholds, false) and
             Map.get(run, "release_guardrail", false) do
          Report.assert_thresholds!(report, thresholds)
        end

        report
      end)

    %{
      "report_schema" => "f11-suite-1",
      "suite_version" => Map.fetch!(manifest, "suite_version"),
      "generated_at" => Clock.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "run_id" => run_id,
      "tuning_policy" => Map.fetch!(manifest, "tuning_policy"),
      "reports" => reports
    }
    |> Report.validate_suite!()
  end

  defp assert_manifest!(%{
         "suite_version" => "f11-1",
         "tuning_policy" => %{"published_split" => published, "tuning_split" => tuning},
         "runs" => runs
       })
       when is_binary(published) and is_binary(tuning) and published != tuning and is_list(runs) and
              runs != [] do
    :ok
  end

  defp assert_manifest!(_manifest) do
    raise ArgumentError,
          "release eval manifest must be f11-1 with distinct tuning/published splits and runs"
  end

  defp load_thresholds(root, manifest, opts) do
    path = Keyword.get(opts, :thresholds) || Map.fetch!(manifest, "thresholds")
    root |> resolve(path) |> read_local!() |> Jason.decode!()
  end

  defp resolve(root, path) do
    if Path.type(path) == :absolute, do: path, else: Path.expand(path, root)
  end

  # Paths are operator-owned Mix task inputs, never HTTP request values.
  # sobelow_skip ["Traversal.FileModule"]
  defp read_local!(path), do: File.read!(path)

  defp default_run_id do
    Clock.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
    |> String.replace(~r/[^0-9TZ]+/, "")
  end
end
