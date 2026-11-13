#!/usr/bin/env bash
# Automatic releases: keep the staging -> default-branch release flowing on
# every repo without a human in the loop. Idempotent: safe to re-run.
#
# For every repo in the org (not archived, not sandbox-*/archive-*, not
# opted out with the AUTO_RELEASE=off repository variable):
#
#   1. When `staging` is ahead of the default branch, the release PR
#      (head `staging`, base the default branch, titled "Release: ...")
#      exists and auto-merge (squash) is on. The app never merges: the
#      required checks green-light it, GitHub merges, queue included.
#   2. When the default branch tip is an untagged "Release: ..." squash
#      merge, it is tagged with the next MINOR and published as the
#      latest GitHub release - as the app, so `on: push: tags` publish
#      workflows fire on production releases.
#
# Staging PATCH tags stay with each repo's own GITHUB_TOKEN workflow
# (reusable-staging-release.yml): those tags are inert on purpose, so a
# beta build never ships from a publish pipeline.
#
# Why the app and not GITHUB_TOKEN: a pull request opened with a repo's
# own GITHUB_TOKEN does not trigger the required workflows (GitHub
# suppresses events caused by that token), so auto-merge would never
# fire. The bootstrap app is installed on every repo and its key never
# leaves the `org-bootstrap` environment.
#
# Usage:
#   scripts/auto-release-prs.sh --dry-run          # report only, change nothing
#   scripts/auto-release-prs.sh --repo my-new-repo # one repo (repeatable)
#   scripts/auto-release-prs.sh                    # every repo in the org
#
# Requires: gh, git, jq, GH_TOKEN (or a logged-in gh). The token needs
# contents and pull requests write (the scheduled workflow mints one
# from the sas-technology bootstrap app).
set -uo pipefail

ORG="${ORG:-sas-technology}"
DRY=0
ONLY=""
FAILURES=""
ACTED=0

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --repo)
      shift
      ONLY="$ONLY $1 "
      ;;
    -h | --help)
      sed -n '2,33p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 2
      ;;
  esac
  shift
done

command -v gh >/dev/null || { echo "gh is not installed" >&2; exit 1; }
command -v git >/dev/null || { echo "git is not installed" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq is not installed" >&2; exit 1; }
GH_TOKEN="${GH_TOKEN:-$(gh auth token)}"
export GH_TOKEN

fail() {
  FAILURES="$FAILURES
  - $1"
  echo "  ! $1" >&2
}

# Announce a change; in dry-run mode it is only a preview.
act() {
  ACTED=$((ACTED + 1))
  if [ "$DRY" -eq 1 ]; then echo "  [dry-run] would $1"; else echo "  $1"; fi
}

# A write command; skipped entirely in dry-run mode (act() reported it).
wr() {
  [ "$DRY" -eq 1 ] && return 0
  "$@"
}

remote() { printf 'https://x-access-token:%s@github.com/%s/%s.git' "$GH_TOKEN" "$ORG" "$1"; }

# The vX.Y.Z tags whose commit is $2 (annotated via the ^{} deref, or the
# plain ref when the tag is lightweight), newest last.
tags_at() { # repo, sha
  git ls-remote --tags "$(remote "$1")" 'refs/tags/v[0-9]*.[0-9]*.[0-9]*' 2>/dev/null |
    awk -v h="$2" '$1 == h {
      t = $2; sub(/^refs\/tags\//, "", t); sub(/\^\{\}$/, "", t); print t
    }' | sort -u
}

# The next MINOR after the repo's highest vX.Y.Z tag (v0.1.0 for a repo
# with none). Empty and non-zero when it cannot be computed or would
# roll past 999 - the caller skips those, like release-version-check.
next_minor() { # repo
  local highest major minor
  highest=$(git ls-remote --tags "$(remote "$1")" 'refs/tags/v[0-9]*.[0-9]*.[0-9]*' 2>/dev/null |
    sed -e 's#.*refs/tags/v##' -e 's/\^{}$//' |
    grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -uV | tail -n1)
  [ -n "$highest" ] || { echo "v0.1.0"; return 0; }
  major=${highest%%.*}
  minor=${highest#*.}
  minor=${minor%%.*}
  [ "$minor" -lt 999 ] || return 1
  echo "v${major}.$((minor + 1)).0"
}

release_pr() { # repo, default branch
  local repo=$1 db=$2 n
  n=$(gh pr list -R "$ORG/$repo" --head staging --base "$db" --state open \
    --json number --jq '.[0].number // empty' 2>/dev/null)
  if [ -n "$n" ]; then
    act "keep release PR #$n auto-merging ($staging -> $db)"
    wr gh pr merge -R "$ORG/$repo" "$n" --auto --squash >/dev/null 2>&1 ||
      fail "$repo: could not enable auto-merge on #$n"
    return
  fi
  act "open the release PR ($staging -> $db) with auto-merge"
  wr gh pr create -R "$ORG/$repo" --base "$db" --head staging \
    --title "Release: $repo $staging into $db" \
    --body "Automatic release PR. Auto-merge (squash) is on: it merges itself once the required checks pass, then \`auto-release.yml\` tags the release. A MAJOR needs the \`semver:major\` label before it merges." \
    >/dev/null 2>&1 || { fail "$repo: could not open the release PR"; return; }
  n=$(gh pr list -R "$ORG/$repo" --head staging --base "$db" --state open \
    --json number --jq '.[0].number // empty' 2>/dev/null)
  wr gh pr merge -R "$ORG/$repo" "$n" --auto --squash >/dev/null 2>&1 ||
    fail "$repo: could not enable auto-merge on #$n"
}

tag_release() { # repo, default branch
  local repo=$1 db=$2 sha title tag
  sha=$(gh api "/repos/$ORG/$repo/commits/$db" --jq '.sha' 2>/dev/null) || return 0
  title=$(gh api "/repos/$ORG/$repo/commits/$db" --jq '.commit.message | split("\n")[0]' 2>/dev/null) || return 0
  case "$title" in
    [Rr]elease:*) ;;
    *) return 0 ;; # not a release squash-merge; release-version-check's territory
  esac
  if [ -n "$(tags_at "$repo" "$sha")" ]; then
    echo "  - $repo: $db tip is already released"
    return 0
  fi
  tag=$(next_minor "$repo") || { fail "$repo: no computable next version"; return 0; }
  [ -n "$tag" ] || { fail "$repo: no computable next version"; return 0; }
  act "release $tag at $db (tag + latest GitHub release)"
  wr gh release create -R "$ORG/$repo" "$tag" --target "$sha" --latest \
    --title "$tag" --generate-notes >/dev/null 2>&1 ||
    fail "$repo: could not create release $tag"
}

one_repo() { # repo
  local repo=$1 db cmp status ahead
  db=$(gh api "/repos/$ORG/$repo" --jq '.default_branch // empty' 2>/dev/null) ||
    { fail "$repo: cannot read the repo"; return 0; }
  [ -n "$db" ] || { echo "  - $repo: no default branch"; return 0; }
  gh api "/repos/$ORG/$repo/branches/$db" --silent 2>/dev/null ||
    { echo "  - $repo: empty repo, nothing to release"; return 0; }
  gh api "/repos/$ORG/$repo/branches/staging" --silent 2>/dev/null ||
    { echo "  - $repo: no staging branch yet (bootstrap creates it)"; return 0; }
  [ "$(gh api "/repos/$ORG/$repo/actions/variables/AUTO_RELEASE" --jq '.value' 2>/dev/null)" = "off" ] &&
    { echo "  - $repo: opted out (AUTO_RELEASE=off)"; return 0; }

  cmp=$(gh api "/repos/$ORG/$repo/compare/$db...staging" \
    --jq '[.status, (.ahead_by // 0)] | @tsv' 2>/dev/null) ||
    { fail "$repo: cannot compare $db...staging"; return 0; }
  status=${cmp%%$'\t'*}
  ahead=${cmp##*$'\t'}
  if [ "${ahead:-0}" -gt 0 ]; then
    release_pr "$repo" "$db"
  else
    echo "  - $repo: nothing to release ($staging $status)"
  fi
  tag_release "$repo" "$db"
}

staging="staging"

if [ -n "$ONLY" ]; then
  # shellcheck disable=SC2086
  for repo in $ONLY; do
    echo "$repo:"
    one_repo "$repo"
  done
else
  while IFS= read -r repo; do
    [ -n "$repo" ] || continue
    echo "$repo:"
    one_repo "$repo"
  done < <(gh api --paginate "/orgs/$ORG/repos" --jq '.[] | select(.archived | not) | .name' |
    grep -Ev '^(sandbox|archive)-' || true)
fi

echo
if [ "$ACTED" -gt 0 ]; then
  echo "$ACTED release action(s)."
fi
if [ -n "$FAILURES" ]; then
  echo "Needs attention:$FAILURES"
  exit 1
fi
echo "Done."
