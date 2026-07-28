# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.ReleaseReadiness do
  @moduledoc "Fail-closed repository, version, changelog, and eval checks for releases."

  alias Cartulary.Eval.Report

  @semver ~r/^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-[0-9A-Za-z.-]+)?$/

  def check!(opts \\ []) do
    root = Keyword.get(opts, :root, File.cwd!())
    version = mix_version!(root)
    assert_semver!(version)
    assert_changelog!(root, version)
    assert_release_docs!(root)
    assert_tag!(version, Keyword.get(opts, :tag))

    case Keyword.get(opts, :eval_report) do
      nil ->
        unless Keyword.get(opts, :allow_missing_eval, false) do
          raise ArgumentError,
                "release evaluation evidence is required; pass --eval-report or --allow-missing-eval for metadata-only checks"
        end

      path ->
        assert_eval!(root, path, version)
    end

    %{version: version, status: :ready}
  end

  def mix_version!(root) do
    mix = read_local!(Path.join(root, "mix.exs"))

    case Regex.run(~r/version:\s*"([^"]+)"/, mix, capture: :all_but_first) do
      [version] -> version
      _match -> raise ArgumentError, "mix.exs must declare one literal version"
    end
  end

  defp assert_semver!(version) do
    unless Regex.match?(@semver, version) do
      raise ArgumentError, "mix.exs version #{inspect(version)} is not Semantic Versioning syntax"
    end
  end

  defp assert_changelog!(root, version) do
    changelog = read_local!(Path.join(root, "CHANGELOG.md"))

    unless String.contains?(changelog, "## [Unreleased]") and
             Regex.match?(~r/^## \[#{Regex.escape(version)}\] - \d{4}-\d{2}-\d{2}$/m, changelog) and
             String.contains?(changelog, "AD-EVAL-") do
      raise ArgumentError,
            "CHANGELOG.md must contain Unreleased, #{version} date, and blueprint-anchor evidence"
    end
  end

  # The evaluation, CI, and release-readiness capability is implemented, so the
  # roadmap no longer carries a phase section for it to be checked complete.
  # The surviving guardrail is that every document a releaser reads must still
  # describe the release gate under the same name.
  @release_docs [
    "README.md",
    "AGENTS.md",
    "docs/roadmap/beta-roadmap.md",
    "docs/implementation-status.md",
    "docs/architecture/evaluation-ci-release-readiness.md"
  ]

  defp assert_release_docs!(root) do
    for file <- @release_docs do
      body = root |> Path.join(file) |> read_local!() |> String.downcase()

      unless String.contains?(body, "release readiness") or
               String.contains?(body, "release-readiness") do
        raise ArgumentError, "#{file} must document evaluation, CI, and release readiness"
      end
    end
  end

  defp assert_tag!(_version, nil), do: :ok

  defp assert_tag!(version, tag) do
    unless tag == "v#{version}" do
      raise ArgumentError, "release tag #{inspect(tag)} must equal v#{version}"
    end
  end

  defp assert_eval!(root, path, version) do
    suite = path |> read_local!() |> Jason.decode!() |> Report.validate_suite!()

    Enum.each(suite["reports"], fn report ->
      unless report["cartulary_version"] == version do
        raise ArgumentError,
              "eval report version #{report["cartulary_version"]} does not match #{version}"
      end
    end)

    manifest =
      root
      |> Path.join("docs/eval/release-suite.json")
      |> read_local!()
      |> Jason.decode!()

    thresholds =
      root
      |> Path.join("docs/eval/deterministic-thresholds.json")
      |> read_local!()
      |> Jason.decode!()

    guarded_ids =
      manifest["runs"]
      |> Enum.filter(&Map.get(&1, "release_guardrail", false))
      |> MapSet.new(& &1["id"])

    suite["reports"]
    |> Enum.filter(&MapSet.member?(guarded_ids, &1["matrix_id"]))
    |> Enum.each(&Report.assert_thresholds!(&1, thresholds))
  end

  # Paths are fixed repository files or operator-owned Mix task inputs.
  # sobelow_skip ["Traversal.FileModule"]
  defp read_local!(path), do: File.read!(path)
end
