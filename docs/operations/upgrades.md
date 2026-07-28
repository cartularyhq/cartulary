<!-- SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0 -->

# Upgrades

Migrations are forward operations. Plan the upgrade so that "go back" means
restoring a snapshot, not running an old binary against a new schema.

## Procedure

```mermaid
flowchart TD
    B1[Create and verify database + blob backups] --> B2[Export an Account archive<br/>as an independent logical check]
    B2 --> S[Stop the old release cleanly]
    S --> U[Unpack the new release beside the old one]
    U --> E[Reuse the same environment<br/>and durable data/blob paths]
    E --> M[Run bin/migrate]
    M --> ST[Start the new release]
    ST --> V{"/api/ready returns 200<br/>and an authenticated read works?"}
    V -->|yes| K[Keep the old tree and backups<br/>until verification completes]
    V -->|no| R[Restore the pre-upgrade database<br/>and blob snapshot together,<br/>then start the prior release]
```

1. Create and verify **both** the database and blob backups described in
   [Backup and restore](backup-restore.md).
2. Export the Account archive as an independent logical recovery check — see
   [Export and import](portability.md).
3. Stop the old release cleanly.
4. Unpack the new release **beside** the old one. Do not overwrite the old
   executable tree or the data directory.
5. Reuse the same environment and the same durable data and blob paths.
6. Run `bin/migrate`, then start the new release.
7. Require `GET /api/ready` to return 200, and exercise one authenticated read.
8. Retain the old executable and the pre-upgrade backups until verification
   completes.

## Rollback

There is no "downgrade migration". Rollback is:

1. stop the new release;
2. restore the database **and** the blob snapshot from the same recovery point;
3. start the prior release.

!!! danger "Never run an old release against a newly migrated database"
    The schema will be ahead of the code. Restore both sides together.

## Migration timing

| Setting | Behaviour |
| --- | --- |
| `CARTULARY_AUTO_MIGRATE=true` | Migrations run as a supervised startup step before traffic is accepted. |
| `CARTULARY_AUTO_MIGRATE=false` | Run `bin/migrate` yourself before starting the release. |

Use `false` where change control requires migration to be a separate, approved
step.

## After the upgrade

Check that background work drains: watch queue depths on `/api/ready`. A new
version may enqueue projection or index rebuild work, and `fast_fallback` on
`/api/v1/context` will read `true` until those projections warm up. That is
expected and self-correcting.

## Version alignment

A release is coherent only when `mix.exs`, the changelog entry, the git tag,
and the evaluation evidence all name the same version. The release-readiness
check enforces this and fails closed. The maintainer-facing procedure lives in
the repository under
[`specs/process/release-checklist.md`](https://github.com/cartularyhq/cartulary/blob/main/specs/process/release-checklist.md).
