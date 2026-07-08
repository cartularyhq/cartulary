# Create a GitHub pull request

Open a pull request for the current branch's changes.

## Steps

1. Inspect the work: `git status`, `git diff`, and `git log` against the base branch so the PR describes what actually changed.
2. Ensure the branch is pushed: `git push -u origin HEAD` if needed. Never open a PR from the default branch — create a feature branch first if you are on it.
3. Draft the PR body using `.github/pull_request_template.md` as a **recommended structure**, not a strict form.
4. Create the PR with the `gh` CLI:

   ```bash
   gh pr create --title "<title>" --body-file <path>
   ```

   Prefer `--body-file` (write the body to a temp file) over inline `--body` so markdown survives intact.
5. Print the created PR URL.

## Template guidance (recommendation, not requirement)

The PR template suggests these sections. Use the ones that add signal:

- **Summary** — what changed and why.
- **Linked issue** — `Closes #<n>` when an issue exists.
- **Architecture anchors touched** — `AINV-`, `AD-`, `NFR-` anchors affected, when applicable.
- **Risk class** — Low / Medium / High.
- **AI usage** — check what applies (no AI, Codex implementation / review / test generation / docs generation).
- **Test evidence** — real commands run and their real output.

Skip any section that would be empty or noise. Accuracy over completeness.

## Rules

- **Test evidence must be real.** Only include commands you actually ran and their actual output. Never fabricate passing results. If tests were not run, say so.
- Keep the summary honest about scope and any known gaps.
- Do not invent architecture anchors or a risk class you cannot justify.
