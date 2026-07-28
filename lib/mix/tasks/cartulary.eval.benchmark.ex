# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Mix.Tasks.Cartulary.Eval.Benchmark do
  @moduledoc """
  Runs LoCoMo, LongMemEval, BEAM, or Cartulary-shaped benchmark fixtures through
  the local POC memory engine.

      mix cartulary.eval.benchmark --benchmark locomo --dataset data/locomo10.json
      mix cartulary.eval.benchmark --benchmark longmemeval --dataset data/longmemeval_s_cleaned.json
      mix cartulary.eval.benchmark --benchmark beam --dataset data/beam.json --output report.json

  Useful development limits:

      mix cartulary.eval.benchmark --dataset data/locomo10.json --limit-cases 1 --limit-questions 5

  Pass `--no-model` to force deterministic extractor/answer fallback for local
  regression runs.
  """

  use Mix.Task

  alias Cartulary.Eval.Adapter
  alias Cartulary.Eval.Runner

  @shortdoc "Runs full Cartulary benchmark ingestion/scoring"

  @impl true
  def run(args) do
    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [
          benchmark: :string,
          dataset: :string,
          profile: :string,
          account: :string,
          run_id: :string,
          output: :string,
          limit_cases: :integer,
          limit_messages: :integer,
          limit_questions: :integer,
          no_model: :boolean
        ],
        aliases: [
          b: :benchmark,
          d: :dataset,
          p: :profile,
          o: :output
        ]
      )

    if invalid != [] do
      Mix.raise("invalid options: #{inspect(invalid)}")
    end

    dataset_path = Keyword.get(opts, :dataset) || Mix.raise("--dataset is required")
    Mix.Task.run("app.start")
    maybe_disable_model(opts)

    dataset =
      Adapter.load!(dataset_path,
        benchmark: Keyword.get(opts, :benchmark)
      )

    Mix.shell().info(
      "running #{dataset.benchmark} from #{dataset.source_format}: #{length(dataset.cases)} case(s)"
    )

    report =
      Runner.run(dataset,
        profile: Keyword.get(opts, :profile, "balanced"),
        account_key: Keyword.get(opts, :account, "eval-benchmark"),
        run_id: Keyword.get(opts, :run_id),
        limit_cases: Keyword.get(opts, :limit_cases),
        limit_messages: Keyword.get(opts, :limit_messages),
        limit_questions: Keyword.get(opts, :limit_questions)
      )

    encoded = Jason.encode_to_iodata!(report, pretty: true)

    case Keyword.get(opts, :output) do
      nil ->
        IO.puts(encoded)

      path ->
        File.write!(path, encoded)
        Mix.shell().info("wrote #{path}")
    end
  end

  defp maybe_disable_model(opts) do
    if Keyword.get(opts, :no_model, false) do
      models = Application.get_env(:cartulary, :models, [])
      Application.put_env(:cartulary, :models, Keyword.put(models, :api_key, nil))

      roles =
        :cartulary
        |> Application.fetch_env!(:model_roles)
        |> Enum.map(fn
          {role, config} when role in [:ingest_extractor, :dream_reasoner, :dialectic_agent] ->
            {role,
             config
             |> Map.put(:provider, "deterministic")
             |> Map.put(:model, "local-structured-fallback")
             |> Map.put(:model_version, "1")}

          role_config ->
            role_config
        end)

      Application.put_env(:cartulary, :model_roles, roles)
      System.delete_env("OPENROUTER_API_KEY")
    end
  end
end
