# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Repo do
  use AshPostgres.Repo,
    otp_app: :cartulary,
    adapter: Ecto.Adapters.Postgres,
    warn_on_missing_ash_functions?: false

  def min_pg_version do
    %Version{major: 16, minor: 0, patch: 0}
  end

  def installed_extensions, do: ["pgcrypto", "vector", "citext"]
end
