// node --test .github/actions/next-version/
import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { mkdtempSync, rmSync, symlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";

import {
  PolicyError,
  UsageError,
  check,
  currentVersion,
  decide,
  highest,
  isMain,
  isStrictVersion,
  parse,
  parseStrict,
  nextVersion,
} from "./next-version.mjs";

const staging = { channel: "staging" };
const main = { channel: "main" };

test("a merge into staging bumps the patch", () => {
  assert.equal(nextVersion("0.27.0", staging), "0.27.1");
  assert.equal(nextVersion("0.27.41", staging), "0.27.42");
});

test("a release to main bumps the minor and resets the patch", () => {
  assert.equal(nextVersion("0.27.0", main), "0.28.0");
  assert.equal(nextVersion("0.27.13", main), "0.28.0");
  assert.equal(nextVersion("4.0.1", main), "4.1.0");
});

test("no tags yet starts from 0.0.0", () => {
  assert.equal(nextVersion("", staging), "0.0.1");
  assert.equal(nextVersion("", main), "0.1.0");
});

test("patch 999 rolls into the next minor", () => {
  assert.equal(nextVersion("0.27.998", staging), "0.27.999");
  assert.equal(nextVersion("0.27.999", staging), "0.28.0");
});

test("minor 999 refuses to roll into a major", () => {
  assert.throws(() => nextVersion("0.999.4", main), /bump: major/);
  assert.throws(() => nextVersion("0.999.999", staging), PolicyError);
});

test("major only on a manual run", () => {
  assert.throws(
    () => nextVersion("0.27.3", { ...main, bump: "major" }),
    /only ever released by hand/,
  );
  assert.equal(
    nextVersion("0.27.3", { ...main, bump: "major", manual: true }),
    "1.0.0",
  );
  assert.equal(
    nextVersion("0.999.4", { ...main, bump: "major", manual: true }),
    "1.0.0",
  );
});

test("a manual override picks the bump", () => {
  const opts = { ...main, manual: true };
  assert.equal(nextVersion("0.27.3", { ...opts, bump: "patch" }), "0.27.4");
  assert.equal(nextVersion("0.27.3", { ...staging, bump: "minor" }), "0.28.0");
  assert.throws(() => nextVersion("0.27.3", { ...main, bump: "huge" }));
});

test("check accepts the next version and refuses others", () => {
  assert.equal(check("0.27.3", "0.28.0", main), "next minor");
  assert.equal(check("0.27.3", "0.27.3", main), "unchanged");
  assert.throws(() => check("", "3.1.4", main), /allows 0.1.0/);
  assert.equal(check("", "0.1.0", main), "next minor");
  assert.throws(() => check("0.27.0", "0.27.1", main), /allows 0.28.0/);
  assert.throws(() => check("0.27.0", "0.29.0", main), PolicyError);
  assert.throws(() => check("0.27.0", "1.0.0", main), /bump: major/);
  assert.equal(
    check("0.27.0", "1.0.0", { ...main, allowMajor: true }),
    "next major",
  );
  assert.equal(
    check("0.999.0", "1.0.0", { ...main, allowMajor: true }),
    "next major",
  );
  assert.throws(() => check("0.999.0", "0.1000.0", main), /not a version/);
  assert.throws(() => check("0.999.0", "0.999.1", main), /bump: major/);
  assert.equal(check("0.27.999", "0.28.0", staging), "next patch");
});

test("only strict versions: pre-releases and suffixes are refused", () => {
  // MAJOR.MINOR.PATCH and nothing else, wherever a version is read.
  for (const bad of [
    "0.27.3-rc.1",
    "0.27.4-rc.1",
    "1.0.0-rc.1",
    "0.28.0+build",
    "v0.28.0",
    " 0.28.0",
    "0.28.0\n",
    "0.28",
  ]) {
    assert.throws(() => check("0.27.3", bad, main), /not a version/, bad);
    assert.throws(
      () => check("0.27.3", bad, { ...main, allowMajor: true }),
      /not a version/,
      bad,
    );
  }
  assert.throws(() => nextVersion("0.27.3-rc.1", main), /not a version/);
  assert.throws(() => check("v0.27.3", "0.28.0", main), /not a version/);
  // A downgrade to an older release is refused.
  assert.throws(() => check("0.27.5", "0.27.3", staging), /allows 0.27.6/);
});

test("isMain: not when imported, yes when it cannot tell", () => {
  assert.equal(isMain(import.meta.url, ""), false);
  assert.equal(isMain(import.meta.url, fileURLToPath(import.meta.url)), true);
  assert.equal(
    isMain("file:///elsewhere.mjs", fileURLToPath(import.meta.url)),
    false,
  );
  assert.equal(isMain(import.meta.url, "/no/such/file.mjs"), true);
});

test("parseStrict and isStrictVersion", () => {
  assert.deepEqual(parseStrict("1.20.300"), {
    major: 1,
    minor: 20,
    patch: 300,
  });
  assert.equal(parse, parseStrict);
  assert.ok(isStrictVersion("999.999.999"));
  assert.ok(!isStrictVersion("1000.0.0"));
  assert.ok(!isStrictVersion(undefined));
  assert.ok(!isStrictVersion(123));
  assert.throws(() => parseStrict(null), PolicyError);
  assert.throws(() => parseStrict("01.2.3"), /not a version/);
});

test("highest ignores pre-releases, other prefixes and junk", () => {
  // Only <prefix><strict version> is a version tag; nothing is trimmed.
  const refs = [
    "abc\trefs/tags/v0.9.0",
    "def\trefs/tags/v0.27.3",
    "def\trefs/tags/v0.27.3^{}",
    "aaa\trefs/tags/v0.28.0-rc.1",
    "bbb\trefs/tags/v0.10.0",
    "ccc\trefs/tags/release-9.0.0",
    "refs/tags/vNext",
    "refs/tags/v99.0.0 ",
    " refs/tags/v98.0.0",
    "refs/tags/v097.0.0",
    "refs/tags/v1000.0.0",
    "",
  ];
  assert.equal(highest(refs), "0.27.3");
  assert.equal(highest(["pkg@1.2.3", "pkg@1.10.0"], "pkg@"), "1.10.0");
  assert.equal(highest([]), "0.0.0");
});

test("from 0.0.0 the rule is the same: 0.0.1, 0.1.0 or 1.0.0", () => {
  assert.equal(check("0.0.0", "0.0.1", staging), "next patch");
  assert.equal(check("0.0.0", "0.1.0", main), "next minor");
  assert.equal(
    check("0.0.0", "1.0.0", { ...main, allowMajor: true }),
    "next major",
  );
  assert.equal(
    check("0.0.0", "1.0.0", { ...staging, allowMajor: true }),
    "next major",
  );
  for (const bad of ["5.0.0", "0.2.0", "1.0.0", "0.1.1", "3.1.4"]) {
    assert.throws(() => check("0.0.0", bad, main), /allows 0.1.0/, bad);
  }
  assert.throws(() => check("0.0.0", "0.1.0", staging), /allows 0.0.1/);
  assert.throws(
    () => check("0.0.0", "2.0.0", { ...main, allowMajor: true }),
    /allows 0.1.0/,
  );
});

test("decide: check mode", () => {
  const t = (...v) => v.map((x) => `refs/tags/${x}`);
  const d = (refs, o) => decide(refs, { mode: "check", ...o });
  // The next version after the highest tag.
  assert.deepEqual(d(t("v0.27.3"), { ...staging, proposed: "0.27.4" }), {
    version: "0.27.4",
    current: "0.27.3",
    reason: "next patch (current: the highest tag v0.27.3)",
  });
  assert.throws(
    () => d(t("v0.27.3"), { ...staging, proposed: "0.28.0" }),
    /allows 0.27.4/,
  );
  // Already tagged only when it IS the current version ...
  assert.match(
    d(t("v0.27.3"), { ...staging, proposed: "0.27.3" }).reason,
    /already tagged/,
  );
  // ... so a downgrade to an old tag is refused.
  assert.throws(
    () => d(t("v0.27.3", "v0.27.5"), { ...staging, proposed: "0.27.3" }),
    /allows 0.27.6/,
  );
  // A major with the label (allowMajor) or a manual bump: major.
  assert.match(
    d(t("v0.27.3"), { ...main, proposed: "1.0.0", allowMajor: true }).reason,
    /next major/,
  );
  assert.match(
    d(t("v0.27.3"), { ...main, proposed: "1.0.0", manual: true, bump: "major" })
      .reason,
    /next major/,
  );
  assert.throws(
    () => d(t("v0.27.3"), { ...main, proposed: "1.0.0" }),
    /bump: major/,
  );
  // No tags: the first release, from 0.0.0 ...
  assert.match(
    d([], { ...staging, proposed: "0.0.1" }).reason,
    /^first release, next patch/,
  );
  assert.throws(() => d([], { ...staging, proposed: "5.0.0" }), /allows 0.0.1/);
  // ... or from the files.
  assert.equal(
    d([], { ...staging, proposed: "1.4.3", fromFiles: "1.4.2" }).current,
    "1.4.2",
  );
  assert.throws(
    () => d([], { ...staging, proposed: "0.0.1", fromFiles: "1.4.2" }),
    /allows 1.4.3/,
  );
  // Files ahead of the tags: the files win, no deadlock.
  const ahead = d(t("v0.27.3"), {
    ...staging,
    proposed: "0.27.5",
    fromFiles: "0.27.4",
  });
  assert.equal(ahead.current, "0.27.4");
  assert.match(ahead.reason, /next patch/);
  // Files behind the tags: the tags win.
  assert.equal(
    d(t("v0.27.3"), { ...staging, proposed: "0.27.4", fromFiles: "0.20.0" })
      .current,
    "0.27.3",
  );
  // Untagged (default prefix): cannot be verified.
  for (const tags of [t("release-1"), t("v1.0.0-rc.1"), t("v2024.10.1")]) {
    assert.throws(
      () => d(tags, { ...staging, proposed: "0.0.1" }),
      /can't be verified/,
    );
  }
  // A custom prefix ignores other tags: a component's first release works.
  assert.match(
    d(t("v3.0.0", "release-1"), { ...main, proposed: "0.1.0", prefix: "web-v" })
      .reason,
    /^first release, next minor/,
  );
  assert.equal(
    d(t("v3.0.0", "web-v0.1.0"), {
      ...main,
      proposed: "0.2.0",
      prefix: "web-v",
    }).current,
    "0.1.0",
  );
  // Its own odd tags are ignored too: only the default prefix is untagged.
  assert.match(
    d(t("web-vNext"), { ...main, proposed: "0.1.0", prefix: "web-v" }).reason,
    /^first release/,
  );
  // Strict inputs only.
  assert.throws(
    () => d([], { ...staging, proposed: "v0.0.1" }),
    /not a version/,
  );
  assert.throws(
    () => d([], { ...staging, proposed: "0.0.1", fromFiles: "1.4" }),
    /--from-files "1.4" is not MAJOR.MINOR.PATCH/,
  );
  // --from-files equal to the proposed version passes only when it is the
  // current tag already (a caller whose parent and head are one commit).
  assert.match(
    d(t("v0.28.5"), { ...main, proposed: "0.28.5", fromFiles: "0.28.5" })
      .reason,
    /already tagged v0.28.5/,
  );
  assert.throws(
    () =>
      d(t("v0.28.5", "v0.28.6"), {
        ...main,
        proposed: "0.28.5",
        fromFiles: "0.28.5",
      }),
    UsageError,
  );
  // --from-files is the version BEFORE the change: never the proposed one.
  assert.throws(
    () => d(t("v0.28.0"), { ...main, proposed: "9.9.9", fromFiles: "9.9.9" }),
    (e) => e instanceof UsageError && /before the change/.test(e.message),
  );
  // A major the files already announce (prior 0.28.5, proposed 1.0.0) is
  // a major like any other: with the label, or refused.
  assert.match(
    d(t("v0.28.5"), {
      ...main,
      proposed: "1.0.0",
      fromFiles: "0.28.5",
      allowMajor: true,
    }).reason,
    /next major/,
  );
  assert.throws(
    () => d(t("v0.28.5"), { ...main, proposed: "1.0.0", fromFiles: "0.28.5" }),
    PolicyError,
  );
  // Prior files already at 1.0.0 (ahead of v0.28.5): the next is checked
  // from 1.0.0, and 1.0.0 itself is the files' own (unchanged) version.
  assert.match(
    d(t("v0.28.5"), { ...main, proposed: "1.1.0", fromFiles: "1.0.0" }).reason,
    /next minor/,
  );
  assert.throws(() => d([], { ...staging }), /needs --proposed/);
  assert.throws(
    () => d([], { channel: "prod", proposed: "0.0.1" }),
    /Unknown channel/,
  );
});

test("decide: a custom prefix ignores everything but its own version tags", () => {
  const t = (...v) => v.map((x) => `refs/tags/${x}`);
  for (const prefix of ["web-v", ""]) {
    // Its only tag a pre-release, or tags of other schemes: a first release.
    const refs = t(`${prefix}1.0.0-rc.1`, "release-1", "v9.9.9-x");
    assert.deepEqual(
      currentVersion(refs, { prefix }),
      { kind: "none" },
      prefix,
    );
    assert.match(
      decide(refs, {
        mode: "check",
        channel: "main",
        proposed: "0.1.0",
        prefix,
      }).reason,
      /^first release, next minor/,
      prefix,
    );
    assert.equal(
      decide(refs, { mode: "compute", channel: "main", prefix }).version,
      "0.1.0",
    );
  }
  // "" counts bare version tags.
  assert.deepEqual(currentVersion(t("1.2.3", "v9.0.0"), { prefix: "" }), {
    kind: "tagged",
    version: "1.2.3",
  });
  // Only the default prefix can be untagged; it carries the files' version.
  assert.deepEqual(currentVersion(t("release-1"), { fromFiles: "0.4.0" }), {
    kind: "untagged",
    written: "0.4.0",
  });
  assert.deepEqual(currentVersion(t("release-1")), {
    kind: "untagged",
    written: "",
  });
  // The CLI prints the files' version with it.
  const cli = fileURLToPath(new URL("./next-version.mjs", import.meta.url));
  const cur = (...a) =>
    execFileSync("node", [cli, "current", ...a], {
      input: "refs/tags/release-1\n",
      encoding: "utf8",
    }).trim();
  assert.equal(cur("--from-files", "0.4.0"), "untagged 0.4.0");
  assert.equal(cur(), "untagged");
  // The prefix goes after --, like decide; a bad --from-files is a usage
  // error (exit 1), not a policy answer.
  assert.equal(
    execFileSync("node", [cli, "current", "--", "web-v"], {
      input: "refs/tags/web-v0.1.0\nrefs/tags/release-1\n",
      encoding: "utf8",
    }).trim(),
    "tagged 0.1.0",
  );
  const bad = spawnSync("node", [cli, "current", "--from-files", "v1"], {
    input: "",
    encoding: "utf8",
  });
  assert.equal(bad.status, 1);
  // A manual override that bumps from the files says so.
  assert.match(
    decide(["refs/tags/release-1"], {
      mode: "compute",
      channel: "main",
      fromFiles: "2.0.0",
      bump: "minor",
      manual: true,
    }).reason,
    /current: the version the repo writes, 2.0.0/,
  );
});

test("decide: compute mode", () => {
  const t = (...v) => v.map((x) => `refs/tags/${x}`);
  const d = (refs, o) => decide(refs, { mode: "compute", ...o });
  assert.equal(d(t("v0.27.3"), staging).version, "0.27.4");
  assert.equal(d(t("v0.27.3"), main).version, "0.28.0");
  assert.equal(d([], staging).version, "0.0.1");
  assert.match(d([], staging).reason, /^first release/);
  // Files ahead of the tags: exactly the version they announce (they
  // reached the branch through the required check or a bypass), even when
  // check(tag, files) would refuse it; never past it.
  for (const [tag, files, channel, want] of [
    ["v0.28.0", "0.29.0", main, "0.29.0"],
    ["v0.28.0", "0.35.0", main, "0.35.0"],
    ["v0.28.5", "1.0.0", main, "1.0.0"],
    ["v0.28.0", "0.28.2", staging, "0.28.2"],
    ["v0.28.0", "0.28.1", staging, "0.28.1"],
  ]) {
    const r = d(t(tag), { ...channel, fromFiles: files });
    assert.equal(r.version, want, `${tag} + ${files}`);
    assert.match(
      r.reason,
      /the version the repo writes, ahead of the highest tag/,
    );
  }
  // Files at or behind the tags: bump from the highest tag.
  assert.equal(
    d(t("v0.28.0"), { ...main, fromFiles: "0.28.0" }).version,
    "0.29.0",
  );
  assert.equal(
    d(t("v0.28.0"), { ...main, fromFiles: "0.20.0" }).version,
    "0.29.0",
  );
  // No version tag: the files' own version, the release they announce.
  assert.equal(d([], { ...staging, fromFiles: "0.1.0" }).version, "0.1.0");
  assert.equal(d([], { ...staging, fromFiles: "1.4.2" }).version, "1.4.2");
  assert.match(
    d([], { ...staging, fromFiles: "1.4.2" }).reason,
    /no version tag yet/,
  );
  // A 0.0.0 placeholder is no version: a first release.
  assert.equal(d([], { ...staging, fromFiles: "0.0.0" }).version, "0.0.1");
  assert.equal(
    d(t("v0.1.0"), { ...main, fromFiles: "1.4.2" }).version,
    "1.4.2",
  );
  // Untagged: the files' version, or 0.0.1.
  assert.equal(d(t("release-1"), staging).version, "0.0.1");
  assert.equal(
    d(t("release-1"), { ...staging, fromFiles: "2.0.0" }).version,
    "2.0.0",
  );
  // A manual run with an explicit bump overrides the files-ahead rule:
  // it bumps from max(tag, files).
  assert.equal(
    d(t("v0.28.5"), {
      ...main,
      fromFiles: "0.28.6",
      bump: "major",
      manual: true,
    }).version,
    "1.0.0",
  );
  assert.equal(
    d(t("v0.28.5"), {
      ...main,
      fromFiles: "0.28.6",
      bump: "patch",
      manual: true,
    }).version,
    "0.28.7",
  );
  assert.equal(
    d(t("v0.28.5"), {
      ...main,
      fromFiles: "0.20.0",
      bump: "patch",
      manual: true,
    }).version,
    "0.28.6",
  );
  assert.equal(
    d([], { ...main, fromFiles: "1.4.2", bump: "minor", manual: true }).version,
    "1.5.0",
  );
  // A manual run without a bump is no override.
  assert.equal(
    d(t("v0.28.5"), { ...main, fromFiles: "0.28.6", manual: true }).version,
    "0.28.6",
  );
  // A custom prefix ignores the rest.
  assert.equal(d(t("v9.0.0"), { ...main, prefix: "web-v" }).version, "0.1.0");
  // A major only on a manual run.
  assert.throws(() => d(t("v0.27.3"), { ...main, bump: "major" }), /by hand/);
  assert.equal(
    d(t("v0.27.3"), { ...main, bump: "major", manual: true }).version,
    "1.0.0",
  );
  assert.throws(
    () => d([], { channel: "staging", mode: "other" }),
    (e) => e instanceof UsageError && /Unknown mode/.test(e.message),
  );
  // The CLI prints one line.
  const cli = fileURLToPath(new URL("./next-version.mjs", import.meta.url));
  const run = (input, ...a) =>
    execFileSync("node", [cli, "decide", ...a], { input, encoding: "utf8" });
  assert.equal(
    run("refs/tags/v0.1.0\n", "--mode", "compute", "--channel", "staging"),
    "ok 0.1.1 0.1.0 next patch (current: the highest tag v0.1.0)\n",
  );
  assert.equal(
    run("", "--mode", "check", "--channel", "main", "--proposed", "0.1.0"),
    "ok 0.1.0 0.0.0 first release, next minor (current: nothing yet)\n",
  );
  assert.throws(
    () =>
      execFileSync(
        "node",
        [
          cli,
          "decide",
          "--mode",
          "check",
          "--channel",
          "main",
          "--proposed",
          "0.2.0",
        ],
        {
          input: "",
          stdio: "pipe",
        },
      ),
    /Command failed/,
  );
});

test("current: the one current-version rule", () => {
  const cur = (refs, opts) => currentVersion(refs, opts);
  // No tags at all.
  assert.deepEqual(cur([]), { kind: "none" });
  assert.deepEqual(cur(["", ""]), { kind: "none" });
  assert.deepEqual(cur([], { fromFiles: "0.4.0" }), {
    kind: "written",
    version: "0.4.0",
  });
  assert.deepEqual(cur([], { fromFiles: "0.0.0" }), { kind: "none" });
  assert.throws(() => cur([], { fromFiles: "v0.4.0" }), /not a version/);
  // Tags, none a version tag: untagged, whatever the files say.
  for (const tags of [
    ["refs/tags/release-1"],
    ["refs/tags/v1.0.0-rc.1"],
    ["refs/tags/v2024.10.1"],
    ["refs/tags/vNext", "refs/tags/1.2.3"],
    ["refs/tags/pkg@1.0.0"],
  ]) {
    assert.deepEqual(
      cur(tags, { fromFiles: "0.4.0" }),
      { kind: "untagged", written: "0.4.0" },
      tags.join(),
    );
  }
  // Version tags: the highest, whatever else is there.
  assert.deepEqual(cur(["refs/tags/v0.0.0"]), {
    kind: "tagged",
    version: "0.0.0",
  });
  assert.deepEqual(
    cur(
      [
        "refs/tags/release-1",
        "refs/tags/v0.27.3",
        "refs/tags/v0.27.10",
        "refs/tags/v1.0.0-rc.1",
      ],
      { fromFiles: "0.1.0" },
    ),
    { kind: "tagged", version: "0.27.10" },
  );
  // Files ahead of the tags win.
  assert.deepEqual(cur(["refs/tags/v0.27.10"], { fromFiles: "9.0.0" }), {
    kind: "written",
    version: "9.0.0",
    tagged: "0.27.10",
  });
  assert.deepEqual(
    cur(["refs/tags/pkg@1.2.3", "refs/tags/v0.1.0"], { prefix: "pkg@" }),
    {
      kind: "tagged",
      version: "1.2.3",
    },
  );
  // The CLI prints one line.
  const cli = fileURLToPath(new URL("./next-version.mjs", import.meta.url));
  const run = (input, ...a) =>
    execFileSync("node", [cli, "current", ...a], { input, encoding: "utf8" });
  assert.equal(run("refs/tags/v0.1.0\nrefs/tags/x\n"), "tagged 0.1.0\n");
  assert.equal(run("refs/tags/x\n"), "untagged\n");
  assert.equal(run("", "--from-files", "0.2.0"), "written 0.2.0\n");
  assert.equal(run("\n"), "none\n");
});

test("CLI exit codes: 0 an answer, 2 the policy says no, 1 a bad call", () => {
  const cli = fileURLToPath(new URL("./next-version.mjs", import.meta.url));
  const run = (input, ...a) =>
    spawnSync("node", [cli, ...a], { input, encoding: "utf8" });
  let r = run(
    "refs/tags/v0.999.0\n",
    "decide",
    "--mode",
    "compute",
    "--channel",
    "main",
  );
  assert.equal(r.status, 2);
  assert.match(r.stderr, /^(::error::)?policy: Minor bump/);
  r = run(
    "refs/tags/v0.27.3\n",
    "decide",
    "--mode",
    "check",
    "--channel",
    "main",
    "--proposed",
    "0.29.0",
  );
  assert.equal(r.status, 2);
  assert.match(r.stderr, /^(::error::)?policy: Version 0.29.0 is not allowed/);
  for (const bad of [
    ["decide", "--mode", "check", "--channel", "main"],
    ["decide", "--mode", "other", "--channel", "main"],
    ["decide", "--mode", "compute", "--channel", "prod"],
    [
      "decide",
      "--mode",
      "check",
      "--channel",
      "main",
      "--proposed",
      "9.9.9",
      "--from-files",
      "9.9.9",
    ],
    ["decide", "--mode", "compute", "--channel", "--prefix"],
    ["strict", "--version", "--x"],
    ["tags-path", "--repo", "o/r"],
    ["bogus"],
    ["next", "--current", "1.0.0", "--channel", "prod"],
    ["next", "--current", "1.0.0", "--channel", "main", "--bump", "huge"],
    [
      "decide",
      "--mode",
      "compute",
      "--channel",
      "main",
      "--prefix",
      "v",
      "--",
      "w",
    ],
    ["decide", "--mode", "compute", "--channel", "main", "--", "a", "b"],
  ]) {
    r = run("", ...bad);
    assert.equal(r.status, 1, bad.join(" "));
    assert.doesNotMatch(r.stderr, /policy:/, bad.join(" "));
  }
  // A prefix that starts with -- goes after --, for decide as for tags-path.
  r = run(
    "refs/tags/--x0.1.0\nrefs/tags/v9.0.0\n",
    "decide",
    "--mode",
    "compute",
    "--channel",
    "main",
    "--",
    "--x",
  );
  assert.equal(r.status, 0);
  assert.equal(
    r.stdout.trim(),
    "ok 0.2.0 0.1.0 next minor (current: the highest tag --x0.1.0)",
  );
  // A value that starts with -- is never taken as a value.
  r = run("", "next", "--current", "--channel", "main");
  assert.equal(r.status, 1);
  assert.match(r.stderr, /--current needs a value/);
});

test("tags-path: all tags for the default prefix, else the prefix's own", () => {
  const cli = fileURLToPath(new URL("./next-version.mjs", import.meta.url));
  const run = (prefix) =>
    execFileSync("node", [cli, "tags-path", "--repo", "o/r", "--", prefix], {
      encoding: "utf8",
    }).trim();
  const base = "repos/o/r/git/matching-refs/tags";
  assert.equal(run("v"), base);
  assert.equal(run(""), base);
  assert.equal(run("web-v"), `${base}/web-v`);
  // Each segment encoded, slashes kept; a leading - is a prefix, not a flag.
  assert.equal(run("packages/web/v"), `${base}/packages/web/v`);
  assert.equal(run("pkg@"), `${base}/pkg%40`);
  assert.equal(run("a b/c?d"), `${base}/a%20b/c%3Fd`);
  assert.equal(run("-x"), `${base}/-x`);
  assert.equal(run("--x"), `${base}/--x`);
  assert.throws(() =>
    execFileSync("node", [cli, "tags-path", "--repo", "bad", "--", "v"], {
      stdio: "pipe",
    }),
  );
});

test("--manual and --allow-major take exactly true or false", () => {
  const cli = fileURLToPath(new URL("./next-version.mjs", import.meta.url));
  const run = (...a) => spawnSync("node", [cli, ...a], { encoding: "utf8" });
  const major = [
    "next",
    "--current",
    "1.0.0",
    "--channel",
    "main",
    "--bump",
    "major",
  ];
  // Exactly true, or a bare flag: a manual run.
  assert.equal(run(...major, "--manual", "true").stdout.trim(), "2.0.0");
  assert.equal(run(...major, "--manual").stdout.trim(), "2.0.0");
  assert.equal(
    run(
      "next",
      "--manual",
      "--current",
      "1.0.0",
      "--channel",
      "main",
      "--bump",
      "major",
    ).stdout.trim(),
    "2.0.0",
  );
  // Exactly false: not one, so the major is refused.
  assert.match(run(...major, "--manual", "false").stderr, /by hand/);
  // Anything else is refused outright, never read as true.
  for (const bad of ["no", "", "0", "False", "yes", "1"]) {
    const r = run(...major, "--manual", bad);
    assert.notEqual(r.status, 0, bad);
    assert.match(r.stderr, /--manual takes true or false/, bad);
  }
  const check = [
    "check",
    "--current",
    "1.0.0",
    "--proposed",
    "2.0.0",
    "--channel",
    "main",
  ];
  assert.equal(
    run(...check, "--allow-major", "true").stdout.trim(),
    "next major",
  );
  assert.match(
    run(...check, "--allow-major", "no").stderr,
    /--allow-major takes true or false/,
  );
});

test("the CLI prints the version and fails with a message", () => {
  const cli = fileURLToPath(new URL("./next-version.mjs", import.meta.url));
  const run = (...a) =>
    execFileSync("node", [cli, ...a], { encoding: "utf8" }).trim();
  assert.equal(
    run("next", "--current", "1.2.3", "--channel", "staging"),
    "1.2.4",
  );
  assert.equal(
    run(
      "next",
      "--current",
      "1.2.3",
      "--channel",
      "main",
      "--bump",
      "major",
      "--manual",
    ),
    "2.0.0",
  );
  assert.equal(
    run(
      "next",
      "--current",
      "1.2.3",
      "--channel",
      "main",
      "--bump",
      "",
      "--manual",
      "false",
    ),
    "1.3.0",
  );
  assert.equal(
    run(
      "check",
      "--current",
      "1.2.3",
      "--proposed",
      "2.0.0",
      "--channel",
      "main",
      "--bump",
      "major",
      "--allow-major",
      "true",
    ),
    "next major",
  );
  assert.throws(
    () =>
      execFileSync(
        "node",
        [
          cli,
          "next",
          "--current",
          "1.2.3",
          "--channel",
          "main",
          "--bump",
          "major",
          "--manual",
          "false",
        ],
        { stdio: "pipe" },
      ),
    /Command failed/,
  );
  assert.throws(
    () =>
      execFileSync(
        "node",
        [cli, "check", "--current", "0.0.0", "--proposed", "5.0.0"].concat([
          "--channel",
          "main",
        ]),
        { stdio: "pipe" },
      ),
    /Command failed/,
  );
  assert.equal(
    run(
      "check",
      "--current",
      "0.0.0",
      "--proposed",
      "0.1.0",
      "--channel",
      "main",
    ),
    "next minor",
  );
  // count and highest are functions, not CLI commands.
  for (const gone of ["count", "highest"]) {
    assert.throws(
      () => execFileSync("node", [cli, gone], { input: "", stdio: "pipe" }),
      /Command failed/,
    );
  }
  // strict: prints the version, or fails.
  assert.equal(run("strict", "--version", "1.2.3"), "1.2.3");
  for (const bad of ["v1.2.3", "1.2.3-rc.1", "", "--x"]) {
    assert.throws(
      () =>
        execFileSync("node", [cli, "strict", "--version", bad], {
          stdio: "pipe",
        }),
      /Command failed/,
      bad,
    );
  }
  // Run through a symlink, the script still runs its CLI.
  const dir = mkdtempSync(join(tmpdir(), "next-version-"));
  try {
    const link = join(dir, "linked.mjs");
    symlinkSync(cli, link);
    assert.equal(
      execFileSync(
        "node",
        [link, "next", "--current", "1.2.3", "--channel", "main"],
        {
          encoding: "utf8",
        },
      ).trim(),
      "1.3.0",
    );
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
  assert.equal(
    execFileSync("node", [cli, "current"], {
      input: "x\trefs/tags/v1.0.0\ny\trefs/tags/v1.0.10\n",
      encoding: "utf8",
    }).trim(),
    "tagged 1.0.10",
  );
  assert.throws(
    () =>
      execFileSync(
        "node",
        [cli, "next", "--current", "1.999.0", "--channel", "main"],
        {
          stdio: "pipe",
        },
      ),
    /Command failed/,
  );
});
