# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule CartularyWeb.GovernanceAuth do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [redirect: 2]

  alias Cartulary.Identity

  def on_mount(:default, _params, %{"governance_token" => token}, socket) do
    with {:ok, actor} <- Identity.authenticate_bearer(token),
         true <- actor.identity_kind == :password,
         true <- actor.role in [:account_admin, :curator] do
      {:cont, assign(socket, :current_actor, actor)}
    else
      _other -> {:halt, redirect(socket, to: "/governance/sign-in")}
    end
  end

  def on_mount(:default, _params, _session, socket),
    do: {:halt, redirect(socket, to: "/governance/sign-in")}
end
