<!-- SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0 -->

# GitHub Actions Workflows

F11 makes the repository automation executable rather than placeholder-only.
All workflows use read-only repository permissions.

## `ci.yml`

Runs on pull requests, `main`, and merge queues:

- `Deterministic gate (external Postgres)` runs Ash snapshot drift, format,
  warnings-as-errors compile, all ExUnit/property tests, Credo, Sobelow, Hex
  retirement audit, the deterministic release-eval matrix, report verification,
  and release readiness.
- `Dialyzer` runs type analysis with cached PLTs.
- `Deterministic gate (packaged pg0)` checksum-builds and boots the packaged pg0
  release, verifies readiness, then runs the complete test suite against that
  pg0 instance.
- `Release and container builds` runs only after all three gates and builds the
  Mix release plus production container.

There is no SQLite lane. ADR-0003 requires Postgres + pgvector + PG-FTS + Oban
in every deployment mode; pg0 and external Postgres vary infrastructure
location, not product behavior.

## `eval.yml`

Runs the versioned `f11-1` release matrix nightly or manually and retains the
report artifact for 30 days. Scheduled runs are deterministic. A manual
maintainer may select live-model mode only when the repository has a protected
`OPENROUTER_API_KEY` and `CARTULARY_EVAL_JUDGE_MODEL` variable. The judge model
must differ from `CARTULARY_MODEL_ASK`; untrusted pull requests never receive
the credential.

## `release.yml`

Runs for semantic tags or manual validation. It repeats deterministic
guardrails, verifies the tag/version/changelog/eval tuple, builds the
checksum-pinned Linux pg0 package and production container, and uploads the
package SHA-256 plus eval evidence. It does not create a GitHub Release or push
an image; those write permissions remain an explicit maintainer decision.

Configure the four CI job names as required checks only after they have reported
successfully. See `docs/operations/release-checklist.md`.
