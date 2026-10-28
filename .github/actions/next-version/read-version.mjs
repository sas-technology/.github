#!/usr/bin/env node
// Read the version a repository writes down, from its version files, and
// decide what release-version-check must do with each
// one. The check is required on every PR, so it FAILS CLOSED: anything it
// cannot read as a version is refused, never skipped.
//
// The entries it knows, each read and judged on its own:
//
//   package.json                  the root "version"
//   Cargo.toml#package            [package] version
//   Cargo.toml#workspace.package  [workspace.package] version
//   pyproject.toml#project        [project] version
//   pyproject.toml#tool.poetry    [tool.poetry] version
//   VERSION                       exactly X.Y.Z, X.Y.Z\n or X.Y.Z\r\n
//                                 (after one leading BOM)
//
// ONE READER PER FORMAT. JSON and TOML are read by Python's standard library
// in one isolated python3 run (`-I`, an empty working directory, no PYTHON*
// variables): json with a hook that refuses a duplicate key at any level,
// and tomllib, the TOML 1.0 that Cargo's toml crate and Poetry read. File
// paths go to it as arguments; a file's text never enters the script. A file
// it cannot decode or parse (bad UTF-8, broken syntax, a duplicate key) makes
// its entries invalid. A missing python3 or tomllib is a hard error, never
// "absent". `version.workspace = true` (inherited) and a pyproject `dynamic`
// version are absent; a version that is not a string is invalid.
//
// ONE VERSION PARSER. Nothing is trimmed and no "v" is stripped: a value is
// a version only if next-version.mjs's isStrictVersion() accepts it
// (MAJOR.MINOR.PATCH, each 0..999), the parser shared with the policy and
// the other checks.
//
// assess() judges every entry at three commits: the merge-base of the PR
// (what the PR started from), the PR head, and the base branch tip (what it
// lands on):
//
//   invalid    the head value is invalid and differs from the merge-base
//   removed    a real version (not 0.0.0) at the merge-base is gone, reset
//              to 0.0.0 or broken at the head. Removing or resetting a
//              version (a version moving into code, say) needs an owner
//              bypass of the check.
//   downgrade  the head is lower than the real merge-base version
//   behind     the PR changes the version, but the base tip already holds
//              a higher one: rebase first, so files and tags agree on merge
//   check      the head is a real version, different from the merge-base
//              (new or changed): the policy decides (next-version.mjs check)
//   (skip)     anything else: unchanged by the PR, or absent / 0.0.0
//
// It also reports `written`: the highest real version at the merge-base
// across all entries, which is the current version of a repo that has no
// version tags yet.
//
// Usage (each prints a header line first, so a caller can tell a real
// answer from an empty one)
//   read-version.mjs files
//     "# read-version files v1", then VERSION_FILES, one per line.
//   read-version.mjs save <path> <out>   (contents-API JSON on stdin)
//     "# read-version save v1", then "file" (the bytes written to <out>) or
//     "not-a-file <type>" (<out>.notfile written: a directory, a symlink).
//   read-version.mjs assess <merge-base-dir> <head-dir> <base-tip-dir>
//     "# read-version assess v2", "written\t<version or ->", then
//     "<entry>\t<action>\t<merge-base>\t<head>\t<tip>" for every entry that
//     is not skipped. A value prints as "-" when absent and "!invalid" when
//     invalid, so PR text never reaches the log.

import { spawnSync } from "node:child_process";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { compare, isMain, isStrictVersion } from "./next-version.mjs";

export const VERSION_FILES = [
  "package.json",
  "Cargo.toml",
  "pyproject.toml",
  "VERSION",
];

/** The entries each file read by python3 holds. */
const STRUCTURED = {
  "package.json": [""],
  "Cargo.toml": ["package", "workspace.package"],
  "pyproject.toml": ["project", "tool.poetry"],
};

const entryName = (file, table) => (table ? `${file}#${table}` : file);

/** Every entry, in the order they are judged and reported. */
export const ENTRIES = [
  ...Object.entries(STRUCTURED).flatMap(([file, tables]) =>
    tables.map((t) => entryName(file, t)),
  ),
  "VERSION",
];

export const FILES_HEADER = "# read-version files v1";
export const ASSESS_HEADER = "# read-version assess v2";

/** A value that cannot be read as a version; `raw` is what it holds. */
export class Invalid {
  constructor(raw) {
    this.raw = String(raw);
  }
}

/**
 * Something at a version file's path that is not a file (a directory, a
 * symlink, a submodule). Every entry of it is invalid, the same on both
 * sides when it is the same kind of thing, so it is only refused when the
 * PR puts it there or changes it.
 */
export class NotAFile {
  constructor(type) {
    this.type = String(type);
  }
}

export const SAVE_HEADER = "# read-version save v1";

/**
 * One contents-API answer (JSON) for `expectedPath`: the file's bytes, or a
 * NotAFile. A directory answers with a list; a symlink with its type, or
 * with the target file under another path, which is not this file either.
 * Throws when a file's content cannot be read (too large, unknown encoding,
 * a size that does not match).
 */
export function fromContents(json, expectedPath) {
  if (Array.isArray(json)) return new NotAFile("dir");
  if (!json || typeof json !== "object") throw new Error("No contents answer.");
  if (json.type !== "file") return new NotAFile(json.type ?? "unknown");
  if (json.path !== expectedPath) return new NotAFile("symlink");
  if (json.encoding !== "base64" || typeof json.content !== "string") {
    throw new Error(`${expectedPath} cannot be read through the contents API.`);
  }
  const bytes = Buffer.from(json.content, "base64");
  if (typeof json.size === "number" && bytes.length !== json.size) {
    throw new Error(`${expectedPath}: the content does not match its size.`);
  }
  return bytes;
}

/**
 * A VERSION file is exactly the version, then nothing, "\n" or "\r\n".
 * Returns the value to classify; anything else (a lone "\r", a second
 * line, spaces) stays in it and makes it invalid.
 */
export function fromVersionFile(text) {
  // One leading byte order mark is not part of it, as for JSON and TOML.
  const v = String(text).replace(/^\uFEFF/, "");
  if (v.endsWith("\r\n")) return v.slice(0, -2);
  if (v.endsWith("\n")) return v.slice(0, -1);
  return v;
}

// Runs in an isolated python3 (-I) with "<file> <path>" argument pairs. For
// each it prints, as JSON, the value of each entry of the file:
// {"kind": "absent"} | {"kind": "string", "value": ...} |
// {"kind": "invalid", "raw": ...}. Exit 3: no tomllib.
const PY = String.raw`
import hashlib, json, sys
try:
    import tomllib
except ImportError:
    sys.stderr.write("python3 has no tomllib (needs Python 3.11 or later)\n")
    sys.exit(3)
STRUCTURED = json.loads(sys.argv[1])
class Obj(dict):
    """A JSON object that remembers every value given for "version"."""
    versions = None
def keep_versions(pairs):
    # JSON.parse keeps the last of a duplicate key, silently. Duplicates are
    # npm's business, except "version": every value is kept, and a root
    # object with more than one is invalid.
    out = Obj()
    out.versions = []
    for k, v in pairs:
        if k == "version":
            out.versions.append(v)
        out[k] = v
    return out
def no_constant(name):
    raise ValueError("not JSON: " + name)
def unreadable(data):
    return {"kind": "invalid", "raw": "unreadable " + hashlib.sha256(data).hexdigest()}
def version_in(node, dotted, project):
    for part in [p for p in dotted.split(".") if p]:
        if not isinstance(node, dict):
            return {"kind": "invalid", "raw": dotted + " is not a table"}
        if part not in node:
            return {"kind": "absent"}
        node = node[part]
    if not isinstance(node, dict):
        return {"kind": "invalid", "raw": (dotted or "the root") + " is not an object"}
    dynamic = node.get("dynamic") if project else None
    is_dynamic = isinstance(dynamic, list) and "version" in dynamic
    if "version" not in node:
        return {"kind": "absent"}
    v = node["version"]
    if is_dynamic:
        return {"kind": "invalid", "raw": "version is both set and dynamic"}
    if isinstance(v, str):
        return {"kind": "string", "value": v}
    if isinstance(v, dict) and list(v) == ["workspace"] and v["workspace"] is True:
        return {"kind": "absent"}
    return {"kind": "invalid", "raw": repr(v)}
out = []
args = sys.argv[2:]
for kind, path in zip(args[0::2], args[1::2]):
    tables = STRUCTURED[kind]
    with open(path, "rb") as f:
        data = f.read()
    try:
        text = data.decode("utf-8")
        # One leading byte order mark is not part of the document.
        if text.startswith("\ufeff"):
            text = text[1:]
        if kind == "package.json":
            doc = json.loads(text, object_pairs_hook=keep_versions, parse_constant=no_constant)
        else:
            doc = tomllib.loads(text)
        if kind == "package.json" and isinstance(doc, Obj) and len(doc.versions) > 1:
            # Compared by the values, so a change to any of them is a change.
            entries = {"": {"kind": "invalid", "raw": "duplicate version " + json.dumps(doc.versions)}}
        else:
            # Inside the try: repr() or json.dumps() of a deep value can
            # raise RecursionError too.
            entries = {t: version_in(doc, t, kind == "pyproject.toml" and t == "project") for t in tables}
            json.dumps(entries)
    except (UnicodeDecodeError, ValueError, RecursionError, tomllib.TOMLDecodeError):
        entries = {t: unreadable(data) for t in tables}
    out.append(entries)
print(json.dumps(out))
`;

/** process.env without PYTHON* variables. */
function pythonEnv() {
  return Object.fromEntries(
    Object.entries(process.env).filter(([k]) => !k.startsWith("PYTHON")),
  );
}

/**
 * Read package.json, Cargo.toml and pyproject.toml texts, all in one
 * isolated python3 run.
 * @param {{file: string, data: string|Buffer}[]} items
 * @returns {Record<string, string|Invalid|null>[]}  per item, the value of
 *   each of its entries (null = absent)
 */
export function readStructured(items) {
  if (items.length === 0) return [];
  const root = mkdtempSync(join(tmpdir(), "read-version-"));
  try {
    const files = join(root, "files");
    const cwd = join(root, "cwd"); // empty: nothing to import from
    mkdirSync(files);
    mkdirSync(cwd);
    const args = [];
    items.forEach((it, i) => {
      const path = join(files, String(i));
      writeFileSync(path, it.data);
      args.push(it.file, path);
    });
    const r = spawnSync(
      "python3",
      ["-I", "-c", PY, JSON.stringify(STRUCTURED), ...args],
      {
        cwd,
        env: pythonEnv(),
        encoding: "utf8",
        maxBuffer: 64 * 1024 * 1024,
      },
    );
    if (r.error) {
      throw new Error(
        `Cannot run python3 to read the files: ${r.error.message}`,
      );
    }
    if (r.status !== 0) {
      throw new Error(`python3 could not read the files: ${r.stderr.trim()}`);
    }
    const out = JSON.parse(r.stdout);
    if (!Array.isArray(out) || out.length !== items.length) {
      throw new Error("python3 gave no answer for every file.");
    }
    return out.map((res, i) => {
      const values = {};
      for (const t of STRUCTURED[items[i].file]) {
        const e = res[t];
        const name = entryName(items[i].file, t);
        if (!e || typeof e !== "object")
          throw new Error(`No answer for ${name}.`);
        if (e.kind === "absent") values[name] = null;
        else if (e.kind === "string") values[name] = e.value;
        else if (e.kind === "invalid") values[name] = new Invalid(e.raw);
        else throw new Error(`Unknown answer for ${name}.`);
      }
      return values;
    });
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

/**
 * Sort a value: { kind: "absent" }, { kind: "valid", version } or
 * { kind: "invalid", raw }.
 */
export function classify(value) {
  if (value == null) return { kind: "absent" };
  if (value instanceof Invalid) return { kind: "invalid", raw: value.raw };
  if (isStrictVersion(value)) return { kind: "valid", version: value };
  return { kind: "invalid", raw: String(value) };
}

/**
 * Every entry, classified, for each file set in `sets` (one python3 run for
 * all of them). A missing text is a missing file: its entries are absent.
 * @param {Record<string, string|Buffer|null|undefined>[]} sets
 */
export function classifySets(sets) {
  const items = [];
  sets.forEach((files, s) => {
    for (const file of Object.keys(STRUCTURED)) {
      const data = files?.[file];
      if (data != null && !(data instanceof NotAFile)) {
        items.push({ s, file, data });
      }
    }
  });
  const read = readStructured(items);
  return sets.map((files, s) => {
    const values = {};
    for (const file of VERSION_FILES) {
      const data = files?.[file];
      if (!(data instanceof NotAFile)) continue;
      const names = file in STRUCTURED ? STRUCTURED[file] : [""];
      for (const t of names) {
        values[entryName(file, t)] = new Invalid(`not a file: ${data.type}`);
      }
    }
    if (files?.VERSION != null && !(files.VERSION instanceof NotAFile)) {
      values.VERSION = fromVersionFile(files.VERSION);
    }
    items.forEach((it, i) => {
      if (it.s === s) Object.assign(values, read[i]);
    });
    const out = {};
    for (const e of ENTRIES) out[e] = classify(values[e] ?? null);
    return out;
  });
}

/** Every entry of one file set, classified. */
export function classifyFiles(files) {
  return classifySets([files])[0];
}

/** 0.0.0 marks a file that is not the repo's version. */
export function isPlaceholder(c) {
  return c.kind === "valid" && c.version === "0.0.0";
}

const isReal = (c) => c.kind === "valid" && !isPlaceholder(c);

const same = (a, b) =>
  a.kind === b.kind &&
  (a.kind === "absent" ||
    (a.kind === "valid" ? a.version === b.version : a.raw === b.raw));

const ABSENT = { kind: "absent" };

/**
 * What to do with each entry, from the merge-base, head and base tip
 * already classified. Only entries that are not skipped are returned.
 */
export function judge(base, head, tip = {}) {
  const out = [];
  for (const entry of ENTRIES) {
    const b = base[entry] ?? ABSENT;
    const h = head[entry] ?? ABSENT;
    const t = tip[entry] ?? ABSENT;
    let action = null;
    if (same(b, h)) action = null;
    else if (h.kind === "invalid") action = "invalid";
    else if (isReal(b) && !isReal(h)) action = "removed";
    else if (!isReal(h)) action = null;
    else if (isReal(b) && compare(h.version, b.version) < 0) {
      action = "downgrade";
    } else if (isReal(t) && compare(t.version, h.version) > 0) {
      action = "behind";
    } else action = "check";
    if (action) out.push({ entry, action, base: b, head: h, tip: t });
  }
  return out;
}

/** The highest real version written in any entry, or null. */
export function written(classified) {
  let best = null;
  for (const c of Object.values(classified)) {
    if (isReal(c) && (best === null || compare(c.version, best) > 0)) {
      best = c.version;
    }
  }
  return best;
}

/**
 * Judge a PR: its merge-base, head and base tip file sets.
 * @returns {{written: string|null, actions: object[]}}
 */
export function assess(baseFiles, headFiles, tipFiles = baseFiles) {
  const [base, head, tip] = classifySets([baseFiles, headFiles, tipFiles]);
  return { written: written(base), actions: judge(base, head, tip) };
}

/**
 * How a classified value prints: "-", "!invalid" or the version. Only a
 * strict version is ever printed, so PR text never reaches the log.
 */
export function show(c) {
  if (c.kind === "absent") return "-";
  return c.kind === "valid" ? c.version : "!invalid";
}

function readDir(dir) {
  const files = {};
  for (const name of VERSION_FILES) {
    const path = join(dir, name);
    // `save` leaves <file>.notfile for something that is not a file.
    if (existsSync(`${path}.notfile`)) {
      files[name] = new NotAFile(readFileSync(`${path}.notfile`, "utf8"));
    } else if (existsSync(path)) {
      // Bytes, so python3 judges the file exactly as written.
      files[name] =
        name === "VERSION" ? readFileSync(path, "utf8") : readFileSync(path);
    }
  }
  return files;
}

function main(argv) {
  const [cmd, baseDir, headDir, tipDir] = argv;
  if (cmd === "files") return [FILES_HEADER, ...VERSION_FILES].join("\n");
  if (cmd === "save" && baseDir && headDir) {
    // save <path in the repo> <out file>, the contents-API JSON on stdin.
    const got = fromContents(JSON.parse(readFileSync(0, "utf8")), baseDir);
    if (got instanceof NotAFile) {
      writeFileSync(`${headDir}.notfile`, got.type);
      return `${SAVE_HEADER}\nnot-a-file ${got.type}`;
    }
    writeFileSync(headDir, got);
    return `${SAVE_HEADER}\nfile`;
  }
  if (cmd === "assess" && baseDir && headDir && tipDir) {
    const r = assess(readDir(baseDir), readDir(headDir), readDir(tipDir));
    const lines = r.actions.map((a) =>
      [a.entry, a.action, show(a.base), show(a.head), show(a.tip)].join("\t"),
    );
    return [ASSESS_HEADER, `written\t${r.written ?? "-"}`, ...lines].join("\n");
  }
  throw new Error(
    "Usage: read-version.mjs files | save <path> <out> | assess <merge-base-dir> <head-dir> <base-tip-dir>",
  );
}

if (isMain(import.meta.url)) {
  try {
    console.log(main(process.argv.slice(2)));
  } catch (err) {
    console.error(err.message);
    process.exit(1);
  }
}
