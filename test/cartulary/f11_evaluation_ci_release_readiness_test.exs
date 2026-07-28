# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.F11EvaluationCiReleaseReadinessTest do
  use ExUnit.Case, async: false

  alias Cartulary.Eval.ModelJudge
  alias Cartulary.Eval.Report
  alias Cartulary.Model.CassetteProvider
  alias Cartulary.ReleaseReadiness

  test "semantic application version has a dated changelog entry and F11 documentation" do
    assert ReleaseReadiness.mix_version!(File.cwd!()) == "0.2.0"

    assert %{status: :ready, version: "0.2.0"} =
             ReleaseReadiness.check!(allow_missing_eval: true)
  end

  test "public eval evidence fails closed on missing reproducibility identity" do
    report = valid_report()
    assert Report.validate(report) == :ok

    assert {:error, errors} = report |> Map.delete("profile_version") |> Report.validate()
    assert "profile_version must identify exactly one profile version" in errors

    assert_raise ArgumentError, ~r/eval regression/, fn ->
      Report.assert_thresholds!(report, %{
        "benchmarks" => %{"locomo" => %{"balanced" => %{"accuracy" => 1.0}}}
      })
    end
  end

  test "release suite separates held-out tuning and published splits and covers the matrix" do
    suite = "docs/eval/release-suite.json" |> File.read!() |> Jason.decode!()
    runs = suite["runs"]

    assert suite["suite_version"] == "f11-1"
    refute suite["tuning_policy"]["tuning_split"] == suite["tuning_policy"]["published_split"]

    assert MapSet.new(Enum.map(runs, & &1["benchmark"])) ==
             MapSet.new(~w(cartulary locomo longmemeval convomem beam))

    for benchmark <- ~w(locomo longmemeval convomem beam) do
      variants = Enum.filter(runs, &(&1["benchmark"] == benchmark))
      assert Enum.any?(variants, &is_nil(&1["strategies"]))
      assert Enum.any?(variants, &(&1["strategies"] == ["lexical"]))
      assert Enum.any?(variants, &(&1["strategies"] == ["salience_recency"]))
      assert Enum.all?(variants, &(&1["deadline"] == "disabled"))
    end
  end

  test "CI gates both database modes, builds releases, and has no retired SQLite lane" do
    ci = File.read!(".github/workflows/ci.yml")
    nightly = File.read!(".github/workflows/eval.yml")
    release = File.read!(".github/workflows/release.yml")

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

    assert ci =~ "external Postgres"
    assert ci =~ "packaged pg0"
    refute String.downcase(ci) =~ "sqlite"
    assert nightly =~ "schedule:"
    assert nightly =~ "mix ecto.create"
    assert nightly =~ "mix ecto.migrate"
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

    refute public_routes =~ "entity"
    refute public_routes =~ "mention"
    refute router =~ ":entity"
    refute router =~ ":mention"
    refute sdk =~ "entity_id"
    refute sdk =~ "entitymention"
  end

  test "surface inventory gates shipped contracts and fails closed around the integration-surfaces boundary" do
    inventory =
      "docs/eval/surface-contract-inventory.json"
      |> File.read!()
      |> Jason.decode!()

    assert inventory["release"] == "0.2.0"
    assert inventory["surfaces"]["phoenix_http"]["status"] == "gated"
    assert inventory["surfaces"]["mcp"]["status"] == "gated"
    assert inventory["surfaces"]["skill_readiness_helpers"]["status"] == "gated"

    for surface <- ~w(ash_json_api_openapi generated_typescript_sdk generated_python_sdk) do
      assert inventory["surfaces"][surface]["status"] == "unavailable"
      assert inventory["surfaces"][surface]["prerequisite"] == "integration-surfaces"
    end
  end

  test "provider cassette replays an independent-family model judge deterministically" do
    original_roles = Application.fetch_env!(:cartulary, :model_roles)
    original_provider = Application.get_env(:cartulary, :model_provider)

    roles =
      Keyword.update!(original_roles, :dream_reasoner, fn config ->
        config
        |> Map.put(:provider, "cassette")
        |> Map.put(:model, "independent-rag-judge")
        |> Map.put(:model_version, "judge-1")
      end)

    Application.put_env(:cartulary, :model_roles, roles)
    Application.put_env(:cartulary, :model_provider, CassetteProvider)
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

    assert score["model_groundedness"] == 1.0
    assert score["model_context_relevance"] == 0.75
    assert score["model_answer_relevance"] == 0.5
    assert score["model_judge"]["model"] == "independent-rag-judge"
    assert CassetteProvider.calls() == [{"structured", "dream_reasoner", "eval_judge"}]
  end

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
