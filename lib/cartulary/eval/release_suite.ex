# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Eval.ReleaseSuite do
  @moduledoc """
  Executes a whole evaluation matrix from a manifest and returns one validated envelope.

  A single benchmark run answers "how did this configuration do on this fixture". The
  matrix answers "is this build releasable". It executes several fixture-and-configuration
  combinations through the real memory surface, validates each result's provenance, asserts
  the committed floors on the ones designated as guardrails, and wraps everything in one
  document a release check can read.

  ## The manifest

  The manifest is a JSON file. It declares its suite version, the path to the floors
  document, a tuning policy, and a list of runs. Paths inside it are resolved relative to
  the manifest's own directory, so a manifest and its fixtures move together.

  Each run must name an id, a benchmark, a dataset path, a retrieval profile, and a split;
  omitting any of those raises. It may also mark itself a release guardrail — absent, it is
  not one — and set a strategy override, a deadline setting, and case, message, and
  question limits. Deadlines default to disabled here: ablations are only comparable with
  each other if none of them is silently truncated by a latency bound.

  ## Guardrails versus ablations

  Only runs flagged as release guardrails are threshold-checked, and only when the caller
  asks for assertion. The rest — strategy ablations and similar — are executed and reported
  so a regression is visible, but they never block a release. That split is intentional: an
  ablation measures a component in isolation and is expected to score worse than the
  product configuration.

  ## Why tuning and published splits must differ

  The manifest is rejected unless its tuning split and published split are different
  strings. Fusion weights and similar tunables may be fitted only on the tuning split; if
  the same rows were then used to produce the published numbers, the report would be
  measuring how well the system was fitted to its own test set. Enforcing the distinction
  in the manifest is what keeps that mistake from being a quiet configuration slip.

  ## Contract identities

  The manifest must declare suite version `"f11-1"`, and the envelope produced here carries
  the report schema `"f11-suite-1"` around individual reports that each carry `"f11-1"`.
  Those strings version the evaluation-evidence format. Changing what a suite or report
  contains means changing the identity, which obliges a maintainer to add a changelog
  entry, regenerate the stored evidence, and note it in the closest architecture document.

  ## Side effects

  This is not a read-only check. Every run writes durable rows through the ordinary ingest
  path under the given Account key, and nothing is cleaned up afterwards. Run it against a
  scratch database.
  """

  alias Cartulary.Clock
  alias Cartulary.Eval.{Adapter, Report, Runner}

  @doc """
  Runs every entry in the manifest at `manifest_path` and returns the validated envelope.

  Recognized options:

    * `:account_key` — Account that owns everything the matrix writes. Defaults to
      `"eval-release"`. All runs share it; they are separated by scope, not by Account.
    * `:run_id` — prefix for each run's id, and therefore for the scope root it writes
      under. Defaults to a UTC timestamp; give concurrent matrices distinct ids.
    * `:thresholds` — path to the floors document, overriding the one the manifest names.
    * `:judge` — `"deterministic"` (default) or `"model"`. Anything else raises.
    * `:assert_thresholds` — when true, guardrail runs are checked against the floors.
      Defaults to false, so a bare invocation reports without gating.

  Returns the envelope map: the suite schema identity, the manifest's suite version, the
  generation timestamp, the run id, the tuning policy copied from the manifest, and the
  list of reports.

  Raises `ArgumentError` for an unusable judge, a manifest that is the wrong version or
  lacks distinct splits or runs, a report that fails provenance validation, or a guardrail
  below its floor. Raises `File.Error` or `Jason.DecodeError` for an unreadable or
  malformed manifest, floors document, or fixture, and `KeyError` when a run omits a
  required key. Validation and threshold assertion happen per run as the matrix proceeds,
  so a failure aborts immediately and no envelope is produced — a missing result means the
  matrix failed, never that it found nothing.
  """
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

    # Runs execute in manifest order, one at a time. Their data is already separated by
    # scope, but they share a database, so overlapping them would make every run contend
    # with the others and turn the recorded latencies into noise. Sequential execution also
    # means the first failing run aborts the matrix before the rest waste time.
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
          # The matrix id ties a report back to the manifest entry that configured it,
          # which is the only way to tell two runs over the same fixture apart.
          |> Map.put("matrix_id", Map.fetch!(run, "id"))
          # Validate immediately rather than at the end, so a report missing provenance is
          # caught next to the run that produced it.
          |> Report.validate!()

        # Ablations are executed and reported but never gated: they measure a component in
        # isolation and are expected to score below the product configuration. Only entries
        # the manifest marks as guardrails carry a floor, and only when asked to assert.
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

  # Structural gate on the manifest, checked before anything is executed. The version must
  # match exactly, the tuning and published splits must be different strings so tuned
  # weights are never validated on the rows they were fitted to, and there must be at least
  # one run — an empty matrix would otherwise report success without measuring anything.
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

  # Loaded up front, before any run executes, so a missing or malformed floors document
  # fails in seconds rather than after the whole matrix has been written to the database.
  defp load_thresholds(root, manifest, opts) do
    path = Keyword.get(opts, :thresholds) || Map.fetch!(manifest, "thresholds")
    root |> resolve(path) |> read_local!() |> Jason.decode!()
  end

  # Relative paths in a manifest are relative to the manifest, not to the working
  # directory, so a matrix runs the same from anywhere it is invoked.
  defp resolve(root, path) do
    if Path.type(path) == :absolute, do: path, else: Path.expand(path, root)
  end

  # Paths are operator-owned Mix task inputs, never HTTP request values.
  # sobelow_skip ["Traversal.FileModule"]
  defp read_local!(path), do: File.read!(path)

  # A second-resolution UTC timestamp reduced to digits and the date/zone separators, so it
  # is safe as a scope path segment. Two matrices started in the same second would collide;
  # pass an explicit run id when running them concurrently.
  defp default_run_id do
    Clock.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
    |> String.replace(~r/[^0-9TZ]+/, "")
  end
end
