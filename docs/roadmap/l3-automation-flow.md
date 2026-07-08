# L3 automation flow

Task 1 establishes only the repository skeleton for the L3 automation plan. It
intentionally does not implement tasks 2-30.

## Intended automated flow

1. A human keeps the 30-task plan in the issue tracker and opens exactly one
   implementation issue per task.
2. The human labels an issue `ai-ready` only after its scope, acceptance
   criteria, architecture anchors, and risk class are clear.
3. Codex works one issue at a time on a feature branch, keeping each PR small
   and focused on that issue.
4. Codex must read the blueprint docs and any applicable repo instructions before
   editing, then implement only the issue scope.
5. Codex opens a PR with real test evidence and links the issue.
6. A human reviews, requests changes if needed, and is the merge gate.
7. After merge, the next task is started from the updated main branch. Do not
   batch tasks 2-30 into a single PR.

## Manual setup required before full automation

The following items require a human with repository or organization access before
Codex can rely on them:

- GitHub labels, especially `ai-ready`, risk labels, and any release/eval labels.
- Branch protection and required checks.
- GitHub Actions permissions, secrets, environments, and runner choices.
- GitHub-side Codex configuration and prompt wiring under `.github/codex/prompts/`.
- Ticket tracker integration and any Telegram or process-channel automation.
- Repository settings for PR templates, issue templates, CODEOWNERS, security
  policy, and disclosure contacts.
- Any paid services, model-provider keys, eval accounts, or deployment targets.

Until those are configured, this repo should prefer inert placeholders and
reviewable documentation over active automation.
