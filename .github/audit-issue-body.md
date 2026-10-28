## Quarterly ORG_SETTINGS.md Audit — {{QID}}

Per [ORG_SETTINGS.md](../ORG_SETTINGS.md), the intended GitHub org and repo
configuration must be compared against live settings **once per quarter**.

### Checklist

- [ ] **Rulesets** — compare the JSON in `github-rulesets/` against live
      **Org settings → Rules → Rulesets**. Confirm the org ruleset still requires
      `org-lint.yml` and `release-version-check.yml` from this repo. Check no
      repo has classic branch protection on its default branch, and that repo
      rulesets do not override the org ruleset. Note any approved drift.
- [ ] **Merge queue** — confirm the squash merge queue is active on every
      repo and that no required check is missing the `merge_group` trigger
      (see the `repo-standards` warnings).
- [ ] **Org security features** — compare `ORG_SETTINGS.md` against
      **Settings → Code security**: Dependabot alerts and security updates,
      secret scanning, and push protection enabled org-wide.
- [ ] **Actions allowlist** — verify every `uses:` in
      `.github/workflows/reusable-*.yml` appears in the allowlist at
      **Settings → Actions → General → Allowed actions**.
- [ ] **SHA-pinned actions** — confirm every SHA comment version matches
      the pinned commit, and look for tag refs that slipped past review.
- [ ] **Org secrets** — confirm the org secrets are current and still
      needed, and that no long-lived cloud credentials have been added.
- [ ] **Reviewer count** — has a second engineer with merge rights joined?
      If yes, consider raising `required_approving_review_count` in
      `github-rulesets/` and re-apply with `scripts/apply-org-rulesets.sh`.
- [ ] **Supply-chain posture** — confirm releases generate SBOMs and
      provenance attestations via `reusable-sbom.yml`,
      `reusable-slsa-provenance.yml` or `reusable-release.yml`, and that
      Semgrep, CodeQL and Scorecard results have been reviewed.
- [ ] **Staging** — confirm repos that use `staging` still have it protected
      and that `staging-version.yml` is tagging merges.

### After the audit

- Approved changes to `ORG_SETTINGS.md` → PR reviewed by `@sas-technology/maintainers`.
- Unapproved drift → fix live GitHub settings immediately.
- Close this issue with a comment summarising what was checked and any drift
  found or corrected.

_Opened automatically by `.github/workflows/scheduled-settings-audit.yml`._
