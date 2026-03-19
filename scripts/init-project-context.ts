#!/usr/bin/env npx tsx
/**
 * init-project-context.ts
 *
 * Scans a project codebase and generates/updates CLAUDE.md with
 * comprehensive project context. Creates a "memory bank" for Claude Code.
 *
 * Usage:
 *   npx tsx scripts/init-project-context.ts [--update] [--dry-run] [--json]
 *
 * Options:
 *   --update   Update existing CLAUDE.md, preserving custom sections
 *   --dry-run  Preview changes without writing
 *   --json     Output scan results as JSON
 */

import { execSync, spawnSync } from "child_process";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const ROOT_DIR = process.cwd();

interface ProjectContext {
  name: string;
  type: "web-app" | "api" | "library" | "cli" | "monorepo" | "unknown";
  language: string;
  packageManager: string;
  frameworks: string[];
  databases: string[];
  testing: string[];
  deployment: string[];
  structure: DirectoryInfo[];
  commands: Record<string, string>;
  claudeIntegration: ClaudeIntegration;
  gitInfo: GitInfo;
  timestamp: string;
}

interface DirectoryInfo {
  path: string;
  purpose: string;
}

interface ClaudeIntegration {
  hasClaudeDir: boolean;
  agentCount: number;
  commandCount: number;
  hookCount: number;
  hasRalph: boolean;
  hasFixPlan: boolean;
}

interface GitInfo {
  branch: string;
  uncommittedCount: number;
  remoteUrl: string;
}

interface ParsedArgs {
  update: boolean;
  dryRun: boolean;
  json: boolean;
}

function parseArgs(): ParsedArgs {
  const args = process.argv.slice(2);
  return {
    update: args.includes("--update"),
    dryRun: args.includes("--dry-run"),
    json: args.includes("--json"),
  };
}

function fileExists(filePath: string): boolean {
  return fs.existsSync(path.join(ROOT_DIR, filePath));
}

function readFileIfExists(filePath: string): string | null {
  const fullPath = path.join(ROOT_DIR, filePath);
  if (fs.existsSync(fullPath)) {
    try {
      return fs.readFileSync(fullPath, "utf-8");
    } catch {
      return null;
    }
  }
  return null;
}

function countFiles(pattern: string): number {
  try {
    const result = spawnSync("find", [".", "-name", pattern, "-type", "f"], {
      cwd: ROOT_DIR,
      encoding: "utf-8",
    });
    if (result.status === 0 && result.stdout) {
      return result.stdout.trim().split("\n").filter(Boolean).length;
    }
  } catch {
    // Fallback
  }
  return 0;
}

function countInDirectory(
  dirPath: string,
  pattern: string = "*",
  recursive: boolean = false,
): number {
  const fullPath = path.join(ROOT_DIR, dirPath);
  if (!fs.existsSync(fullPath)) return 0;

  if (recursive) {
    // Use find for recursive counting
    try {
      const result = spawnSync(
        "find",
        [fullPath, "-name", pattern, "-type", "f"],
        {
          encoding: "utf-8",
        },
      );
      if (result.status === 0 && result.stdout) {
        return result.stdout.trim().split("\n").filter(Boolean).length;
      }
    } catch {
      // Fallback to non-recursive
    }
  }

  try {
    const files = fs.readdirSync(fullPath);
    if (pattern === "*") return files.length;
    return files.filter((f) => f.match(new RegExp(pattern.replace("*", ".*"))))
      .length;
  } catch {
    return 0;
  }
}

function detectProjectName(): string {
  // Try package.json first
  const packageJson = readFileIfExists("package.json");
  if (packageJson) {
    try {
      const pkg = JSON.parse(packageJson);
      if (pkg.name) return pkg.name;
    } catch {
      // Continue to fallback
    }
  }

  // Try Cargo.toml
  const cargoToml = readFileIfExists("Cargo.toml");
  if (cargoToml) {
    const match = cargoToml.match(/name\s*=\s*"([^"]+)"/);
    if (match) return match[1];
  }

  // Fallback to directory name
  return path.basename(ROOT_DIR);
}

function detectLanguage(): string {
  if (fileExists("package.json")) return "TypeScript/JavaScript";
  if (fileExists("Cargo.toml")) return "Rust";
  if (fileExists("go.mod")) return "Go";
  if (fileExists("pyproject.toml") || fileExists("requirements.txt"))
    return "Python";
  if (fileExists("build.gradle") || fileExists("pom.xml")) return "Java";
  if (fileExists("Package.swift")) return "Swift";
  return "Unknown";
}

function detectPackageManager(): string {
  // Check lock files first (most reliable)
  if (fileExists("bun.lockb")) return "bun";
  if (fileExists("pnpm-lock.yaml")) return "pnpm";
  if (fileExists("yarn.lock")) return "yarn";
  if (fileExists("package-lock.json")) return "npm";
  if (fileExists("Cargo.lock")) return "cargo";
  if (fileExists("go.sum")) return "go";
  if (fileExists("poetry.lock")) return "poetry";
  if (fileExists("Pipfile.lock")) return "pipenv";

  // Fallback: check package.json scripts or packageManager field
  const packageJson = readFileIfExists("package.json");
  if (packageJson) {
    try {
      const pkg = JSON.parse(packageJson);
      // Check packageManager field (pnpm/yarn set this)
      if (pkg.packageManager) {
        if (pkg.packageManager.startsWith("pnpm")) return "pnpm";
        if (pkg.packageManager.startsWith("yarn")) return "yarn";
        if (pkg.packageManager.startsWith("bun")) return "bun";
        if (pkg.packageManager.startsWith("npm")) return "npm";
      }
      // If package.json exists, default to npm
      return "npm";
    } catch {
      return "npm";
    }
  }

  return "unknown";
}

function detectProjectType(): ProjectContext["type"] {
  // Check for monorepo indicators
  if (
    fileExists("turbo.json") ||
    fileExists("nx.json") ||
    fileExists("lerna.json") ||
    fileExists("pnpm-workspace.yaml")
  ) {
    return "monorepo";
  }

  // Check for CLI indicators
  if (
    fileExists("src/cli.ts") ||
    fileExists("src/bin.ts") ||
    fileExists("bin/")
  ) {
    return "cli";
  }

  // Check for library indicators
  const packageJson = readFileIfExists("package.json");
  if (packageJson) {
    try {
      const pkg = JSON.parse(packageJson);
      if (pkg.main || pkg.exports) {
        if (!pkg.dependencies?.next && !pkg.dependencies?.react) {
          return "library";
        }
      }
    } catch {
      // Continue
    }
  }

  // Check for web app indicators
  if (
    fileExists("next.config.js") ||
    fileExists("next.config.mjs") ||
    fileExists("next.config.ts") ||
    fileExists("app/") ||
    fileExists("pages/")
  ) {
    return "web-app";
  }

  // Check for API indicators
  if (
    fileExists("src/routes/") ||
    fileExists("src/api/") ||
    fileExists("src/server.ts")
  ) {
    return "api";
  }

  return "unknown";
}

function detectFrameworks(): string[] {
  const frameworks: string[] = [];
  const packageJson = readFileIfExists("package.json");

  if (packageJson) {
    try {
      const pkg = JSON.parse(packageJson);
      const allDeps = { ...pkg.dependencies, ...pkg.devDependencies };

      // Frontend frameworks
      if (allDeps.next) frameworks.push(`Next.js ${allDeps.next}`);
      if (allDeps.react) frameworks.push(`React ${allDeps.react}`);
      if (allDeps.vue) frameworks.push(`Vue ${allDeps.vue}`);
      if (allDeps.svelte) frameworks.push(`Svelte ${allDeps.svelte}`);
      if (allDeps.angular) frameworks.push(`Angular ${allDeps.angular}`);
      if (allDeps.astro) frameworks.push(`Astro ${allDeps.astro}`);
      if (allDeps.remix) frameworks.push(`Remix ${allDeps.remix}`);

      // Backend frameworks
      if (allDeps.express) frameworks.push(`Express ${allDeps.express}`);
      if (allDeps.fastify) frameworks.push(`Fastify ${allDeps.fastify}`);
      if (allDeps.hono) frameworks.push(`Hono ${allDeps.hono}`);
      if (allDeps["@nestjs/core"])
        frameworks.push(`NestJS ${allDeps["@nestjs/core"]}`);
      if (allDeps["@trpc/server"])
        frameworks.push(`tRPC ${allDeps["@trpc/server"]}`);

      // UI libraries
      if (allDeps.tailwindcss)
        frameworks.push(`Tailwind CSS ${allDeps.tailwindcss}`);
      if (allDeps["@shadcn/ui"] || allDeps["shadcn-ui"])
        frameworks.push("shadcn/ui");
      if (allDeps["styled-components"]) frameworks.push("styled-components");

      // State management
      if (allDeps.zustand) frameworks.push(`Zustand ${allDeps.zustand}`);
      if (allDeps.redux || allDeps["@reduxjs/toolkit"])
        frameworks.push("Redux");
      if (allDeps.jotai) frameworks.push("Jotai");
      if (allDeps["@tanstack/react-query"]) frameworks.push("TanStack Query");
    } catch {
      // Continue
    }
  }

  // Rust frameworks
  const cargoToml = readFileIfExists("Cargo.toml");
  if (cargoToml) {
    if (cargoToml.includes("actix-web")) frameworks.push("Actix Web");
    if (cargoToml.includes("axum")) frameworks.push("Axum");
    if (cargoToml.includes("rocket")) frameworks.push("Rocket");
    if (cargoToml.includes("tokio")) frameworks.push("Tokio");
  }

  return frameworks;
}

function detectDatabases(): string[] {
  const databases: string[] = [];
  const packageJson = readFileIfExists("package.json");

  if (packageJson) {
    try {
      const pkg = JSON.parse(packageJson);
      const allDeps = { ...pkg.dependencies, ...pkg.devDependencies };

      if (allDeps.prisma || allDeps["@prisma/client"]) databases.push("Prisma");
      if (allDeps.drizzle || allDeps["drizzle-orm"])
        databases.push("Drizzle ORM");
      if (allDeps.typeorm) databases.push("TypeORM");
      if (allDeps.mongoose) databases.push("Mongoose (MongoDB)");
      if (allDeps.kysely) databases.push("Kysely");
      if (allDeps.pg) databases.push("PostgreSQL (pg)");
      if (allDeps.mysql2) databases.push("MySQL");
      if (allDeps["better-sqlite3"] || allDeps.sqlite3)
        databases.push("SQLite");
      if (allDeps.redis || allDeps.ioredis) databases.push("Redis");
    } catch {
      // Continue
    }
  }

  // Check for schema files
  if (fileExists("prisma/schema.prisma")) {
    if (!databases.includes("Prisma")) databases.push("Prisma");
  }
  if (fileExists("drizzle/")) {
    if (!databases.includes("Drizzle ORM")) databases.push("Drizzle ORM");
  }

  return databases;
}

function detectTesting(): string[] {
  const testing: string[] = [];
  const packageJson = readFileIfExists("package.json");

  if (packageJson) {
    try {
      const pkg = JSON.parse(packageJson);
      const allDeps = { ...pkg.dependencies, ...pkg.devDependencies };

      if (allDeps.vitest) testing.push("Vitest");
      if (allDeps.jest) testing.push("Jest");
      if (allDeps.playwright || allDeps["@playwright/test"])
        testing.push("Playwright");
      if (allDeps.cypress) testing.push("Cypress");
      if (allDeps["@testing-library/react"])
        testing.push("React Testing Library");
      if (allDeps.stagehand) testing.push("Stagehand");
    } catch {
      // Continue
    }
  }

  // Check for test config files
  if (fileExists("vitest.config.ts") || fileExists("vitest.config.js")) {
    if (!testing.includes("Vitest")) testing.push("Vitest");
  }
  if (fileExists("jest.config.js") || fileExists("jest.config.ts")) {
    if (!testing.includes("Jest")) testing.push("Jest");
  }
  if (fileExists("playwright.config.ts")) {
    if (!testing.includes("Playwright")) testing.push("Playwright");
  }

  return testing;
}

function detectDeployment(): string[] {
  const deployment: string[] = [];

  if (fileExists("wrangler.toml")) deployment.push("Cloudflare Workers");
  if (fileExists("vercel.json")) deployment.push("Vercel");
  if (fileExists("netlify.toml")) deployment.push("Netlify");
  if (fileExists("Dockerfile")) deployment.push("Docker");
  if (fileExists("docker-compose.yml") || fileExists("docker-compose.yaml"))
    deployment.push("Docker Compose");
  if (fileExists(".github/workflows/")) deployment.push("GitHub Actions");
  if (fileExists(".gitlab-ci.yml")) deployment.push("GitLab CI");
  if (fileExists("fly.toml")) deployment.push("Fly.io");
  if (fileExists("railway.json")) deployment.push("Railway");
  if (fileExists("render.yaml")) deployment.push("Render");

  return deployment;
}

function detectStructure(): DirectoryInfo[] {
  const structure: DirectoryInfo[] = [];

  const dirPurposes: Record<string, string> = {
    src: "Source code",
    app: "Next.js/Remix app directory",
    apps: "Monorepo applications",
    packages: "Monorepo packages",
    lib: "Library code",
    components: "UI components",
    pages: "Page components/routes",
    api: "API routes",
    routes: "Route handlers",
    services: "Business logic services",
    utils: "Utility functions",
    hooks: "React hooks",
    types: "TypeScript types",
    styles: "CSS/styling",
    public: "Static assets",
    assets: "Asset files",
    docs: "Documentation",
    tests: "Test files",
    __tests__: "Jest test files",
    e2e: "End-to-end tests",
    scripts: "Build/utility scripts",
    prisma: "Prisma schema/migrations",
    drizzle: "Drizzle schema/migrations",
    migrations: "Database migrations",
    ".claude": "Claude Code configuration",
    ".github": "GitHub configuration",
  };

  for (const [dir, purpose] of Object.entries(dirPurposes)) {
    if (fileExists(dir)) {
      structure.push({ path: dir, purpose });
    }
  }

  return structure;
}

function detectCommands(): Record<string, string> {
  const commands: Record<string, string> = {};
  const packageJson = readFileIfExists("package.json");
  const pm = detectPackageManager();

  if (packageJson) {
    try {
      const pkg = JSON.parse(packageJson);
      if (pkg.scripts) {
        if (pkg.scripts.dev) commands.dev = `${pm} dev`;
        if (pkg.scripts.build) commands.build = `${pm} build`;
        if (pkg.scripts.test) commands.test = `${pm} test`;
        if (pkg.scripts.lint) commands.lint = `${pm} lint`;
        if (pkg.scripts.typecheck) commands.typecheck = `${pm} typecheck`;
        if (pkg.scripts.start) commands.start = `${pm} start`;
      }
    } catch {
      // Continue
    }
  }

  // Rust commands
  if (fileExists("Cargo.toml")) {
    commands.build = "cargo build";
    commands.test = "cargo test";
    commands.run = "cargo run";
    commands.lint = "cargo clippy";
  }

  return commands;
}

function detectClaudeIntegration(): ClaudeIntegration {
  return {
    hasClaudeDir: fileExists(".claude"),
    agentCount: countInDirectory(".claude/agents", "*.md", true), // Recursive
    commandCount: countInDirectory(".claude/commands", "*.md"),
    hookCount: countInDirectory(".claude/hooks", "*.sh"),
    hasRalph: fileExists("ralph-start.sh") || fileExists("PROMPT.md"),
    hasFixPlan: fileExists("fix_plan.md"),
  };
}

function detectGitInfo(): GitInfo {
  let branch = "unknown";
  let uncommittedCount = 0;
  let remoteUrl = "";

  try {
    const branchResult = spawnSync("git", ["branch", "--show-current"], {
      cwd: ROOT_DIR,
      encoding: "utf-8",
    });
    if (branchResult.status === 0) {
      branch = branchResult.stdout.trim();
    }

    const statusResult = spawnSync("git", ["status", "--porcelain"], {
      cwd: ROOT_DIR,
      encoding: "utf-8",
    });
    if (statusResult.status === 0 && statusResult.stdout) {
      uncommittedCount = statusResult.stdout
        .trim()
        .split("\n")
        .filter(Boolean).length;
    }

    const remoteResult = spawnSync("git", ["remote", "get-url", "origin"], {
      cwd: ROOT_DIR,
      encoding: "utf-8",
    });
    if (remoteResult.status === 0) {
      remoteUrl = remoteResult.stdout.trim();
    }
  } catch {
    // Git not available
  }

  return { branch, uncommittedCount, remoteUrl };
}

function scanProject(): ProjectContext {
  return {
    name: detectProjectName(),
    type: detectProjectType(),
    language: detectLanguage(),
    packageManager: detectPackageManager(),
    frameworks: detectFrameworks(),
    databases: detectDatabases(),
    testing: detectTesting(),
    deployment: detectDeployment(),
    structure: detectStructure(),
    commands: detectCommands(),
    claudeIntegration: detectClaudeIntegration(),
    gitInfo: detectGitInfo(),
    timestamp: new Date().toISOString(),
  };
}

function generateClaudeMd(context: ProjectContext): string {
  const lines: string[] = [];

  lines.push("@~/.claude/CLAUDE.md");
  lines.push("");
  lines.push("# Project-Specific Instructions");
  lines.push("");
  lines.push("<!-- AUTO-GENERATED by /init - Do not edit above this line -->");
  lines.push("");

  // Project Overview
  lines.push("## Project Overview");
  lines.push("");
  lines.push(`**Project Name**: ${context.name}`);
  lines.push(`**Type**: ${context.type}`);
  lines.push(`**Primary Language**: ${context.language}`);
  lines.push(`**Package Manager**: ${context.packageManager}`);
  lines.push("");

  // Tech Stack
  lines.push("## Tech Stack");
  lines.push("");
  if (context.frameworks.length > 0) {
    lines.push("### Frameworks & Libraries");
    for (const fw of context.frameworks) {
      lines.push(`- ${fw}`);
    }
    lines.push("");
  }
  if (context.databases.length > 0) {
    lines.push("### Database & ORM");
    for (const db of context.databases) {
      lines.push(`- ${db}`);
    }
    lines.push("");
  }
  if (context.testing.length > 0) {
    lines.push("### Testing");
    for (const test of context.testing) {
      lines.push(`- ${test}`);
    }
    lines.push("");
  }
  if (context.deployment.length > 0) {
    lines.push("### Deployment & Infrastructure");
    for (const dep of context.deployment) {
      lines.push(`- ${dep}`);
    }
    lines.push("");
  }

  // Project Structure
  lines.push("## Project Structure");
  lines.push("");
  lines.push("```");
  lines.push(`${context.name}/`);
  for (const dir of context.structure) {
    lines.push(`├── ${dir.path}/  # ${dir.purpose}`);
  }
  lines.push("```");
  lines.push("");

  // Development Commands
  if (Object.keys(context.commands).length > 0) {
    lines.push("## Development Commands");
    lines.push("");
    lines.push("```bash");
    lines.push(`# Install dependencies`);
    lines.push(`${context.packageManager} install`);
    lines.push("");
    for (const [name, cmd] of Object.entries(context.commands)) {
      lines.push(`# ${name.charAt(0).toUpperCase() + name.slice(1)}`);
      lines.push(cmd);
      lines.push("");
    }
    lines.push("```");
    lines.push("");
  }

  // Claude Code Integration
  lines.push("## Claude Code Integration");
  lines.push("");
  const ci = context.claudeIntegration;
  lines.push(
    `- **Claude Directory**: ${ci.hasClaudeDir ? "Configured" : "Not configured"}`,
  );
  lines.push(`- **Agents**: ${ci.agentCount} available`);
  lines.push(`- **Commands**: ${ci.commandCount} configured`);
  lines.push(`- **Hooks**: ${ci.hookCount} active`);
  lines.push(
    `- **Ralph Integration**: ${ci.hasRalph ? "Ready" : "Not configured"}`,
  );
  if (ci.hasFixPlan) {
    lines.push(`- **fix_plan.md**: Active task queue present`);
  }
  lines.push("");

  // Current State
  lines.push("## Current State");
  lines.push("");
  lines.push(`**Last Scanned**: ${context.timestamp}`);
  lines.push(`**Active Branch**: ${context.gitInfo.branch}`);
  lines.push(
    `**Uncommitted Changes**: ${context.gitInfo.uncommittedCount} files`,
  );
  lines.push("");

  lines.push("<!-- END AUTO-GENERATED -->");
  lines.push("");
  lines.push("## Custom Instructions");
  lines.push("");
  lines.push("<!-- CUSTOM - Add your project-specific instructions below -->");
  lines.push("");

  return lines.join("\n");
}

function updateExistingClaudeMd(
  existingContent: string,
  context: ProjectContext,
): string {
  const newGenerated = generateClaudeMd(context);

  // Extract auto-generated section from new content
  const autoStart = "<!-- AUTO-GENERATED by /init";
  const autoEnd = "<!-- END AUTO-GENERATED -->";

  const newAutoSection = newGenerated.substring(
    newGenerated.indexOf(autoStart),
    newGenerated.indexOf(autoEnd) + autoEnd.length,
  );

  // Check if existing has auto-generated section
  if (
    existingContent.includes(autoStart) &&
    existingContent.includes(autoEnd)
  ) {
    // Replace existing auto-generated section
    const before = existingContent.substring(
      0,
      existingContent.indexOf(autoStart),
    );
    const after = existingContent.substring(
      existingContent.indexOf(autoEnd) + autoEnd.length,
    );
    return before + newAutoSection + after;
  } else {
    // Insert after the import line or at the beginning
    const importLine = "@~/.claude/CLAUDE.md";
    if (existingContent.includes(importLine)) {
      const insertPoint =
        existingContent.indexOf(importLine) + importLine.length;
      return (
        existingContent.substring(0, insertPoint) +
        "\n\n" +
        newAutoSection +
        "\n" +
        existingContent.substring(insertPoint)
      );
    } else {
      return importLine + "\n\n" + newAutoSection + "\n\n" + existingContent;
    }
  }
}

function main() {
  const args = parseArgs();

  // Only show progress message in non-JSON mode
  if (!args.json) {
    console.log("Scanning project...\n");
  }

  const context = scanProject();

  if (args.json) {
    console.log(JSON.stringify(context, null, 2));
    return;
  }

  const claudeMdPath = path.join(ROOT_DIR, "CLAUDE.md");
  const existingContent = readFileIfExists("CLAUDE.md");

  let newContent: string;

  if (existingContent && args.update) {
    newContent = updateExistingClaudeMd(existingContent, context);
    console.log("Updating existing CLAUDE.md...");
  } else if (existingContent && !args.update) {
    console.log(
      "CLAUDE.md already exists. Use --update to refresh auto-generated sections.",
    );
    console.log("Use --dry-run to preview changes.\n");

    // Show preview anyway
    newContent = updateExistingClaudeMd(existingContent, context);
    console.log("--- Preview of changes ---\n");
    console.log(newContent);
    return;
  } else {
    newContent = generateClaudeMd(context);
    console.log("Generating new CLAUDE.md...");
  }

  if (args.dryRun) {
    console.log("\n--- Dry Run Output ---\n");
    console.log(newContent);
    return;
  }

  fs.writeFileSync(claudeMdPath, newContent);

  // Print summary
  console.log("\n/init complete\n");
  console.log(`Project: ${context.name}`);
  console.log(`Type: ${context.type}`);
  console.log(`Tech Stack: ${context.frameworks.slice(0, 3).join(", ")}`);
  console.log(
    `Structure: ${context.type === "monorepo" ? "monorepo" : "single-app"}`,
  );
  console.log("");
  console.log("Updated Sections:");
  console.log("  ✅ Project Overview");
  console.log("  ✅ Tech Stack");
  console.log("  ✅ Project Structure");
  console.log("  ✅ Development Commands");
  console.log("  ✅ Claude Code Integration");
  console.log("");
  console.log("Claude Code Integration:");
  console.log(`  📦 ${context.claudeIntegration.agentCount} agents available`);
  console.log(
    `  🔧 ${context.claudeIntegration.commandCount} commands configured`,
  );
  console.log(`  🪝 ${context.claudeIntegration.hookCount} hooks active`);
  console.log(
    `  🤖 Ralph: ${context.claudeIntegration.hasRalph ? "Ready" : "Not configured"}`,
  );
  console.log("");
  console.log("Memory bank updated. Context ready for development.");
}

main();
