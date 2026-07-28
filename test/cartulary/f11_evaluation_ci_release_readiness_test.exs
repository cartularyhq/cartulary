# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.F11EvaluationCiReleaseReadinessTest do
  @moduledoc """
  Pins the release gate: version discipline, evaluation evidence, CI coverage, and the
  honesty of what the project claims to ship.

  Most tests check that code works. This one checks that the *process* around the code
  cannot quietly degrade — that a release cannot be cut without a changelog entry, that a
  published quality number cannot be stated without the information needed to reproduce it,
  that CI still runs both database configurations, and that documentation cannot advertise
  a surface that does not exist.

  It reads repository files (workflow definitions, the release matrix, the surface
  inventory) as data and asserts on their content, so it fails when someone deletes a CI
  job or relabels an unavailable surface as shipped.

  ## What it pins

  * **Version and changelog agree.** The declared version is valid Semantic Versioning and
    has a dated changelog entry.
  * **Evaluation reports fail closed.** A report missing any reproducibility field is
    invalid, and a result below a committed floor raises. A benchmark number without its
    exact version, dataset digest, split, deadline, and model identities is unreproducible
    and therefore not publishable.
  * **Tuning and published data are separate splits.** Fusion weights may only be tuned on
    held-out data; tuning on the split you then report is how a benchmark becomes fiction.
  * **The evaluation matrix covers the shipped benchmarks and their ablations.** For every
    benchmark there is a named-profile run plus single-strategy variants, so a headline
    number can always be compared against what one strategy alone achieves.
  * **CI keeps both database configurations green** — one against an operator-run Postgres,
    one against the packaged embedded launcher — and still builds both the release and the
    container. That is what makes "one codebase, two deployment modes" true rather than
    aspirational. It also asserts a retired database engine has not crept back in.
  * **The entity cache stays invisible on every public surface**, checked here across routes,
    the router source, and the client helper sources, independently of the retrieval suite.
  * **Unimplemented surfaces stay marked unavailable.** Generated API schemas and generated
    clients do not exist at this version; the inventory says so, and the release must not
    present the hand-written helper modules as complete clients.
  * **The evaluation judge is independent and reproducible.** When a model grades answers,
    it must come from a different provider or model family than the one that produced them,
    and the graded run is replayed from a recorded script so the score is deterministic.

  ## The contract identity strings

  `f11-1` versions the evaluation report schema; `f11-suite-1` versions the bundle of
  reports a release ships. `f7-1` (retrieval profile) and `f5-1` (extractor and pipeline)
  appear inside a report because a result is meaningless without them. All are data that
  external tooling pins; changing one is a deliberate contract transition requiring a
  changelog entry and updated evidence.

  ## If this file fails

  Ask what the change removed from the release gate. Deleting a CI step, dropping a
  reproducibility field, or flipping a surface from `unavailable` to `gated` all make this
  file green and make a future release claim something untrue.
  """

  use ExUnit.Case, async: false

  alias Cartulary.Eval.ModelJudge
  alias Cartulary.Eval.Report
  alias Cartulary.Model.CassetteProvider
  alias Cartulary.ReleaseReadiness

  test "semantic application version has a dated changelog entry and F11 documentation" do
    # The version the build declares. When this changes, the changelog entry, the tag, and
    # the surface inventory release field below all have to change with it.
    assert ReleaseReadiness.mix_version!(File.cwd!()) == "0.2.0"

    # Metadata-only pass: version syntax, dated changelog entry, and agreement between the
    # documents a releaser reads. Evaluation evidence is skipped here because a real report
    # requires a full benchmark run; the release command itself demands one.
    assert %{status: :ready, version: "0.2.0"} =
             ReleaseReadiness.check!(allow_missing_eval: true)
  end

  test "public eval evidence fails closed on missing reproducibility identity" do
    report = valid_report()
    assert Report.validate(report) == :ok

    # Remove one reproducibility field and the whole report becomes invalid. Retrieval
    # ranking behaviour is versioned, so a score without the profile version cannot be
    # compared against any other score — validation refuses rather than degrading silently.
    assert {:error, errors} = report |> Map.delete("profile_version") |> Report.validate()
    assert "profile_version must identify exactly one profile version" in errors

    # Thresholds are a floor, and falling below one raises rather than warns. The fixture
    # scores 0.5 accuracy against a demanded 1.0, so this must fail — a regression must stop
    # a release, not appear in a log nobody reads.
    assert_raise ArgumentError, ~r/eval regression/, fn ->
      Report.assert_thresholds!(report, %{
        "benchmarks" => %{"locomo" => %{"balanced" => %{"accuracy" => 1.0}}}
      })
    end
  end

  test "release suite separates held-out tuning and published splits and covers the matrix" do
    suite = "specs/eval/release-suite.json" |> File.read!() |> Jason.decode!()
    runs = suite["runs"]

    assert suite["suite_version"] == "f11-1"
    # The split used to tune ranking weights must never be the split whose results are
    # published. Tuning on the reported data inflates every number and cannot be detected
    # from the numbers themselves, so it is enforced structurally here.
    refute suite["tuning_policy"]["tuning_split"] == suite["tuning_policy"]["published_split"]

    assert MapSet.new(Enum.map(runs, & &1["benchmark"])) ==
             MapSet.new(~w(cartulary locomo longmemeval convomem beam))

    for benchmark <- ~w(locomo longmemeval convomem beam) do
      variants = Enum.filter(runs, &(&1["benchmark"] == benchmark))
      # Three variants per external benchmark: the named profile (no strategy override, so
      # `strategies` is null), plus two single-strategy ablations. Without the ablations a
      # headline number cannot be attributed — you cannot tell whether the full pipeline
      # actually beats plain keyword search or plain recency.
      assert Enum.any?(variants, &is_nil(&1["strategies"]))
      assert Enum.any?(variants, &(&1["strategies"] == ["lexical"]))
      assert Enum.any?(variants, &(&1["strategies"] == ["salience_recency"]))
      # Deadlines off for every published run: a timing-dependent cutoff would make results
      # depend on how loaded the machine was, and quality would stop being comparable.
      assert Enum.all?(variants, &(&1["deadline"] == "disabled"))
    end
  end

  test "CI gates both database modes, builds releases, and has no retired SQLite lane" do
    ci = File.read!(".github/workflows/ci.yml")
    nightly = File.read!(".github/workflows/eval.yml")
    release = File.read!(".github/workflows/release.yml")

    # Each of these is a gate someone could delete to make a red build go green: schema-drift
    # detection, formatting, warnings-as-errors, the test suite, linting, type checking,
    # security scanning, the evaluation run, the release metadata check, and proof that both
    # the release and the container still build. Asserting on the workflow text is crude but
    # it is the only thing that notices a removed step.
    for command <- [
          "mix ash.codegen --check",
          "mix format --check-formatted",
          "mix compile --warnings-as-errors",
          "mix test",
          "mix credo --strict",
          "mix dialyzer",
          "mix sobelow --config",
          "mix cartulary.eval.release",
          "mix cartulary.release.check",
          "mix release --overwrite",
          "docker build"
        ] do
      assert ci =~ command
    end

    # Both database configurations run the same suite. Losing either lane means the two
    # deployment modes stop being verified as equivalent.
    assert ci =~ "external Postgres"
    assert ci =~ "packaged pg0"
    # A retired embedded engine that must not return: it cannot provide the vector and
    # full-text behaviour the product depends on, so supporting it would fork the guarantees.
    refute String.downcase(ci) =~ "sqlite"
    # The nightly evaluation workflow runs on a schedule and provisions its own database.
    assert nightly =~ "schedule:"
    assert nightly =~ "mix ecto.create"
    assert nightly =~ "mix ecto.migrate"
    # Releases are triggered by a semantic version tag and repeat the packaged-database lane
    # on the tagged commit, so the artifact is built from verified code.
    assert release =~ "tags: [\"v*.*.*\"]"
    assert release =~ "./scripts/ci-pg0-lane"
  end

  test "entity and mention caches remain absent from every current public surface" do
    public_routes =
      CartularyWeb.Router.__routes__()
      |> Enum.map_join("\n", fn route -> "#{route.verb} #{route.path}" end)
      |> String.downcase()

    router = File.read!("lib/cartulary_web/router.ex") |> String.downcase()
    sdk = Path.wildcard("sdk/**/*.*") |> Enum.map_join("\n", &File.read!/1) |> String.downcase()

    # Entities and their mentions are a private recall cache built from governed statements.
    # Exposing them would create a second, ungoverned view of who an account knows about,
    # bypassing the approval and consent rules that apply to knowledge itself.
    #
    # Checked three ways because each catches a different mistake: compiled routes catch a
    # route added anywhere, the router source catches a resource wired in by an atom, and the
    # client helper sources catch a field name that leaked into a published type definition.
    refute public_routes =~ "entity"
    refute public_routes =~ "mention"
    refute router =~ ":entity"
    refute router =~ ":mention"
    refute sdk =~ "entity_id"
    refute sdk =~ "entitymention"
  end

  test "surface inventory gates shipped contracts and fails closed around the integration-surfaces boundary" do
    inventory =
      "specs/eval/surface-contract-inventory.json"
      |> File.read!()
      |> Jason.decode!()

    # The inventory is the machine-readable answer to "what does this release actually
    # offer?". It is versioned with the application so a consumer can trust it.
    assert inventory["release"] == "0.2.0"

    # "gated" means the surface ships and has a test lane holding its contract in place.
    assert inventory["surfaces"]["phoenix_http"]["status"] == "gated"
    assert inventory["surfaces"]["mcp"]["status"] == "gated"
    assert inventory["surfaces"]["skill_readiness_helpers"]["status"] == "gated"

    # "unavailable" means not built yet, and it must stay that way until it is. Generated API
    # schemas and generated clients do not exist at this version; the hand-written readiness
    # helper modules are not substitutes for them. Marking one of these shipped — or dropping
    # it from the inventory so no lane is missing — would make the release overstate itself.
    for surface <- ~w(ash_json_api_openapi generated_typescript_sdk generated_python_sdk) do
      assert inventory["surfaces"][surface]["status"] == "unavailable"
      assert inventory["surfaces"][surface]["prerequisite"] == "integration-surfaces"
    end
  end

  test "provider cassette replays an independent-family model judge deterministically" do
    original_roles = Application.fetch_env!(:cartulary, :model_roles)
    original_provider = Application.get_env(:cartulary, :model_provider)

    # The judge runs on the reasoning role, which must resolve to a different provider or
    # model family than the role that produced the answers. A model grading its own family's
    # output is not an independent measurement.
    roles =
      Keyword.update!(original_roles, :dream_reasoner, fn config ->
        config
        |> Map.put(:provider, "cassette")
        |> Map.put(:model, "independent-rag-judge")
        |> Map.put(:model_version, "judge-1")
      end)

    Application.put_env(:cartulary, :model_roles, roles)
    Application.put_env(:cartulary, :model_provider, CassetteProvider)
    # Replaying a recorded verdict makes the judged score deterministic. A live judge would
    # make this test flaky and would make published scores unreproducible.
    CassetteProvider.start!("test/fixtures/model/f11-judge-cassette.json", "rag_triad")

    on_exit(fn ->
      CassetteProvider.stop()
      Application.put_env(:cartulary, :model_roles, original_roles)

      if original_provider,
        do: Application.put_env(:cartulary, :model_provider, original_provider),
        else: Application.delete_env(:cartulary, :model_provider)
    end)

    score =
      ModelJudge.score(
        "What format is preferred?",
        "Concise bullet points.",
        [%{"statement" => "Concise bullet points are preferred."}]
      )

    # Three separate axes, not one blended score: whether the answer is supported by the
    # retrieved material, whether that material was relevant to the question, and whether the
    # answer addresses the question. They fail independently and must stay distinguishable.
    # The values come from the recorded verdict, normalised from its 1-5 integer scale.
    assert score["model_groundedness"] == 1.0
    assert score["model_context_relevance"] == 0.75
    assert score["model_answer_relevance"] == 0.5
    # The judge's identity travels with the score, because a score is only interpretable
    # alongside who produced it.
    assert score["model_judge"]["model"] == "independent-rag-judge"
    # Exactly one provider call, on the reasoning role, for the judging task. More calls
    # would mean retries or leakage of the answer into another request.
    assert CassetteProvider.calls() == [{"structured", "dream_reasoner", "eval_judge"}]
  end

  # A minimal report that passes validation, used as the baseline the negative cases mutate.
  #
  # Every field here is load-bearing for reproducibility, which is why validation rejects a
  # report missing any of them: the application version, the exact retrieval profile version,
  # any strategy override, the deadline setting, the run limits, the dataset identity with
  # its digest and split, all four model-role identities, and how the answers were graded.
  # Together they are the complete recipe for re-running the measurement.
  defp valid_report do
    %{
      "report_schema" => "f11-1",
      "cartulary_version" => "0.2.0",
      "generated_at" => "2026-07-28T12:00:00Z",
      "benchmark" => "locomo",
      "profile" => "balanced",
      "profile_version" => "f7-1",
      "strategies" => nil,
      "deadline" => "disabled",
      "limits" => %{
        "cases" => nil,
        "messages_per_case" => nil,
        "questions_per_case" => nil
      },
      "dataset" => %{
        "id" => "locomo.json",
        "sha256" => String.duplicate("a", 64),
        "split" => "release-evaluation"
      },
      "model_roles" =>
        Map.new(~w(embedder ingest_extractor dream_reasoner dialectic_agent), fn role ->
          {role,
           %{
             "provider" => "deterministic",
             "model" => "fixture",
             "version" => "1",
             "prompt_version" => "1",
             "pipeline_version" => "f5-1"
           }}
        end),
      "judge" => %{"kind" => "deterministic", "method" => "deterministic-lexical-f11-1"},
      "metrics" => %{
        "overall" => %{
          "accuracy" => 0.5,
          "abstention_accuracy" => nil,
          "citation_hit_rate" => 0.5,
          "mean_citation_recall" => 0.5,
          "mean_groundedness" => 0.5,
          "mean_context_relevance" => 0.5,
          "mean_answer_relevance" => 0.5,
          "mean_end_to_end_tokens" => 10.0,
          "mean_full_context_tokens" => 20.0,
          "mean_token_efficiency_ratio" => 0.5
        }
      }
    }
  end
end
