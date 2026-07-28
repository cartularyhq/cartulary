# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Mix.Tasks.Cartulary.Eval.Release do
  @moduledoc """
  Runs and validates the F11 release evaluation matrix.

      mix cartulary.eval.release --no-model --assert-thresholds --output report.json
  """

  use Mix.Task

  alias Cartulary.Eval.{ReleaseSuite, Runtime}

  @shortdoc "Runs the F11 release/nightly evaluation matrix"

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
