# Rules for AI coding agents

This file is read by AI coding agents (Claude, GitHub Copilot, Cursor,
etc.) operating in sas-technology repositories. It does not
auto-propagate — copy it into a repo that wants these rules applied to
its own agent sessions.

## Hard rules

1. **Never commit real student, staff, or family data.** No names,
   emails, grades, attendance, health, or disciplinary records in code,
   tests, fixtures, logs, or commit messages — synthetic data only.
2. **Never commit secrets.** API keys, tokens, passwords, connection
   strings, service-account JSON — all go in environment variables or
   the platform's secret store, never in the repo.
3. **A human reviews and approves every PR an agent opens or
   materially authors**, even in a private repo. Agents do not
   self-merge and do not bypass branch protection.
4. **Don't weaken security or CI controls to make a task easier** —
   no disabling tests, linters, or required checks to get a change
   through; no `--no-verify`, no silently loosening a GitHub ruleset.
5. **Flag anything uncertain** rather than guessing on: data retention
   rules, FERPA/COPPA-adjacent handling, third-party integrations that
   touch student data, or infra/production changes. Ask a human.

## Pull request hygiene

Every PR an agent opens, in any repo:

- **Assign the requesting human** as assignee (`--assignee <login>`). Never
  leave a PR unassigned, and never assign the agent.
- **Add labels**: one `type:` label (`type: feature`, `type: bug`,
  `type: chore`, `type: docs`, `type: security`, `type: release`) plus any
  repo-specific ones. Org standard labels exist in every repo.
- **Target `staging`**; only a release PR (`staging` into `main`) targets
  `main`, titled `Release: ...` and labelled `type: release`. The org's
  `Auto release` workflow opens and merges these itself — do not open one
  by hand unless it fails to.
- **Fill in the PR template**: what changed and why, the related issue, the
  checklist, and the AI-assistance note.
- The org workflow `pr-metadata.yml` fills in a missing assignee and label as
  a backstop; don't rely on it.

## Expected behavior

- Follow this repo's own `CONTRIBUTING.md` and lint/format config
  (falls back to the org defaults in `sas-technology/.github` if the
  repo doesn't have its own).
- Keep changes scoped to what was asked; don't opportunistically
  refactor unrelated code in the same PR.
- Explain non-obvious changes in the PR description, not just in code
  comments.
- When generating a commit or PR authored with AI assistance, it's
  fine (and encouraged) to note that in the PR description.

## Scope

These rules apply to agent sessions working inside sas-technology
repositories. They are guidance for how an agent should behave here,
not a legal agreement.
