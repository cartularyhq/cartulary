# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Memory.KnowledgeItem do
  @moduledoc false

  use Ash.Resource,
    domain: Cartulary.Memory.Domain,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "knowledge_items"
    repo Cartulary.Repo
  end

  actions do
    defaults [:read]
  end

  attributes do
    uuid_primary_key :id
    attribute :account_id, :uuid, allow_nil?: false, public?: true
    attribute :scope_id, :uuid, allow_nil?: false, public?: true
    attribute :subject_peer_id, :uuid, public?: true
    attribute :subject_scope_id, :uuid, public?: true
    attribute :statement, :string, allow_nil?: false, public?: true
    attribute :kind, :string, allow_nil?: false, default: "fact", public?: true
    attribute :confidence, :float, allow_nil?: false, default: 0.5, public?: true
    attribute :sensitivity, :string, allow_nil?: false, default: "internal", public?: true
    attribute :state, :string, allow_nil?: false, default: "proposed", public?: true
    attribute :expires_at, :utc_datetime_usec, public?: true
    attribute :revalidate_after, :utc_datetime_usec, public?: true
    attribute :relevant_from, :utc_datetime_usec, public?: true
    attribute :relevant_until, :utc_datetime_usec, public?: true
    attribute :source_message_ids, {:array, :uuid}, allow_nil?: false, default: [], public?: true
    attribute :extracting_model, :string, public?: true
    attribute :pipeline_version, :string, allow_nil?: false, default: "poc-0", public?: true
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end
end
