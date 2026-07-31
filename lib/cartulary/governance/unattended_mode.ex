# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Governance.UnattendedMode do
  @moduledoc """
  Reports whether the deployment has no human governance participant.

  `CARTULARY_GOVERNANCE_UNATTENDED=true` applies to every Account, unlike per-Account
  `consent_mode`, and supports headless benchmarks or evaluation.

  It affects consent resolution only, not Gate A/B rules. It is boot-time configuration except in
  tests.
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
