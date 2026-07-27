# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Mix.Tasks.Cartulary.Identity.Bootstrap do
  use Mix.Task

  @shortdoc "Bootstraps the free Account and its first human administrator"

  @moduledoc """
  Bootstraps the single community Account and its first password identity.

      CARTULARY_BOOTSTRAP_PASSWORD='a long password' \
        mix cartulary.identity.bootstrap \
          --email admin@example.test \
          --name 'Local Admin'

  The JWT printed by this one-time command expires after 12 hours. Use the
  password sign-in endpoint for later sessions.
  """

  @impl true
  def run(argv) do
    Mix.Task.run("app.start")

    {opts, _args, invalid} =
      OptionParser.parse(argv,
        strict: [email: :string, name: :string, password: :string],
        aliases: [e: :email, n: :name]
      )

    if invalid != [], do: Mix.raise("invalid options: #{inspect(invalid)}")

    email = Keyword.get(opts, :email) || Mix.raise("--email is required")
    name = Keyword.get(opts, :name, email)

    password =
      Keyword.get(opts, :password) ||
        System.get_env("CARTULARY_BOOTSTRAP_PASSWORD") ||
        Mix.raise("set CARTULARY_BOOTSTRAP_PASSWORD or pass --password")

    result =
      Cartulary.Identity.bootstrap_human(%{
        email: email,
        name: name,
        password: password
      })

    Mix.shell().info("Bootstrapped community Account #{result.account.key}.")
    Mix.shell().info("Administrator peer: #{result.peer.id}")
    Mix.shell().info("Bearer token (12h): #{result.token}")
  end
end
