# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Portability.Registry do
  @moduledoc """
  Versioned F10 archive inventory.

  Ordering is dependency-aware for import. Credentials and every rebuildable
  cache are deliberately absent.
  """

  @resources [
    {"accounts", Cartulary.Accounts.Account},
    {"scopes", Cartulary.Topology.Scope},
    {"peers", Cartulary.Accounts.Peer},
    {"external_identities", Cartulary.Accounts.ExternalIdentity},
    {"sessions", Cartulary.Observations.Session},
    {"session_scopes", Cartulary.Observations.SessionScope},
    {"session_participants", Cartulary.Observations.SessionParticipant},
    {"connector_configs", Cartulary.Documents.ConnectorConfig},
    {"documents", Cartulary.Observations.Document},
    {"document_versions", Cartulary.Observations.DocumentVersion},
    {"messages", Cartulary.Observations.Message},
    {"model_role_configs", Cartulary.Model.ModelRoleConfig},
    {"retrieval_profiles", Cartulary.Retrieval.RetrievalProfile},
    {"skill_requirement_cards", Cartulary.Skills.SkillRequirementCard},
    {"policy_configs", Cartulary.Governance.PolicyConfig},
    {"governance_gate_rules", Cartulary.Governance.GateRule},
    {"knowledge_items", Cartulary.Knowledge.KnowledgeItem},
    {"provenances", Cartulary.Knowledge.Provenance},
    {"attributions", Cartulary.Knowledge.Attribution},
    {"knowledge_relations", Cartulary.Knowledge.KnowledgeRelation},
    {"knowledge_lifecycle_events", Cartulary.Knowledge.LifecycleEvent},
    {"validation_items", Cartulary.Governance.ValidationItem},
    {"gate_decisions", Cartulary.Governance.GateDecision},
    {"knowledge_consents", Cartulary.Governance.Consent},
    {"peer_queries", Cartulary.Governance.PeerQuery},
    {"peer_query_deliveries", Cartulary.Governance.PeerQueryDelivery},
    {"peer_ask_preferences", Cartulary.Governance.PeerAskPreference},
    {"erasure_requests", Cartulary.Governance.ErasureRequest},
    {"role_grants", Cartulary.Topology.RoleGrant},
    {"scope_relations", Cartulary.Topology.ScopeRelation},
    {"usage_events", Cartulary.Operations.UsageEvent},
    {"pipeline_runs", Cartulary.Operations.PipelineRun},
    {"audit_events", Cartulary.Governance.AuditEvent}
  ]

  @derived_resources [
    Cartulary.Documents.DocumentChunk,
    Cartulary.Knowledge.Entity,
    Cartulary.Knowledge.EntityMention,
    Cartulary.Knowledge.Projection
  ]

  @credential_resources [Cartulary.Accounts.ApiKey]

  @sensitive_attributes %{
    Cartulary.Accounts.Peer => [:hashed_password],
    Cartulary.Knowledge.KnowledgeItem => [
      :embedding,
      :embedding_provider,
      :embedding_model,
      :embedding_version,
      :embedding_dimensions
    ],
    Cartulary.Observations.DocumentVersion => [
      :extracted_text,
      :extraction_metadata,
      :chunk_count,
      :embedded_chunk_count,
      :extraction_completed_at
    ]
  }

  def resources, do: @resources
  def derived_resources, do: @derived_resources
  def credential_resources, do: @credential_resources
  def excluded_attributes(resource), do: Map.get(@sensitive_attributes, resource, [])

  def resource!(name) do
    case List.keyfind(@resources, name, 0) do
      {^name, resource} -> resource
      nil -> raise ArgumentError, "unknown portability resource #{inspect(name)}"
    end
  end
end
