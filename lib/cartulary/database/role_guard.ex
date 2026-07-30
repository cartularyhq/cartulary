# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Database.RoleGuard do
  @moduledoc """
  Supervised startup step that refuses to serve traffic when the database's half
  of cross-Account isolation would not enforce.

  It sits after the repository and the migration step and before anything that
  answers a request. That position is deliberate: the role it checks is created
  by the provisioning step and granted rights over tables the migration step may
  have only just created, and a node that fails this check must fail before it
  accepts its first request rather than after.

  The check itself is one query, and its outcome is a boot decision rather than
  a log line, because the condition it detects is invisible in every other way.
  Row-level security that is skipped produces no error, no warning, and no
  behavioural difference until the day an application-layer tenant filter is
  wrong — at which point it produces another Account's rows.

  All the work happens in `init/1`, which blocks the supervisor until it
  returns. The process then sits idle for the life of the node.
  """

  use GenServer

  alias Cartulary.Database.AppRole

  @doc """
  Starts the guard under the supervision tree.

  Registered under the module name. Options are accepted and ignored. Raises
  from `init/1` — and so fails the boot — when the node's connections can bypass
  row-level security and the deployment has not explicitly opted out.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    AppRole.assert_enforced!()
    {:ok, %{}}
  end
end
