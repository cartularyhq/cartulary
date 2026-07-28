<!-- SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0 -->

# Identity, Tenancy, And Basic RBAC

Status: implemented

Identity, tenancy, and RBAC replace the original HTTP Account header with
authenticated, Account-bound Peers. This work implements the free-core identity
and authorization boundary defined
by `FR-TOP-1`, `FR-TOP-2`, `FR-TOP-6`, `FR-API-3`, `FR-GOV-18`,
`FR-GOV-19`, `AD-SEC-1` through `AD-SEC-5`, and `AINV-6`.

## Identity paths

Humans use the AshAuthentication password strategy. A successful password
sign-in returns a signed 12-hour JWT containing the Peer subject and the
community Account tenant. Agents use the AshAuthentication API-key strategy.
API keys are generated once, stored only as SHA-256 hashes, bound to one Peer
and Account, and may be restricted to one scope subtree.

Both paths resolve to `Cartulary.Actor`:

- `account_id` and `peer_id` come from the verified identity;
- the linked `ExternalIdentity` supplies `identity_kind` and assurance;
- `RoleGrant` resolution supplies effective `scope_ids`, `scope_roles`, and the
  highest effective basic role;
- the actor is installed as the Ash actor/tenant and as transaction-local
  `cartulary.account_id` before domain work runs.

`POST /api/auth/password` is the human sign-in endpoint. Every `/api/v1`
memory route requires `Authorization: Bearer <JWT-or-API-key>`. The deprecated
`x-cartulary-account-key` header and Account fields in request bodies are
ignored. Health remains unauthenticated.

## Account bootstrap and free-edition enforcement

The first operator runs:

```bash
CARTULARY_BOOTSTRAP_PASSWORD='a long password' \
  mix cartulary.identity.bootstrap \
    --email admin@example.test \
    --name 'Local Admin'
```

This provisions the configured `CARTULARY_FREE_ACCOUNT_KEY`, links the human
password identity at medium assurance, creates the containment root, and grants
propagating `account-admin`.

The `accounts.edition_slot` partial unique index permits exactly one
`community-free` Account. Account-key helpers from the frozen API baseline and
the Ash domain backbone remain internal for eval fixtures and migration
compatibility, but they cannot create another authenticated free slot and no
HTTP route calls them.

The later enterprise migration seam is explicit: enterprise enablement must
replace the free-slot constraint with its licensed Account provisioning action
while preserving the same identity-to-actor, Ash tenant/policy, and RLS
contract. The free-core identity layer does not implement or enable that
enterprise action.

## API-key bootstrap and RLS

AshAuthentication API keys contain a random credential id as part of their
validated envelope. Before the Account RLS setting exists,
`Cartulary.Identity.CredentialLocator` passes only that opaque id to the
`SECURITY DEFINER` function `cartulary_resolve_api_key_account(uuid)`. The
function returns only `account_id`; it cannot return peer data, hashes, or
content. The key hash is then verified by AshAuthentication inside the
resolved Account transaction.

The API-key path additionally requires the resolved Account to own the one
`community-free` edition slot. A valid key attached to a legacy or foreign
Account receives the same unauthorized response as an unknown credential.

This is the identity layer's named infrastructure exception to the direct Repo
rule. It is a bootstrap lookup, not a durable write or authorization decision.

`api_keys` carries `account_id`, has forced Account RLS, and joins the existing
RLS policy inventory. Password/JWT resolution uses the one configured free
Account and rejects a signed subject that is absent from that tenant.

## Basic scope RBAC

Roles are `account-admin`, `curator`, `member`, and `reader`. Each grant records
`effect=allow|deny`, `propagate`, grantor, and grant time.

For a target scope, the resolver:

1. collects exact grants plus grants on containment ancestors whose
   `propagate` flag is true;
2. rejects the scope if any applicable deny exists;
3. otherwise chooses the highest applicable allow;
4. intersects the result with an API key's optional scope restriction.

Containment affects inheritance; cross-links do not. A `ScopeRelation` is
readable only if both its source and target scopes are authorized. This keeps
cross-linked retrieval from bypassing `FR-API-3`.

Cartulary provides the basic free-core role set and inheritance behavior.
Advanced role definition, relationship-based authorization adapters, and
enterprise RBAC administration remain out of scope.

## Contract and evidence

The frozen API baseline's `poc-0` response payloads, downward memory
inheritance, raw-message persistence, and pipeline-only knowledge writes remain
unchanged; `poc-0` is a historical version tag and no longer names a roadmap
phase. Identity, tenancy, and RBAC intentionally replace only the HTTP
Account-selection precondition: authenticated identity is now required and the
old header is inert.

Evidence lives in:

- `test/cartulary/f3_identity_tenancy_basic_rbac_test.exs`;
- `test/cartulary_web/controllers/memory_controller_test.exs`;
- `priv/repo/migrations/20260727155503_f3_identity_tenancy_basic_rbac.exs`;
- `priv/resource_snapshots/`; and
- the baseline-contract, Ash domain backbone, and transactional writes, audit,
  and jobs regression suites listed in `AGENTS.md`.

The identity suite exercises password and API-key authentication, linked
assurance, single-Account enforcement, opaque failures, API-key hash storage,
cross-link authorization, and property-based Account-wall and inheritance/deny
cases.
