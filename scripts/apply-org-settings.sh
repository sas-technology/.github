#!/usr/bin/env bash
# One-shot org setup for sas-technology. Idempotent: safe to re-run.
#
#   1. Org rulesets   (runs scripts/apply-org-rulesets.sh)
#   2. Security       (Dependabot alerts/updates, secret scanning + push protection,
#                      applied to all repos and set as the default for new repos)
#   3. Repo defaults  (squash/rebase only, auto-delete branches, auto-merge, update-branch)
#   4. Verify         (per repo: staging branch + the rules that apply to main and staging)
#
# Usage:
#   scripts/apply-org-settings.sh --dry-run          # preview, change nothing
#   scripts/apply-org-settings.sh                    # rulesets imported DISABLED; review in the UI
#   scripts/apply-org-settings.sh --active           # rulesets ENFORCED
#   scripts/apply-org-settings.sh --verify-only      # just print the verification table
#   Skip steps with: --skip-rulesets --skip-security --skip-repos
#
# Requires: gh (logged in as an org owner), jq. A failed item is reported and the
# script continues; the summary at the end lists everything that needs attention.
set -uo pipefail

ORG="sas-technology"
DRY=0
ACTIVE=0
VERIFY_ONLY=0
DO_RULESETS=1
DO_SECURITY=1
DO_REPOS=1
FAILURES=()

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY=1 ;;
    --active) ACTIVE=1 ;;
    --verify-only) VERIFY_ONLY=1 ;;
    --skip-rulesets) DO_RULESETS=0 ;;
    --skip-security) DO_SECURITY=0 ;;
    --skip-repos) DO_REPOS=0 ;;
    -h | --help)
      sed -n '2,19p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown option: $arg" >&2
      exit 2
      ;;
  esac
done

cd "$(dirname "$0")/.."
command -v gh >/dev/null || { echo "gh is not installed" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq is not installed" >&2; exit 1; }

fail() { FAILURES+=("$1"); echo "  ! $1" >&2; }

ensure_scope() {
  if ! gh api "/orgs/$ORG/rulesets" >/dev/null 2>&1; then
    echo "Granting the admin:org scope (a browser prompt will open)..."
    gh auth refresh -h github.com -s admin:org || { echo "Could not get admin:org" >&2; exit 1; }
  fi
}

step_rulesets() {
  echo "== 1. Org rulesets"
  local flags=()
  [ "$ACTIVE" -eq 1 ] && flags+=(--active)
  [ "$DRY" -eq 1 ] && flags+=(--dry-run)
  scripts/apply-org-rulesets.sh "${flags[@]}" || fail "rulesets: apply-org-rulesets.sh failed (merge the workflow PRs first; the ruleset names workflow files on main)"
}

step_security() {
  echo "== 2. Org security configuration"
  local name="sas-technology-default"
  local full='{"name":"'$name'","description":"Org default: Dependabot + secret scanning","dependabot_alerts":"enabled","dependabot_security_updates":"enabled","secret_scanning":"enabled","secret_scanning_push_protection":"enabled","enforcement":"enforced"}'
  local lite='{"name":"'$name'","description":"Org default: Dependabot","dependabot_alerts":"enabled","dependabot_security_updates":"enabled","enforcement":"enforced"}'
  local id
  id=$(gh api "/orgs/$ORG/code-security/configurations" --jq ".[] | select(.name==\"$name\") | .id" 2>/dev/null | head -n1)

  if [ "$DRY" -eq 1 ]; then
    echo "  [dry-run] would ${id:+update}${id:-create} configuration '$name', attach to all repos, set as default for new repos"
    return
  fi

  if [ -n "$id" ]; then
    gh api -X PATCH "/orgs/$ORG/code-security/configurations/$id" --input - <<<"$full" >/dev/null 2>&1 ||
      gh api -X PATCH "/orgs/$ORG/code-security/configurations/$id" --input - <<<"$lite" >/dev/null 2>&1 ||
      { fail "security: could not update configuration #$id"; return; }
  else
    if id=$(gh api -X POST "/orgs/$ORG/code-security/configurations" --input - --jq '.id' <<<"$full" 2>/dev/null); then
      echo "  created with secret scanning + push protection"
    elif id=$(gh api -X POST "/orgs/$ORG/code-security/configurations" --input - --jq '.id' <<<"$lite" 2>/dev/null); then
      fail "security: secret scanning not available for this plan/licence; created with Dependabot only"
    else
      fail "security: could not create configuration"
      return
    fi
  fi
  gh api -X POST "/orgs/$ORG/code-security/configurations/$id/attach" -f scope=all >/dev/null 2>&1 || fail "security: could not attach configuration to all repos"
  gh api -X PUT "/orgs/$ORG/code-security/configurations/$id/defaults" -f default_for_new_repos=all >/dev/null 2>&1 || fail "security: could not set as default for new repos"
  echo "  configuration #$id attached to all repos and set as default for new repos"
}

step_repos() {
  echo "== 3. Repo merge settings"
  local payload='{"allow_merge_commit":false,"allow_squash_merge":true,"allow_rebase_merge":true,"delete_branch_on_merge":true,"allow_auto_merge":true,"allow_update_branch":true,"squash_merge_commit_title":"PR_TITLE","squash_merge_commit_message":"PR_BODY"}'
  local repo
  for repo in $(gh api --paginate "/orgs/$ORG/repos" --jq '.[] | select(.archived|not) | .name'); do
    if [ "$DRY" -eq 1 ]; then
      echo "  [dry-run] $repo"
    elif gh api -X PATCH "/repos/$ORG/$repo" --input - <<<"$payload" >/dev/null 2>&1; then
      echo "  ok  $repo"
    else
      fail "repo settings: $repo"
    fi
  done
}

step_verify() {
  echo "== 4. Verification"
  printf "%-36s %-8s %-6s %-6s %-6s %-6s %s\n" REPO STAGING LINEAR QUEUE LINT STD VERSION
  local repo db stg rules
  for repo in $(gh api --paginate "/orgs/$ORG/repos" --jq '.[] | select(.archived|not) | .name'); do
    db=$(gh api "/repos/$ORG/$repo" --jq .default_branch 2>/dev/null)
    stg=$(gh api "/repos/$ORG/$repo/branches/staging" >/dev/null 2>&1 && echo yes || echo NO)
    rules=$(gh api "/repos/$ORG/$repo/rules/branches/${db:-main}" 2>/dev/null || echo '[]')
    has() { jq -r --arg t "$1" 'any(.[]; .type==$t)' <<<"$rules" | sed 's/true/yes/;s/false/NO/'; }
    wf() { jq -r --arg p "$1" 'any(.[]; .type=="workflows" and any(.parameters.workflows[]?; .path|endswith($p)))' <<<"$rules" | sed 's/true/yes/;s/false/NO/'; }
    printf "%-36s %-8s %-6s %-6s %-6s %-6s %s\n" "$repo" "$stg" "$(has required_linear_history)" "$(has merge_queue)" \
      "$(wf org-lint.yml)" "$(wf repo-standards.yml)" "$(wf release-version-check.yml)"
  done
}

ensure_scope

if [ "$VERIFY_ONLY" -eq 0 ]; then
  [ "$DO_RULESETS" -eq 1 ] && step_rulesets
  [ "$DO_SECURITY" -eq 1 ] && step_security
  [ "$DO_REPOS" -eq 1 ] && step_repos
fi
step_verify

echo
if [ "${#FAILURES[@]}" -gt 0 ]; then
  echo "Needs attention:"
  printf '  - %s\n' "${FAILURES[@]}"
  exit 1
fi
echo "Done."
