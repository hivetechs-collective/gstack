#!/usr/bin/env tsx
/**
 * plan-w-team-import-coupling.test.ts
 *
 * Fixture-based tests for the import-coupling analyzer.
 * Builds tiny TS projects in os.tmpdir(), spawns the analyzer as a child
 * process (cwd = fixture root), and asserts on the resulting JSON report.
 *
 * Run via: npx tsx .claude/scripts/plan-w-team-import-coupling.test.ts
 */
import { spawnSync } from "node:child_process";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import * as assert from "node:assert/strict";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const SCRIPT = path.resolve(__dirname, "plan-w-team-import-coupling.ts");

interface Fixture {
  name: string;
  files: Record<string, string>;
  tasks: { id: string; files_touched: string[] }[];
}

interface RunResult {
  code: number;
  stdout: string;
  stderr: string;
  report: unknown;
}

function buildFixture(fx: Fixture): string {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), `coupling-${fx.name}-`));
  for (const [rel, content] of Object.entries(fx.files)) {
    const abs = path.join(root, rel);
    fs.mkdirSync(path.dirname(abs), { recursive: true });
    fs.writeFileSync(abs, content);
  }
  fs.mkdirSync(path.join(root, ".claude/state"), { recursive: true });
  fs.writeFileSync(path.join(root, ".tasks.json"), JSON.stringify(fx.tasks));
  return root;
}

function run(root: string, args: string[]): RunResult {
  const res = spawnSync("npx", ["tsx", SCRIPT, ...args], {
    cwd: root,
    encoding: "utf8",
  });
  const slugIdx = args.indexOf("--slug");
  const slug = slugIdx >= 0 ? args[slugIdx + 1] : "";
  const reportPath = path.join(
    root,
    ".claude/state",
    `plan-w-team-coupling-${slug}.json`,
  );
  const report = fs.existsSync(reportPath)
    ? JSON.parse(fs.readFileSync(reportPath, "utf8"))
    : null;
  return {
    code: res.status ?? -1,
    stdout: res.stdout,
    stderr: res.stderr,
    report,
  };
}

let passCount = 0;
let failCount = 0;
function test(name: string, fn: () => void) {
  try {
    fn();
    console.log(`  ✓ ${name}`);
    passCount++;
  } catch (e: unknown) {
    console.log(`  ✗ ${name}\n    ${(e as Error).message}`);
    failCount++;
  }
}

console.log("plan-w-team-import-coupling tests\n");

interface Report {
  task_count: number;
  files_analyzed: number;
  files_skipped: { path: string; reason: string }[];
  couplings: {
    kind: "direct" | "transitive";
    shared_target?: string;
  }[];
  ack_required: boolean;
}

test("empty task list → exit 0, empty couplings", () => {
  const root = buildFixture({ name: "empty", files: {}, tasks: [] });
  const { code, report } = run(root, [
    "--slug",
    "empty",
    "--tasks-json",
    path.join(root, ".tasks.json"),
  ]);
  assert.equal(code, 0);
  const r = report as Report;
  assert.deepEqual(r.couplings, []);
  assert.equal(r.task_count, 0);
});

test("single task → exit 0, no coupling", () => {
  const root = buildFixture({
    name: "single",
    files: { "a.ts": "export const x = 1;" },
    tasks: [{ id: "1", files_touched: ["a.ts"] }],
  });
  const { code, report } = run(root, [
    "--slug",
    "single",
    "--tasks-json",
    path.join(root, ".tasks.json"),
  ]);
  assert.equal(code, 0);
  const r = report as Report;
  assert.equal(r.couplings.length, 0);
  assert.equal(r.files_analyzed, 1);
});

test("two tasks with direct import → 1 direct coupling, exit 1", () => {
  const root = buildFixture({
    name: "direct",
    files: {
      "src/a.ts": "import { y } from './b';\nexport const x = y;",
      "src/b.ts": "export const y = 2;",
    },
    tasks: [
      { id: "1", files_touched: ["src/a.ts"] },
      { id: "2", files_touched: ["src/b.ts"] },
    ],
  });
  const { code, report } = run(root, [
    "--slug",
    "direct",
    "--tasks-json",
    path.join(root, ".tasks.json"),
  ]);
  assert.equal(code, 1, `expected exit 1, got ${code}`);
  const r = report as Report;
  assert.equal(r.couplings.length, 1);
  assert.equal(r.couplings[0].kind, "direct");
  assert.equal(r.ack_required, true);
});

test("two tasks importing common third file → 1 transitive", () => {
  const root = buildFixture({
    name: "trans",
    files: {
      "src/a.ts": "import { z } from './shared';",
      "src/b.ts": "import { z } from './shared';",
      "src/shared.ts": "export const z = 0;",
    },
    tasks: [
      { id: "1", files_touched: ["src/a.ts"] },
      { id: "2", files_touched: ["src/b.ts"] },
    ],
  });
  const { code, report } = run(root, [
    "--slug",
    "trans",
    "--tasks-json",
    path.join(root, ".tasks.json"),
  ]);
  assert.equal(code, 1);
  const r = report as Report;
  assert.equal(r.couplings.length, 1);
  assert.equal(r.couplings[0].kind, "transitive");
  assert.match(r.couplings[0].shared_target ?? "", /shared\.ts$/);
});

test("non-TS file → skipped, no crash", () => {
  const root = buildFixture({
    name: "skip",
    files: { "foo.py": "x = 1\n", "a.ts": "export const x = 1;" },
    tasks: [
      { id: "1", files_touched: ["foo.py"] },
      { id: "2", files_touched: ["a.ts"] },
    ],
  });
  const { code, report } = run(root, [
    "--slug",
    "skip",
    "--tasks-json",
    path.join(root, ".tasks.json"),
  ]);
  assert.equal(code, 0);
  const r = report as Report;
  const skip = r.files_skipped.find((s) => s.path === "foo.py");
  assert.ok(skip, "foo.py should be in files_skipped");
  assert.equal(skip!.reason, "language-not-supported");
});

test("missing file → skipped, no crash", () => {
  const root = buildFixture({
    name: "missing",
    files: {},
    tasks: [{ id: "1", files_touched: ["ghost.ts"] }],
  });
  const { code, report } = run(root, [
    "--slug",
    "missing",
    "--tasks-json",
    path.join(root, ".tasks.json"),
  ]);
  assert.equal(code, 0);
  const r = report as Report;
  assert.equal(r.files_skipped[0].reason, "file-missing");
});

test("nonexistent --tasks-json → exit 3", () => {
  const root = buildFixture({ name: "bad", files: {}, tasks: [] });
  const { code, stderr } = run(root, [
    "--slug",
    "bad",
    "--tasks-json",
    "/definitely/not/a/file.json",
  ]);
  assert.equal(code, 3);
  assert.match(stderr, /tasks-json file not found/);
});

test("external imports (react, etc.) → not flagged", () => {
  const root = buildFixture({
    name: "ext",
    files: {
      "a.ts": "import React from 'react';",
      "b.ts": "import { y } from 'lodash';",
    },
    tasks: [
      { id: "1", files_touched: ["a.ts"] },
      { id: "2", files_touched: ["b.ts"] },
    ],
  });
  const { code, report } = run(root, [
    "--slug",
    "ext",
    "--tasks-json",
    path.join(root, ".tasks.json"),
  ]);
  assert.equal(code, 0);
  const r = report as Report;
  assert.equal(r.couplings.length, 0);
});

test('annotation suffix "(create)" / "(modify)" stripped', () => {
  const root = buildFixture({
    name: "annot",
    files: {
      "src/a.ts": "import { y } from './b';",
      "src/b.ts": "export const y = 2;",
    },
    tasks: [
      { id: "1", files_touched: ["src/a.ts (modify)"] },
      { id: "2", files_touched: ["src/b.ts (create)"] },
    ],
  });
  const { code, report } = run(root, [
    "--slug",
    "annot",
    "--tasks-json",
    path.join(root, ".tasks.json"),
  ]);
  assert.equal(code, 1);
  const r = report as Report;
  assert.equal(r.couplings.length, 1);
  assert.equal(r.couplings[0].kind, "direct");
});

test("--ack flag converts exit 1 → 2", () => {
  const root = buildFixture({
    name: "ack",
    files: {
      "src/a.ts": "import { y } from './b';",
      "src/b.ts": "export const y = 2;",
    },
    tasks: [
      { id: "1", files_touched: ["src/a.ts"] },
      { id: "2", files_touched: ["src/b.ts"] },
    ],
  });
  const { code } = run(root, [
    "--slug",
    "ack",
    "--tasks-json",
    path.join(root, ".tasks.json"),
    "--ack",
  ]);
  assert.equal(code, 2);
});

console.log(`\n${passCount} passed, ${failCount} failed`);
process.exit(failCount > 0 ? 1 : 0);
