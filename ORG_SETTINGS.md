# Org settings — apply guide

Everything in this repo that's just a _file_ (community health files,
templates, reusable workflows) takes effect automatically, per the
table in [`README.md`](./README.md). Everything below needs a human
with **organization owner** access to click through GitHub's UI (or
use a `gh`/API script with `admin:org` scope) — there is no file that
applies these for you.

## Plan: GitHub Team

This org is on **GitHub Team**, so branch protection and rulesets
enforce on every repo — public and private alike. The import steps
below apply org-wide as written; there's no public/private split to
worry about.

## 1. Import the branch/tag rulesets

For each JSON file in [`github-rulesets/`](./github-rulesets/):

1. Go to **github.com/organizations/sas-technology/settings/rules** →
   **New ruleset** → **Import a ruleset**.
2. Upload the JSON file.
3. Review it, then set **Enforcement status** to **Active**.

Or run `scripts/apply-org-rulesets.sh` (imports both files as
_disabled_; add `--active` to enforce, `--dry-run` to preview).

| File                            | What it does                                                                                                                                                                                                                                                                                         |
| ------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `org-wide-main-protection.json` | On every repo's default branch: no deletion, no force-push, PR required before merge (0 required approvals), PR review threads must be resolved, squash/rebase merges only, and the five `lint / *` checks + the org-required `org-lint.yml` workflow must pass before merge. Org admins can bypass. |
| `release-tag-protection.json`   | Tags matching `vX.Y.Z` can't be deleted, force-pushed, or moved once created — for any repo that does semver releases.                                                                                                                                                                               |

**Before you import `org-wide-main-protection.json`**, note it
hardcodes this repo's numeric ID (`1211111495`, i.e.
`sas-technology/.github`) in the `workflows` rule so the required
`org-lint.yml` workflow resolves correctly. That ID only needs to
change if this repo is ever deleted and recreated.

**Adjust before importing, if needed:**

- `required_approving_review_count: 0` — most work here is built in
  isolation, so no reviewer is required. Raise it per your needs; a
  value above 0 locks out repos with no second reviewer.
- `require_code_owner_review: false` — flip to `true` once most repos
  actually have a `.github/CODEOWNERS` (see §3). Turning it on before
  that just makes PRs unmergeable on repos with no owners defined.
- `repository_name.exclude` — add any repo name patterns that should
  be exempt (e.g. scratch/sandbox repos).

## 2. Turn on org-wide security defaults

**github.com/organizations/sas-technology/settings/security**:

- [ ] Dependabot alerts: **on** for all repos
- [ ] Dependabot security updates: **on** for all repos
- [ ] Secret scanning: **on** for all repos (private repos need this
      enabled explicitly — it's not on by default like it is for
      public repos)
- [ ] Secret scanning push protection: **on**, at least for new repos

Some of these (secret scanning in particular) have historically had
their own plan/add-on requirements for private repos, separate from
the branch-protection limitation above — check what's actually offered
for this org's plan on the settings page itself before assuming it's
available.

## 3. Create the placeholder GitHub teams

`CODEOWNERS.example` and `.github/CODEOWNERS` in this repo reference
teams that don't exist yet:

- `@sas-technology/maintainers`
- `@sas-technology/security`

Create them at **github.com/orgs/sas-technology/teams** and add the
right people, or rename the references in those two files to teams
you already have.

## 4. Roll reusable workflows + Dependabot out per repo

These are opt-in per repo (that's intentional — see "Per-repo
configuration" in `README.md`):

- Lint (`org-lint.yml`) already runs on every repo automatically once
  §1's ruleset is active — no action needed, and it's a required,
  merge-blocking check on every repo (public and private) under Team.
- For CodeQL / dependency review / PR-title lint / stale-bot on a
  given repo, add a thin caller workflow referencing the matching
  `reusable-*.yml` (see examples in each file's header comment).
- Copy `.github/dependabot.example.yml` → `.github/dependabot.yml` in
  each repo and delete the ecosystem blocks that don't apply.
- Copy `CODEOWNERS.example` → `.github/CODEOWNERS` in each repo once
  §3's teams exist.

## Review cadence

Revisit this doc and the rulesets at least once a year, or whenever a
new repo type (e.g. a new language/stack) shows up in the org, or the
org's GitHub plan changes.
