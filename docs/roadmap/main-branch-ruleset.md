# Initial `main` branch GitHub ruleset

Issue: https://github.com/cartularyhq/cartulary/issues/11

This document is the intended initial GitHub ruleset checklist for `main`.
It is an operator runbook, not proof that the GitHub-hosted ruleset is active.
A human maintainer with repository settings access must apply and verify these
settings in GitHub.

## Blueprint anchors

- `AINV-1` — one codebase, two modes, identical guarantees. The protected
  branch is the shared integration point for both deployment modes, so merge
  controls must not create separate implementation tracks.
- `AD-EVAL-*` — deterministic PR gate and eval separation. Required checks
  should eventually point at deterministic PR-gate jobs only; nightly, release,
  live-model, or exploratory evals should report separately unless a later task
  explicitly promotes one to the merge gate.

## Target

Create one active branch ruleset named `main protected integration` targeting
only the default branch:

- Include: `main`
- Exclude: none initially
- Enforcement status: start as **Evaluate** or a disabled/draft equivalent while
  validating the configuration; switch to **Active** only after a low-risk PR
  confirms the rule behavior.

If GitHub rulesets are not available on the repository plan, configure an
equivalent classic branch protection rule for `main`.

## Required rules

Enable these rules for `main`:

1. **Require a pull request before merging.**
   - Require at least **1 approving review**.
   - Dismiss stale approvals when new commits are pushed.
   - Require conversation resolution before merge.
   - Require review from Code Owners once `.github/CODEOWNERS` is present and
     GitHub confirms it is requesting the expected reviewers.
2. **Block force pushes.**
   - Do not allow force pushes for contributors or automation accounts.
   - Keep administrator bypass limited to emergency use by repository owners.
3. **Block deletions.**
   - The `main` branch must not be deletable through normal contributor flows.
4. **Require status checks only after CI exists and has reported.**
   - Do **not** require a check until the corresponding GitHub Actions job has
     run successfully at least once on a pull request or branch, because GitHub
     can only require checks it has seen.
   - Start without required checks in the current repository skeleton.
   - Add deterministic PR-gate checks incrementally as their workflow tasks land.
5. **Require branches to be up to date before merging** until merge queue is
   enabled.
   - Enable merge queue later when PR volume or deterministic gate duration makes
     it useful.
   - Do not enable merge queue before the required check set is stable enough to
     validate queued merge groups.

## Future required-check placeholders

The current repository does not yet contain active CI workflows. Treat the names
below as placeholders, not as required settings to enable now:

| Placeholder check | When to require it | Notes |
| --- | --- | --- |
| `elixir / deps` | After a workflow runs `mix deps.get` successfully. | Needed only once a Mix project exists. |
| `elixir / format` | After a workflow runs `mix format --check-formatted`. | Deterministic PR-gate check. |
| `elixir / compile` | After a workflow runs `mix compile --warnings-as-errors`. | Deterministic PR-gate check. |
| `elixir / test` | After a workflow runs `mix test`. | Deterministic PR-gate check. |
| `elixir / credo` | After Credo is configured and reports successfully. | Optional until configuration exists. |
| `elixir / dialyzer` | After PLT/build caching and Dialyzer configuration are stable. | Optional until configuration exists. |
| `security / sobelow` | After Sobelow configuration exists and reports successfully. | Security-sensitive gate when available. |
| `eval / deterministic` | After in-repo deterministic eval scenarios exist. | Must exclude live-model/nightly release evals unless explicitly promoted. |

Never require placeholder checks in GitHub before they exist and report. Doing so
can block all merges without adding safety.

## Manual GitHub setup steps

1. Open the repository on GitHub.
2. Go to **Settings** → **Rules** → **Rulesets**.
3. Click **New ruleset** → **New branch ruleset**.
4. Name it `main protected integration`.
5. Target only `main`.
6. Configure the required rules listed above.
7. Leave required status checks empty until CI jobs exist and have reported.
8. Save in **Evaluate** mode first, or save disabled/draft if Evaluate is not
   available.
9. Open a low-risk PR and confirm that GitHub requires a PR review, blocks direct
   pushes, and reports the expected rule evaluation.
10. After validation, switch the ruleset to **Active**.
11. When each CI task lands, return to the ruleset and add only the check names
    that have already reported successfully.
12. Record the human verification result in the PR or issue that activates the
    GitHub-hosted settings.

## Verification checklist

A maintainer should verify these items after manual configuration:

- [ ] `main` is targeted by the ruleset or equivalent branch protection rule.
- [ ] Direct pushes to `main` are blocked for non-bypass users.
- [ ] Force pushes to `main` are blocked.
- [ ] Deleting `main` is blocked.
- [ ] Pull requests require at least one approval.
- [ ] CODEOWNER review is required after CODEOWNERS is confirmed active.
- [ ] Required checks are empty until matching CI jobs exist and report.
- [ ] Each required check name exactly matches a recently reported GitHub check.
- [ ] Merge queue remains disabled until the check set is stable, or is tested
      with queued merge groups before being relied upon.
- [ ] Any bypass ability is limited to repository administrators/owners and is
      documented as emergency-only.

## Non-goals

- This document does not enable the GitHub-hosted ruleset.
- This document does not require checks before CI jobs exist.
- This document does not add GitHub Actions workflows, secrets, environments, or
  Codex automation.
- This document does not claim that repository settings have been verified.
