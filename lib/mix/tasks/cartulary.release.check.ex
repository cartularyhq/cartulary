# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Mix.Tasks.Cartulary.Release.Check do
  @moduledoc """
  Fails unless the working tree is actually releasable.

  This is the last gate before tagging. It reads the repository as data and refuses to pass
  when the version, the changelog, the shipped documentation, the git tag, and the recorded
  evaluation evidence do not all describe the same release.

      mix cartulary.release.check --eval-report /tmp/cartulary-release-eval.json
      mix cartulary.release.check --tag v0.2.0 --eval-report /tmp/cartulary-release-eval.json

  ## Switches

    * `--eval-report PATH` — the evaluation suite document produced by
      `mix cartulary.eval.release`. Required unless `--allow-missing-eval` is given.
    * `--tag NAME` — the tag about to be pushed. Default: unset, and the tag check is
      skipped. When given it must be exactly `v` followed by the declared version, so a
      mistyped tag cannot ship.
    * `--allow-missing-eval` — skip the evaluation evidence check. Default off. This exists
      for metadata-only checks such as an early pull-request lane; a real release must
      supply the report, because without it nothing verifies the quality floors.

  ## What passes and what fails

  The declared version is read from the project's `mix.exs` and must be a single literal
  that parses as Semantic Versioning. `CHANGELOG.md` must still carry an Unreleased section
  and a dated entry for exactly that version, with the anchor evidence the changelog format
  requires. The documents a releaser reads — the README, the agent operating contract, the
  roadmap, the implementation-status note, and the evaluation architecture note — must each
  still describe the release-readiness gate, so a rename cannot quietly orphan it.

  When an evaluation report is supplied, the suite is provenance-validated, every report
  inside it must name the same application version as `mix.exs` (stale evidence from a
  previous version is rejected), and every run flagged as a release guardrail is
  re-asserted against the committed deterministic floors. Ablation runs are ignored here on
  purpose: they inform, they do not gate.

  ## Output and failure behaviour

  On success the task prints one line naming the version it accepted and writes nothing.
  Any failed check raises with the specific reason and the task exits non-zero; there is no
  partial or warning outcome.
  """

  use Mix.Task

  alias Cartulary.ReleaseReadiness

  @shortdoc "Fails unless the release satisfies release readiness"

  @doc """
  Parses the switches described in the module documentation and runs every release check.

  Raises on an unknown switch, on missing evaluation evidence without an explicit opt-out,
  and on any failed check, which surfaces as a non-zero exit status.
  """
  @impl true
  def run(args) do
    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [
          tag: :string,
          eval_report: :string,
          allow_missing_eval: :boolean
        ]
      )

    if invalid != [], do: Mix.raise("invalid options: #{inspect(invalid)}")

    # Deliberately no app.start: every check reads repository files, so this gate stays
    # runnable in a lane that has no database and no configured model provider.
    result =
      ReleaseReadiness.check!(
        tag: Keyword.get(opts, :tag),
        eval_report: Keyword.get(opts, :eval_report),
        allow_missing_eval: Keyword.get(opts, :allow_missing_eval, false)
      )

    Mix.shell().info("release #{result.version} satisfies release readiness")
  end
end
