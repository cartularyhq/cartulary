# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Governance.UnattendedMode do
  @moduledoc """
  Whether this deployment process has declared it has no human governance
  participant at all.

  This is the deployment-wide counterpart to
  `Cartulary.Accounts.Account.consent_mode`: the per-Account attribute needs a
  console session or a mix task to flip, which a headless benchmark or eval
  process may never have. Setting `CARTULARY_GOVERNANCE_UNATTENDED=true`
  covers every Account in the process instead.

  Read only by `Cartulary.Governance.Engine`'s consent resolution. It has no
  effect on `Cartulary.Governance.GateRule`'s Gate A/B automation, which stays
  entirely rule-configured, and it is boot-time only — nothing in this
  codebase changes it at runtime outside of tests.
  """

  @doc """
  True when `CARTULARY_GOVERNANCE_UNATTENDED` was set at boot.

  False whenever the config key is absent, so an unconfigured deployment
  behaves exactly as it did before this module existed.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    :cartulary
    |> Application.get_env(:governance, [])
    |> Keyword.get(:unattended, false)
  end
end
