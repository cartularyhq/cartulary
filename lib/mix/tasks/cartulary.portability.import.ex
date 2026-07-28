# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Mix.Tasks.Cartulary.Portability.Import do
  @moduledoc "Imports a verified logical archive into a fresh database."

  use Mix.Task

  @shortdoc "Import an Account archive"

  @switches [input: :string, validate_only: :boolean]
  @aliases [i: :input]

  @impl true
  def run(args) do
    {opts, _rest, invalid} = OptionParser.parse(args, strict: @switches, aliases: @aliases)
    if invalid != [], do: Mix.raise("invalid options: #{inspect(invalid)}")

    input = Keyword.get(opts, :input) || Mix.raise("--input is required")
    Mix.Task.run("app.start")

    if Keyword.get(opts, :validate_only, false) do
      {:ok, result} = Cartulary.Portability.validate(input)
      Mix.shell().info("Archive valid: #{result.account_id} (#{result.manifest_hash})")
    else
      {:ok, result} = Cartulary.Portability.import(input)
      Mix.shell().info("Imported #{result.account_id}; derived rebuilds enqueued")
    end
  end
end
