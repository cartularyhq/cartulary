# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Mix.Tasks.Cartulary.Eval.Release do
  @moduledoc """
  Runs the whole release evaluation matrix and emits one validated suite document.

  A manifest lists the runs that make up the matrix: for each entry, which benchmark
  fixture to load, which retrieval profile to use, whether to force a strategy override,
  which deadline setting applies, which dataset split it belongs to, and whether it is a
  release guardrail or a reported ablation. Every run is executed through the ordinary
  ingest and answer path, scored, and provenance-validated; the results are wrapped in a
  suite envelope. This is the command CI and the release procedure use.

      mix cartulary.eval.release --no-model --assert-thresholds --output report.json

  ## Switches

    * `--manifest PATH` — matrix definition. Default `docs/eval/release-suite.json`.
    * `--thresholds PATH` — deterministic floors to assert. Default: the path the manifest
      names, resolved relative to the manifest's own directory.
    * `--output PATH` — write the suite document here. Default: print to standard output.
      Unlike the smoke and benchmark tasks, no "wrote" line is printed.
    * `--account KEY` — Account key that owns everything the matrix writes. Default
      `eval-release`.
    * `--run-id ID` — prefix for each run's id and for the scope roots it writes under.
      Default: a UTC timestamp. Concurrent runs need distinct ids.
    * `--judge KIND` — `deterministic` (default) or `model`. `deterministic` uses
      reproducible lexical scoring. `model` calls a live judge whose provider/model family
      must differ from the one that produced the answers, and the run fails if it does not.
    * `--no-model` — run against the deterministic local extractor and answerer. Default
      off. Do not combine it with `--judge model`: the judge would then be scoring with the
      same local fallback, which produces a number that means nothing.
    * `--assert-thresholds` — fail the task when a guardrail run misses a committed floor.
      Default off, so a bare invocation reports without gating. CI and releases pass it.

  ## Guardrails versus ablations

  Only manifest entries flagged as release guardrails are threshold-checked. Strategy
  ablations (lexical-only, salience-and-recency-only, and similar) are executed and
  reported so regressions are visible, but they never gate a release. Splits are kept
  distinct on purpose: the manifest must declare a tuning split separate from the published
  one, so fusion weights tuned on held-out data are never validated against the same rows.

  ## Contract identities in the output

  Each individual report carries `report_schema` `"f11-1"`, and the envelope around them
  carries `"f11-suite-1"`; the manifest must declare `suite_version` `"f11-1"` to be
  accepted. Those strings are the evaluation-evidence contract. Changing one is a
  deliberate transition that obliges a maintainer to update the changelog, regenerate the
  stored evidence, and note the change in the closest architecture document — it is not a
  free-form label.

  ## Failure behaviour

  An unknown switch, a manifest that is not the expected version or lacks distinct splits
  or runs, an unreadable fixture, a report that fails provenance validation, or a guardrail
  run below its floor all raise, and the task exits non-zero. The raise happens before the
  output file is written, so a failed gated run leaves no report behind: treat a missing
  artifact as a failure rather than as "nothing to report".
  """

  use Mix.Task

  alias Cartulary.Eval.{ReleaseSuite, Runtime}

  @shortdoc "Runs the release/nightly evaluation matrix"

  @doc """
  Parses the switches described in the module documentation, runs every matrix entry, and
  emits the validated suite document to standard output or `--output`.

  Raises on invalid arguments, manifest or report contract violations, and guardrail
  threshold failures, which surfaces as a non-zero exit status.
  """
  @impl true
  def run(args) do
    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [
          manifest: :string,
          thresholds: :string,
          output: :string,
          account: :string,
          run_id: :string,
          judge: :string,
          no_model: :boolean,
          assert_thresholds: :boolean
        ]
      )

    if invalid != [], do: Mix.raise("invalid options: #{inspect(invalid)}")

    # Ordering matters and is easy to "tidy" into a bug: switching to deterministic models
    # rewrites application environment (job execution becomes manual, the ingest-extractor,
    # dream-reasoner, and dialectic-agent roles point at the local fallback, and provider
    # keys are cleared; the embedder role is left alone so vectors stay compatible with the
    # installed indexes). The supervision tree reads that environment once, at boot, so the
    # rewrite has to happen before app.start or the run will still reach a live provider.
    if Keyword.get(opts, :no_model, false), do: Runtime.use_deterministic_models()
    Mix.Task.run("app.start")

    report =
      ReleaseSuite.run(
        Keyword.get(opts, :manifest, "docs/eval/release-suite.json"),
        account_key: Keyword.get(opts, :account, "eval-release"),
        run_id: Keyword.get(opts, :run_id),
        thresholds: Keyword.get(opts, :thresholds),
        judge: Keyword.get(opts, :judge, "deterministic"),
        assert_thresholds: Keyword.get(opts, :assert_thresholds, false)
      )

    encoded = Jason.encode_to_iodata!(report, pretty: true)

    case Keyword.get(opts, :output) do
      nil -> IO.puts(encoded)
      path -> File.write!(path, encoded)
    end
  end
end
