<!-- SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0 -->

# F1 Ash Domain Backbone

Status: implemented

F1 makes Ash Resources, Actions, tenancy, and policies the authoritative
boundary for durable Cartulary data. It preserves the frozen `poc-0` public
contract while replacing the POC service's direct writes with Ash actions.

## Domain ownership

| Ash domain | Resources |
| --- | --- |
| `Cartulary.Accounts` | Account, Peer, ExternalIdentity |
| `Cartulary.Topology` | Scope, ScopeRelation, RoleGrant |
| `Cartulary.Observations` | Session, SessionScope, SessionParticipant, Message, Document, DocumentVersion |
| `Cartulary.Knowledge` | KnowledgeItem, Attribution, Provenance, KnowledgeRelation, LifecycleEvent, Projection, Entity, EntityMention |
| `Cartulary.Governance` | AuditEvent, PolicyConfig |
| `Cartulary.Model` | ModelRoleConfig |
| `Cartulary.Retrieval` | RetrievalProfile |
| `Cartulary.Skills` | SkillRequirementCard |
| `Cartulary.Operations` | UsageEvent |

This decomposition implements the F1 resource inventory and follows the domain
map in `docs/roadmap/free-core-roadmap.md`. It is subordinate to `FR-TOP-*`,
`FR-KN-*`, `FR-FORM-*`, `FR-GOV-*`, `AD-DATA-*`, and `AD-SEC-*`.

## Action rules

- Account, scope, peer, session, and session membership metadata have explicit
  create/read/update actions where mutation is legal.
- Message content and document-version content are create-only.
- Knowledge statements are immutable. Only a pipeline actor may call
  `create_from_pipeline` or `merge_from_pipeline`; merge cannot change the
  statement.
- Provenance, lifecycle, audit, and usage events are append-only.
- Policy, model-role, retrieval-profile, role-grant, and skill-card mutations
  require a governance or system role.
- Entity and entity-mention actions are pipeline-internal and have no public
  route, preserving `FR-KN-21`.

`Cartulary.Memory` remains a compatibility facade for the frozen HTTP and eval
surfaces, but its durable reads and writes call Ash actions. Static retrieval
SQL is isolated in `Cartulary.Memory.Query` with roadmap F7 as its explicit
removal ticket.

## Isolation

The F1 Account wall has three in-process/database layers:

1. `Cartulary.DataLayer` installs one identity-derived Account as the Ash actor
   and tenant for an Account-scoped transaction.
2. Ash attribute multitenancy and policies filter every Account resource;
   scoped reads additionally use the actor's resolved scope ids.
3. PostgreSQL RLS is enabled and forced on `accounts` and every table carrying
   `account_id`. Policies use transaction-local `cartulary.account_id` (and
   `cartulary.account_key` only while bootstrapping the POC Account).

The local HTTP adapter still obtains the Account key from
`x-cartulary-account-key`. F3 replaces that adapter with real identity,
single-Account free-mode enforcement, and inherited RBAC; the Ash actor/tenant
and RLS contract does not change.

## Migration and evidence

`priv/resource_snapshots/` contains the AshPostgres resource snapshots.
`priv/repo/migrations/20260727142300_f1_ash_domain_backbone.exs` is the
Ash-generated additive migration, manually reviewed and extended with
pgcrypto/pgvector setup, PostgreSQL FTS, indexes, foreign keys, and RLS.

Deterministic evidence is in:

- `test/cartulary/f1_ash_domain_backbone_test.exs`;
- the frozen F0 contract tests listed in `AGENTS.md`; and
- `mix ash.codegen --check`, which detects resource/snapshot drift.

F2 now transactionally couples state transitions, audit entries, durable
pipeline-run records, and AshOban enqueue effects. Its implementation boundary
and evidence are documented in
`docs/architecture/f2-transactional-writes-audit-jobs.md`. F7 owns the
remaining retrieval SQL transition.
