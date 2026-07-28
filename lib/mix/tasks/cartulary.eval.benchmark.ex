# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Mix.Tasks.Cartulary.Eval.Benchmark do
  @moduledoc """
  Runs one public or local memory benchmark fixture end to end and prints a scored report.

  The fixture is normalized into a common case shape, ingested through the ordinary durable
  write path, queried through the ordinary answer path, and scored. Recognized source
  shapes are LoCoMo, LongMemEval, ConvoMem, BEAM, and Cartulary's own
  `{"messages": [...], "questions": [...]}` form.

      mix cartulary.eval.benchmark --benchmark locomo --dataset data/locomo10.json
      mix cartulary.eval.benchmark --benchmark longmemeval \
        --dataset data/longmemeval_s_cleaned.json
      mix cartulary.eval.benchmark --benchmark beam --dataset data/beam.json --output report.json

  Useful development limits:

      mix cartulary.eval.benchmark --dataset data/locomo10.json \
        --limit-cases 1 --limit-questions 5

  ## Switches

    * `--dataset PATH`, `-d` — required. JSON or JSON-lines fixture. Its bytes are hashed
      so the report can name the exact data a number came from.
    * `--benchmark NAME`, `-b` — one of `locomo`, `longmemeval`, `convomem`, `beam`,
      `cartulary`. Default: inferred from the fixture's shape. Pass it explicitly when a
      fixture is ambiguous or hand-edited.
    * `--profile NAME`, `-p` — retrieval profile under test. Default `balanced`.
    * `--account KEY` — Account key that owns everything the run writes. Default
      `eval-benchmark`.
    * `--run-id ID` — identifies the run and seeds the scope root it writes under. Default:
      a UTC timestamp. Give concurrent runs distinct ids so their scopes cannot collide.
    * `--output PATH`, `-o` — write the report here. Default: print to standard output.
    * `--limit-cases N`, `--limit-messages N`, `--limit-questions N` — truncate the fixture
      for a fast local loop. Default: no limit. The chosen limits are recorded in the
      report, because a truncated run is not comparable with a full one.
    * `--no-model` — run against the deterministic local extractor and answerer instead of
      a live provider. Default off.

  ## What it writes

  Durable rows in the configured database, under the given Account key and a scope root
  derived from the benchmark name and run id. Nothing is cleaned up afterwards. Use a
  scratch database; never an Account key holding real user data.

  Standard output (or `--output`) receives one pretty-printed report carrying the
  application version, generation timestamp, benchmark and source format, dataset id, its
  SHA-256 and split, profile and profile version, strategy override, deadline setting, the
  four model-role identities, the judge identity, applied limits, ingest counts, scored
  metrics, and per-case detail. That provenance set is what makes a published number
  checkable, so do not strip fields from the report before sharing it.

  ## Scope of the result

  This task scores a single configuration; it applies no pass/fail floor. Release gating is
  `mix cartulary.eval.release`, which runs the whole matrix and asserts the committed
  thresholds.

  ## Failure behaviour

  An unknown switch, a missing `--dataset`, an unreadable or unrecognizable fixture, or an
  unwritable output path raises and the task exits non-zero.
  """

  use Mix.Task

  alias Cartulary.Eval.{Adapter, Runner, Runtime}

  @shortdoc "Runs full Cartulary benchmark ingestion/scoring"

  @doc """
  Parses the switches described in the module documentation, runs the benchmark, and emits
  the report to standard output or `--output`.

  Raises on invalid arguments, unusable fixtures, and unwritable output, which surfaces as
  a non-zero exit status.
  """
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

    # Ordering matters and is easy to "tidy" into a bug: switching to deterministic models
    # rewrites application environment (job execution becomes manual, the ingest-extractor,
    # dream-reasoner, and dialectic-agent roles point at the local fallback, and provider
    # keys are cleared; the embedder role is left alone so vectors stay compatible with the
    # installed indexes). The supervision tree reads that environment once, at boot, so the
    # rewrite has to happen before app.start or the run will still reach a live provider.
    if Keyword.get(opts, :no_model, false), do: Runtime.use_deterministic_models()
    Mix.Task.run("app.start")

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
end
