#!/usr/bin/env bash
# Tests for the release-version-check composite action,
# the next-version composite action, and the event step of
# .github/workflows/release-version-check.yml.
#
# Runs each one's own `run:` script, taken from its YAML, against a fake
# `gh` that serves commits, the base and head version files, the repo's tags
# and the PR's labels from a scratch directory, and can fail each read. Each
# case states the exit it wants, the `result` output it wants (or "-" for
# none), and a piece of text the log must hold.
#
#   bash .github/actions/release-version-check/test.sh
#
# Needs bash, node, jq, python3 >= 3.11 (tomllib, which read-version uses),
# and yq or PyYAML to read the YAML. Run from test-actions.yml.

set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd -P)"
lib="$(cd "$here/../next-version" && pwd -P)"
workflow="$(cd "$here/../../workflows" && pwd -P)/release-version-check.yml"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# extract <yaml file> <yq path> <python path>: one `run:` script.
extract() {
  if command -v yq >/dev/null; then
    yq -e "$2" "$1"
  else
    python3 -c "import sys, yaml; d = yaml.safe_load(open(sys.argv[1])); print($3)" "$1"
  fi
}
extract "$here/action.yml" '.runs.steps[0].run' 'd["runs"]["steps"][0]["run"]' > "$work/run.sh"
extract "$lib/action.yml" '.runs.steps[0].run' 'd["runs"]["steps"][0]["run"]' > "$work/next.sh"
extract "$workflow" '.jobs.check.steps[] | select(.id == "event") | .run' \
  '[s for s in d["jobs"]["check"]["steps"] if s.get("id") == "event"][0]["run"]' > "$work/event.sh"
test -s "$work/run.sh" && test -s "$work/next.sh" && test -s "$work/event.sh"

# Commits: the base tip, the PR head, and a separate merge-base when the
# base moved on after the PR branched.
TIP=1111111111111111111111111111111111111111
HEAD=2222222222222222222222222222222222222222
MB=3333333333333333333333333333333333333333

# A fake gh that behaves like the real one for the calls the scripts make:
#   repos/o/r/compare/<tip>...<head>     {"merge_base_commit": {"sha": $FIX/merge-base}}
#   repos/o/r/contents/<path>?ref=<sha>  the JSON for $FIX/<sha>/<path>: a file
#                                        (base64), [] for a directory, a
#                                        symlink when <path>.symlink exists;
#                                        else 404
#   repos/o/r/git/matching-refs/tags[/p] $FIX/tags.json
#   repos/o/r/issues/<n>/labels          $FIX/labels.json
# --jq is applied with jq; --paginate is accepted (every answer is one page).
# Failure modes, by marker file in $FIX: fail-labels (502), fail-commit (404
# from compare), bad-merge-base (compare answers no SHA), fail-contents (500),
# fail-tags (500).
mkdir -p "$work/bin"
cat > "$work/bin/gh" <<'FAKE'
#!/usr/bin/env bash
[ "${1:-}" = api ] || { echo "fake gh: only 'api' is faked" >&2; exit 1; }
shift
url="" jq_expr=""
while [ $# -gt 0 ]; do
  case "$1" in
    --jq) jq_expr="$2"; shift 2 ;;
    --paginate) shift ;;
    -H) shift 2 ;;
    repos/*) url="$1"; shift ;;
    *) echo "fake gh: unexpected argument: $1" >&2; exit 1 ;;
  esac
done
fail() { echo "gh: $1" >&2; exit 1; }
answer() { if [ -n "$jq_expr" ]; then jq -r "$jq_expr"; else cat; fi; }
case "$url" in
  repos/o/r/compare/*)
    [ -e "$FIX/fail-commit" ] && fail "Not Found (HTTP 404)"
    if [ -e "$FIX/bad-merge-base" ]; then
      printf '{"merge_base_commit":null}' | answer
    else
      printf '{"merge_base_commit":{"sha":"%s"}}' "$(cat "$FIX/merge-base")" | answer
    fi ;;
  repos/o/r/contents/*)
    [ -e "$FIX/fail-contents" ] && fail "Server Error (HTTP 500)"
    path="${url#*/contents/}"
    ref="${path#*\?ref=}"
    path="${path%%\?ref=*}"
    file="$FIX/$ref/$path"
    if [ -e "$file.symlink" ]; then printf '{"type":"symlink","path":"%s"}' "$path"; exit 0; fi
    if [ -d "$file" ]; then printf '[]'; exit 0; fi
    [ -f "$file" ] || fail "Not Found (HTTP 404)"
    # The contents API's JSON: a file, base64.
    node -e 'const b = require("fs").readFileSync(process.argv[1]);
      process.stdout.write(JSON.stringify({ type: "file", path: process.argv[2],
        encoding: "base64", size: b.length, content: b.toString("base64") }));' "$file" "$path" ;;
  repos/o/r/git/matching-refs/tags)
    [ -e "$FIX/fail-tags" ] && fail "Server Error (HTTP 500)"
    answer < "$FIX/tags.json" ;;
  repos/o/r/git/matching-refs/tags/*)
    # Filtered on the server by the prefix: each /-separated segment is
    # decoded, but an encoded slash (%2F) is not a slash, as on GitHub.
    [ -e "$FIX/fail-tags" ] && fail "Server Error (HTTP 500)"
    prefix="$(node -p 'process.argv[1].split("/").map((s) => /%2f/i.test(s) ? s : decodeURIComponent(s)).join("/")' \
      "${url#repos/o/r/git/matching-refs/tags/}")"
    jq --arg p "refs/tags/$prefix" '[.[] | select(.ref | startswith($p))]' "$FIX/tags.json" | answer ;;
  repos/o/r/issues/*/labels)
    [ -e "$FIX/fail-labels" ] && fail "Bad Gateway (HTTP 502)"
    answer < "$FIX/labels.json" ;;
  *) fail "fake gh: unexpected call: $url" ;;
esac
FAKE
chmod +x "$work/bin/gh"

# The scripts through a symlink, the way a symlinked checkout runs them
# (argv[1] is not the real path).
ln -s "$lib" "$work/lib-link"

# Broken scripts, to prove every answer is checked before it is used:
#   lib-empty  read-version prints nothing at all
#   lib-stub   next-version answers `decide` with STUB_DECIDE (or exits with
#              STUB_DECIDE_FAIL and no reason), or `strict` with
#              STUB_STRICT
mkdir -p "$work/lib-empty" "$work/lib-stub"
cp "$lib/next-version.mjs" "$work/lib-empty/next-version.mjs"
printf '#!/usr/bin/env node\n' > "$work/lib-empty/read-version.mjs"
cp "$lib/read-version.mjs" "$work/lib-stub/read-version.mjs"
cp "$lib/next-version.mjs" "$work/lib-stub/next-version-real.mjs"
cat > "$work/lib-stub/next-version.mjs" <<'STUB'
export * from "./next-version-real.mjs";
import { spawnSync } from "node:child_process";
import { realpathSync } from "node:fs";
import { fileURLToPath } from "node:url";
const self = fileURLToPath(import.meta.url);
if (process.argv[1] && realpathSync(process.argv[1]) === realpathSync(self)) {
  const cmd = process.argv[2];
  if (cmd === "decide" && process.env.STUB_DECIDE_FAIL) {
    process.exit(Number(process.env.STUB_DECIDE_FAIL));
  } else if (cmd === "decide" && process.env.STUB_DECIDE !== undefined) {
    console.log(process.env.STUB_DECIDE);
  } else if (cmd === "strict" && process.env.STUB_STRICT !== undefined) {
    console.log(process.env.STUB_STRICT);
  } else {
    const real = self.replace(/next-version\.mjs$/, "next-version-real.mjs");
    const r = spawnSync(process.execPath, [real, ...process.argv.slice(2)], {
      stdio: "inherit",
    });
    process.exit(r.status ?? 1);
  }
}
STUB

pj() { printf '{"private":true,"version":"%s"}' "$1"; }
cargo() { printf '[package]\nversion = "%s"\n\n[dependencies]\nx = { version = "9.0.0" }\n' "$1"; }
pyp() { printf '[project]\nname = "x"\nversion = "%s"\n' "$1"; }

fails=0
n=0
# report <label> <want rc> <want result> <want text> <rc> <result> <out>
report() {
  if [ "$5" = "$2" ] && [ "$6" = "$3" ] && grep -qF -- "$4" <<<"$7"; then
    echo "ok   $1"
  else
    echo "FAIL $1: wanted exit $2, result $3, text '$4'"
    echo "     got exit $5, result $6"
    while IFS= read -r line; do echo "     | $line"; done <<<"$7"
    fails=$((fails + 1))
  fi
}

# fixture <dir> <tags> <labels> [spec]...: writes files, tags and labels.
# spec: B:<file>=<text>  at the merge-base (also the tip, unless T: is used)
#       T:<file>=<text>  at the base tip, which then moved on from the
#                        merge-base (a T:- spec alone: an empty tip)
#       H:<file>=<text>  at the head
#       Bdir:<file> / Hdir:<file>    a directory at that path
#       Hlink:<file>                 a symlink at that path (head)
#       fail-labels | fail-commit | bad-merge-base | fail-contents |
#       fail-tags | lib=<link|empty|stub> | env:NAME=value
fixture() {
  local fix="$1" tags="$2" labels="$3" spec side rest moved=false base_dir
  shift 3
  for spec in "$@"; do [[ "$spec" == T:* ]] && moved=true; done
  mkdir -p "$fix/$TIP" "$fix/$HEAD" "$fix/$MB"
  if [ "$moved" = true ]; then base_dir="$MB"; else base_dir="$TIP"; fi
  echo "$base_dir" > "$fix/merge-base"
  : > "$fix/env"
  for spec in "$@"; do
    case "$spec" in
      fail-* | bad-merge-base) touch "$fix/$spec"; continue ;;
      lib=*) echo "${spec#lib=}" > "$fix/lib"; continue ;;
      env:*) echo "${spec#env:}" >> "$fix/env"; continue ;;
      T:-) continue ;;
      Bdir:*) mkdir -p "$fix/$base_dir/${spec#Bdir:}"; continue ;;
      Hdir:*) mkdir -p "$fix/$HEAD/${spec#Hdir:}"; continue ;;
      Hlink:*) touch "$fix/$HEAD/${spec#Hlink:}.symlink"; continue ;;
    esac
    side="${spec%%:*}" rest="${spec#*:}"
    case "$side" in
      B) side="$base_dir" ;;
      T) side="$TIP" ;;
      H) side="$HEAD" ;;
    esac
    printf '%s' "${rest#*=}" > "$fix/$side/${rest%%=*}"
  done
  # shellcheck disable=SC2086 # split the lists into words on purpose
  jq -n '$ARGS.positional | map({ref: ("refs/tags/" + .)})' --args $tags > "$fix/tags.json"
  # shellcheck disable=SC2086
  jq -n '$ARGS.positional | map({name: .})' --args $labels > "$fix/labels.json"
}

# case_ <label> <want exit> <want result|-> <want text> <base ref> <tags> <labels> [spec]...
case_() {
  local label="$1" want_rc="$2" want_result="$3" want_text="$4" base_ref="$5"
  n=$((n + 1))
  local fix="$work/fix$n" rt="$work/rt$n" use_lib="$lib" out rc=0 result
  fixture "$fix" "$6" "$7" "${@:8}"
  mkdir -p "$rt"
  : > "$rt/out"
  if [ -s "$fix/lib" ]; then use_lib="$work/lib-$(cat "$fix/lib")"; fi
  local -a extra=()
  while IFS= read -r line; do [ -n "$line" ] && extra+=("$line"); done < "$fix/env"
  # env: specs come last, so they can override the defaults.
  out="$(env PATH="$work/bin:$PATH" FIX="$fix" RUNNER_TEMP="$rt" \
    GITHUB_OUTPUT="$rt/out" GITHUB_STEP_SUMMARY="$rt/summary" GITHUB_ACTIONS=true \
    BASE_REF="$base_ref" BASE_SHA="$TIP" HEAD_SHA="$HEAD" DEFAULT_BRANCH=main PR_NUMBER=7 \
    REPO=o/r PREFIX=v GH_TOKEN=fake LIB="$use_lib" ${extra[@]+"${extra[@]}"} \
    bash -e "$work/run.sh" 2>&1)" || rc=$?
  result="$(sed -n 's/^result=//p' "$rt/out" | tail -1)"
  report "$label" "$want_rc" "$want_result" "$want_text" "$rc" "${result:--}" "$out"
}

# next_ <label> <want exit> <want version|-> <want text> <channel> <current>
#       <proposed> <tags> [current-from-files]
#       (NEXT_PREFIX, NEXT_BUMP, NEXT_MANUAL: the action's inputs; NEXT_SPEC: one
#       fixture spec, such as fail-tags)
next_() {
  local label="$1" want_rc="$2" want_version="$3" want_text="$4"
  n=$((n + 1))
  local fix="$work/fix$n" rt="$work/rt$n" out rc=0 version
  fixture "$fix" "$8" "" ${NEXT_SPEC:+"$NEXT_SPEC"}
  mkdir -p "$rt"
  : > "$rt/out"
  out="$(PATH="$work/bin:$PATH" FIX="$fix" RUNNER_TEMP="$rt" GITHUB_OUTPUT="$rt/out" GITHUB_ACTIONS=true \
    CHANNEL="$5" BUMP="${NEXT_BUMP:-}" MANUAL="${NEXT_MANUAL-false}" CURRENT="$6" PROPOSED="$7" FROM_FILES="${9:-}" \
    PREFIX="${NEXT_PREFIX:-v}" REPO=o/r \
    GH_TOKEN=fake SCRIPT="$lib/next-version.mjs" bash -e "$work/next.sh" 2>&1)" || rc=$?
  version="$(sed -n 's/^version=//p' "$rt/out" | tail -1)"
  report "next-version: $label" "$want_rc" "$want_version" "$want_text" "$rc" "${version:--}" "$out"
}

# event_ <label> <want exit> <want pr-number|-> <want text> <event> [NAME=value]...
# The pull_request / merge_group values default to a well-formed event.
event_() {
  local label="$1" want_rc="$2" want_pr="$3" want_text="$4" event="$5"
  shift 5
  n=$((n + 1))
  local rt="$work/rt$n" out rc=0 pr
  mkdir -p "$rt"
  : > "$rt/out"
  out="$(env PR_BASE_REF=main PR_BASE_SHA="$TIP" PR_HEAD_SHA="$HEAD" PR_NUMBER=7 \
    MG_BASE_REF=refs/heads/main MG_BASE_SHA="$TIP" MG_HEAD_SHA="$HEAD" \
    MG_HEAD_REF="refs/heads/gh-readonly-queue/main/pr-42-$HEAD" "$@" \
    EVENT="$event" GITHUB_OUTPUT="$rt/out" bash -e "$work/event.sh" 2>&1)" || rc=$?
  pr="$(sed -n 's/^pr-number=//p' "$rt/out" | tail -1)"
  if [ "$rc" = 0 ] && ! { grep -qx "base-sha=$TIP" "$rt/out" \
    && grep -qx "head-sha=$HEAD" "$rt/out" && grep -qx "base-ref=main" "$rt/out"; }; then
    out="$out (outputs missing)"
    rc=99
  fi
  report "workflow: $label" "$want_rc" "$want_pr" "$want_text" "$rc" "${pr:--}" "$out"
}

# The usual paths.
case_ "no version change on staging" 0 unchanged "will be tagged v0.27.4" \
  staging "v0.27.3" "" "B:package.json=$(pj 0.27.3)" "H:package.json=$(pj 0.27.3)"
case_ "no version file, release to main" 0 unchanged "will be tagged v0.28.0" \
  main "v0.27.3 v0.27.4" ""
case_ "next patch on staging" 0 allowed "allowed (next patch" \
  staging "v0.27.3" "" "B:package.json=$(pj 0.27.3)" "H:package.json=$(pj 0.27.4)"
case_ "minor on staging is refused" 1 - "the policy allows 0.27.4" \
  staging "v0.27.3" "" "B:package.json=$(pj 0.27.3)" "H:package.json=$(pj 0.28.0)"
case_ "next minor on main, above staging tags" 0 allowed "allowed (next minor" \
  main "v0.27.3 v0.27.5" "" "B:package.json=$(pj 0.27.3)" "H:package.json=$(pj 0.28.0)"
case_ "major without the label is refused" 1 - "the semver:major label allows a major" \
  main "v0.27.3" "" "B:package.json=$(pj 0.27.3)" "H:package.json=$(pj 1.0.0)"
case_ "major with the label is allowed" 0 allowed "allowed (next major" \
  main "v0.27.3" "bug semver:major" "B:package.json=$(pj 0.27.3)" "H:package.json=$(pj 1.0.0)"
case_ "pre-release of the released version is refused" 1 - "does not hold a version" \
  main "v0.27.3" "" "B:package.json=$(pj 0.27.3)" "H:package.json=$(pj 0.27.3-rc.1)"

# A first release (no tags at all) fails closed: 0.0.1 / 0.1.0 / 1.0.0 only.
case_ "no tags, staging: 0.0.1 is the first release" 0 allowed "first release, next patch" \
  staging "" "" "H:Cargo.toml=$(cargo 0.0.1)"
case_ "no tags, main: 0.1.0 is the first release" 0 allowed "first release, next minor" \
  main "" "" "H:package.json=$(pj 0.1.0)"
case_ "no tags, main, semver:major: 1.0.0 is the first release" 0 allowed "first release, next major" \
  main "" "semver:major" "H:VERSION=1.0.0"
case_ "no tags: 9.0.0 is refused" 1 - "the policy allows 0.0.1" \
  staging "" "" "H:Cargo.toml=$(cargo 9.0.0)"
case_ "no tags: 0.1.0 on staging is refused" 1 - "the policy allows 0.0.1" \
  staging "" "" "H:package.json=$(pj 0.1.0)"
case_ "no tags: 1.0.0 without the label is refused" 1 - "the policy allows 0.1.0" \
  main "" "" "H:package.json=$(pj 1.0.0)"
case_ "only a v0.0.0 tag: a jump to 5.0.0 is refused" 1 - "the policy allows 0.1.0" \
  main "v0.0.0" "" "H:package.json=$(pj 5.0.0)"

# Fail closed: API failures are hard errors.
case_ "a failed labels read is a hard error" 1 - "Could not read the PR's labels" \
  main "v0.27.3" "" fail-labels "B:package.json=$(pj 0.27.3)" "H:package.json=$(pj 0.27.3)"
case_ "a head commit that cannot be found is a hard error" 1 - "Could not compare the base and head" \
  staging "v0.27.3" "" fail-commit "B:package.json=$(pj 0.27.3)" "H:package.json=$(pj 0.27.3)"
case_ "a compare without a merge-base is a hard error" 1 - "gave no merge-base" \
  staging "v0.27.3" "" bad-merge-base "B:package.json=$(pj 0.27.3)" "H:package.json=$(pj 0.27.3)"
case_ "a contents read that fails (500) is a hard error" 1 - "Could not read package.json" \
  staging "v0.27.3" "" fail-contents "B:package.json=$(pj 0.27.3)" "H:package.json=$(pj 0.27.3)"
case_ "a tags read that fails is a hard error" 1 - "Could not read the repo's tags" \
  staging "v0.27.3" "" fail-tags "B:package.json=$(pj 0.27.3)" "H:package.json=$(pj 0.27.3)"

# Fail closed: every script answer is checked.
case_ "an empty read-version answer is a hard error" 1 - "read-version gave no answer" \
  staging "v0.27.3" "" lib=empty "B:package.json=$(pj 0.27.3)" "H:package.json=$(pj 0.27.3)"
case_ "a decide answer that is not 'ok ...' is a hard error" 1 - "decide gave no answer" \
  staging "v0.27.3" "" lib=stub env:STUB_DECIDE=abc "B:VERSION=0.27.3" "H:VERSION=0.27.4"
case_ "an empty decide answer is a hard error" 1 - "decide gave no answer" \
  staging "v0.27.3" "" lib=stub env:STUB_DECIDE= "B:VERSION=0.27.3" "H:VERSION=0.27.4"
case_ "a decide answer without a reason is a hard error" 1 - "decide gave no answer" \
  staging "v0.27.3" "" lib=stub "env:STUB_DECIDE=ok 0.27.4 0.27.3" "B:VERSION=0.27.3" "H:VERSION=0.27.4"
case_ "a decide answer with a bad version is a hard error" 1 - "decide gave a bad version" \
  staging "v0.27.3" "" lib=stub "env:STUB_DECIDE=ok v0.27.4 0.27.3 next patch" "B:VERSION=0.27.3" "H:VERSION=0.27.4"
case_ "a policy refusal (exit 2) without a reason is a hard error" 1 - "refused without a reason" \
  staging "v0.27.3" "" lib=stub env:STUB_DECIDE_FAIL=2 "B:VERSION=0.27.3" "H:VERSION=0.27.4"
case_ "a decide failure (exit 1) is a hard error, not a refusal" 1 - "decide failed (exit 1" \
  staging "v0.27.3" "" lib=stub env:STUB_DECIDE_FAIL=1 "B:VERSION=0.27.3" "H:VERSION=0.27.4"
case_ "a decide crash (exit 3) is a hard error" 1 - "decide failed (exit 3" \
  staging "v0.27.3" "" lib=stub env:STUB_DECIDE_FAIL=3 "B:VERSION=0.27.3" "H:VERSION=0.27.4"
case_ "a decide crash in compute, no version written: still a hard error" 1 - "decide failed (exit 1" \
  staging "v0.27.3" "" lib=stub env:STUB_DECIDE_FAIL=1
case_ "a policy refusal in compute (minor 999) is only a warning" 0 unchanged \
  "::warning::No version change in this PR, but: Minor bump" main "v0.999.0" ""
case_ "a strict that does not echo the version is a hard error" 1 - "bad 'written' version" \
  staging "v0.27.3" "" lib=stub env:STUB_STRICT=9.9.9 "B:VERSION=0.27.3" "H:VERSION=0.27.4"
case_ "an empty strict answer is a hard error" 1 - "bad 'written' version" \
  staging "v0.27.3" "" lib=stub env:STUB_STRICT= "B:VERSION=0.27.3" "H:VERSION=0.27.4"
case_ "a strict that does not echo decide's version is a hard error" 1 - "decide gave a bad version" \
  staging "v0.27.3" "" lib=stub env:STUB_STRICT=9.9.9 "H:VERSION=0.27.4"
case_ "the stub passes through when nothing is stubbed" 0 allowed "allowed (next patch" \
  staging "v0.27.3" "" lib=stub "B:VERSION=0.27.3" "H:VERSION=0.27.4"

# The scripts still run through a symlinked path.
case_ "through a symlink, a wrong version is still refused" 1 - "the policy allows 0.27.4" \
  staging "v0.27.3" "" lib=link "B:package.json=$(pj 0.27.3)" "H:package.json=$(pj 0.28.0)"
case_ "through a symlink, the next patch is still allowed" 0 allowed "allowed (next patch" \
  staging "v0.27.3" "" lib=link "B:package.json=$(pj 0.27.3)" "H:package.json=$(pj 0.27.4)"

# Invalid values are refused in every path; an unchanged one is not new.
case_ "an invalid head value is refused" 1 - "does not hold a version" \
  staging "v0.27.3" "" "B:VERSION=0.27.3" "H:VERSION=$(printf '0.27.4\t::warning::x')"
case_ "an unchanged odd VERSION line passes" 0 unchanged "No version change" \
  staging "v0.27.3" "" "B:VERSION=$(printf 'odd\tline')" "H:VERSION=$(printf 'odd\tline')"
case_ '{"version":28} is refused' 1 - "does not hold a version" \
  staging "v0.27.3" "" "B:package.json=$(pj 0.27.3)" 'H:package.json={"version":28}'
case_ "broken package.json JSON is refused" 1 - "does not hold a version" \
  staging "v0.27.3" "" "B:package.json=$(pj 0.27.3)" 'H:package.json={ "version": '
case_ "banana in an untagged repo is refused" 1 - "does not hold a version" \
  staging "release-1" "" "B:VERSION=0.1.0" "H:VERSION=banana"

# Tags that are not v<MAJOR.MINOR.PATCH>: a written version can't be verified.
case_ "tags in another scheme: a bump is refused" 1 - "can't be verified" \
  staging "release-1 vNext" "" "B:package.json=$(pj 0.1.0)" "H:package.json=$(pj 0.1.1)"
case_ "tags in another scheme: a new version file is refused" 1 - "can't be verified" \
  staging "release-1" "" "H:VERSION=0.0.1"
case_ "only pre-release tags: a bump is refused" 1 - "can't be verified" \
  staging "v1.0.0-rc.1" "" "H:package.json=$(pj 0.0.1)"
case_ "out-of-range tags (v2024.10.1): a bump is refused" 1 - "can't be verified" \
  staging "v2024.10.1" "" "B:VERSION=2024.10.1" "H:VERSION=0.0.1"
case_ "tags in another scheme, no change: passes; the first version tag is the files' version" 0 unchanged "will be tagged v0.1.0" \
  staging "release-1" "" "B:package.json=$(pj 0.1.0)" "H:package.json=$(pj 0.1.0)"
case_ "only pre-release tags, no change: passes; the first version tag is the files' version" 0 unchanged "will be tagged v0.1.0" \
  staging "v1.0.0-rc.1" "" "B:package.json=$(pj 0.1.0)" "H:package.json=$(pj 0.1.0)"
case_ "only pre-release tags: an invalid head is refused" 1 - "does not hold a version" \
  staging "v1.0.0-rc.1" "" "H:package.json=$(pj 5.0.0-rc.2)"

# Removing or resetting a version is refused (an owner bypass is needed).
case_ "a VERSION file removed is refused" 1 - "version removed or reset" \
  staging "v0.27.3" "" "B:VERSION=0.27.3"
case_ "a version reset to 0.0.0 is refused" 1 - "version removed or reset" \
  staging "v0.27.3" "" "B:package.json=$(pj 0.27.3)" "H:package.json=$(pj 0.0.0)"
case_ "a version moved into code (dynamic) is refused" 1 - "version removed or reset" \
  staging "v0.27.3" "" "B:pyproject.toml=$(pyp 0.27.3)" \
  "H:pyproject.toml=$(printf '[project]\nname = "x"\ndynamic = ["version"]\n')"
case_ "a version moved to the workspace is refused" 1 - "Cargo.toml#package: version removed or reset" \
  staging "v0.27.3" "" "B:Cargo.toml=$(cargo 0.27.3)" \
  "H:Cargo.toml=$(printf '[package]\nversion.workspace = true\n[workspace.package]\nversion = "0.27.4"\n')"
case_ "a 0.0.0 placeholder removed passes" 0 unchanged "No version change" \
  staging "v0.27.3" "" "B:package.json=$(pj 0.0.0)"

# New files and placeholders.
case_ "a version moved into a new Cargo.toml at 9.0.0 is refused" 1 - "Cargo.toml#package: Version 9.0.0" \
  staging "v0.27.3" "" "B:VERSION=0.27.3" "H:Cargo.toml=$(cargo 9.0.0)"
case_ "a private 0.0.0 package.json added to a tagged repo passes" 0 unchanged "No version change" \
  staging "v0.27.3" "" "H:package.json=$(pj 0.0.0)"
case_ "a 0.0.0 package.json beside Cargo.toml passes" 0 unchanged "No version change" \
  staging "v0.4.0" "" "B:Cargo.toml=$(cargo 0.4.0)" "H:Cargo.toml=$(cargo 0.4.0)" "H:package.json=$(pj 0.0.0)"
case_ "a 0.0.0 package.json does not hide a Cargo.toml bump" 1 - "Cargo.toml#package: Version 0.6.0" \
  staging "v0.4.0" "" "B:package.json=$(pj 0.0.0)" "H:package.json=$(pj 0.0.0)" \
  "B:Cargo.toml=$(cargo 0.4.0)" "H:Cargo.toml=$(cargo 0.6.0)"
case_ "two files bumped, one wrong, is refused" 1 - "Cargo.toml#package: Version 0.5.0" \
  staging "v0.4.0" "" "B:package.json=$(pj 0.4.0)" "H:package.json=$(pj 0.4.1)" \
  "B:Cargo.toml=$(cargo 0.4.0)" "H:Cargo.toml=$(cargo 0.5.0)"
case_ "both Cargo tables, only the second bumped wrong, is refused" 1 - "Cargo.toml#workspace.package: Version 0.6.0" \
  staging "v0.4.0" "" \
  "B:Cargo.toml=$(printf '[package]\nversion = "0.4.0"\n[workspace.package]\nversion = "0.4.0"\n')" \
  "H:Cargo.toml=$(printf '[package]\nversion = "0.4.0"\n[workspace.package]\nversion = "0.6.0"\n')"

# Only a file is a file: a directory or symlink there is invalid, unless it is
# the same on both sides.
case_ "a directory named VERSION on both sides passes" 0 unchanged "No version change" \
  staging "v0.27.3" "" Bdir:VERSION Hdir:VERSION
case_ "a directory named VERSION added by the PR is refused" 1 - "does not hold a version" \
  staging "v0.27.3" "" Hdir:VERSION
case_ "a version file replaced by a directory is refused" 1 - "does not hold a version" \
  staging "v0.27.3" "" "B:Cargo.toml=$(cargo 0.27.3)" Hdir:Cargo.toml
case_ "a version file replaced by a symlink is refused" 1 - "does not hold a version" \
  staging "v0.27.3" "" "B:VERSION=0.27.3" Hlink:VERSION

# package.json: only a duplicate root "version" refuses; a BOM is fine.
case_ "other duplicate keys in package.json do not refuse the PR" 0 allowed "allowed (next patch" \
  staging "v0.27.3" "" "B:package.json=$(pj 0.27.3)" \
  'H:package.json={"name":"a","name":"b","scripts":{"x":"1","x":"2"},"version":"0.27.4"}'
case_ "a BOM before Cargo.toml is fine" 0 allowed "allowed (next patch" \
  staging "v0.27.3" "" "B:Cargo.toml=$(cargo 0.27.3)" "H:Cargo.toml=$(printf '\357\273\277'; cargo 0.27.4)"

# Files ahead of the tags; a custom prefix.
case_ "no change, files ahead of the tags: the merge is tagged the files' version" 0 unchanged \
  "will be tagged v0.29.0" main "v0.28.0" "" "B:VERSION=0.29.0" "H:VERSION=0.29.0"
case_ "a custom prefix ignores other tags: a component's first release" 0 allowed "first release, next minor" \
  main "v3.0.0 release-1 web-v1.0.0-rc.1" "" env:PREFIX=web-v "H:VERSION=0.1.0"
case_ "a prefix with slashes: its own tags only" 0 allowed "next minor" \
  main "v9.0.0 packages/web/v0.1.0 packages/other/v5.0.0" "" env:PREFIX=packages/web/v \
  "B:VERSION=0.1.0" "H:VERSION=0.2.0"
case_ "a new entry at the written version, which is the tag: already tagged" 0 allowed "already tagged v0.27.3" \
  staging "v0.27.3" "" "B:VERSION=0.27.3" "H:VERSION=0.27.3" "H:package.json=$(pj 0.27.3)"
case_ "a new entry at the written version, below the tag: refused" 1 - "0.28.5 is not allowed after 0.28.6" \
  main "v0.28.6" "" "B:VERSION=0.28.5" "H:VERSION=0.28.5" "H:package.json=$(pj 0.28.5)"
case_ "a new entry at the written version, no tags: judged as a first release" 1 - "the policy allows 0.0.1" \
  staging "" "" "B:VERSION=0.27.3" "H:VERSION=0.27.3" "H:package.json=$(pj 0.27.3)"
case_ "a new entry at the written version, untagged repo: refused" 1 - "can't be verified" \
  staging "release-1" "" "B:VERSION=0.27.3" "H:VERSION=0.27.3" "H:package.json=$(pj 0.27.3)"
case_ "a custom prefix counts its own tags" 1 - "the policy allows 0.3.0" \
  main "v3.0.0 web-v0.2.0" "" env:PREFIX=web-v "B:VERSION=0.2.0" "H:VERSION=0.4.0"

# Judged against the merge-base; rebase when the base tip is ahead.
case_ "a bump landed on the base after the PR branched: no downgrade" 0 unchanged "No version change" \
  staging "v0.27.4" "" "B:VERSION=0.27.3" "T:VERSION=0.27.4" "H:VERSION=0.27.3"
case_ "a version file added on the base after the PR branched: no removal" 0 unchanged "No version change" \
  staging "v0.27.4" "" "T:VERSION=0.27.4"
case_ "a PR bump behind a higher base tip must rebase" 1 - "rebase onto staging: it is now at 0.27.5" \
  staging "v0.27.5" "" "B:VERSION=0.27.3" "T:VERSION=0.27.5" "H:VERSION=0.27.4"
case_ "a PR bump equal to the tagged base tip passes as already tagged" 0 allowed "already tagged v0.27.4" \
  staging "v0.27.4" "" "B:VERSION=0.27.3" "T:VERSION=0.27.4" "H:VERSION=0.27.4"

# No tags at all, but a version already written: that is the current one.
case_ "no tags, 0.27.3 written: 0.27.4 is the next patch" 0 allowed "allowed (next patch" \
  staging "" "" "B:VERSION=0.27.3" "H:VERSION=0.27.4"
case_ "no tags, 0.27.3 written: 0.0.1 is a downgrade" 1 - "0.0.1 is lower than 0.27.3" \
  staging "" "" "B:VERSION=0.27.3" "H:VERSION=0.0.1"
case_ "no tags, 0.27.3 written elsewhere: a new file at 0.0.1 is refused" 1 - "the policy allows 0.27.4" \
  staging "" "" "B:VERSION=0.27.3" "H:VERSION=0.27.3" "H:package.json=$(pj 0.0.1)"
case_ "no tags, no change: the first tag is the written version" 0 unchanged "will be tagged v0.27.3" \
  main "" "" "B:VERSION=0.27.3" "H:VERSION=0.27.3"

# Downgrades.
case_ "a downgrade from 0.27.4 to 0.27.3 is refused" 1 - "0.27.3 is lower than 0.27.4" \
  staging "v0.27.3" "" "B:package.json=$(pj 0.27.4)" "H:package.json=$(pj 0.27.3)"
case_ "a downgrade to an old tag is refused" 1 - "0.27.3 is lower than 0.27.5" \
  staging "v0.27.3 v0.27.5" "" "B:package.json=$(pj 0.27.5)" "H:package.json=$(pj 0.27.3)"
case_ "a downgrade in an untagged repo is refused" 1 - "0.1.0 is lower than 0.2.0" \
  staging "release-1" "" "B:VERSION=0.2.0" "H:VERSION=0.1.0"

# The one strict parser, end to end (fixtures from version-fixtures.json).
case_ "fixture 999.999.999 (valid) is checked by the policy" 1 - "the policy allows 0.27.4" \
  staging "v0.27.3" "" "B:VERSION=0.27.3" "H:VERSION=999.999.999"
case_ "fixture 0.27.4 (valid) in every file is allowed" 0 allowed "VERSION: 0.27.3 -> 0.27.4" \
  staging "v0.27.3" "" "B:package.json=$(pj 0.27.3)" "H:package.json=$(pj 0.27.4)" \
  "B:Cargo.toml=$(cargo 0.27.3)" "H:Cargo.toml=$(cargo 0.27.4)" \
  "B:pyproject.toml=$(pyp 0.27.3)" "H:pyproject.toml=$(pyp 0.27.4)" \
  "B:VERSION=0.27.3" "H:VERSION=0.27.4"
for bad in "v0.27.4" " 0.27.4" "0.27.4 " "0.27.4-rc.1" "0.27.4+b" "00.27.4" "0.27.04" "1000.0.0" "0.27" "0.27.4.1" ""; do
  case_ "fixture '$bad' (invalid) in package.json is refused" 1 - "does not hold a version" \
    staging "v0.27.3" "" "B:package.json=$(pj 0.27.3)" "H:package.json=$(pj "$bad")"
done
case_ "a VERSION file with more than one line is refused" 1 - "does not hold a version" \
  staging "v0.27.3" "" "B:VERSION=0.27.3" "H:VERSION=$(printf '0.27.4\n\nx')"
case_ "fixture 'v0.27.4' (invalid) in Cargo.toml is refused" 1 - "does not hold a version" \
  staging "v0.27.3" "" "B:Cargo.toml=$(cargo 0.27.3)" "H:Cargo.toml=$(cargo v0.27.4)"

# Duplicate keys and odd TOML (read by tomllib).
case_ "a duplicate root version in package.json is refused" 1 - "does not hold a version" \
  staging "v0.27.3" "" "B:package.json=$(pj 0.27.3)" 'H:package.json={"version":"0.27.4","version":"9.0.0"}'
case_ "a duplicate version in [package] is refused" 1 - "does not hold a version" \
  staging "v0.27.3" "" "B:Cargo.toml=$(cargo 0.27.3)" \
  "H:Cargo.toml=$(printf '[package]\nversion = "0.27.4"\nversion = "9.0.0"\n')"
case_ "a quoted second version key in [project] is refused" 1 - "does not hold a version" \
  staging "v0.27.3" "" "B:pyproject.toml=$(pyp 0.27.3)" \
  "H:pyproject.toml=$(printf '[project]\nversion = "0.27.4"\n"version" = "9.0.0"\n')"
case_ "a prefix inline table is read (and checked)" 1 - "Cargo.toml#workspace.package: Version 9.0.0" \
  staging "v0.27.3" "" "B:Cargo.toml=$(cargo 0.27.3)" \
  "H:Cargo.toml=$(printf 'workspace = { package = { version = "9.0.0" } }\n[package]\nversion = "0.27.3"\n')"
case_ "an escaped header is read (and checked)" 1 - "Cargo.toml#package: Version 9.0.0" \
  staging "v0.27.3" "" "B:Cargo.toml=$(cargo 0.27.3)" \
  "H:Cargo.toml=$(printf '["pack\\u0061ge"]\nversion = "9.0.0"\n')"

# The next-version composite action.
next_ "a strict proposed version is checked" 0 0.28.0 ": next minor" main 0.27.3 0.28.0 ""
next_ "a non-strict proposed version is refused first" 1 - "is not a version" main "" v0.28.0 "v0.28.0"
next_ "a pre-release proposed version is refused" 1 - "is not a version" main 0.27.3 0.28.0-rc.1 ""
next_ "the current, tagged version passes as already tagged" 0 0.27.4 "already tagged" staging "" 0.27.4 "v0.27.3 v0.27.4"
next_ "an older tagged version is a downgrade, refused" 1 - "the policy allows 0.27.5" staging "" 0.27.3 "v0.27.3 v0.27.4"
next_ "files ahead of the tags: no deadlock" 0 0.27.6 "next patch" staging "" 0.27.6 "v0.27.4" 0.27.5
next_ "compute, no tags: the files' version" 0 1.4.2 "no version tag yet" staging "" "" "" 1.4.2
next_ "compute, untagged repo: the files' version" 0 2.0.0 "no version tag yet" staging "" "" "release-1" 2.0.0
NEXT_BUMP=major NEXT_MANUAL=true next_ "compute, a manual major overrides files ahead" 0 1.0.0 "next major" \
  main "" "" "v0.28.5" 0.28.6
next_ "check: from-files equal to proposed, and the current tag: already tagged" 0 0.28.5 "already tagged" \
  main "" 0.28.5 "v0.28.5" 0.28.5
next_ "files ahead of the tags, and allowed: the files' version itself" 0 0.29.0 "the version the repo writes" \
  main "" "" "v0.28.0" 0.29.0
next_ "files ahead of the tags, beyond the policy: still the files' version" 0 0.35.0 \
  "the version the repo writes" main "" "" "v0.28.0" 0.35.0
next_ "files 1.0.0 ahead of v0.28.5: compute tags 1.0.0" 0 1.0.0 "ahead of the highest tag" \
  main "" "" "v0.28.5" 1.0.0
next_ "files 0.28.2 ahead of v0.28.0 on staging: compute tags 0.28.2" 0 0.28.2 "ahead of the highest tag" \
  staging "" "" "v0.28.0" 0.28.2
next_ "check: from-files equal to the proposed version is refused" 1 - "version before the change" \
  main "" 9.9.9 "v0.28.0" 9.9.9
next_ "check: prior files 0.28.5, proposed 1.0.0 without a major: refused" 1 - "bump: major" \
  main "" 1.0.0 "v0.28.5" 0.28.5
NEXT_BUMP=major NEXT_MANUAL=true next_ "check: prior files 0.28.5, proposed 1.0.0 on a manual major" 0 1.0.0 \
  "next major" main "" 1.0.0 "v0.28.5" 0.28.5
NEXT_PREFIX=packages/web/v next_ "a prefix with slashes: its own tags only" 0 0.2.0 "next minor" \
  main "" "" "v9.0.0 packages/web/v0.1.0 packages/other/v5.0.0"
NEXT_PREFIX=web-v next_ "a component whose only tag is a pre-release: a normal first release" 0 0.1.0 \
  "first release" main "" "" "web-v1.0.0-rc.1 v3.0.0"
NEXT_BUMP=major NEXT_MANUAL=no next_ "--manual no is never true: a major is refused" 1 - "by hand" \
  main 1.0.0 "" ""
NEXT_BUMP=major NEXT_MANUAL='' next_ "--manual empty is never true: a major is refused" 1 - "by hand" \
  main 1.0.0 "" ""
NEXT_BUMP=major NEXT_MANUAL=true next_ "--manual true: a major" 0 2.0.0 "next major" main 1.0.0 "" ""
NEXT_PREFIX=web-v next_ "a custom prefix ignores other tags" 0 0.1.0 "first release" main "" "" "v3.0.0 release-1"
NEXT_PREFIX=web-v next_ "a custom prefix counts its own tags" 0 0.3.0 "next minor" main "" "" "v3.0.0 web-v0.2.0"
next_ "no tags: the first release fails closed" 1 - "the policy allows 0.0.1" staging "" 5.0.0 ""
next_ "no tags: 0.0.1 is the first release" 0 0.0.1 "first release, next patch" staging "" 0.0.1 ""
next_ "a v0.0.0 tag: checked against 0.0.0" 0 0.1.0 ": next minor" main "" 0.1.0 "v0.0.0"
next_ "out-of-range tags are ignored" 0 0.0.1 "Version 0.0.0 -> 0.0.1" staging "" "" "v2024.10.1"
NEXT_SPEC=fail-tags next_ "a failed tags read is a hard error" 1 - "Could not read the repo's tags" \
  staging "" "" "v0.1.0"
next_ "untagged (another scheme): a proposed version is refused" 1 - "can't be verified" staging "" 0.0.1 "release-1"
next_ "untagged (pre-releases only): a proposed version is refused" 1 - "can't be verified" staging "" 0.0.1 "v1.0.0-rc.1"
next_ "no tags, current-from-files 0.27.3: 0.27.4 is allowed" 0 0.27.4 ": next patch" staging "" 0.27.4 "" 0.27.3
next_ "no tags, current-from-files 0.27.3: 0.0.1 is refused" 1 - "the policy allows 0.27.4" staging "" 0.0.1 "" 0.27.3
next_ "no tags, current-from-files empty: a true first release" 0 0.0.1 "first release, next patch" staging "" 0.0.1 ""
next_ "a non-strict current-from-files is refused" 1 - "is not MAJOR.MINOR.PATCH" staging "" 0.0.1 "" v0.27.3

# THE decision: both actions decide the same on the same tags and files,
# in compute mode (what the merge is tagged) and in check mode (a PR that
# writes 0.4.1).
# same_rule_ <label> <tags> [written]
same_rule_() {
  local label="$1" tags="$2" written="${3:-}" fix rt out a_compute a_check b_compute b_check
  n=$((n + 1))
  fix="$work/fix$n" rt="$work/rt$n"
  if [ -n "$written" ]; then
    fixture "$fix" "$tags" "" "B:VERSION=$written" "H:VERSION=0.4.1"
  else
    fixture "$fix" "$tags" "" "H:VERSION=0.4.1"
  fi
  mkdir -p "$rt"
  : > "$rt/out"
  out="$(PATH="$work/bin:$PATH" FIX="$fix" RUNNER_TEMP="$rt" GITHUB_OUTPUT="$rt/out" \
    GITHUB_STEP_SUMMARY="$rt/summary" GITHUB_ACTIONS=true BASE_REF=staging BASE_SHA="$TIP" \
    HEAD_SHA="$HEAD" DEFAULT_BRANCH=main PR_NUMBER='' REPO=o/r PREFIX=v GH_TOKEN=fake \
    LIB="$lib" bash -e "$work/run.sh" 2>&1)" || true
  a_compute="$(sed -n 's/^decide compute: //p' <<<"$out")"
  a_check="$(sed -n 's/^decide check: //p' <<<"$out")"
  # next_run <proposed>: the next-version action's decide line.
  next_run() {
    PATH="$work/bin:$PATH" FIX="$fix" RUNNER_TEMP="$rt" GITHUB_OUTPUT="$rt/out" GITHUB_ACTIONS=true \
      CHANNEL=staging BUMP="" MANUAL=false CURRENT="" PROPOSED="$1" FROM_FILES="$written" \
      PREFIX=v REPO=o/r GH_TOKEN=fake SCRIPT="$lib/next-version.mjs" bash -e "$work/next.sh" 2>&1 || true
  }
  b_compute="$(next_run "" | sed -n 's/^decide compute: //p')"
  # A refusal is reported as ::error::<reason> by the next-version action.
  out="$(next_run 0.4.1)"
  b_check="$(sed -n 's/^decide check: //p' <<<"$out")"
  [ -n "$b_check" ] || b_check="refused: $(sed -n 's/^::error:://p' <<<"$out")"
  if [ -n "$a_compute" ] && [ "$a_compute" = "$b_compute" ] && [ -n "$a_check" ] \
    && [ "$a_check" = "$b_check" ]; then
    echo "ok   both actions: $label (compute: $a_compute | check: $a_check)"
  else
    echo "FAIL both actions: $label:"
    echo "     release-version-check: compute '$a_compute', check '$a_check'"
    echo "     next-version:          compute '$b_compute', check '$b_check'"
    fails=$((fails + 1))
  fi
}
same_rule_ "no tags, nothing written" ""
same_rule_ "no tags, a version written" "" 0.4.0
same_rule_ "no tags, 0.0.0 written" "" 0.0.0
same_rule_ "version tags" "v0.27.3 v0.27.10 release-1" 0.4.0
same_rule_ "a v0.0.0 tag" "v0.0.0"
same_rule_ "another scheme" "release-1 vNext" 0.4.0
same_rule_ "pre-releases only" "v1.0.0-rc.1 v1.0.0-beta" 0.4.0
same_rule_ "out of range" "v2024.10.1"
same_rule_ "another prefix" "pkg@1.0.0" 0.4.0
same_rule_ "mixed" "v1.0.0-rc.1 v0.3.0 release-9"
same_rule_ "files ahead of the tags" "v0.3.0" 0.4.0

# The workflow's event step.
event_ "pull_request goes on" 0 7 "" pull_request
event_ "merge_group is checked again, PR number from the queue ref" 0 42 "" merge_group
event_ "merge_group with a base branch holding a slash" 0 42 "" merge_group \
  MG_HEAD_REF="refs/heads/gh-readonly-queue/main/pr-42-$HEAD"
event_ "merge_group with an unreadable queue ref: no PR number, major refused" 0 - \
  "a major version will be refused" merge_group MG_HEAD_REF=refs/heads/something-else
event_ "merge_group with a PR number of 0 is not a PR number" 0 - "a major version will be refused" \
  merge_group MG_HEAD_REF="refs/heads/gh-readonly-queue/main/pr-0-$HEAD"
event_ "merge_group without a base commit fails" 1 - "no base commit" merge_group MG_BASE_SHA=
event_ "pull_request without a head commit fails" 1 - "no head commit" pull_request PR_HEAD_SHA=abc
event_ "push is an unexpected event" 1 - "unexpected event 'push'" push
event_ "workflow_dispatch is an unexpected event" 1 - "unexpected event" workflow_dispatch

# A merge queue group, end to end: the PR number's label allows a major.
case_ "merge queue: a major with the PR's label is allowed" 0 allowed "allowed (next major" \
  main "v0.27.3" "semver:major" "B:VERSION=0.27.3" "H:VERSION=1.0.0"
case_ "merge queue: no PR number, a major is refused" 1 - "the policy allows 0.28.0" \
  main "v0.27.3" "semver:major" env:PR_NUMBER= "B:VERSION=0.27.3" "H:VERSION=1.0.0"

if [ "$fails" -ne 0 ]; then
  echo "$fails of $n case(s) failed."
  exit 1
fi
echo "All $n cases passed."
