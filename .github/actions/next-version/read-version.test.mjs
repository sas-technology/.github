// node --test .github/actions/next-version/   (needs python3 >= 3.11)
import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import {
  chmodSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";

import {
  ASSESS_HEADER,
  ENTRIES,
  FILES_HEADER,
  Invalid,
  NotAFile,
  SAVE_HEADER,
  VERSION_FILES,
  assess,
  classify,
  classifyFiles,
  fromContents,
  fromVersionFile,
  isPlaceholder,
  judge,
  written,
} from "./read-version.mjs";

const CLI = fileURLToPath(new URL("./read-version.mjs", import.meta.url));
const pj = (text) => classifyFiles({ "package.json": text })["package.json"];
const cargo = (text) => classifyFiles({ "Cargo.toml": text });
const py = (text) => classifyFiles({ "pyproject.toml": text });
const valid = (version) => ({ kind: "valid", version });
const ABSENT = { kind: "absent" };
const kind = (c) => c.kind;

test("package.json: the root version only, read by python's json", () => {
  assert.deepEqual(pj('{"name":"a","version":"1.2.3"}'), valid("1.2.3"));
  assert.deepEqual(
    pj(
      JSON.stringify({
        name: "a",
        dependencies: { b: "2.0.0" },
        workspaces: { version: "9.9.9" },
      }),
    ),
    ABSENT,
  );
  assert.deepEqual(pj('{"private":true}'), ABSENT);
  assert.deepEqual(pj('\uFEFF{"version":"1.0.1"}'), valid("1.0.1"));
  // Nothing is trimmed, and anything that is not a version is invalid.
  for (const bad of [
    '{"version": "  0.4.0 "}',
    '{"version": ""}',
    '{"version": 28}',
    '{"version": null}',
    '{"version": NaN}',
    "[]",
    "null",
    "{ not json",
    "",
  ]) {
    assert.equal(kind(pj(bad)), "invalid", bad);
  }
  // Nesting too deep for python (RecursionError) is invalid, not a crash.
  const deep = `{"version":"1.0.0","x":${"[".repeat(100000)}${"]".repeat(100000)}}`;
  assert.equal(kind(pj(deep)), "invalid");
  assert.equal(
    kind(
      cargo(
        `[package]\nversion = "1.0.0"\nx = ${"[".repeat(100000)}${"]".repeat(100000)}\n`,
      )["Cargo.toml#package"],
    ),
    "invalid",
  );
  // Bad UTF-8 is invalid, not a crash.
  assert.equal(kind(pj(Buffer.from([0x7b, 0xff, 0x7d]))), "invalid");
});

test("package.json: only a duplicate root version is invalid", () => {
  assert.equal(kind(pj('{"version":"1.0.0","version":"2.0.0"}')), "invalid");
  assert.equal(
    kind(pj('{"\\u0076ersion":"1.0.0","version":"1.0.0"}')),
    "invalid",
  );
  // Other duplicates are npm's business, not this check's.
  assert.deepEqual(
    pj('{"name":"a","name":"b","version":"1.0.0"}'),
    valid("1.0.0"),
  );
  assert.deepEqual(pj('{"version":"1.0.0","a":{"b":1,"b":2}}'), valid("1.0.0"));
  assert.deepEqual(
    pj('{"a":{"version":"1","version":"2"},"version":"1.0.0"}'),
    valid("1.0.0"),
  );
  // Nested or quoted "version" text is not a root key.
  assert.deepEqual(
    pj(
      '{"a":{"version":"9.9.9"},"b":"\\"version\\"","c":["version"],"version":"1.0.0"}',
    ),
    valid("1.0.0"),
  );
  // Entries compare by their parsed values: an unrelated edit is no change,
  // a change to either duplicate is one.
  const pkg = (extra) => `{"name":"a"${extra},"version":"1.0.0"}`;
  assert.deepEqual(
    assess({ "package.json": pkg("") }, { "package.json": pkg(',"x":1') })
      .actions,
    [],
  );
  const dup = (a, b) => `{"version":"${a}","x":1,"version":"${b}"}`;
  assert.deepEqual(
    assess(
      { "package.json": dup("1.0.0", "1.0.1") },
      {
        "package.json": dup("1.0.0", "1.0.1").replace('"x":1', '"x":2'),
      },
    ).actions,
    [],
  );
  assert.deepEqual(
    assess(
      { "package.json": dup("1.0.0", "1.0.1") },
      { "package.json": dup("1.0.0", "1.0.2") },
    ).actions.map((x) => x.action),
    ["invalid"],
  );
  // A broken file has no readable version: it is fingerprinted.
  assert.notDeepEqual(pj("{ broken"), pj("{ broken too"));
});

test("a leading BOM is stripped before tomllib too", () => {
  const bom = "\uFEFF";
  assert.deepEqual(
    cargo(`${bom}[package]\nversion = "0.2.0"\n`)["Cargo.toml#package"],
    valid("0.2.0"),
  );
  assert.deepEqual(
    py(`${bom}[project]\nversion = "0.3.0"\n`)["pyproject.toml#project"],
    valid("0.3.0"),
  );
  // Only one.
  assert.equal(
    kind(
      cargo(`${bom}${bom}[package]\nversion = "0.2.0"\n`)["Cargo.toml#package"],
    ),
    "invalid",
  );
});

test("contents answers: a file, or not a file", () => {
  const file = (path, text, extra = {}) => ({
    type: "file",
    path,
    encoding: "base64",
    content: Buffer.from(text).toString("base64"),
    size: Buffer.byteLength(text),
    ...extra,
  });
  assert.equal(
    fromContents(file("VERSION", "1.2.3\n"), "VERSION").toString(),
    "1.2.3\n",
  );
  assert.ok(fromContents([{ type: "file" }], "VERSION") instanceof NotAFile);
  assert.equal(
    fromContents({ type: "symlink", path: "VERSION" }, "VERSION").type,
    "symlink",
  );
  assert.equal(
    fromContents({ type: "submodule", path: "VERSION" }, "VERSION").type,
    "submodule",
  );
  // A symlink the API follows answers with its target's path.
  assert.equal(
    fromContents(file("other/VERSION", "1.2.3"), "VERSION").type,
    "symlink",
  );
  assert.throws(() =>
    fromContents(file("VERSION", "1.2.3", { size: 99 }), "VERSION"),
  );
  assert.throws(() =>
    fromContents(
      { type: "file", path: "VERSION", encoding: "none", content: "" },
      "VERSION",
    ),
  );
  assert.throws(() => fromContents(null, "VERSION"));
  // Not a file: invalid, the same on both sides when unchanged.
  const dir = new NotAFile("dir");
  assert.equal(classifyFiles({ VERSION: dir }).VERSION.kind, "invalid");
  assert.equal(
    classifyFiles({ "Cargo.toml": dir })["Cargo.toml#package"].kind,
    "invalid",
  );
  assert.deepEqual(
    assess({ VERSION: dir }, { VERSION: new NotAFile("dir") }).actions,
    [],
  );
  assert.deepEqual(
    assess({}, { VERSION: dir }).actions.map((x) => x.action),
    ["invalid"],
  );
  assert.deepEqual(
    assess({ VERSION: "1.0.0" }, { VERSION: dir }).actions.map((x) => x.action),
    ["invalid"],
  );
});

test("VERSION: the version, then at most one line ending", () => {
  assert.equal(fromVersionFile("1.2.3"), "1.2.3");
  assert.equal(fromVersionFile("1.2.3\n"), "1.2.3");
  assert.equal(fromVersionFile("1.2.3\r\n"), "1.2.3");
  assert.equal(fromVersionFile("  1.2.3  \r\n"), "  1.2.3  ");
  assert.equal(fromVersionFile("v0.4.0\n"), "v0.4.0");
  assert.equal(fromVersionFile("1.2.3\n\n"), "1.2.3\n");
  // Exactly X.Y.Z, X.Y.Z\n or X.Y.Z\r\n: a lone \r stays and is invalid.
  assert.equal(fromVersionFile("1.2.3\r"), "1.2.3\r");
  // One leading BOM is stripped, as for JSON and TOML; only one.
  assert.equal(fromVersionFile("\uFEFF1.2.3\n"), "1.2.3");
  assert.equal(classify(fromVersionFile("\uFEFF\uFEFF1.2.3")).kind, "invalid");
  assert.equal(fromVersionFile("1.2.3\n\r\n"), "1.2.3\n");
  for (const t of [
    "v0.4.0\n",
    "1.2.3\n\n",
    "\n1.0.0\n",
    "",
    " 1.2.3\n",
    "1.2.3\r",
    "1.2.3\r\r\n",
    "1.2.3\n\r\n",
  ]) {
    assert.equal(classify(fromVersionFile(t)).kind, "invalid", t);
  }
});

test("TOML is read by tomllib, one entry per table", () => {
  assert.deepEqual(ENTRIES, [
    "package.json",
    "Cargo.toml#package",
    "Cargo.toml#workspace.package",
    "pyproject.toml#project",
    "pyproject.toml#tool.poetry",
    "VERSION",
  ]);
  const c = cargo(
    '[package]\nversion = "0.31.4"  # c\n\n[dependencies]\nserde = { version = "1.0" }\n' +
      '[dependencies.tokio]\nversion = "1.40.0"\n[workspace.dependencies.x]\nversion = "9.9.9"\n',
  );
  assert.deepEqual(c["Cargo.toml#package"], valid("0.31.4"));
  assert.deepEqual(c["Cargo.toml#workspace.package"], ABSENT);
  // Both tables, each its own entry.
  const both = cargo(
    '[package]\nversion = "1.0.0"\n[workspace.package]\nversion = "1.1.0"\n',
  );
  assert.deepEqual(both["Cargo.toml#package"], valid("1.0.0"));
  assert.deepEqual(both["Cargo.toml#workspace.package"], valid("1.1.0"));
  const p = py(
    '[project]\nname = "n"\nversion = "0.5.2"\n[tool.poetry]\nversion = "0.6.0"\n',
  );
  assert.deepEqual(p["pyproject.toml#project"], valid("0.5.2"));
  assert.deepEqual(p["pyproject.toml#tool.poetry"], valid("0.6.0"));
});

test("TOML: inherited, dynamic, non-string and broken", () => {
  assert.deepEqual(
    cargo("[package]\nversion.workspace = true\n")["Cargo.toml#package"],
    ABSENT,
  );
  assert.deepEqual(
    cargo("[package]\nversion = { workspace = true }\n")["Cargo.toml#package"],
    ABSENT,
  );
  assert.equal(
    kind(
      cargo("[package]\nversion = { workspace = 1 }\n")["Cargo.toml#package"],
    ),
    "invalid",
  );
  assert.equal(
    kind(cargo("[package]\nversion = 1\n")["Cargo.toml#package"]),
    "invalid",
  );
  assert.equal(kind(cargo("package = 1\n")["Cargo.toml#package"]), "invalid");
  assert.deepEqual(
    py('[project]\nname = "x"\ndynamic = ["version"]\n')[
      "pyproject.toml#project"
    ],
    ABSENT,
  );
  assert.equal(
    kind(
      py('[project]\ndynamic = ["version"]\nversion = "1.0.0"\n')[
        "pyproject.toml#project"
      ],
    ),
    "invalid",
  );
  assert.equal(
    kind(py("[project]\nversion = [1, 2]\n")["pyproject.toml#project"]),
    "invalid",
  );
  // A file tomllib refuses makes every entry of it invalid.
  for (const broken of [
    '[package]\nversion = "1.0.0"\nversion = "1.0.1"\n',
    '[package]\nversion = "1.0.0"\n"version" = "1.0.0"\n',
    'package.version = "1.0.0"\n[package]\nname = "x"\n',
    "[package\n",
  ]) {
    const c = cargo(broken);
    assert.equal(kind(c["Cargo.toml#package"]), "invalid", broken);
    assert.equal(kind(c["Cargo.toml#workspace.package"]), "invalid", broken);
  }
});

test("TOML: the shapes a hand-written reader got wrong", () => {
  const pkg = (t) => cargo(t)["Cargo.toml#package"];
  const ws = (t) => cargo(t)["Cargo.toml#workspace.package"];
  // A literal ''' in a string or a comment.
  assert.deepEqual(
    pkg("[package]\ndescription = \"it's '''here'''\"\nversion = \"0.2.0\"\n"),
    valid("0.2.0"),
  );
  assert.deepEqual(
    pkg("[package]\n# a ''' comment\nversion = \"0.2.0\"\n"),
    valid("0.2.0"),
  );
  // Escaped keys and headers.
  assert.deepEqual(
    pkg('["pack\\u0061ge"]\n"vers\\u0069on" = "0.3.0"\n'),
    valid("0.3.0"),
  );
  assert.deepEqual(pkg("[ 'package' ]\n'version' = '0.3.1'\n"), valid("0.3.1"));
  // An array element that looks like a header.
  assert.deepEqual(
    pkg(
      '[package]\nkeywords = [\n"x",\n]\n[other]\nv = [\n["package"],\n]\nversion = "9.0.0"\n',
    ),
    ABSENT,
  );
  assert.deepEqual(
    pkg('[package]\nversion = "0.4.0"\nkw = [\n"[workspace.package]",\n]\n'),
    valid("0.4.0"),
  );
  // Inline tables, and prefix inline tables.
  assert.deepEqual(pkg('package = { version = "0.5.0" }\n'), valid("0.5.0"));
  assert.deepEqual(
    ws('workspace = { package = { version = "0.6.0" } }\n'),
    valid("0.6.0"),
  );
  assert.deepEqual(
    py('tool = { poetry = { version = "0.7.0" } }\n')[
      "pyproject.toml#tool.poetry"
    ],
    valid("0.7.0"),
  );
  assert.deepEqual(
    py('project = { name = "x", version = "0.7.1" }\n')[
      "pyproject.toml#project"
    ],
    valid("0.7.1"),
  );
  // A root dotted key.
  assert.deepEqual(pkg('package.version = "0.8.0"\n'), valid("0.8.0"));
  assert.deepEqual(
    ws('[workspace]\npackage.version = "0.8.1"\n'),
    valid("0.8.1"),
  );
});

test("classify: absent, valid or invalid", () => {
  assert.deepEqual(classify(null), ABSENT);
  assert.deepEqual(classify("1.2.3"), valid("1.2.3"));
  assert.deepEqual(classify("1.2.3-rc.1"), {
    kind: "invalid",
    raw: "1.2.3-rc.1",
  });
  assert.deepEqual(classify("banana"), { kind: "invalid", raw: "banana" });
  assert.deepEqual(classify(""), { kind: "invalid", raw: "" });
  assert.deepEqual(classify(new Invalid("28")), { kind: "invalid", raw: "28" });
  assert.ok(isPlaceholder(valid("0.0.0")));
  assert.ok(!isPlaceholder(valid("0.0.1")));
  assert.ok(!isPlaceholder(ABSENT));
});

test("assess: the rules, entry by entry", () => {
  const pkg = (v) => JSON.stringify({ private: true, version: v });
  const ct = (v) => `[package]\nversion = "${v}"\n`;
  const actions = (b, h, t = b) =>
    assess(b, h, t).actions.map((a) => `${a.entry}:${a.action}`);

  // Nothing changes: nothing to do, even for an odd value.
  assert.deepEqual(actions({ VERSION: "banana" }, { VERSION: "banana" }), []);
  assert.deepEqual(actions({}, {}), []);
  // A changed or new version is checked.
  assert.deepEqual(
    actions({ "Cargo.toml": ct("0.4.0") }, { "Cargo.toml": ct("0.5.0") }),
    ["Cargo.toml#package:check"],
  );
  assert.deepEqual(actions({}, { VERSION: "0.1.0" }), ["VERSION:check"]);
  assert.deepEqual(
    actions(
      { "package.json": pkg("0.4.0") },
      { "package.json": pkg("0.4.0"), "Cargo.toml": ct("9.0.0") },
    ),
    ["Cargo.toml#package:check"],
  );
  // Both tables present, only the second bumped.
  const two = (a, b) =>
    `[package]\nversion = "${a}"\n[workspace.package]\nversion = "${b}"\n`;
  assert.deepEqual(
    actions(
      { "Cargo.toml": two("1.0.0", "1.0.0") },
      { "Cargo.toml": two("1.0.0", "1.1.0") },
    ),
    ["Cargo.toml#workspace.package:check"],
  );
  // 0.0.0 is a placeholder: never checked.
  assert.deepEqual(
    actions(
      { "Cargo.toml": ct("0.4.0") },
      { "Cargo.toml": ct("0.4.0"), "package.json": pkg("0.0.0") },
    ),
    [],
  );
  assert.deepEqual(
    actions({ "package.json": pkg("0.0.0") }, { "package.json": pkg("0.5.0") }),
    ["package.json:check"],
  );
  // Invalid heads are refused.
  assert.deepEqual(
    actions(
      { "package.json": pkg("1.0.0") },
      { "package.json": '{"version":28}' },
    ),
    ["package.json:invalid"],
  );
  assert.deepEqual(actions({}, { VERSION: "banana\n" }), ["VERSION:invalid"]);
  assert.deepEqual(
    actions(
      { "Cargo.toml": ct("1.0.0") },
      { "Cargo.toml": ct("1.0.0") + 'version = "1.0.1"\n' },
    ),
    ["Cargo.toml#package:invalid", "Cargo.toml#workspace.package:invalid"],
  );
  // Removing or resetting a real version is refused.
  assert.deepEqual(actions({ VERSION: "1.0.0" }, {}), ["VERSION:removed"]);
  assert.deepEqual(
    actions({ "package.json": pkg("1.0.0") }, { "package.json": pkg("0.0.0") }),
    ["package.json:removed"],
  );
  assert.deepEqual(
    actions(
      { "pyproject.toml": '[project]\nversion = "1.0.0"\n' },
      { "pyproject.toml": '[project]\ndynamic = ["version"]\n' },
    ),
    ["pyproject.toml#project:removed"],
  );
  assert.deepEqual(
    actions(
      { "Cargo.toml": ct("1.0.0") },
      { "Cargo.toml": "[package]\nversion.workspace = true\n" },
    ),
    ["Cargo.toml#package:removed"],
  );
  // A placeholder going away is not a removal.
  assert.deepEqual(actions({ "package.json": pkg("0.0.0") }, {}), []);
  // A lower version than the merge-base is a downgrade.
  assert.deepEqual(actions({ VERSION: "0.27.4" }, { VERSION: "0.27.3" }), [
    "VERSION:downgrade",
  ]);
  // Judged against the merge-base: a bump that landed on the base tip after
  // the PR branched is not the PR's downgrade or removal.
  assert.deepEqual(
    actions(
      { VERSION: "0.27.3" },
      { VERSION: "0.27.3" },
      { VERSION: "0.27.4" },
    ),
    [],
  );
  assert.deepEqual(
    actions({ VERSION: "0.27.3" }, { VERSION: "0.27.3" }, {}),
    [],
  );
  // But a PR that changes the version while the tip is higher must rebase.
  assert.deepEqual(
    actions(
      { VERSION: "0.27.3" },
      { VERSION: "0.27.4" },
      { VERSION: "0.27.5" },
    ),
    ["VERSION:behind"],
  );
  assert.deepEqual(
    actions(
      { VERSION: "0.27.3" },
      { VERSION: "0.27.4" },
      { VERSION: "0.27.4" },
    ),
    ["VERSION:check"],
  );
});

test("written: the highest real version at the merge-base", () => {
  const c = (files) => classifyFiles(files);
  assert.equal(written(c({})), null);
  assert.equal(written(c({ VERSION: "0.0.0" })), null);
  assert.equal(
    written(
      c({
        VERSION: "0.3.0",
        "Cargo.toml": '[package]\nversion = "0.4.0"\n',
        "package.json": '{"version":"banana"}',
      }),
    ),
    "0.4.0",
  );
  assert.equal(assess({ VERSION: "1.2.3" }, {}).written, "1.2.3");
  assert.deepEqual(judge({}, {}), []);
});

test("the CLI prints a header, then its answer", () => {
  const root = mkdtempSync(join(tmpdir(), "read-version-"));
  const base = join(root, "base");
  const head = join(root, "head");
  const tip = join(root, "tip");
  try {
    for (const d of [base, head, tip]) mkdirSync(d);
    const run = (...a) =>
      execFileSync("node", [CLI, ...a], { encoding: "utf8" }).trimEnd();
    const assessed = () => run("assess", base, head, tip);
    assert.equal(run("files"), [FILES_HEADER, ...VERSION_FILES].join("\n"));
    assert.equal(assessed(), `${ASSESS_HEADER}\nwritten\t-`);
    writeFileSync(join(head, "VERSION"), "0.2.0\n");
    assert.equal(
      assessed(),
      `${ASSESS_HEADER}\nwritten\t-\nVERSION\tcheck\t-\t0.2.0\t-`,
    );
    writeFileSync(join(base, "VERSION"), "0.3.0\n");
    writeFileSync(join(tip, "VERSION"), "0.3.1\n");
    assert.equal(
      assessed(),
      `${ASSESS_HEADER}\nwritten\t0.3.0\nVERSION\tdowngrade\t0.3.0\t0.2.0\t0.3.1`,
    );
    // PR text that is not a version is never printed raw.
    writeFileSync(
      join(head, "package.json"),
      JSON.stringify({ version: "1.0.0\n::warning::x" }),
    );
    assert.equal(
      assessed(),
      `${ASSESS_HEADER}\nwritten\t0.3.0\npackage.json\tinvalid\t-\t!invalid\t-\nVERSION\tdowngrade\t0.3.0\t0.2.0\t0.3.1`,
    );
    // save: a file's bytes, or a .notfile marker.
    const json = (o) => JSON.stringify(o);
    const save = (path, out, answer) =>
      execFileSync("node", [CLI, "save", path, out], {
        input: json(answer),
        encoding: "utf8",
      }).trimEnd();
    const out1 = join(root, "saved");
    assert.equal(
      save("VERSION", out1, {
        type: "file",
        path: "VERSION",
        encoding: "base64",
        content: Buffer.from("4.5.6\n").toString("base64"),
        size: 6,
      }),
      `${SAVE_HEADER}\nfile`,
    );
    assert.equal(readFileSync(out1, "utf8"), "4.5.6\n");
    const out2 = join(root, "dir");
    assert.equal(save("VERSION", out2, []), `${SAVE_HEADER}\nnot-a-file dir`);
    assert.equal(readFileSync(`${out2}.notfile`, "utf8"), "dir");
    assert.throws(() => execFileSync("node", [CLI], { stdio: "pipe" }));
    assert.throws(() =>
      execFileSync("node", [CLI, "assess", base, head], { stdio: "pipe" }),
    );
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("no python3 or no tomllib is a hard error, not absent", () => {
  const root = mkdtempSync(join(tmpdir(), "read-version-py-"));
  try {
    const bin = join(root, "bin");
    mkdirSync(bin);
    mkdirSync(join(root, "b"));
    mkdirSync(join(root, "h"));
    writeFileSync(
      join(root, "h", "Cargo.toml"),
      '[package]\nversion = "1.0.0"\n',
    );
    const run = (path) =>
      spawnSync(
        process.execPath,
        [CLI, "assess", join(root, "b"), join(root, "h"), join(root, "b")],
        {
          encoding: "utf8",
          env: { ...process.env, PATH: path },
        },
      );
    // No python3 at all.
    let r = run(bin);
    assert.notEqual(r.status, 0);
    assert.match(r.stderr, /python3/);
    // A python3 without tomllib.
    writeFileSync(
      join(bin, "python3"),
      '#!/bin/sh\necho "python3 has no tomllib (needs Python 3.11 or later)" >&2\nexit 3\n',
    );
    chmodSync(join(bin, "python3"), 0o755);
    r = run(bin);
    assert.notEqual(r.status, 0);
    assert.match(r.stderr, /tomllib/);
    // python3 runs isolated: PYTHON* variables do not reach it.
    writeFileSync(
      join(bin, "python3"),
      '#!/bin/sh\nenv | grep -q "^PYTHON" && { echo "PYTHON leaked" >&2; exit 9; }\n' +
        'case "$1" in -I) ;; *) echo "not isolated" >&2; exit 9;; esac\n' +
        '[ -z "$(ls -A .)" ] || { echo "cwd not empty" >&2; exit 9; }\nexit 4\n',
    );
    r = spawnSync(
      process.execPath,
      [CLI, "assess", join(root, "b"), join(root, "h"), join(root, "b")],
      {
        encoding: "utf8",
        env: {
          ...process.env,
          PATH: bin,
          PYTHONPATH: "/x",
          PYTHONSTARTUP: "/y",
        },
      },
    );
    assert.notEqual(r.status, 0);
    assert.doesNotMatch(r.stderr, /PYTHON leaked|not isolated|cwd not empty/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
