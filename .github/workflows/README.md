<!-- SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0 -->

# GitHub Actions Workflows

Evaluation, CI, and release readiness makes the repository automation executable
rather than placeholder-only. CI and evaluation use read-only repository
permissions. The tag-only release job receives `contents: write` and
`packages: write` so it can publish the gated outputs. Repository action access
is deliberately narrower than “allow all”:
GitHub-owned actions and `erlef/setup-beam@*` are the only non-local actions
needed. The matching repository setting is documented in
`specs/roadmap/beta-roadmap.md`.

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

Runs for semantic tags or manual publication of an existing tag. It repeats
deterministic guardrails, verifies the tag/version/changelog/eval tuple, and
builds the checksum-pinned Linux x86_64, macOS Apple Silicon, and macOS Intel
pg0 packages. Each package boots from an empty data root and passes the full
suite on its native runner. A final fan-in publishes all three archives, their
SHA-256 files, and eval evidence as durable GitHub Release assets. The Linux
job also pushes the container to this repository's GHCR package with both
`<version>` and `v<version>` tags; a stable release advances `latest`.
Workflow-run copies remain available for 90 days for debugging.
An existing GitHub Release is never overwritten; prerelease versions are marked
as prereleases and do not move `latest`.

Configure the four CI job names as required checks only after they have reported
successfully. See `specs/process/release-checklist.md`.

## `docs.yml`

Builds the published user documentation from `docs/` with MkDocs Material and
deploys it to GitHub Pages. It runs on pushes to the default branch that touch
`docs/`, `mkdocs.yml`, or the workflow itself, on pull requests touching the
same paths, and on manual dispatch.

The build job needs no permissions and runs on pull requests too, so an
untrusted branch proves the site still compiles without being able to publish
it. Only the default branch reaches the deploy job, which holds `pages: write`
and `id-token: write` and nothing else.

`mkdocs.yml` sets `strict: true`, so a broken internal link or a page missing
from the navigation fails the build rather than shipping a dead link.

Publishing requires GitHub Pages to be set to "GitHub Actions" as its source.
That is a repository setting and remains a maintainer action; until it is set,
the deploy job fails and the build job still guards the Markdown.
