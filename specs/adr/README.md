<!-- SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0 -->

# Architecture Decision Records

Use this directory for ADRs that record implementation decisions not already
settled by the blueprint specs.

| ADR | Decision |
| --- | --- |
| `0001-repo-automation-model.md` | How repository automation is structured. |
| `0002-l3-automation-boundary.md` | What autonomous agents may and may not decide. |
| `0003-embedded-postgres-pg0.md` | One data layer everywhere; pg0 as the local launcher. |
| `0004-multi-strategy-retrieval.md` | Candidate generation, fusion, and rerank as three seams under a deadline. |
| `0005-peer-inline-validation-over-mcp.md` | Validation questions attached to read-tool results. |
| `0006-entity-resolution.md` | Canonical referents resolved at dream-time, exposed through no public surface. |
| `0007-unattended-governance-consent.md` | Declared-account/deployment auto-grant of subject consent, off by default. |
| `0008-restricted-database-role-for-rls-enforcement.md` | A NOSUPERUSER NOBYPASSRLS role is what makes Postgres row-level security actually enforce. |

Conventions for future ADRs:

- Name files `NNNN-short-title.md`.
- Cite relevant `FR-*`, `AD-*`, `AINV-*`, or `NFR-*` anchors.
- Keep status explicit: `Proposed`, `Accepted`, `Superseded`, or `Rejected`.
- Do not use ADRs to override blueprint requirements without an explicit
  blueprint update in the same or a preceding PR.
- Longer design documents that fan out into an ADR live in `specs/design/`.
- ADRs are never published to the documentation site. If a decision changes
  what a user sees, update the affected page under `docs/` in the same patch.
