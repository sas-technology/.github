#!/usr/bin/env bash
# Main gate: the default branch takes releases only.
#
# Squash releases mean the default branch and staging never share history,
# and a release is built as "the default branch, replaced by staging's tree".
# Anything that lands on the default branch without going through staging is
# therefore deleted, silently, by the next release. That can silently revert real work.
# This gate makes that impossible instead of relying on people remembering.
#
# In a repo that has a `staging` branch, a pull request into the default
# branch must:
#   1. come from `staging`, a `release/*` branch, a release bot's
#      `release-pr/*` branch, or the
#      registry pin bot's `bot/registry-pin` branch; and
#   2. if it is a release, find no commit on the default branch since the
#      last release. Such a commit exists only there and the release would
#      erase it: forward-port it to staging and re-cut the release. The
#      commits stay in the default branch's history after that, so once
#      they are on staging the `forward-ported` label lets the release by.
# A pin-bot PR is let through rule 1 and is then caught by rule 2 at the next
# release, which is the point at which it must be forward-ported.
#
# PRs into staging, and repos without staging, are not affected.
#
# Env: GH_TOKEN REPO BASE_REF DEFAULT_BRANCH BASE_SHA HEAD_REF PR_NUMBER
#   HEAD_REF may be empty in a merge queue; it is then read from PR_NUMBER.
set -euo pipefail

fail() { echo "::error title=Main gate::$1"; exit 1; }
ok() { echo "Main gate: $1"; echo "Main gate: $1" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"; }

if [ "$BASE_REF" != "$DEFAULT_BRANCH" ]; then
  ok "base is '$BASE_REF', not the default branch; nothing to check."
  exit 0
fi

if ! gh api "repos/$REPO/branches/staging" --silent 2>/dev/null; then
  ok "this repo has no staging branch; nothing to check."
  exit 0
fi

head_ref="${HEAD_REF:-}"
if [ -z "$head_ref" ]; then
  [[ "${PR_NUMBER:-}" =~ ^[1-9][0-9]*$ ]] \
    || fail "Cannot tell which branch this merge queue group came from, so it is refused. Queue releases one at a time."
  head_ref="$(gh api "repos/$REPO/pulls/$PR_NUMBER" --jq .head.ref)" \
    || fail "Cannot read PR #$PR_NUMBER."
fi

case "$head_ref" in
  staging|release/*|release-pr/*|bot/registry-pin) ;;
  *)
    fail "'$DEFAULT_BRANCH' takes releases only, and this PR comes from '$head_ref'. Open it against 'staging' instead (gh pr edit <n> --base staging); it reaches '$DEFAULT_BRANCH' with the next release. Dependabot: set target-branch: staging in .github/dependabot.yml." ;;
esac

if [ "$head_ref" = "bot/registry-pin" ]; then
  ok "registry pin bot; allowed. The next release must forward-port it to staging (rule 2 enforces that)."
  exit 0
fi

# Rule 2: commits on the default branch since the last release.
# Release commits are recognised by title: "chore(release): staging to main…",
# "Release staging to main…", "Release v1.2.0…", "release: v1.2.0".
is_release='^(chore\(release\)|release)([:(]|\b)|staging to main'
commits="$(gh api "repos/$REPO/commits?sha=$BASE_SHA&per_page=100" \
  --jq '.[] | "\(.sha[0:7]) \(.commit.message | split("\n")[0])"')" \
  || fail "Cannot list the commits on '$DEFAULT_BRANCH'."

stray=""
found_release=false
while IFS= read -r line; do
  [ -z "$line" ] && continue
  title="${line#* }"
  if grep -Eiq "$is_release" <<<"$title"; then found_release=true; break; fi
  stray+="$line"$'\n'
done <<<"$commits"

if [ "$found_release" = false ]; then
  ok "no earlier release in the last 100 commits on '$DEFAULT_BRANCH'; treating this as the first release."
  exit 0
fi

if [ -n "$stray" ] && [[ "${PR_NUMBER:-}" =~ ^[1-9][0-9]*$ ]] \
  && gh api "repos/$REPO/issues/$PR_NUMBER/labels" --jq '.[].name' 2>/dev/null | grep -qx 'forward-ported'; then
  echo "::warning title=Main gate::'forward-ported' label set: accepting that these commits are already on staging:"
  printf '%s' "$stray"
  ok "commits since the last release are marked forward-ported by the 'forward-ported' label."
  exit 0
fi

if [ -n "$stray" ]; then
  {
    echo "### Main gate: commits on $DEFAULT_BRANCH since the last release"
    echo
    echo "This release replaces $DEFAULT_BRANCH with staging's tree, so these would be deleted:"
    echo
    echo '```'
    printf '%s' "$stray"
    echo '```'
    echo
    echo "Forward-port them to staging (cherry-pick onto a branch off staging, PR into staging), then re-cut the release."
    echo "Once each one is on staging, add the \`forward-ported\` label to this PR and re-run the check."
  } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
  fail "'$DEFAULT_BRANCH' has $(printf '%s' "$stray" | grep -c .) commit(s) since the last release that staging may not have; this release would delete them. They are listed in the job summary. Forward-port them to staging and re-cut the release."
fi

ok "release from '$head_ref'; nothing on '$DEFAULT_BRANCH' since the last release."
