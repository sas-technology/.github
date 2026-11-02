# Contributing

Thanks for contributing to an SAS Technology project. This document
covers the workflow that applies across the org unless a repository's
own `CONTRIBUTING.md` says otherwise.

## Before you start

- Check open issues/PRs first so work isn't duplicated.
- For anything non-trivial, open an issue describing the change
  before writing code — it's a lot cheaper to redirect a plan than a
  finished PR.

## Branches

- Branch off the repository's default branch.
- Name branches descriptively, e.g. `<github-username>/<short-description>`
  or `fix/<short-description>`.
- Don't push directly to the default branch — every change goes
  through a pull request (see [`github-rulesets/`](./github-rulesets/)
  for the org's branch rules).

## Commits

- Prefer [Conventional Commits](https://www.conventionalcommits.org/)
  style (`fix:`, `feat:`, `chore:`, `docs:`, …) — it makes history and
  changelogs easier to read, but it is a convention here, not a
  CI-enforced requirement.
- Write commit messages that explain **why**, not just what changed.

## Pull requests

- Keep PRs focused — one logical change per PR.
- Fill in the PR template; link the issue it closes, if any.
- CI must pass (see the org's [reusable lint
  workflow](./.github/workflows/reusable-lint.yml)) before merge.
- At least one review approval is required (see the org ruleset in
  [`github-rulesets/org-wide-main-protection.json`](./github-rulesets/org-wide-main-protection.json)).
- Squash, rebase, or merge commits are all accepted; pick whichever keeps
  history readable for the change.

## Code review

- Reviewers: focus on correctness, security, and maintainability
  first; style nits last (and ideally caught by lint/format tooling,
  not a human).
- Authors: respond to every comment, even if just to say "done" or
  explain why not.

## AI-assisted contributions

If you use an AI coding assistant (Claude, Copilot, etc.) to help
with a contribution, see [`AGENTS.md`](./AGENTS.md). You're still the
accountable author of anything you submit — review AI-generated
changes before opening the PR.

## Data handling

Never commit real student, staff, or family data (names, emails,
grades, attendance, health info, etc.) into a repository, even a
private one, even in a test fixture. Use synthetic/fake data for
examples and tests.
