# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Repo.Migrations.EnablePgvector do
  use Ecto.Migration

  def up do
    execute "CREATE EXTENSION IF NOT EXISTS vector"
  end

  def down do
    execute "DROP EXTENSION IF EXISTS vector"
  end
end
