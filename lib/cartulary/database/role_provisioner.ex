# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Database.RoleProvisioner do
  @moduledoc """
  Supervised startup step that creates the restricted database role before the
  repository opens its pool.

  The ordering is the whole reason this is a supervision child rather than a
  function call somewhere convenient. Pooled connections switch to the
  restricted role as they are opened, so the role has to exist by then; a
  provisioning step that ran after the repository would leave every connection
  already established under the unrestricted role for the rest of its life.

  It cannot use the application's repository for the same reason — that pool
  does not exist yet — so it starts a short-lived, unnamed repository instance
  of its own, provisions over it, and stops it again. That instance is started
  without the connect-time role switch, which is required: provisioning issues
  DDL, and the restricted role is precisely the role that may not.

  All the work happens in `init/1`, which blocks the supervisor until it
  returns. The process then sits idle for the life of the node.

  Failure to provision is logged, not raised. An operator whose connection role
  lacks `CREATEROLE` may have created a restricted login by hand, and that
  arrangement is supported; the boot assertion that runs after migrations is
  what decides whether the node is safe to serve traffic.
  """

  use GenServer

  alias Cartulary.Database.AppRole

  @doc """
  Starts the provisioning step under the supervision tree.

  Registered under the module name. Options are accepted and ignored: the role
  name comes from the node's configuration.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    AppRole.with_privileged_repo(&AppRole.provision!/1)
    {:ok, %{}}
  end
end
