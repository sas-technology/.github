# sas-technology/.github

Organization-wide defaults for every repo under
[SAS Technology](https://github.com/sas-technology) — the GitHub
organization for Singapore American School's technology department.

Anything here is inherited by every repository in the org that
doesn't define its own equivalent file.

## What's in this repo

| Path | Purpose |
| --- | --- |
| `CODE_OF_CONDUCT.md` | Expected conduct across every repo. |
| `SECURITY.md` | How to privately report a vulnerability or data-handling concern. |
| `SUPPORT.md` | Where to go for help. |
| `CONTRIBUTING.md` | Branching, commits, PR, and review conventions. |
| `AGENTS.md` | Rules for AI coding agents (Claude, Copilot, etc.) working in a repo. |
| `.github/copilot-instructions.md` | Copilot-specific pointer to `AGENTS.md`. |
| `CODEOWNERS.example` | Starter template to copy to `.github/CODEOWNERS` in your repo. |
| `.github/CODEOWNERS` | Code-review ownership for *this* repo. |
| `.github/PULL_REQUEST_TEMPLATE.md` | Default PR template. |
| `.github/ISSUE_TEMPLATE/*` | Default bug report / feature request forms. |
| `.github/dependabot.yml` | Dependabot config for *this* repo. |
| `.github/dependabot.example.yml` | Starter template other repos copy. |
| `.editorconfig`, `.gitignore`, `.prettierrc`, `.prettierignore`, `.markdownlint.jsonc`, `.markdownlint-cli2.jsonc`, `.yamllint.yaml` | Shared lint/format baseline; also the fallback config used by `reusable-lint.yml` for repos without their own. |
| `.github/workflows/reusable-lint.yml` | The org lint gate: actionlint, JSON validity, prettier, markdownlint, yamllint. |
| `.github/workflows/org-lint.yml` | Thin caller of the above — this is the workflow GitHub is told to require on every repo (see `github-rulesets/`). |
| `.github/workflows/reusable-pr-title-lint.yml` | Opt-in Conventional Commits PR title check. |
| `.github/workflows/reusable-dependency-review.yml` | Opt-in dependency vulnerability check on PRs. |
| `.github/workflows/reusable-codeql.yml` | Opt-in CodeQL static analysis (JS/TS, Python, Swift, etc.). |
| `.github/workflows/reusable-stale.yml` | Opt-in stale issue/PR bot. |
| `workflow-templates/lint.yml` + `.properties.json` | The same lint check, offered in every repo's "New workflow" picker. |
| `github-rulesets/*.json` | Branch/tag protection rules, importable via GitHub's ruleset UI. |
| `ORG_SETTINGS.md` | Step-by-step guide for an org owner to apply the rulesets and related settings. |
| `profile/README.md` | The landing page shown at <https://github.com/sas-technology>. |

## How GitHub uses this repo

### Auto-propagated by GitHub (no action needed by consuming repos)

- **Community health files** (`CODE_OF_CONDUCT.md`, `CONTRIBUTING.md`,
  `SECURITY.md`, `SUPPORT.md`) at the root of this repo apply as
  defaults to any repo in the org that doesn't have its own copy —
  see [GitHub's docs on default community health files][chf].
- **Issue and PR templates** under `.github/` apply the same way to
  any repo that doesn't define its own.

### Referenced at runtime (consuming repo opts in via `uses:`)

- **Reusable workflows** under `.github/workflows/reusable-*.yml` are
  called by other repos via
  `uses: sas-technology/.github/.github/workflows/<name>.yml@main`.
  Fixes here propagate to every caller on its next CI run.
- **Lint is the exception** — it's already required org-wide once the
  ruleset in `github-rulesets/` is imported (see `ORG_SETTINGS.md`),
  so a repo does not need to add its own `lint.yml` caller.

### Read by AI agents in this repo only

- **`AGENTS.md`** and **`.github/copilot-instructions.md`** apply to
  agent sessions in *this* repo. They don't auto-propagate — copy them
  into a repo that wants the same rules for its own agent sessions.

### Per-repo configuration (starter templates here, each repo copies)

- **`.github/dependabot.example.yml`** and **`CODEOWNERS.example`**
  are templates. Each repo copies the one it needs to
  `.github/dependabot.yml` / `.github/CODEOWNERS` and adjusts for its
  own stack and teams.

### Operational (applied manually in GitHub's UI)

- **`github-rulesets/*.json`** and the rest of **`ORG_SETTINGS.md`**
  describe settings that live in GitHub's web UI (org security
  defaults, branch/tag rulesets). They're not enforced by any file
  here — an org owner applies them once, per `ORG_SETTINGS.md`.

## Overriding the defaults

Any repo can override a default just by adding its own file at the
same path — GitHub prefers the repo-level file.

## What this repo intentionally does *not* include

This started from a much larger reference `.github` repo built for a
public open-source organization shipping packages across a dozen
languages (Rust, Solidity, Terraform/OpenTofu, container images,
SLSA/SBOM supply-chain attestation, a written governance constitution,
a CLA, automated releases, etc.). Almost none of that fits an internal
school IT department running mostly-private apps, so it was left out
rather than copied in. See the PR that introduced this repo's content
for the full list of what was dropped and why — the short version is:
no CLA/legal-contribution paperwork, no corporate-governance
documents, no release/supply-chain automation, and only one
language-agnostic CI check (lint) instead of a reusable workflow per
language. Per-stack CI (Node/TS, Python, Swift) can be added the same
way once specific repos want it.

[chf]: https://docs.github.com/en/communities/setting-up-your-project-for-healthy-contributions/creating-a-default-community-health-file
