# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Repo.Migrations.DefaultAppendOnlyLegacyTimestamp do
  use Ecto.Migration

  def up do
    execute """
    ALTER TABLE knowledge_lifecycle_events
    ALTER COLUMN updated_at SET DEFAULT (now() AT TIME ZONE 'utc')
    """
  end

  def down do
    execute """
    ALTER TABLE knowledge_lifecycle_events
    ALTER COLUMN updated_at DROP DEFAULT
    """
  end
end
