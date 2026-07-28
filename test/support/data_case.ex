# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.DataCase do
  @moduledoc """
  ExUnit case template for tests that reach the database through Ash, Oban, or Ecto.

  It owns exactly one thing: the SQL sandbox connection for the test. Each test
  checks a connection out of the sandbox pool, runs inside a transaction on that
  connection, and the transaction is rolled back when the test ends, so no row a
  test writes survives it. `Cartulary.DataCase.setup_sandbox/1` is public because
  the connection case template reuses the same checkout for endpoint tests.

  ## Async and shared mode

  Ownership is shared whenever the test is *not* tagged `async: true`. Shared mode
  publishes the checked-out connection globally, so any other process the test
  spawns or triggers — an Oban job executed by `Oban.drain_queue/1`, a `Task`
  fan-out inside retrieval, a supervised GenServer, a LiveView process — sees the
  same open transaction and the same uncommitted rows. Only one shared owner can
  exist at a time, which is precisely why those tests cannot be async.

  A test may use `async: true` only when every query happens in the test process
  itself. Draining Oban, spawning tasks, or asserting on work done by another
  process under `async: true` fails with an ownership error, and adding a
  connection-sharing workaround instead of dropping the flag reintroduces
  cross-test interference.

  ## Accounts and row-level security

  This template deliberately does not create an Account or authenticate anyone.
  Tenancy is derived from the actor a test enters with, never from a value the
  test assigns to a request or a changeset. Tests obtain an Account by calling the
  Account-scoped transaction helper in `Cartulary.DataLayer`, which opens its own
  transaction, installs the Account identifier and key as transaction-local
  PostgreSQL settings, and lets the row-level-security policies on every tenant
  table filter against them.

  Those settings are scoped to the enclosing transaction, and under the sandbox
  the enclosing transaction is the whole test. So once a scoped block has run and
  returned, its Account setting stays installed for the remainder of that test
  unless a later scoped block replaces it. A test asserting cross-Account
  isolation must therefore enter each Account through its own scoped block rather
  than assuming the previous Account was cleared in between.

  ## What callers must not do

  Do not query the test database over a second connection or an external `psql`
  session: the sandbox transaction is uncommitted and invisible from outside it.
  Do not expect data written by one test to be visible in another; sequences,
  hash-chain audit heads, and every derived row reset with the rollback. Do not
  commit the sandbox transaction manually.
  """

  use ExUnit.CaseTemplate

  # Injected into every module that does `use Cartulary.DataCase`. Kept to
  # aliases and imports on purpose: a case template that also seeded data would
  # make every test pay for fixtures it does not use, and would hide which test
  # created which row.
  using do
    quote do
      alias Cartulary.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Cartulary.DataCase
    end
  end

  setup tags do
    Cartulary.DataCase.setup_sandbox(tags)
    :ok
  end

  @doc """
  Checks a sandbox connection out for the current test and schedules its return.

  Pass the ExUnit `tags` map. A test tagged `async: true` gets a private owner
  usable only from the test process; anything else gets a shared owner that other
  processes in the node can borrow, which is what makes Oban drains and task
  fan-out observe the test's uncommitted rows.

  Registers an `on_exit` callback that stops the owner, rolling the test's
  transaction back, and returns that registration's `:ok` rather than the owner
  pid. Raises if no connection can be checked out, which usually means the test
  database is missing or unreachable, or the pool is exhausted by a leaked owner.

  Call this at most once per test. The connection case template already calls it,
  so endpoint tests must not call it again.
  """
  def setup_sandbox(tags) do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Cartulary.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
  end

  @doc """
  A helper that transforms changeset errors into a map of messages.

      assert {:error, changeset} = Accounts.create_user(%{password: "short"})
      assert "password is too short" in errors_on(changeset).password
      assert %{password: ["password is too short"]} = errors_on(changeset)

  The result maps each field to a list of rendered messages, with placeholders
  such as the count in "should be at least %{count} character(s)" substituted
  from the error options so assertions can match the final human-readable string.

  This reads `Ecto.Changeset` errors only. Failures raised by Ash actions and
  policies are Ash error structs and do not pass through here; inspect those
  directly. Raises `ArgumentError` if a message contains a placeholder whose name
  has never been used as an atom in the running system.
  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
