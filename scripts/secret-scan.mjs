#!/usr/bin/env node
// Secret scan for the NaviNote repository. No dependencies.
//
//   node scripts/secret-scan.mjs            scan every file Git would commit
//   node scripts/secret-scan.mjs <dir>      scan a directory (e.g. a built .app)
//
// Fails (exit 1) on anything that looks like a credential, on a committed
// .env file, or if Backend/.env is not ignored. Test fixtures may use
// obviously fake keys containing "TESTONLY"; those matches are allowed.
import { execFileSync } from "node:child_process";
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join, relative, resolve } from "node:path";

const root = resolve(import.meta.dirname, "..");
const PATTERNS = [
  ["OpenAI-style key", /\bsk-(?:proj-|live-|svcacct-|admin-)?[A-Za-z0-9_-]{20,}/g],
  ["OPENAI_API_KEY with a value (env-file style)", /OPENAI_API_KEY\s*=\s*["']?[A-Za-z0-9_-]{8,}/g],
  ["Bearer token", /\bBearer\s+[A-Za-z0-9._~+/-]{20,}/g],
  ["Private key", /-----BEGIN [A-Z ]*PRIVATE KEY-----/g],
  ["AWS access key", /\bAKIA[0-9A-Z]{16}\b/g],
  ["Generic API key assignment", /\bapi[_-]?key\s*[:=]\s*["'][A-Za-z0-9_-]{20,}["']/gi],
];

function gitFiles() {
  const out = execFileSync("git", ["ls-files", "-z", "--cached", "--others", "--exclude-standard"], { cwd: root });
  return out.toString("utf8").split("\0").filter(Boolean).map((file) => join(root, file));
}

function walk(dir) {
  return readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const path = join(dir, entry.name);
    return entry.isDirectory() ? walk(path) : [path];
  });
}

const target = process.argv[2] ? resolve(process.argv[2]) : null;
const files = target ? walk(target) : gitFiles();
const findings = [];

for (const file of files) {
  let stats;
  try { stats = statSync(file); } catch { continue; }
  if (!stats.isFile() || stats.size > 20 * 1024 * 1024) continue;
  // Binary files are scanned as Latin-1 so embedded strings still match.
  const text = readFileSync(file).toString("latin1");
  for (const [name, pattern] of PATTERNS) {
    for (const match of text.matchAll(pattern)) {
      if (match[0].includes("TESTONLY")) continue;
      const line = text.slice(0, match.index).split("\n").length;
      findings.push(`${relative(root, file)}:${line}: ${name}`);
    }
  }
}

if (!target) {
  const tracked = execFileSync("git", ["ls-files"], { cwd: root }).toString("utf8").split("\n");
  for (const file of tracked) {
    const name = file.split("/").pop() ?? "";
    if (/^\.env(\..+)?$/.test(name) && name !== ".env.example") findings.push(`${file}: committed environment file`);
  }
  try {
    execFileSync("git", ["check-ignore", "-q", "Backend/.env"], { cwd: root });
  } catch {
    findings.push("Backend/.env is not ignored by Git");
  }
}

if (findings.length > 0) {
  process.stderr.write(`Secret scan FAILED (${findings.length}):\n${findings.map((f) => `  ${f}`).join("\n")}\n`);
  process.exit(1);
}
process.stdout.write(`Secret scan passed: ${files.length} files, no secrets found${target ? "" : "; .env is ignored and not committed"}.\n`);
