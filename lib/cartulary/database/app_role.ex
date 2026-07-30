# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Database.AppRole do
  @moduledoc """
  Makes the database half of cross-Account isolation actually enforce.

  Every tenant table carries a row-level security policy that compares each row
  against the transaction-local Account settings the Account-scoped transaction
  helper installs. Those policies are correct, and until this module existed
  they were also inert: PostgreSQL exempts superusers from row-level security
  unconditionally, `FORCE ROW LEVEL SECURITY` removes only the *table owner's*
  exemption and never the superuser's, and every shipped deployment connected as
  a superuser. A query that escaped the application-layer tenant filter would
  have been answered in full.

  This module closes that gap by making the *effective* role of every
  application connection a role that cannot bypass row-level security:

  * `provision!/1` creates that role and grants it the data-manipulation rights
    the running system needs — no DDL, no ownership, and explicitly
    `NOSUPERUSER NOBYPASSRLS`. It is idempotent and safe to run on every boot.
  * `set_role/1` runs as each pooled connection is opened, switching the session
    to that role. PostgreSQL evaluates the row-level-security exemption against
    the *current* role, so after this the policies apply to every statement the
    connection issues.
  * `assert_enforced!/1` refuses to finish booting when the effective role can
    still bypass row-level security, so a deployment cannot silently regress by
    being pointed at a superuser.

  ## Two supported shapes, one guarantee

  An operator may instead point the release at a login role that is already
  `NOSUPERUSER NOBYPASSRLS`. That is the stronger arrangement and it is what the
  operations documentation recommends, because the connection then has no path
  back to unrestricted access at all. In that shape `set_role/1` is a no-op that
  cannot succeed (the login role need not be a member of the app role) and the
  boot assertion passes on the login role's own attributes. Both shapes end at
  the same guarantee, which is why the assertion checks the effective role
  rather than how it was reached.

  Where the connection *is* a superuser, `SET ROLE` is a real barrier against
  the failure this defends against — an application-layer tenant filter that
  was missed — but it is not a barrier against code that deliberately issues
  `RESET ROLE`. Nothing in this codebase does, and no caller may add one.

  ## Ordering, and why provisioning runs before the repository

  The role must exist before the first pooled connection tries to switch to it,
  so provisioning runs as its own supervision step ahead of the repository, over
  a short-lived privileged connection of its own. Grants are re-applied after
  migrations because a migration that creates a table creates it unreachable to
  a role that was granted rights before it existed; the default-privilege rules
  installed here cover tables created later by the same owner, and the explicit
  grants cover everything that already exists.

  Provisioning is best-effort by design: a deployment whose connection role
  lacks `CREATEROLE` cannot create anything, and failing the boot there would
  strand an operator who had already created a restricted role by hand. The
  authoritative failure is `assert_enforced!/1`, which runs afterwards and
  states exactly what is wrong.
  """

  require Logger

  alias Cartulary.Repo

  # PostgreSQL role names are identifiers, not values, so they cannot be passed
  # as bound parameters and must be interpolated. Every name this module emits
  # is checked against this pattern first: lowercase start, then letters,
  # digits, or underscores. Anything else is rejected rather than quoted,
  # because a role name is operator configuration and a name needing quoting is
  # far more likely to be a mistake than an intention.
  @role_name_pattern ~r/\A[a-z_][a-z0-9_]*\z/

  @doc """
  Creates the restricted application role and grants it what the running system needs.

  `repo` is a started repository (or dynamic repository name) whose connection
  still holds its original, privileged role — provisioning issues DDL, so it
  must not run over a connection that has already switched roles.

  Returns `:ok` when every statement applied, and `{:error, reason}` when the
  connection lacked the privileges to apply them. The error is deliberately not
  raised: see the module documentation for why this step is advisory and
  `assert_enforced!/1` is the gate.
  """
  # The role name is interpolated into DDL rather than bound as a parameter, because a
  # PostgreSQL identifier cannot be a bound parameter. `role_name!/0` is what makes that safe:
  # it rejects anything that is not a plain lowercase identifier before this ever runs, so the
  # value reaching these statements is never attacker-controlled input, only reviewed
  # configuration.
  # sobelow_skip ["SQL.Query"]
  @spec provision!(Ecto.Repo.t() | atom()) :: :ok | {:error, term()}
  def provision!(repo \\ Repo) do
    role = role_name!()

    Enum.reduce_while(provisioning_statements(role), :ok, fn statement, :ok ->
      case Ecto.Adapters.SQL.query(repo, statement, []) do
        {:ok, _result} ->
          {:cont, :ok}

        {:error, error} ->
          Logger.warning("""
          could not provision the restricted database role #{role}: #{Exception.message(error)}.
          Row-level security is only enforced once the application connects as a role that is \
          NOSUPERUSER NOBYPASSRLS; create that role manually or connect with one that may.
          """)

          {:halt, {:error, error}}
      end
    end)
  end

  @doc """
  Switches a freshly opened connection to the restricted role.

  Wired in as the repository's `:after_connect` callback, so `conn` is the
  Postgrex connection the pool has just established. The switch is session-level
  on purpose: a transaction-local one would be undone by the first rollback and
  hand the rest of that connection's life back to the unrestricted role.

  Always returns `:ok`. A failure here means the role does not exist or this
  login is not a member of it, which is normal for a deployment that already
  connects as a restricted login. Crashing the connection instead would make
  that deployment unbootable, so the condition is logged and the boot assertion
  decides whether it mattered.
  """
  @spec set_role(pid()) :: :ok
  def set_role(conn) do
    role = role_name!()

    case Postgrex.query(conn, "SET ROLE #{role}", []) do
      {:ok, _result} ->
        :ok

      {:error, error} ->
        Logger.debug("could not switch connection to #{role}: #{Exception.message(error)}")
        :ok
    end
  end

  @doc """
  Verifies that this node's connections cannot bypass row-level security, or refuses to boot.

  Reads the attributes of the connection's *effective* role — after any switch
  performed at connect time — and raises unless that role is neither a superuser
  nor holds `BYPASSRLS`. Either attribute means the tenant policies would be
  skipped and cross-Account isolation would rest on the application layer alone.

  Returns `:ok` when the role is restricted. Raises a `RuntimeError` naming the
  role and the remedy otherwise, unless the deployment has explicitly opted out
  through configuration, in which case the same message is logged at error level
  and the boot continues.
  """
  @spec assert_enforced!(Ecto.Repo.t() | atom()) :: :ok
  def assert_enforced!(repo \\ Repo) do
    %{rows: [[current_role, superuser?, bypass_rls?]]} =
      Ecto.Adapters.SQL.query!(
        repo,
        """
        SELECT current_user::text,
               COALESCE(rolsuper, false),
               COALESCE(rolbypassrls, false)
        FROM pg_roles
        WHERE rolname = current_user
        """,
        []
      )

    if superuser? or bypass_rls? do
      unenforced!(current_role, superuser?)
    else
      :ok
    end
  end

  @doc """
  Runs `fun` against a short-lived repository instance that has not switched roles.

  Two callers need a connection whose role is still the one the connection URL
  names: provisioning, which issues DDL, and migrations, which do the same. Both
  run at points where the application pool is either not started yet or already
  restricted, so neither can borrow it.

  `fun` receives the started instance's pid, which is passed to
  `Ecto.Adapters.SQL` calls and to `Ecto.Migrator` as its `:dynamic_repo`. The
  instance is unnamed so it cannot collide with the application repository, is
  sized for one caller rather than for serving traffic, and is stopped in an
  `after` block so a raising callback still leaves no pool behind.

  Returns whatever `fun` returns.
  """
  @spec with_privileged_repo((pid() -> result)) :: result when result: term()
  def with_privileged_repo(fun) when is_function(fun, 1) do
    # Two connections: migrations hold one for the migration lock and use the
    # other for the statements themselves.
    {:ok, pid} = Repo.start_link(name: nil, pool_size: 2, pool: DBConnection.ConnectionPool)

    try do
      fun.(pid)
    after
      Supervisor.stop(pid)
    end
  end

  @doc """
  The configured name of the restricted role.

  Raises when the configured name is not a plain lowercase SQL identifier, since
  the name is interpolated into DDL rather than bound as a parameter.
  """
  @spec role_name!() :: String.t()
  def role_name! do
    name =
      :cartulary
      |> Application.fetch_env!(:database)
      |> Keyword.fetch!(:app_role)

    unless is_binary(name) and Regex.match?(@role_name_pattern, name) do
      raise "CARTULARY_DATABASE_APP_ROLE must be a lowercase SQL identifier"
    end

    name
  end

  # Every statement is written to be safe to re-run: the role creation swallows
  # only the "already there" error, the attribute reset is unconditional, and
  # grants are additive.
  #
  # The attribute reset is the security-carrying statement. It runs even when
  # the role already existed, so an operator who granted the role BYPASSRLS by
  # hand — or a cluster where an unrelated role of the same name exists — cannot
  # leave the wall down without also editing this code.
  #
  # Default privileges are recorded against the current login role because that
  # is the role migrations run as, and PostgreSQL keys default privileges by the
  # role that creates the object. Tables created by a later migration are
  # therefore reachable without re-granting; the explicit grants below cover
  # everything that exists already.
  #
  # Function execution is granted because one lookup the system depends on — the
  # SECURITY DEFINER resolver that maps an API key id to its Account before any
  # Account is known — has been revoked from PUBLIC.
  defp provisioning_statements(role) do
    [
      """
      DO $cartulary$
      BEGIN
        CREATE ROLE #{role} NOLOGIN NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE;
      EXCEPTION WHEN duplicate_object THEN
        NULL;
      END
      $cartulary$
      """,
      "ALTER ROLE #{role} NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE",
      "GRANT #{role} TO CURRENT_USER",
      "GRANT USAGE ON SCHEMA public TO #{role}",
      "GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO #{role}",
      "GRANT USAGE, SELECT, UPDATE ON ALL SEQUENCES IN SCHEMA public TO #{role}",
      "GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO #{role}",
      """
      DO $cartulary$
      BEGIN
        EXECUTE format(
          'ALTER DEFAULT PRIVILEGES FOR ROLE %I IN SCHEMA public
             GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO %I',
          current_user, '#{role}');
        EXECUTE format(
          'ALTER DEFAULT PRIVILEGES FOR ROLE %I IN SCHEMA public
             GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO %I',
          current_user, '#{role}');
        EXECUTE format(
          'ALTER DEFAULT PRIVILEGES FOR ROLE %I IN SCHEMA public
             GRANT EXECUTE ON FUNCTIONS TO %I',
          current_user, '#{role}');
      END
      $cartulary$
      """
    ]
  end

  # The message names the role actually in effect, because "you are a superuser"
  # is useless to an operator who believed the switch had happened.
  defp unenforced!(current_role, superuser?) do
    attribute = if superuser?, do: "a superuser", else: "granted BYPASSRLS"

    message = """
    this node connects to PostgreSQL as #{current_role}, which is #{attribute}, so the \
    row-level security policies protecting every Account's rows are skipped on every query. \
    Cross-Account isolation would rest on the application layer alone. Either let this node \
    provision and switch to the restricted role (its connection role needs CREATEROLE), or \
    point DATABASE_URL at a login role created with NOSUPERUSER NOBYPASSRLS. Set \
    CARTULARY_ALLOW_UNRESTRICTED_DATABASE_ROLE=true to boot anyway.
    """

    if allow_unrestricted?() do
      Logger.error(message)
      :ok
    else
      raise message
    end
  end

  defp allow_unrestricted? do
    :cartulary
    |> Application.fetch_env!(:database)
    |> Keyword.fetch!(:allow_unrestricted_role)
  end
end
