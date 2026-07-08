# Create a GitHub issue

Draft and open a GitHub issue for the work described in the request (or the current context if no description is given).

## Steps

1. Understand the change: read the relevant code/blueprint so the issue is grounded in reality.
2. Draft the issue body using `.github/ISSUE_TEMPLATE/task.md` as a **recommended structure**, not a strict form.
3. Fill in the sections you can. Omit or trim sections that do not apply — do not pad with empty headings just to match the template.
4. Create the issue with the `gh` CLI:

   ```bash
   gh issue create --title "<title>" --body-file <path>
   ```

   Prefer `--body-file` (write the body to a temp file) over inline `--body` so markdown survives intact. Add `--label` where a label clearly applies.
5. Print the created issue URL.

## Template guidance (recommendation, not requirement)

The task template suggests these sections. Use the ones that add signal:

- **Goal** — one or two sentences on the outcome.
- **Architecture anchors** — reference relevant `AINV-`, `AD-`, `NFR-` anchors from `blueprint/` when applicable.
- **Scope** — in scope / out of scope bullets when the boundary is non-obvious.
- **Expected behavior**
- **Acceptance criteria** — checklist of verifiable outcomes.
- **Required tests** — check the test types that apply (unit, SQLite/Postgres data-layer, contract, property/invariant, security, eval).
- **Risk class** — Low / Medium / High / Human-only.

Skip any section that would be empty or noise. A short, accurate issue beats a fully-populated but hollow one.

## Rules

- Do not invent architecture anchors, acceptance criteria, or test requirements. Leave them out if unknown and note the gap.
- Ask for missing critical detail (the goal) rather than guessing.
