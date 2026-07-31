# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Portability.Registry do
  @moduledoc """
  Defines the durable resources and dependency order in an Account archive.

  Only system-of-record rows belong here. Credentials, secrets, and rebuildable chunks, vectors,
  projections, entities, and mentions remain excluded; original blobs are handled separately
  with checksums.
  """

  # Restoration order. Each entry maps the archive's file name to the resource
  # that owns those rows; the file name is part of the archive format, so
  # renaming one breaks archives already written.
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

  # Rebuildable caches. Never exported; recomputed on the target after import.
  # Listed explicitly rather than merely omitted so the manifest can state what
  # was left out, and so a reader can tell "excluded on purpose" from "someone
  # forgot to add it".
  @derived_resources [
    Cartulary.Documents.DocumentChunk,
    Cartulary.Knowledge.Entity,
    Cartulary.Knowledge.EntityMention,
    Cartulary.Knowledge.Projection
  ]

  # Credential-bearing resources. An archive must never be a way to move
  # authentication material between installations.
  @credential_resources [Cartulary.Accounts.ApiKey]

  # Attributes stripped from rows that are otherwise portable.
  #
  #   * a peer's password hash is a credential and does not travel;
  #   * knowledge embeddings and their provider/model identity are recomputed by
  #     the target's own embedder, so exporting them would risk restoring
  #     vectors that do not match the target's embedding identity;
  #   * a document version's extracted text, extraction metadata, chunk counts,
  #     and completion stamp are extraction bookkeeping — the original blob is
  #     exported instead, and the target re-derives all of it.
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

  @doc """
  The portable resources as `{archive_file_name, resource_module}` pairs, in
  dependency order. Export writes them in this order and import restores them in
  this order; callers must not sort or regroup the list.
  """
  def resources, do: @resources

  @doc """
  Resources that are rebuilt on the target instead of being exported. Reported
  in the archive manifest so the exclusion is visible to whoever inspects it.
  """
  def derived_resources, do: @derived_resources

  @doc """
  Resources holding authentication material, which never appear in an archive.
  """
  def credential_resources, do: @credential_resources

  @doc """
  Attributes to strip from a portable resource's rows.

  Returns a list of attribute names, empty for resources that export in full.
  Export consults this per row, so adding an entry here is all that is needed to
  keep a newly added secret or derived column out of every future archive.
  """
  def excluded_attributes(resource), do: Map.get(@sensitive_attributes, resource, [])

  @doc """
  Resolves an archive file name to the resource that owns those rows.

  Import calls this on every manifest entry, which is what makes an archive
  naming an unknown or non-portable resource fail early instead of being
  partially applied. Raises `ArgumentError` for a name that is not in the
  portable list.
  """
  def resource!(name) do
    case List.keyfind(@resources, name, 0) do
      {^name, resource} -> resource
      nil -> raise ArgumentError, "unknown portability resource #{inspect(name)}"
    end
  end
end
