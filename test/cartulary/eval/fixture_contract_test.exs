# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Eval.FixtureContractTest do
  use ExUnit.Case, async: true

  alias Cartulary.Eval.Adapter

  @baseline_path "test/fixtures/eval/poc-contract-baseline.json"

  test "poc-0 eval fixtures match the committed source and normalization baseline" do
    baseline = @baseline_path |> File.read!() |> Jason.decode!()

    assert baseline["contract_version"] == "poc-0"

    Enum.each(baseline["fixtures"], fn expected ->
      path = expected["path"]
      dataset = Adapter.load!(path, benchmark: expected["benchmark"])

      assert sha256(path) == expected["sha256"]
      assert summarize(dataset) == expected["normalized"]
    end)
  end

  defp sha256(path) do
    path
    |> File.read!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

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
