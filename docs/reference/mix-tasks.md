<!-- SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0 -->

# Mix tasks

Operator and maintainer commands available from a source checkout. A packaged
release contains no Mix tasks; the release equivalents are noted where they
exist.

| Task | Purpose |
| --- | --- |
| `cartulary.identity.bootstrap` | Create the Account and first administrator |
| `cartulary.portability.export` | Write a whole-Account logical archive |
| `cartulary.portability.import` | Load or verify an archive |
| `cartulary.eval.smoke` | Developer sanity pass over the real write/read path |
| `cartulary.eval.benchmark` | Run one benchmark fixture and score it |
| `cartulary.eval.release` | Run the deterministic release matrix |
| `cartulary.eval.verify` | Validate a report's provenance |
| `cartulary.release.check` | Fail unless the tree is releasable |

---

## `cartulary.identity.bootstrap`

Turns a migrated but empty database into a usable installation: provisions the
community Account, registers a human peer with a password identity, grants the
administrator role on the root scope with downward propagation, and prints a
bearer token valid for 12 hours.

```bash
CARTULARY_BOOTSTRAP_PASSWORD='a long password' \
  mix cartulary.identity.bootstrap \
    --email admin@example.test \
    --name 'Local Admin'
```

| Switch | Notes |
| --- | --- |
| `--email`, `-e` | Required. Becomes the sign-in identity and, normalised, the peer key |
| `--name`, `-n` | Display name. Defaults to the email |
| `--password` | Prefer the environment variable — an argument is visible in shell history and the process list |

There is no fallback password. Re-running for an existing email raises. The
whole bootstrap is one transaction, so a failure never leaves a half-created
administrator.

**In a release:** call `Cartulary.Identity.bootstrap_human/1` through
`bin/cartulary rpc` — see the
[Quickstart](../getting-started/quickstart.md#1-bootstrap-an-administrator).

---

## `cartulary.portability.export`

```bash
mix cartulary.portability.export --output /secure/path/cartulary-account.tar.gz
```

Default output is `cartulary-export-YYYY-MM-DD.tar.gz` in the working
directory. Read inside one Account-scoped transaction, so the snapshot is
internally consistent.

**In a release:**
`bin/cartulary rpc 'Cartulary.Release.export!("/secure/path/account.tar.gz")'`

See [Export and import](../operations/portability.md) for what is included.

---

## `cartulary.portability.import`

```bash
mix cartulary.portability.import --input /secure/path/account.tar.gz
mix cartulary.portability.import --input /secure/path/account.tar.gz --validate-only
```

Verification always happens first: manifest hash, every per-resource file hash,
every blob hash, and the entire audit hash chain — all before any durable
write.

Import requires a **fresh target**: migrated, with no Account holding the
archived id or occupying the community slot. It refuses rather than blending
two histories.

**In a release:** `Cartulary.Release.import!/1` and
`Cartulary.Release.validate_archive!/1` through `bin/cartulary rpc`.

---

## `cartulary.eval.smoke`

```bash
mix cartulary.eval.smoke --profile balanced --account eval-poc
```

A developer sanity check, not a graded evaluation: it ingests a few messages,
asks a few questions, and prints what came back. No scores, no thresholds.

!!! danger "It writes real rows"
    There is no dry-run mode and no cleanup. Point it at a scratch database,
    and never reuse an Account key that holds real user data.

---

## `cartulary.eval.benchmark`

```bash
mix cartulary.eval.benchmark --benchmark locomo --dataset data/locomo10.json
```

Runs one fixture end to end through the ordinary write and answer paths and
scores it. Recognised shapes: LoCoMo, LongMemEval, ConvoMem, BEAM, and
Cartulary's own `{"messages": [...], "questions": [...]}`.

| Switch | Notes |
| --- | --- |
| `--dataset`, `-d` | Required. Hashed, so the report names the exact data |
| `--benchmark`, `-b` | Inferred from shape when omitted |
| `--profile`, `-p` | Default `balanced` |
| `--account` | Default `eval-benchmark` |
| `--run-id` | Seeds the scope root; give concurrent runs distinct ids |
| `--limit-cases` / `--limit-messages` / `--limit-questions` | Truncate for a fast loop — recorded in the report, because a truncated run is not comparable |
| `--no-model` | Deterministic local extractor and answerer |

Also writes real rows. Same warning applies.

---

## `cartulary.eval.release`

```bash
mix cartulary.eval.release \
  --no-model \
  --assert-thresholds \
  --output /private/tmp/cartulary-release-eval.json
```

Runs the versioned release matrix. The matrix definition lives in the
repository at `specs/eval/release-suite.json` and the floors at
`specs/eval/deterministic-thresholds.json`. Only runs explicitly flagged as
release guardrails can block; the rest are ablations that inform.

---

## `cartulary.eval.verify`

```bash
mix cartulary.eval.verify /tmp/cartulary-eval.json
```

Checks that a report carries enough provenance to be quotable: application
version, timestamp, benchmark, retrieval profile and version, deadline,
strategy override, run limits, dataset id with SHA-256 and split, all four
model-role identities, judge, and metrics.

Provenance only — it re-runs nothing and compares nothing to a floor.

---

## `cartulary.release.check`

```bash
mix cartulary.release.check --eval-report /private/tmp/cartulary-release-eval.json
mix cartulary.release.check --tag v0.2.0 --eval-report /private/tmp/...
```

The last gate before tagging. Fails unless the version in `mix.exs`, the
changelog, the shipped documentation, the git tag, and the recorded evaluation
evidence all describe the same release. There is no partial or warning outcome.

`--allow-missing-eval` exists for metadata-only lanes; a real release must
supply the report.
