# Org settings — apply guide

Everything in this repo that's just a *file* (community health files,
templates, reusable workflows) takes effect automatically, per the
table in [`README.md`](./README.md). Everything below needs a human
with **organization owner** access to click through GitHub's UI (or
use a `gh`/API script with `admin:org` scope) — there is no file that
applies these for you.

## ⚠️ Plan limitation: GitHub Free

This org is currently on **GitHub Free for organizations**. On that
plan, **branch protection and rulesets only work on public
repositories** — GitHub does not enforce them on private repos at all,
regardless of how they're configured. Of this org's repos, only
`sas-default-app`, `sas-knowledge`, and `knowledge` are public; the
rest are private.

Practically, that means importing `org-wide-main-protection.json`
today will:

- **Work** on the 3 public repos (actual merge-blocking enforcement).
- **Do nothing** on the ~18 private repos — the ruleset can still be
  created/imported, but GitHub won't apply it to a private repo under
  Free, so PRs there stay fully unrestricted.

The lint check (`org-lint.yml`) and CODEOWNERS auto-review-requests
still work on private repos either way — those aren't plan-gated, they
just can't be made *required to merge* without protection/rulesets.

**To get real enforcement on private repos, upgrade the org to GitHub
Team** (or Pro, repo-by-repo). Re-check the current plan comparison at
github.com/pricing before deciding, since plan features do change.
Until then, treat the ruleset import below as "protects the public
repos now, ready to go the moment the org upgrades."

## 1. Import the branch/tag rulesets

For each JSON file in [`github-rulesets/`](./github-rulesets/):

1. Go to **github.com/organizations/sas-technology/settings/rules** →
   **New ruleset** → **Import a ruleset**.
2. Upload the JSON file.
3. Review it, then set **Enforcement status** to **Active**.

| File | What it does |
| --- | --- |
| `org-wide-main-protection.json` | On every repo's default branch: no deletion, no force-push, 1 required PR approval, PR review threads must be resolved, squash/rebase merges only, and the five `lint / *` checks + the org-required `org-lint.yml` workflow must pass before merge. Org admins can bypass. **Only takes effect on public repos under the org's current GitHub Free plan — see the callout above.** |
| `release-tag-protection.json` | Tags matching `vX.Y.Z` can't be deleted, force-pushed, or moved once created — for any repo that does semver releases. Same Free-plan caveat applies. |

**Before you import `org-wide-main-protection.json`**, note it
hardcodes this repo's numeric ID (`1211111495`, i.e.
`sas-technology/.github`) in the `workflows` rule so the required
`org-lint.yml` workflow resolves correctly. That ID only needs to
change if this repo is ever deleted and recreated.

**Adjust before importing, if needed:**

- `required_approving_review_count: 1` — raise it if you want more
  than one reviewer org-wide. Consider dropping this to `0` for any
  single-maintainer repo once rulesets do apply to it (Team/Pro), so
  it doesn't lock that repo's own owner out of merging.
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
  §1's ruleset is active — no action needed. On private repos (Free
  plan), it still runs and reports pass/fail on PRs even though it
  isn't a required/blocking check — see the plan callout above.
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
