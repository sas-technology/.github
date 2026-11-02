#!/usr/bin/env bash
# Bring sas-technology repos up to the org defaults. Idempotent: safe to re-run.
#
# GitHub has no org-level default for repo settings, branches or standard
# files, so a new repo starts bare. For every repo this makes sure of:
#
#   1. A default branch exists (an empty repo gets an initial README commit)
#   2. A `staging` branch exists (the release flow is staging -> main)
#   3. Merge settings match the org standard (same payload as apply-org-settings.sh)
#   4. Immutable releases are on
#   5. The standard files exist: AGENTS.md, CONTRIBUTING.md, SECURITY.md,
#      CODE_OF_CONDUCT.md, PR template, CODEOWNERS, README. Missing ones are
#      proposed in ONE pull request into `staging` from `bootstrap/org-standards`;
#      nothing is pushed straight to a protected branch.
#   6. The CODEOWNERS team can review the repo (warns; --grant-team adds it)
#
# Usage:
#   scripts/bootstrap-repos.sh --dry-run             # report only, change nothing
#   scripts/bootstrap-repos.sh --repo my-new-repo    # one repo (repeatable)
#   scripts/bootstrap-repos.sh                       # every repo in the org
#   Options: --skip-files  --grant-team
#
# Requires: gh, jq. The token needs repository administration, contents and
# pull requests write (the scheduled workflow mints one from a GitHub App).
set -uo pipefail

ORG="${ORG:-sas-technology}"
TEAM="${CODEOWNERS_TEAM:-edtech}"
BRANCH="bootstrap/org-standards"
DRY=0
DO_FILES=1
GRANT_TEAM=0
ONLY=""
FAILURES=""
CHANGED=0

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --skip-files) DO_FILES=0 ;;
    --grant-team) GRANT_TEAM=1 ;;
    --repo)
      shift
      ONLY="$ONLY $1 "
      ;;
    -h | --help)
      sed -n '2,25p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 2
      ;;
  esac
  shift
done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
command -v gh >/dev/null || { echo "gh is not installed" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq is not installed" >&2; exit 1; }

# Keep in step with step_repos in apply-org-settings.sh.
# delete_branch_on_merge is on. The org ruleset's `deletion` rule protects main and
# staging, so the auto-delete never removes them after a release PR.
DESIRED='{"allow_merge_commit":true,"allow_squash_merge":true,"allow_rebase_merge":true,"delete_branch_on_merge":true,"allow_auto_merge":true,"allow_update_branch":true,"squash_merge_commit_title":"PR_TITLE","squash_merge_commit_message":"PR_BODY"}'

# target | source in this repo (or generated:NAME) | paths that also count as present
FILES='AGENTS.md|AGENTS.md|AGENTS.md
CONTRIBUTING.md|CONTRIBUTING.md|CONTRIBUTING.md .github/CONTRIBUTING.md docs/CONTRIBUTING.md
SECURITY.md|SECURITY.md|SECURITY.md .github/SECURITY.md docs/SECURITY.md
CODE_OF_CONDUCT.md|CODE_OF_CONDUCT.md|CODE_OF_CONDUCT.md .github/CODE_OF_CONDUCT.md docs/CODE_OF_CONDUCT.md
.github/PULL_REQUEST_TEMPLATE.md|.github/PULL_REQUEST_TEMPLATE.md|.github/PULL_REQUEST_TEMPLATE.md .github/pull_request_template.md PULL_REQUEST_TEMPLATE.md docs/PULL_REQUEST_TEMPLATE.md
.github/CODEOWNERS|generated:codeowners|.github/CODEOWNERS CODEOWNERS docs/CODEOWNERS
README.md|generated:readme|README.md'

fail() {
  FAILURES="$FAILURES
  - $1"
  echo "  ! $1" >&2
}

# Announce a change; in dry-run mode it is only a preview.
act() {
  CHANGED=$((CHANGED + 1))
  if [ "$DRY" -eq 1 ]; then echo "  [dry-run] would $1"; else echo "  $1"; fi
}

# Write call: skipped entirely in dry-run mode.
api() {
  [ "$DRY" -eq 1 ] && return 0
  gh api "$@"
}

has_file() { gh api "/repos/$ORG/$1/contents/$3?ref=$2" --silent 2>/dev/null; }

present_any() {
  local repo=$1 ref=$2 p
  shift 2
  for p in "$@"; do
    has_file "$repo" "$ref" "$p" && return 0
  done
  return 1
}

render() { # repo, source -> file body on stdout
  case "$2" in
    generated:codeowners) printf '# Default reviewers. The team needs write access to this repo.\n* @%s/%s\n' "$ORG" "$TEAM" ;;
    generated:readme) printf '# %s\n\nTODO: what this repo is, who owns it, how to run it.\n' "$1" ;;
    *) cat "$ROOT/$2" ;;
  esac
}

put_file() { # repo, branch, target, source
  local body
  body=$(render "$1" "$4" | base64 | tr -d '\n')
  gh api -X PUT "/repos/$ORG/$1/contents/$3" -f message="chore: add $3 (org standard)" \
    -f content="$body" -f branch="$2" >/dev/null
}

bootstrap_repo() {
  local repo=$1 info db nb sha changes cur ready=1
  echo "== $repo"
  info=$(gh api "/repos/$ORG/$repo") || { fail "$repo: cannot read the repo"; return; }
  db=$(jq -r .default_branch <<<"$info")

  # 1. Default branch
  nb=$(gh api "/repos/$ORG/$repo/branches?per_page=1" --jq length 2>/dev/null || echo 0)
  if [ "$nb" -eq 0 ]; then
    act "create '$db' with an initial README commit"
    if [ "$DRY" -eq 1 ]; then
      ready=0
    else
      render "$repo" generated:readme | base64 | tr -d '\n' |
        gh api -X PUT "/repos/$ORG/$repo/contents/README.md" -f message="chore: initial commit" \
          -f content="$(cat)" -f branch="$db" >/dev/null ||
        { fail "$repo: could not create '$db' (a ruleset may need to let the bootstrap app bypass)"; return; }
    fi
  fi

  # 2. staging
  if [ "$ready" -eq 1 ] && ! gh api "/repos/$ORG/$repo/branches/staging" --silent 2>/dev/null; then
    act "create 'staging' from '$db'"
    sha=$(gh api "/repos/$ORG/$repo/git/ref/heads/$db" --jq .object.sha)
    api -X POST "/repos/$ORG/$repo/git/refs" -f ref=refs/heads/staging -f sha="$sha" >/dev/null ||
      fail "$repo: could not create staging"
  fi

  # 3. Merge settings
  changes=$(jq -rn --argjson cur "$info" --argjson want "$DESIRED" \
    '$want | to_entries | map(select($cur[.key] != .value) | "\(.key) \($cur[.key]) -> \(.value)") | join(", ")')
  if [ -n "$changes" ]; then
    act "update settings: $changes"
    api -X PATCH "/repos/$ORG/$repo" --input - <<<"$DESIRED" >/dev/null || fail "$repo: could not update settings"
  fi

  # 4. Immutable releases
  cur=$(gh api "/repos/$ORG/$repo/immutable-releases" --jq .enabled 2>/dev/null || echo unknown)
  case "$cur" in
    true) ;;
    false)
      act "turn on immutable releases"
      api -X PUT "/repos/$ORG/$repo/immutable-releases" >/dev/null || fail "$repo: could not enable immutable releases"
      ;;
    *) fail "$repo: could not read immutable-releases" ;;
  esac

  # 5. Standard files, proposed in one PR into staging
  if [ "$DO_FILES" -eq 1 ] && [ "$repo" != ".github" ]; then
    adopt_files "$repo" "$db" "$ready"
  fi

  # 6. CODEOWNERS team access
  if ! gh api "/orgs/$ORG/teams/$TEAM/repos/$ORG/$repo" --silent 2>/dev/null; then
    if [ "$GRANT_TEAM" -eq 1 ]; then
      act "give team '$TEAM' write access"
      api -X PUT "/orgs/$ORG/teams/$TEAM/repos/$ORG/$repo" -f permission=push >/dev/null || fail "$repo: could not grant team access"
    else
      echo "  ? team '$TEAM' has no access, so CODEOWNERS is ignored (re-run with --grant-team)"
    fi
  fi
}

adopt_files() {
  local repo=$1 db=$2 ready=$3 line target source alts missing="" open sha n pending=""
  # Files an earlier manual adoption PR already adds count as covered, so the two never collide.
  for n in $(gh api "/repos/$ORG/$repo/pulls?state=open&per_page=100" --jq '.[] | select(.head.ref == "adopt-org-standards") | .number' 2>/dev/null); do
    pending="$pending $(gh api "/repos/$ORG/$repo/pulls/$n/files?per_page=100" --jq '.[].filename' 2>/dev/null | tr '\n' ' ')"
  done
  while IFS='|' read -r target source alts; do
    case " $pending " in *" $target "*) continue ;; esac
    # shellcheck disable=SC2086
    if [ "$ready" -eq 0 ] || ! present_any "$repo" "$db" $alts; then
      missing="$missing $target"
    fi
  done <<<"$FILES"
  [ -z "$missing" ] && return

  open=$(gh api "/repos/$ORG/$repo/pulls?state=open&per_page=100" \
    --jq "[.[] | select(.head.ref == \"$BRANCH\")] | length" 2>/dev/null || echo 0)
  if [ "$open" -gt 0 ]; then
    echo "  = adoption PR already open (missing:$missing)"
    return
  fi

  act "open a PR into staging adding:$missing"
  [ "$DRY" -eq 1 ] && return

  if ! gh api "/repos/$ORG/$repo/branches/$BRANCH" --silent 2>/dev/null; then
    sha=$(gh api "/repos/$ORG/$repo/git/ref/heads/staging" --jq .object.sha) || { fail "$repo: no staging branch to base the PR on"; return; }
    gh api -X POST "/repos/$ORG/$repo/git/refs" -f ref="refs/heads/$BRANCH" -f sha="$sha" >/dev/null || { fail "$repo: could not create $BRANCH"; return; }
  fi
  while IFS='|' read -r target source alts; do
    case " $missing " in *" $target "*) ;; *) continue ;; esac
    has_file "$repo" "$BRANCH" "$target" && continue
    put_file "$repo" "$BRANCH" "$target" "$source" || fail "$repo: could not add $target"
  done <<<"$FILES"
  gh api -X POST "/repos/$ORG/$repo/pulls" -f title="chore: adopt org standards" -f head="$BRANCH" -f base=staging \
    -f body="Adds the org-standard files this repo is missing:$(printf '\n- %s' $missing)

Opened by scripts/bootstrap-repos.sh in sas-technology/.github. Edit or delete anything that doesn't fit this repo; the bootstrap only re-proposes files that are absent." \
    >/dev/null || fail "$repo: could not open the PR"
}

repos=$(gh api --paginate "/orgs/$ORG/repos" --jq '.[] | select(.archived|not) | .name') || { echo "Could not list repos" >&2; exit 1; }
for repo in $repos; do
  case "$repo" in sandbox-* | archive-*) continue ;; esac
  [ -n "$ONLY" ] && case "$ONLY" in *" $repo "*) ;; *) continue ;; esac
  bootstrap_repo "$repo"
done

echo
echo "$CHANGED change(s)$([ "$DRY" -eq 1 ] && echo ' previewed (dry run)')."
if [ -n "$FAILURES" ]; then
  echo "Needs attention:$FAILURES"
  exit 1
fi
