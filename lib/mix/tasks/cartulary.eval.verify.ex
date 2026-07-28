# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Mix.Tasks.Cartulary.Eval.Verify do
  @moduledoc """
  Checks that a stored evaluation report carries enough provenance to be quotable.

      mix cartulary.eval.verify /tmp/cartulary-eval.json

  ## Command line

  Exactly one positional argument: the path to a JSON evaluation report or suite. There are
  no switches, no defaults, and nothing is written — the task only reads and reports.

  ## What it enforces

  A number is only meaningful next to the conditions that produced it, so a valid report
  must name the exact application version, the generation timestamp, the benchmark, the
  retrieval profile and its version, the deadline setting, any strategy override, the run
  limits, the dataset id with its SHA-256 and split, all four model-role identities
  (embedder, ingest extractor, dream reasoner, dialectic agent), the judge, and the scored
  metrics. Anything missing means the run cannot be reproduced or compared and is rejected.

  The task accepts either shape. A document whose `report_schema` is `"f11-suite-1"` is a
  matrix envelope and every report inside it is checked; anything else is validated as a
  single `"f11-1"` report. Both strings are the evaluation-evidence contract identity;
  changing either is a deliberate transition that obliges a maintainer to update the
  changelog, regenerate the stored evidence, and record the change in the closest
  architecture document.

  ## What it does not do

  This is a provenance check only. It re-runs nothing, recomputes no metric, and compares
  no score against a release floor — thresholds are asserted by the release evaluation and
  release check tasks.

  ## Failure behaviour

  A missing file, malformed JSON, a wrong argument count, or any missing provenance field
  raises and the task exits non-zero. On success it prints one confirmation line naming the
  validated path.
  """

  use Mix.Task

  alias Cartulary.Eval.Report

  @shortdoc "Validates evaluation report provenance"

  @doc """
  Validates the report at the single positional path.

  Raises when the path is unreadable, the JSON is malformed, the provenance contract is not
  satisfied, or the argument list is not exactly one path; each surfaces as a non-zero exit
  status.
  """
  @impl true
  def run([path]) do
    # Deliberately no app.start: validation is pure JSON inspection, so this stays usable
    # on a machine with no database, which is how CI checks an uploaded artifact.
    report = path |> File.read!() |> Jason.decode!()

    case report do
      %{"report_schema" => "f11-suite-1"} -> Report.validate_suite!(report)
      _report -> Report.validate!(report)
    end

    Mix.shell().info("valid f11-1 evaluation evidence: #{path}")
  end

  # Any argument list other than a single path is a caller mistake, not a default-path
  # invitation: silently verifying some assumed file would let CI "pass" on stale evidence.
  def run(_args), do: Mix.raise("usage: mix cartulary.eval.verify PATH")
end
