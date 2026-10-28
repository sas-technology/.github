#!/usr/bin/env bash
# Creates or updates the org rulesets in github-rulesets/ via the GitHub API.
# Re-runnable: rulesets are matched by name, so it updates instead of duplicating.
#
# Usage:
#   scripts/apply-org-rulesets.sh              # import with enforcement "disabled" (review in the UI first)
#   scripts/apply-org-rulesets.sh --active     # import with enforcement "active"
#   scripts/apply-org-rulesets.sh --dry-run    # print what would be sent, change nothing
#
# Requires: gh (logged in as an org owner), jq.
# "evaluate" enforcement is Enterprise-only, so it is not offered here.
set -euo pipefail

ORG="sas-technology"
ENFORCEMENT="disabled"
DRY_RUN=0

for arg in "$@"; do
  case "$arg" in
    --active) ENFORCEMENT="active" ;;
    --dry-run) DRY_RUN=1 ;;
    -h | --help)
      sed -n '2,10p' "$0"
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

if ! existing=$(gh api "/orgs/$ORG/rulesets" 2>&1); then
  echo "Cannot list org rulesets. Granting the admin:org scope and retrying..." >&2
  gh auth refresh -h github.com -s admin:org
  existing=$(gh api "/orgs/$ORG/rulesets")
fi

for file in github-rulesets/*.json; do
  # Org rulesets must target repositories; add all repos if the file has no condition.
  payload=$(jq --arg e "$ENFORCEMENT" '
    .enforcement = $e
    | .conditions.repository_name //= {"include": ["~ALL"], "exclude": []}
  ' "$file")
  name=$(jq -r '.name' <<<"$payload")
  id=$(jq -r --arg n "$name" '.[] | select(.name == $n) | .id' <<<"$existing" | head -n1)

  if [ "$DRY_RUN" -eq 1 ]; then
    echo "[dry-run] ${id:+update #$id}${id:-create} '$name' (enforcement: $ENFORCEMENT)"
    continue
  fi

  if [ -n "$id" ]; then
    gh api -X PUT "/orgs/$ORG/rulesets/$id" --input - <<<"$payload" >/dev/null
    echo "Updated '$name' (#$id), enforcement: $ENFORCEMENT"
  else
    new_id=$(gh api -X POST "/orgs/$ORG/rulesets" --input - --jq '.id' <<<"$payload")
    echo "Created '$name' (#$new_id), enforcement: $ENFORCEMENT"
  fi
done

echo
gh api "/orgs/$ORG/rulesets" --jq '.[] | "\(.id)\t\(.name)\t\(.enforcement)"'
