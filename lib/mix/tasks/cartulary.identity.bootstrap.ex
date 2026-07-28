# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Mix.Tasks.Cartulary.Identity.Bootstrap do
  use Mix.Task

  @shortdoc "Bootstraps the free Account and its first human administrator"

  @moduledoc """
  Creates the single community Account and its first human administrator.

  This is the one-time step that turns a migrated but empty database into a usable
  installation. It provisions the community Account if it does not exist, registers a human
  peer with a password identity, grants that peer the administrator role on the root scope
  with downward propagation, and prints a short-lived bearer token so the operator can make
  an authenticated call immediately.

      CARTULARY_BOOTSTRAP_PASSWORD='a long password' \
        mix cartulary.identity.bootstrap \
          --email admin@example.test \
          --name 'Local Admin'

  ## Switches

    * `--email ADDRESS`, `-e` — required. Becomes the sign-in identity, and a normalized
      form of it becomes the administrator's peer key.
    * `--name TEXT`, `-n` — display name. Default: the email address.
    * `--password TEXT` — takes precedence over the environment variable. Prefer the
      environment variable: an argument is visible in shell history and in the process list
      of every other user on the machine.

  ## Environment

    * `CARTULARY_BOOTSTRAP_PASSWORD` — the password to set when `--password` is absent. If
      neither is present the task refuses to run rather than inventing a default
      credential.

  ## Output

  Three lines on standard output: the community Account key, the administrator peer id, and
  a bearer token valid for 12 hours. Nothing is written to a file. The token is not
  recoverable afterwards — it is a credential, so keep it out of logs, tickets, and chat;
  once it expires, sign in with the password through the ordinary sign-in endpoint.

  ## Who this creates

  A human administrator. Only human peers can make curator decisions such as approving or
  rejecting proposed knowledge; machine peers are provisioned separately with API keys and
  can never approve their own submissions. Do not reuse this account as an agent identity.

  ## Failure behaviour

  A missing email, a missing password, or an unknown switch raises before anything is
  written. Re-running for an email or peer key that already exists also raises, because the
  underlying registration is unique per Account. Bootstrapping happens inside one database
  transaction, so a failure never leaves a half-created administrator with no role grant.
  Every failure exits non-zero.
  """

  @doc """
  Parses the switches described in the module documentation, performs the bootstrap, and
  prints the Account key, administrator peer id, and bearer token.

  Raises on missing or invalid arguments and on a conflicting existing identity, which
  surfaces as a non-zero exit status.
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

    # There is no fallback password by design. An installation that silently came up with a
    # known credential would be reachable by anyone who read this file.
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
    # The token is issued once and never stored in retrievable form; the operator must copy
    # it now. It is a credential, so it must not be echoed into logs or telemetry.
    Mix.shell().info("Bearer token (12h): #{result.token}")
  end
end
