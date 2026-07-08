# Manual automation setup guide

This guide expands the manual setup checklist from `l3-automation-flow.md` into
operator steps for the repository owner. It is intentionally written as a manual
runbook because these settings require repository or organization permissions
that Codex should not assume.

Use this guide after Task 1 and before relying on Codex for full L3 automation.
Keep changes incremental: configure one area, verify it with a small PR, then
move to the next area.

## 0. Recommended order

1. Confirm repository basics and maintainer access.
2. Create labels and milestones.
3. Confirm issue and PR templates are active.
4. Add or verify CODEOWNERS and security policy when those task PRs land.
5. Add CI workflows one lane at a time.
6. Configure branch protection or rulesets after CI jobs exist.
7. Configure Codex Cloud and Codex PR review.
8. Configure secrets, environments, eval accounts, and deployment targets only
   when a task needs them.
9. Add process-channel automation such as Telegram last, after the GitHub flow is
   stable.

## 1. GitHub labels

Labels are the control surface that decides whether Codex may implement an issue
and which reviewers/gates are required.

### Required label set

Create these labels first:

| Label | Purpose |
| --- | --- |
| `ai-ready` | Codex may implement the issue. Apply only after scope, acceptance criteria, risk, and tests are clear. |
| `ai-assisted` | AI may help, but the task still needs close human steering. |
| `ai-review-only` | Codex may review but should not implement. |
| `human-only` | Codex must not implement; human decision or implementation required. |
| `needs-adr` | Requires an ADR before implementation. |
| `security-sensitive` | Security review required. |
| `tenancy-sensitive` | Tenant isolation or account-boundary review required. |
| `audit-sensitive` | Audit, ledger, or immutable-history review required. |
| `pipeline-sensitive` | Oban, transactional outbox, ingest, or background-job review required. |
| `backend-parity-required` | SQLite and Postgres parity evidence required. |
| `eval-required` | Eval scenario or eval workflow evidence required. |
| `good-first-agent-task` | Small, low-risk task suitable for Codex. |

### How to create labels in the GitHub UI

1. Open the repository on GitHub.
2. Go to **Issues** → **Labels**.
3. Click **New label**.
4. Add the label name, description, and color.
5. Repeat for each label above.
6. For each new task issue, apply exactly one execution-control label:
   `ai-ready`, `ai-assisted`, `ai-review-only`, or `human-only`.

### How to create labels with GitHub CLI

Run from a machine with `gh` authenticated as a maintainer:

```bash
gh label create ai-ready --description "Codex may implement after scope and tests are clear" --color 2ea44f
gh label create ai-assisted --description "AI may help with close human steering" --color a2eeef
gh label create ai-review-only --description "Codex review allowed; implementation not allowed" --color 7057ff
gh label create human-only --description "Human-only decision or implementation" --color b60205
gh label create needs-adr --description "Architecture decision record required before implementation" --color d93f0b
gh label create security-sensitive --description "Security review required" --color ee0701
gh label create tenancy-sensitive --description "Tenant isolation review required" --color ee0701
gh label create audit-sensitive --description "Audit or ledger review required" --color ee0701
gh label create pipeline-sensitive --description "Pipeline or Oban review required" --color fbca04
gh label create backend-parity-required --description "SQLite and Postgres parity evidence required" --color 5319e7
gh label create eval-required --description "Eval scenario or workflow evidence required" --color 006b75
gh label create good-first-agent-task --description "Small low-risk Codex task" --color c5def5
```

## 2. Branch protection, rulesets, and required checks

Do not configure required status checks before the corresponding CI jobs exist;
GitHub can only require checks that have reported recently.

### Initial `main` protection target

When CI tasks land, protect `main` with these rules:

- Require a pull request before merge.
- Require at least one approving review.
- Require CODEOWNER review after CODEOWNERS is added.
- Require status checks for the deterministic PR gate jobs that exist.
- Require branches to be up to date, or enable merge queue once PR volume
  justifies it.
- Block force pushes.
- Block deletions.
- Restrict bypass permissions to repository administrators only, if anyone.

### Setup path in GitHub UI

1. Open **Settings** → **Rules** → **Rulesets**.
2. Create a branch ruleset targeting `main`.
3. Add the restrictions above.
4. Add required checks only after their workflow jobs have run at least once.
5. Save the ruleset in active mode only after testing it with a low-risk PR.

If rulesets are not available on your plan, use **Settings** → **Branches** →
**Branch protection rules** and create a rule for `main` with equivalent options.

## 3. GitHub Actions permissions, secrets, environments, and runners

Start with the principle that Actions should be read-only by default and receive
write permissions only in narrowly scoped release or publishing jobs.

### Repository-level Actions settings

1. Open **Settings** → **Actions** → **General**.
2. Set default workflow permissions to **Read repository contents permission**.
3. Disable broad write tokens unless a specific workflow task requires them.
4. Decide whether GitHub-hosted runners are enough for Elixir/Phoenix builds.
5. Add self-hosted runners only if you need private network access, specialized
   hardware, or cost controls.

### Secrets and variables

Create secrets only when a workflow needs them. Prefer environment-specific
secrets for deployment targets.

Suggested initial convention:

| Secret or variable | When to add | Notes |
| --- | --- | --- |
| `CODECOV_TOKEN` | Coverage upload task | Optional. Do not add before coverage exists. |
| `HEX_API_KEY` | Package publish task | Release-only; environment protected. |
| `GHCR_TOKEN` or GitHub token permissions | Container publish task | Prefer built-in `GITHUB_TOKEN` with minimal package permissions. |
| `OPENAI_API_KEY` | Eval or Codex Action task that truly needs model calls | Never expose to pull requests from forks. |
| Deployment credentials | Deployment task | Store in protected environments. |

## 4. GitHub-side Codex configuration and prompt wiring

Codex Cloud and automatic PR review require human setup outside the repo. The
repo can provide instructions and prompt files, but the owner must connect the
integration.

### Manual Codex setup

1. Open Codex Cloud / ChatGPT Codex and connect the GitHub organization or repo.
2. Grant the minimum repository access needed for Cartulary.
3. Enable Codex PR review only after `AGENTS.md` exists.
4. Start with manual `@codex review` on PRs.
5. Enable automatic reviews only after several manual reviews produce useful,
   low-noise feedback.
6. Keep Codex implementation limited to issues labeled `ai-ready`.

### Prompt wiring policy

- `.codex/prompts/` contains local helper prompts.
- `.github/codex/prompts/` is reserved for GitHub-side automation prompts.
- Add GitHub-side prompt files only when a task defines:
  - the prompt name,
  - when it runs,
  - what permissions it receives,
  - whether it may write comments, commits, or only produce artifacts,
  - how humans review its output.

## 5. Ticket tracker and process-channel automation

Do not automate Telegram or external tracker actions until the GitHub issue and
PR flow is stable.

Minimum expected flow:

1. Human creates or approves one issue per practical task.
2. Human applies `ai-ready` only when implementation is allowed.
3. Codex opens one PR for that issue.
4. CI and review complete.
5. Human merges or closes the PR.
6. Automation posts status updates to the process channel only after the GitHub
   state changes.

For Telegram or another process channel, create a bot/token only when you know
which events it will report. Recommended initial events are:

- issue marked `ai-ready`,
- PR opened,
- CI failed,
- PR ready for human review,
- PR merged,
- manual setup blocked.

Never send secrets, customer data, model keys, restricted content, or PII to the
process channel.

## 6. Repository settings for templates, CODEOWNERS, and security policy

After the corresponding task PRs land:

1. Verify issue templates appear when opening a new issue.
2. Verify the PR template appears when opening a pull request.
3. Verify CODEOWNERS requests the expected reviewers on sensitive paths.
4. Add `SECURITY.md` with disclosure contacts before enabling public security
   reporting.
5. In **Settings** → **Security**, enable the security features appropriate for
   the repo plan, such as secret scanning and dependency alerts.

## 7. Paid services, model-provider keys, eval accounts, and deployment targets

Treat these as production credentials even during early development.

1. Create separate accounts/projects for development, evaluation, staging, and
   production.
2. Use least-privilege keys with rotation plans.
3. Prefer GitHub Environments for protected deployment and release credentials.
4. Never expose model-provider keys to untrusted pull-request workflows.
5. Keep eval datasets and cassettes deterministic in PR gates; live model evals
   should run nightly or on release, not as a required PR check at first.
6. Document every external service in `docs/security/` or `docs/eval/` before a
   workflow depends on it.

## 8. Verification checklist

Before declaring automation ready, verify:

- [ ] Labels exist and are used consistently.
- [ ] At least one issue has complete scope, risk, acceptance criteria, and tests.
- [ ] PR and issue templates render in GitHub.
- [ ] CI jobs run on pull requests.
- [ ] Required checks match actual CI job names.
- [ ] `main` cannot be merged to without required review and checks.
- [ ] CODEOWNERS requests the expected reviewer for sensitive paths.
- [ ] Codex can review a PR manually.
- [ ] Automatic Codex review is either disabled intentionally or enabled with
      acceptable noise.
- [ ] Secrets are limited to workflows that need them.
- [ ] Process-channel automation posts only non-sensitive status.

## References

- GitHub Docs: managing labels for issues and pull requests — https://docs.github.com/issues/using-labels-and-milestones-to-track-work/managing-labels
- GitHub Docs: branch protection rules — https://docs.github.com/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches
- GitHub Docs: repository rulesets and available rules — https://docs.github.com/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/available-rules-for-rulesets
- OpenAI Developers: Codex code review in GitHub — https://developers.openai.com/codex/integrations/github
