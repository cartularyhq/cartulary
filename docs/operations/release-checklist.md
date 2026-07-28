<!-- SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0 -->

# Release Checklist

This checklist is the F11 release gate for `AD-EVAL-1` through `AD-EVAL-5`,
`FR-PLAT-2`, `FR-PLAT-4`, `FR-PLAT-5`, `NFR-1`, and `NFR-11`.

## Prepare

- [ ] Choose the SemVer bump under `versioning.md`.
- [ ] Update `mix.exs`, `CHANGELOG.md`, and any changed protocol identity.
- [ ] Confirm README, AGENTS, roadmap, architecture, operations, and eval docs
  describe the same release.
- [ ] Confirm every public quality number has dataset id/hash/split, date,
  profile/version, deadline, four model-role identities, judge method, and run
  limits.
- [ ] Confirm tuning used only the held-out split.

## Deterministic guardrails

- [ ] `mix deps.get`
- [ ] `mix ash.codegen --check`
- [ ] `mix format --check-formatted`
- [ ] `mix compile --warnings-as-errors`
- [ ] `mix test`
- [ ] `mix credo --strict`
- [ ] `mix dialyzer`
- [ ] `mix sobelow --config`
- [ ] `mix hex.audit`

## Evaluation and parity

```bash
mix cartulary.eval.release \
  --no-model \
  --assert-thresholds \
  --output /private/tmp/cartulary-release-eval.json

mix cartulary.release.check \
  --tag "v$(sed -n 's/.*version: \"\\([^\"]*\\)\".*/\\1/p' mix.exs)" \
  --eval-report /private/tmp/cartulary-release-eval.json
```

- [ ] External-Postgres deterministic gate passed.
- [ ] Packaged-pg0 readiness and full-suite lane passed.
- [ ] Mix release and production container builds passed.
- [ ] Frontier changes in quality, abstention, latency, token efficiency, and
  BEAM degradation have an explanation even when guardrail floors pass.
- [ ] Any unavailable lane or surface is explicitly present in the release
  evidence; do not describe it as shipped.

## Publish

- [ ] Tag the gated commit exactly `v<version>`.
- [ ] Retain the `f11-suite-1` report and artifact SHA-256 with the release.
- [ ] Verify the unpacked pg0 package and container both return readiness.
- [ ] Exercise authenticated ingest, governed read, export, and fresh import.
- [ ] Keep the prior package and verified database/blob backups until the
  upgrade checks complete.

GitHub rulesets should require:

- `Deterministic gate (external Postgres)`
- `Dialyzer`
- `Deterministic gate (packaged pg0)`
- `Release and container builds`

Rulesets and publishing permissions are repository settings and remain a human
maintainer action.
