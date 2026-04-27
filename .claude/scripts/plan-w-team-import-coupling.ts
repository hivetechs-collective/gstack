#!/usr/bin/env tsx
/**
 * plan-w-team-import-coupling.ts
 *
 * Stage 2 deterministic import-coupling analyzer for /plan-w-team.
 * Reads task metadata (TaskList JSON), parses imports for every file in any
 * task's files_touched, and emits a coupling matrix:
 *   - direct: task A's file imports a file in task B's files_touched
 *   - transitive: task A and task B both import a common third file
 *
 * Output:
 *   - JSON report at .claude/state/plan-w-team-coupling-$SLUG.json
 *   - Human-readable summary on stdout
 *
 * Exit codes:
 *   0 — no coupling
 *   1 — coupling detected, no ack present
 *   2 — coupling detected and acknowledged (--ack flag or ack file)
 *   3 — environment error (bad input, IO failure)
 *
 * Language support: TypeScript/JavaScript (.ts/.tsx/.js/.jsx/.mjs/.cjs).
 * Other languages → entry in files_skipped, no crash. The Parser interface
 * below is the extension point for future tree-sitter parsers (Python, Rust, etc.).
 */
import * as fs from "fs";
import * as path from "path";
import * as ts from "typescript";

const SCHEMA_VERSION = 1;
const TS_JS_EXTENSIONS = new Set([
  ".ts",
  ".tsx",
  ".js",
  ".jsx",
  ".mjs",
  ".cjs",
]);
const repoRoot = (): string => process.cwd();

// ---------- Types ----------

export interface Task {
  id: string;
  files_touched?: string[];
}

export interface CouplingEvidence {
  from_file: string;
  from_task: string;
  imports: string;
  imported_by_task?: string;
}

export interface CouplingEntry {
  task_a: string;
  task_b: string;
  kind: "direct" | "transitive";
  shared_target?: string;
  evidence: CouplingEvidence[];
}

export interface SkippedFile {
  path: string;
  reason: "language-not-supported" | "file-missing" | "parse-error";
}

export interface CouplingReport {
  schema_version: number;
  slug: string;
  computed_at: string;
  task_count: number;
  files_analyzed: number;
  files_skipped: SkippedFile[];
  couplings: CouplingEntry[];
  ack_required: boolean;
}

interface Parser {
  canParse(filePath: string): boolean;
  parseImports(filePath: string, source: string): string[];
}

// ---------- TypeScript / JavaScript parser ----------

const tsJsParser: Parser = {
  canParse(filePath) {
    return TS_JS_EXTENSIONS.has(path.extname(filePath).toLowerCase());
  },
  parseImports(filePath, source) {
    const sf = ts.createSourceFile(
      filePath,
      source,
      ts.ScriptTarget.Latest,
      /*setParentNodes*/ true,
      ts.ScriptKind.TSX,
    );
    const specifiers: string[] = [];
    const visit = (node: ts.Node) => {
      if (
        ts.isImportDeclaration(node) &&
        ts.isStringLiteral(node.moduleSpecifier)
      ) {
        specifiers.push(node.moduleSpecifier.text);
      } else if (
        ts.isExportDeclaration(node) &&
        node.moduleSpecifier &&
        ts.isStringLiteral(node.moduleSpecifier)
      ) {
        specifiers.push(node.moduleSpecifier.text);
      } else if (ts.isCallExpression(node)) {
        // require("x")
        if (
          ts.isIdentifier(node.expression) &&
          node.expression.text === "require" &&
          node.arguments.length === 1 &&
          ts.isStringLiteral(node.arguments[0])
        ) {
          specifiers.push((node.arguments[0] as ts.StringLiteral).text);
        }
        // import("x")
        if (
          node.expression.kind === ts.SyntaxKind.ImportKeyword &&
          node.arguments.length === 1 &&
          ts.isStringLiteral(node.arguments[0])
        ) {
          specifiers.push((node.arguments[0] as ts.StringLiteral).text);
        }
      }
      ts.forEachChild(node, visit);
    };
    visit(sf);
    return specifiers;
  },
};

// Extension point: register additional parsers (e.g., tree-sitter for Python/Rust) here.
const PARSERS: Parser[] = [tsJsParser];

// ---------- Import resolution ----------

function resolveImport(fromFile: string, specifier: string): string | null {
  // External (bare specifier) → skip
  if (!specifier.startsWith(".") && !specifier.startsWith("/")) return null;

  const baseDir = path.dirname(fromFile);
  const target = path.resolve(baseDir, specifier);

  // Try as-is, then with each TS/JS extension, then as a directory index.
  const candidates = [
    target,
    ...Array.from(TS_JS_EXTENSIONS).map((e) => target + e),
    ...Array.from(TS_JS_EXTENSIONS).map((e) => path.join(target, "index" + e)),
  ];
  for (const c of candidates) {
    if (fs.existsSync(c) && fs.statSync(c).isFile()) {
      const rel = path.relative(repoRoot(), c);
      // Reject paths outside the repo root — keeps the report scoped and
      // prevents surprising entries like "../../etc/passwd" if a file ever
      // contains a pathological relative import.
      if (rel.startsWith("..") || path.isAbsolute(rel)) return null;
      return rel;
    }
  }
  return null;
}

// ---------- Core analysis ----------

function stripAnnotation(p: string): string {
  // "src/foo.ts (create)" → "src/foo.ts"
  return p.replace(/\s*\((create|modify)\)\s*$/i, "").trim();
}

function analyze(tasks: Task[], slug: string): CouplingReport {
  const filesSkipped: SkippedFile[] = [];
  // file → task IDs that own it
  const fileOwners = new Map<string, Set<string>>();
  // (task_id, file) → list of resolved imports
  type Edge = { fromTask: string; fromFile: string; toFile: string };
  const edges: Edge[] = [];

  for (const task of tasks) {
    for (const raw of task.files_touched ?? []) {
      const f = stripAnnotation(raw);
      const owners = fileOwners.get(f) ?? new Set<string>();
      owners.add(task.id);
      fileOwners.set(f, owners);
    }
  }

  let filesAnalyzed = 0;
  for (const [file, owners] of fileOwners) {
    const parser = PARSERS.find((p) => p.canParse(file));
    if (!parser) {
      filesSkipped.push({ path: file, reason: "language-not-supported" });
      continue;
    }
    const abs = path.resolve(repoRoot(), file);
    if (!fs.existsSync(abs)) {
      filesSkipped.push({ path: file, reason: "file-missing" });
      continue;
    }
    let source: string;
    let specs: string[];
    try {
      source = fs.readFileSync(abs, "utf8");
      specs = parser.parseImports(abs, source);
    } catch {
      filesSkipped.push({ path: file, reason: "parse-error" });
      continue;
    }
    filesAnalyzed++;
    for (const spec of specs) {
      const resolved = resolveImport(abs, spec);
      if (!resolved) continue;
      for (const owner of owners) {
        edges.push({ fromTask: owner, fromFile: file, toFile: resolved });
      }
    }
  }

  // Compute couplings
  const couplings: CouplingEntry[] = [];
  const pairKey = (a: string, b: string) => (a < b ? `${a}|${b}` : `${b}|${a}`);
  const directPairs = new Map<string, CouplingEntry>();
  const transitiveByShared = new Map<string, Map<string, CouplingEntry>>(); // shared_target → pair → entry

  for (const e of edges) {
    const targetOwners = fileOwners.get(e.toFile);
    if (targetOwners) {
      // DIRECT: importing a file owned by another task
      for (const tb of targetOwners) {
        if (tb === e.fromTask) continue;
        const k = pairKey(e.fromTask, tb);
        const existing = directPairs.get(k);
        const ev: CouplingEvidence = {
          from_file: e.fromFile,
          from_task: e.fromTask,
          imports: e.toFile,
          imported_by_task: tb,
        };
        if (existing) existing.evidence.push(ev);
        else {
          directPairs.set(k, {
            task_a: e.fromTask < tb ? e.fromTask : tb,
            task_b: e.fromTask < tb ? tb : e.fromTask,
            kind: "direct",
            evidence: [ev],
          });
        }
      }
    }
  }

  // TRANSITIVE: shared third file imported by edges from different tasks
  // Group edges by toFile; if file is not owned by any task and 2+ tasks import it
  const importersByTarget = new Map<string, Map<string, Edge[]>>();
  for (const e of edges) {
    if (fileOwners.has(e.toFile)) continue; // owned files are direct, handled above
    const byTask = importersByTarget.get(e.toFile) ?? new Map<string, Edge[]>();
    const arr = byTask.get(e.fromTask) ?? [];
    arr.push(e);
    byTask.set(e.fromTask, arr);
    importersByTarget.set(e.toFile, byTask);
  }
  for (const [shared, byTask] of importersByTarget) {
    const tasks = [...byTask.keys()];
    if (tasks.length < 2) continue;
    for (let i = 0; i < tasks.length; i++) {
      for (let j = i + 1; j < tasks.length; j++) {
        const ta = tasks[i],
          tb = tasks[j];
        // Skip if these two tasks already have a direct coupling
        if (directPairs.has(pairKey(ta, tb))) continue;
        const sharedMap = transitiveByShared.get(shared) ?? new Map();
        const k = pairKey(ta, tb);
        const evidence: CouplingEvidence[] = [
          ...byTask.get(ta)!.map((e) => ({
            from_file: e.fromFile,
            from_task: e.fromTask,
            imports: shared,
          })),
          ...byTask.get(tb)!.map((e) => ({
            from_file: e.fromFile,
            from_task: e.fromTask,
            imports: shared,
          })),
        ];
        sharedMap.set(k, {
          task_a: ta < tb ? ta : tb,
          task_b: ta < tb ? tb : ta,
          kind: "transitive",
          shared_target: shared,
          evidence,
        });
        transitiveByShared.set(shared, sharedMap);
      }
    }
  }

  couplings.push(...directPairs.values());
  for (const sharedMap of transitiveByShared.values())
    couplings.push(...sharedMap.values());

  return {
    schema_version: SCHEMA_VERSION,
    slug,
    computed_at: new Date().toISOString(),
    task_count: tasks.length,
    files_analyzed: filesAnalyzed,
    files_skipped: filesSkipped,
    couplings,
    ack_required: couplings.length > 0,
  };
}

// ---------- CLI ----------

function recommendStrategy(c: CouplingEntry): string {
  if (c.kind === "direct")
    return "merge tasks OR designate one as barrel-owner (shared_file_owner: true)";
  return `extract T0 shared-types task that owns ${c.shared_target}`;
}

function printSummary(report: CouplingReport): void {
  const lines: string[] = [];
  lines.push(`Import-coupling report for slug=${report.slug}`);
  lines.push(`  tasks:           ${report.task_count}`);
  lines.push(`  files analyzed:  ${report.files_analyzed}`);
  lines.push(`  files skipped:   ${report.files_skipped.length}`);
  for (const s of report.files_skipped)
    lines.push(`    - ${s.path} (${s.reason})`);
  lines.push(`  couplings:       ${report.couplings.length}`);
  for (const c of report.couplings) {
    const tag = c.kind === "direct" ? "DIRECT" : "TRANSITIVE";
    const head =
      c.kind === "direct"
        ? `T${c.task_a} ↔ T${c.task_b}`
        : `T${c.task_a} ↔ T${c.task_b} via ${c.shared_target}`;
    lines.push(`    [${tag}] ${head}`);
    lines.push(`      → recommended: ${recommendStrategy(c)}`);
  }
  process.stdout.write(lines.join("\n") + "\n");
}

function readTasksFromArgs(args: Record<string, string>): Task[] {
  if (args["tasks-json"]) {
    if (!fs.existsSync(args["tasks-json"])) {
      throw new Error(`tasks-json file not found: ${args["tasks-json"]}`);
    }
    return JSON.parse(fs.readFileSync(args["tasks-json"], "utf8"));
  }
  // fall through to stdin
  const stdin = fs.readFileSync(0, "utf8");
  if (!stdin.trim())
    throw new Error(
      "no task data: provide --tasks-json <path> or pipe JSON to stdin",
    );
  return JSON.parse(stdin);
}

function parseArgs(argv: string[]): {
  args: Record<string, string>;
  flags: Set<string>;
} {
  const args: Record<string, string> = {};
  const flags = new Set<string>();
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (!a.startsWith("--")) continue;
    const key = a.slice(2);
    const next = argv[i + 1];
    if (next && !next.startsWith("--")) {
      args[key] = next;
      i++;
    } else flags.add(key);
  }
  return { args, flags };
}

export function main(argv: string[]): number {
  const { args, flags } = parseArgs(argv);
  const slug = args["slug"];
  if (!slug) {
    process.stderr.write("error: --slug is required\n");
    return 3;
  }

  let tasks: Task[];
  try {
    tasks = readTasksFromArgs(args);
  } catch (e: unknown) {
    process.stderr.write(`error: ${(e as Error).message}\n`);
    return 3;
  }

  const report = analyze(tasks, slug);
  const reportPath = path.resolve(
    repoRoot(),
    ".claude/state",
    `plan-w-team-coupling-${slug}.json`,
  );
  try {
    fs.mkdirSync(path.dirname(reportPath), { recursive: true });
    fs.writeFileSync(reportPath, JSON.stringify(report, null, 2) + "\n");
  } catch (e: unknown) {
    process.stderr.write(`error: write report: ${(e as Error).message}\n`);
    return 3;
  }

  printSummary(report);
  process.stdout.write(
    `\nReport written to ${path.relative(repoRoot(), reportPath)}\n`,
  );

  if (report.couplings.length === 0) return 0;
  const ackFile = path.resolve(
    repoRoot(),
    ".claude/state",
    `plan-w-team-coupling-ack-${slug}`,
  );
  if (flags.has("ack") || fs.existsSync(ackFile)) return 2;
  return 1;
}

// Entry point — only runs when invoked directly
const invokedDirectly =
  import.meta.url === `file://${process.argv[1]}` ||
  process.argv[1]?.endsWith("plan-w-team-import-coupling.ts");
if (invokedDirectly) {
  process.exit(main(process.argv.slice(2)));
}
