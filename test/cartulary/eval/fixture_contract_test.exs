# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Eval.FixtureContractTest do
  @moduledoc """
  Freezes the evaluation inputs so benchmark numbers stay comparable over time.

  A published quality figure only means something if two things are stable: the
  bytes that were measured, and the way those bytes are turned into cases,
  messages, and questions. This file pins both. `poc-contract-baseline.json`
  records, for each committed fixture, the file's SHA-256 digest and a summary
  of what normalization produced from it; the test recomputes both and demands
  an exact match.

  A failure means one of two different things, and they are worth telling
  apart:

  - **Digest mismatch** — the fixture file itself was edited. Any score
    measured before the edit is now measured over different data.
  - **Summary mismatch** — the fixture is untouched but the normalizer changed
    how it derives ids, formats, or case boundaries. Retrieval and scoring
    behaviour then shifts even though neither of those modules changed.

  Either way the correct response is a deliberate re-baseline with a changelog
  entry, not a quiet update of the JSON to whatever the code now emits.

  `"poc-0"` in the baseline file is a contract identity value. It names the
  frozen behaviour baseline that regression evidence is measured against; it is
  not the application's semantic version and does not move with releases.
  Changing that string is a declared contract transition and obliges a
  maintainer to update the changelog and the surrounding contract evidence.

  This file is itself named as regression evidence elsewhere. Make it clearer
  by improving this documentation, not by renaming the file or the module.
  """

  use ExUnit.Case, async: true

  alias Cartulary.Eval.Adapter

  # Data, not prose: the test reads this JSON file and compares against it.
  @baseline_path "test/fixtures/eval/poc-contract-baseline.json"

  test "poc-0 eval fixtures match the committed source and normalization baseline" do
    baseline = @baseline_path |> File.read!() |> Jason.decode!()

    assert baseline["contract_version"] == "poc-0"

    Enum.each(baseline["fixtures"], fn expected ->
      path = expected["path"]
      dataset = Adapter.load!(path, benchmark: expected["benchmark"])

      # Digest first, then shape: if the source bytes changed, the shape
      # comparison that follows is answering a question about different data.
      assert sha256(path) == expected["sha256"]
      assert summarize(dataset) == expected["normalized"]
    end)
  end

  # Lowercase hex of the raw file bytes — the same encoding recorded in the
  # baseline, so the two are directly comparable strings.
  defp sha256(path) do
    path
    |> File.read!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  # Deliberately records identities and never content. Ids and the detected
  # source format are exactly the parts other components depend on — evidence
  # matching cites message ids, and reports key results by case and question id
  # — while the conversation text is already covered by the digest above.
  # Keeping content out also stops the baseline file from becoming a second,
  # divergent copy of every fixture.
  defp summarize(dataset) do
    %{
      "benchmark" => dataset.benchmark,
      "source_format" => dataset.source_format,
      "case_ids" => Enum.map(dataset.cases, & &1.id),
      "message_ids" =>
        Enum.flat_map(dataset.cases, &Enum.map(&1.messages, fn item -> item.id end)),
      "question_ids" =>
        Enum.flat_map(dataset.cases, &Enum.map(&1.questions, fn item -> item.id end))
    }
  end
end
