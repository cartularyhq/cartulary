# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Mix.Tasks.Cartulary.Eval.Verify do
  @moduledoc "Validates the provenance contract of an f11-1 eval report or suite."

  use Mix.Task

  alias Cartulary.Eval.Report

  @shortdoc "Validates evaluation report provenance"

  @impl true
  def run([path]) do
    report = path |> File.read!() |> Jason.decode!()

    case report do
      %{"report_schema" => "f11-suite-1"} -> Report.validate_suite!(report)
      _report -> Report.validate!(report)
    end

    Mix.shell().info("valid f11-1 evaluation evidence: #{path}")
  end

  def run(_args), do: Mix.raise("usage: mix cartulary.eval.verify PATH")
end
