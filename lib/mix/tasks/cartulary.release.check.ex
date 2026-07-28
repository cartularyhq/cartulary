# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Mix.Tasks.Cartulary.Release.Check do
  @moduledoc """
  Verifies semantic version, changelog, F11 evidence, optional tag identity,
  and required release-eval guardrails.
  """

  use Mix.Task

  alias Cartulary.ReleaseReadiness

  @shortdoc "Fails unless the release satisfies F11 readiness"

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

    result =
      ReleaseReadiness.check!(
        tag: Keyword.get(opts, :tag),
        eval_report: Keyword.get(opts, :eval_report),
        allow_missing_eval: Keyword.get(opts, :allow_missing_eval, false)
      )

    Mix.shell().info("release #{result.version} satisfies F11 readiness")
  end
end
