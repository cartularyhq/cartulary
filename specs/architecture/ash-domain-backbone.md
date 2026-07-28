<!-- SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0 -->

# Ash Domain Backbone

Status: implemented

The Ash domain backbone makes Ash Resources, Actions, tenancy, and policies the
authoritative boundary for durable Cartulary data. It preserves the frozen
`poc-0` public contract — a historical version tag that no longer names a
roadmap phase — while replacing the earlier service's direct writes with Ash
actions.

## Domain ownership

| Ash domain | Resources |
| --- | --- |
| `Cartulary.Accounts` | Account, Peer, ExternalIdentity, ApiKey (added by identity, tenancy, and RBAC) |
| `Cartulary.Topology` | Scope, ScopeRelation, RoleGrant |
| `Cartulary.Observations` | Session, SessionScope, SessionParticipant, Message, Document, DocumentVersion |
| `Cartulary.Knowledge` | KnowledgeItem, Attribution, Provenance, KnowledgeRelation, LifecycleEvent, Projection, Entity, EntityMention |
| `Cartulary.Governance` | AuditEvent, PolicyConfig |
| `Cartulary.Model` | ModelRoleConfig |
| `Cartulary.Retrieval` | RetrievalProfile |
| `Cartulary.Skills` | SkillRequirementCard |
| `Cartulary.Operations` | UsageEvent |

This decomposition implements the backbone resource inventory and follows the
domain map in `specs/architecture/free-core-architecture.md`. It is subordinate
to `FR-TOP-*`, `FR-KN-*`, `FR-FORM-*`, `FR-GOV-*`, `AD-DATA-*`, and
`AD-SEC-*`.

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

`Cartulary.Memory` remains a compatibility facade for the HTTP and eval
surfaces, but its durable reads and writes call Ash actions. Retrieval, entity
resolution, and context removed `Cartulary.Memory.Query`; database-native
retrieval reads now live in the reviewed read-only
`Cartulary.Retrieval.Store` data-layer helper.

## Isolation

The Account wall has three in-process/database layers:

1. `Cartulary.DataLayer` installs one identity-derived Account as the Ash actor
   and tenant for an Account-scoped transaction.
2. Ash attribute multitenancy and policies filter every Account resource;
   scoped reads additionally use the actor's resolved scope ids.
3. PostgreSQL RLS is enabled and forced on `accounts` and every table carrying
   `account_id`. Policies use transaction-local `cartulary.account_id` (and
   `cartulary.account_key` only while bootstrapping the initial Account).

Identity, tenancy, and RBAC replaced the local HTTP Account header with
password/JWT and API-key identities, single-Account free-mode enforcement, and
inherited RBAC. The Ash
actor/tenant and RLS contract introduced here did not change; legacy
account-key adapters remain internal to eval/migration compatibility paths.

## Migration and evidence

`priv/resource_snapshots/` contains the AshPostgres resource snapshots.
`priv/repo/migrations/20260727142300_f1_ash_domain_backbone.exs` is the
Ash-generated additive migration, manually reviewed and extended with
pgcrypto/pgvector setup, PostgreSQL FTS, indexes, foreign keys, and RLS.

Deterministic evidence is in:

- `test/cartulary/f1_ash_domain_backbone_test.exs`;
- the frozen baseline contract tests listed in `AGENTS.md`; and
- `mix ash.codegen --check`, which detects resource/snapshot drift.

Transactional writes, audit, and jobs now couple state transitions, audit
entries, durable pipeline-run records, and AshOban enqueue effects in one
transaction. That implementation boundary and its evidence are documented in
`specs/architecture/transactional-writes-audit-jobs.md`. Retrieval, entity
resolution, and context completes the retrieval SQL transition and is
documented in `specs/architecture/retrieval-entity-context.md`.

Identity, tenancy, and RBAC adds the 28th Resource,
`Cartulary.Accounts.ApiKey`, and the authenticated edge/RBAC resolver without
changing the domain ownership above. Its implementation and evidence are
documented in `specs/architecture/identity-tenancy-rbac.md`.

Skill readiness and procedural memory completes the authored
`SkillRequirementCard` placeholder without adding a new Resource. Versioned
selectors, inherited procedural memory, readiness checks, and their
public/helper contracts are documented in
`specs/architecture/skill-readiness-procedural-memory.md`.
