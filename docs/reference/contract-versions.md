<!-- SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0 -->

# Contract versions

Several Cartulary responses carry a version string of their own, separate from
the application's semantic version. They tell a client **which behaviour it is
talking to**, so a client can pin or reject a shape it does not understand.

The `f`-prefixed strings are historical version tags. They do not name a
release phase, and they are not cosmetic — changing one is a deliberate
contract transition.

| Identity | Where you see it | Covers |
| --- | --- | --- |
| `poc-0` | Not in responses | The frozen behaviour baseline and the historical evaluation reports |
| `f4-1` | Governance records | Governed lifecycle: proposals enter `proposed`/`provisional`, or are held |
| `f5-1` | `GET /api/health` → `version` | Extractor and pipeline identity |
| `f7-1` | `search`, `ask`, `context` → `profile_version` | Retrieval and context profile identity |
| `f9-1` | `readiness` → `report_version` | Skill selector language and gap-report schema |
| `f10-1` | `GET /api/ready` | Readiness payload shape |
| `f11-1`, `f11-suite-1` | Evaluation reports | Report schema and release bundle |
| `f11-surface-contracts-1` | Surface contract inventory | Which surfaces exist, are gated, or are unavailable |
| `cartulary-account-1` | Logical archive manifests | Account archive schema |

## Application version versus contract version

`GET /api/health` returns `"version": "f5-1"`. That is **not** `0.2.0`.

- **Application version** — Semantic Versioning, authoritative in `mix.exs`,
  matched by a dated changelog entry and a `v`-prefixed git tag. It answers
  "which build is this?"
- **Contract version** — answers "which behaviour does this build implement for
  this surface?"

They move independently. A patch release changes the application version and
nothing else; a change to the gap-report shape moves `f9-1` and also needs a
release.

## What a client should do

**Pin what you parse.** If your client depends on the shape of a readiness
report, check `report_version` and refuse a value you do not recognise. Failing
loudly on an unknown contract is better than silently misreading a field.

**Do not treat a contract identity as an ordering.** `f9-1` is not "newer than"
`f7-1`; they version different things.

**Expect these strings to be stable.** A transition requires a changelog entry,
updated contract evidence, and a note in the closest architecture document. It
is not something that happens quietly between patch releases.

## Related

- [HTTP API reference](http-api.md) — where each identity appears
- [Limitations](limitations.md) — surfaces marked unavailable in the inventory
