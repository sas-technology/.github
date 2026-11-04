#!/usr/bin/env python3
"""Scan a PR's added lines for likely PII and flag matches for human review.

Usage: pii-scan.py <patterns.json> <base_sha> <head_sha> <fail_on_match: true|false>

Only lines ADDED by the diff between base_sha and head_sha are checked --
never the whole repo -- so this stays fast and never flags pre-existing
content nobody touched. Matches are redacted before they're printed: the
actual PII is never written to CI logs or the job summary in full.

Exit code is 0 unless fail_on_match is "true" and at least one match was
found; the caller workflow decides whether that failure blocks a merge.
"""
import json
import os
import re
import subprocess
import sys

EXCLUDE_PATHSPECS = [
    ".",
    ":!**/*.lock",
    ":!**/package-lock.json",
    ":!**/yarn.lock",
    ":!**/node_modules/**",
    ":!pii-patterns.json",
    ":!scripts/pii-scan.py",
]

HUNK_HEADER = re.compile(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@")


def load_patterns(path):
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    compiled = []
    for p in data["patterns"]:
        compiled.append(
            {
                "name": p["name"],
                "regex": re.compile(p["regex"]),
                "allow_domains": [d.lower() for d in p.get("allow_domains", [])],
                "severity": p.get("severity", "warning"),
            }
        )
    return compiled


def get_added_lines(base_sha, head_sha):
    """Yield (file_path, line_number, content) for every line the diff adds."""
    diff = subprocess.run(
        ["git", "diff", "--unified=0", base_sha, head_sha, "--", *EXCLUDE_PATHSPECS],
        capture_output=True,
        text=True,
        check=True,
    ).stdout

    file_path = None
    line_no = None
    in_header = False
    for line in diff.splitlines():
        # "+++ " is a file header only before a file's first hunk; inside a hunk
        # an added line that begins with "++ " looks the same and must be scanned.
        if line.startswith("diff --git "):
            in_header = True
            file_path = None
            line_no = None
            continue
        if in_header and line.startswith("+++ "):
            file_path = line[6:] if line.startswith("+++ b/") else None
            continue
        if line.startswith("@@"):
            in_header = False
            m = HUNK_HEADER.match(line)
            line_no = int(m.group(1)) if m else None
            continue
        if file_path is None or line_no is None:
            continue
        if in_header:
            continue
        if line.startswith("+"):
            yield file_path, line_no, line[1:]
            line_no += 1
        elif not line.startswith("-"):
            # Context line inside a hunk (only appears with non-zero context);
            # keep the counter in step even though --unified=0 avoids this.
            line_no += 1


def redact(text, span):
    start, end = span
    matched = text[start:end]
    if len(matched) <= 4:
        masked = "*" * len(matched)
    else:
        masked = matched[:2] + "*" * (len(matched) - 4) + matched[-2:]
    return text[:start] + masked + text[end:]


def domain_allowed(email, allow_domains):
    domain = email.rsplit("@", 1)[-1].lower()
    return any(domain == d or domain.endswith("." + d) for d in allow_domains)


def find_matches(added_lines, patterns):
    findings = []
    for file_path, line_no, content in added_lines:
        if "pii-scan:ignore" in content:
            continue
        redacted_content = content
        line_findings = []
        for pattern in patterns:
            for m in pattern["regex"].finditer(content):
                if pattern["name"] == "email address" and domain_allowed(
                    m.group(0), pattern["allow_domains"]
                ):
                    continue
                line_findings.append((pattern, m.span()))
        if not line_findings:
            continue
        # Redact every match on the line before recording it, so a line with
        # several hits never reveals any of them in full.
        for pattern, span in sorted(line_findings, key=lambda pm: pm[1][0], reverse=True):
            redacted_content = redact(redacted_content, span)
        for pattern, _span in line_findings:
            findings.append(
                {
                    "file": file_path,
                    "line": line_no,
                    "type": pattern["name"],
                    "severity": pattern["severity"],
                    "context": redacted_content.strip()[:200],
                }
            )
    return findings


def report(findings, fail_on_match):
    if not findings:
        print("No potential PII found in this PR's added lines.")
        return 0

    print(f"::group::Potential PII ({len(findings)} finding(s))")
    for f in findings:
        level = "error" if f["severity"] == "error" else "warning"
        print(
            f"::{level} file={f['file']},line={f['line']}::"
            f"Possible {f['type']} — review before merging. "
            f"Context (redacted): {f['context']}"
        )
    print("::endgroup::")

    summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary_path:
        with open(summary_path, "a", encoding="utf-8") as s:
            s.write("## Possible PII found — needs human review\n\n")
            s.write("| File | Line | Type | Context (redacted) |\n")
            s.write("| --- | --- | --- | --- |\n")
            for f in findings:
                s.write(
                    f"| `{f['file']}` | {f['line']} | {f['type']} | `{f['context']}` |\n"
                )
            s.write(
                "\nFalse positive? Add `pii-scan:ignore` as a comment on that line "
                "and push again.\n"
            )

    if fail_on_match:
        print(
            f"::error::{len(findings)} potential PII match(es) found; "
            "failing because fail-on-match is true."
        )
        return 1
    print(
        f"{len(findings)} potential PII match(es) found — flagged for "
        "human review, not blocking this merge."
    )
    return 0


def main(argv):
    if len(argv) != 5:
        print(f"usage: {argv[0]} <patterns.json> <base_sha> <head_sha> <true|false>", file=sys.stderr)
        return 2
    _, config_path, base_sha, head_sha, fail_flag = argv
    patterns = load_patterns(config_path)
    added_lines = list(get_added_lines(base_sha, head_sha))
    findings = find_matches(added_lines, patterns)
    return report(findings, fail_flag.strip().lower() == "true")


if __name__ == "__main__":
    sys.exit(main(sys.argv))
