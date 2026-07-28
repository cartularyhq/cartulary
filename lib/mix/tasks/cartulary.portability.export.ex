# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Mix.Tasks.Cartulary.Portability.Export do
  @moduledoc "Exports the configured free Account to a verified logical archive."

  use Mix.Task

  @shortdoc "Export the free Account"

  @switches [output: :string]
  @aliases [o: :output]

  @impl true
  def run(args) do
    {opts, _rest, invalid} = OptionParser.parse(args, strict: @switches, aliases: @aliases)
    if invalid != [], do: Mix.raise("invalid options: #{inspect(invalid)}")

    output =
      Keyword.get(opts, :output) ||
        "cartulary-export-#{Date.utc_today() |> Date.to_iso8601()}.tar.gz"

    Mix.Task.run("app.start")

    result =
      Cartulary.DataLayer.with_existing_free_account(fn _account, actor ->
        {:ok, result} = Cartulary.Portability.export(actor, output)
        result
      end)

    Mix.shell().info("Exported #{result.account_id} to #{result.path}")
  end
end
