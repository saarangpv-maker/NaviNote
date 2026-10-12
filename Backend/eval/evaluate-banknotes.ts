// Evaluates cloud banknote recognition on the user's labelled photos
// (TestData/BanknotePhotos, git-ignored). Runs on this Mac only; the key
// comes from Backend/.env and never leaves the process.
//
//   npm run eval:banknotes -- --limit 8            pilot (cost per photo)
//   npm run eval:banknotes                          all photos, both modes
//   npm run eval:banknotes -- --mode appearance     appearance only
//
// Modes: "withText" (printed numerals allowed as supporting evidence) and
// "appearance" (the model is told not to use printed numerals at all).
// Thresholds come from these measured results, never from the model's own
// uncertainty words.
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, readdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { basename, dirname, join, relative, resolve } from "node:path";
import OpenAI from "openai";
import { banknoteInstructions, OpenAIBanknoteModel, validateBanknoteOutput, type BanknoteRequest } from "../src/banknote.ts";

interface Photo {
  path: string;
  /** AED value, or null for "not a note". */
  value: number | null;
  side: "english" | "arabic" | null;
  valueCovered: boolean;
}

interface Result {
  photo: string;
  value: number | null;
  side: string | null;
  valueCovered: boolean;
  mode: Mode;
  outcome: "correct" | "wrong" | "abstained" | "rejected" | "error";
  predicted: number | null;
  currency: string | null;
  uncertainty: string | null;
  usedPrintedValue: boolean | null;
  evidence: string[];
  ms: number;
  /** Why validation discarded the reply, and the reply itself (eval only). */
  rejection?: string;
  raw?: unknown;
  inputTokens: number | null;
  outputTokens: number | null;
}

type Mode = "withText" | "appearance";

const root = resolve(import.meta.dirname, "../..");
const photosRoot = join(root, "TestData/BanknotePhotos");
const cacheRoot = join(photosRoot, ".cache");

function argument(name: string): string | undefined {
  const index = process.argv.indexOf(`--${name}`);
  return index === -1 ? undefined : process.argv[index + 1];
}

function findPhotos(): Photo[] {
  const photos: Photo[] = [];
  const walk = (dir: string) => {
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      if (entry.name.startsWith(".")) continue;
      const path = join(dir, entry.name);
      if (entry.isDirectory()) { walk(path); continue; }
      if (!/\.(jpe?g|heic|png)$/iu.test(entry.name)) continue;
      const parts = relative(photosRoot, path).split("/");
      const label = parts[0] ?? "";
      const match = /^AED-(\d+)$/u.exec(label);
      photos.push({
        path,
        value: match ? Number(match[1]) : null,
        side: parts[1] === "english-side" ? "english" : parts[1] === "arabic-side" ? "arabic" : null,
        valueCovered: parts.includes("value-covered"),
      });
    }
  };
  walk(photosRoot);
  return photos.sort((a, b) => a.path.localeCompare(b.path));
}

/// A 1024 px JPEG, as the app would send (converted with macOS `sips`).
function preparedJPEG(photo: Photo): string {
  const out = join(cacheRoot, relative(photosRoot, photo.path).replace(/\.[^.]+$/u, ".jpg"));
  if (!existsSync(out) || statSync(out).mtimeMs < statSync(photo.path).mtimeMs) {
    mkdirSync(dirname(out), { recursive: true });
    execFileSync("sips", ["-s", "format", "jpeg", "-s", "formatOptions", "80", "-Z", "1024", photo.path, "--out", out], { stdio: "ignore" });
  }
  return readFileSync(out).toString("base64");
}

async function main(): Promise<void> {
  const apiKey = process.env["OPENAI_API_KEY"]?.trim();
  if (!apiKey) throw new Error("OPENAI_API_KEY is not set (Backend/.env).");
  const configured = process.env["ASTRA_MODEL"]?.trim() ?? "";
  const modelName = configured === "" ? "gpt-6-astra" : configured;
  const model = new OpenAIBanknoteModel(new OpenAI({ apiKey, maxRetries: 0 }), modelName);
  const modes: Mode[] = argument("mode") === "appearance" ? ["appearance"] : argument("mode") === "withText" ? ["withText"] : ["withText", "appearance"];
  const limit = Number(argument("limit") ?? "Infinity");

  let photos = findPhotos();
  const match = argument("match");
  if (match !== undefined) photos = photos.filter((photo) => match.split("|").some((part) => photo.path.includes(part)));
  if (photos.length === 0) throw new Error(`No photos in ${photosRoot}. Expected folders: TestData/BanknotePhotos/AED-<value>/<english|arabic>-side/[value-covered/] and not-a-note/.`);
  if (Number.isFinite(limit)) {
    // Spread a pilot across labels rather than taking the first folder.
    const byLabel = new Map<string, Photo[]>();
    for (const photo of photos) {
      const key = `${photo.value ?? "none"}-${photo.side ?? ""}-${photo.valueCovered}`;
      byLabel.set(key, [...(byLabel.get(key) ?? []), photo]);
    }
    const spread: Photo[] = [];
    while (spread.length < limit && [...byLabel.values()].some((list) => list.length > 0)) {
      for (const list of byLabel.values()) {
        const next = list.shift();
        if (next && spread.length < limit) spread.push(next);
      }
    }
    photos = spread;
  }
  process.stdout.write(`Evaluating ${photos.length} photos × ${modes.join(", ")} with ${modelName}\n`);

  const results: Result[] = [];
  for (const mode of modes) {
    for (const [index, photo] of photos.entries()) {
      const request: BanknoteRequest = {
        requestId: crypto.randomUUID(), sessionId: crypto.randomUUID(), installId: crypto.randomUUID(),
        consent: true, purpose: "evaluation", mode, expectedCurrency: null,
        image: { mimeType: "image/jpeg", base64: preparedJPEG(photo) },
      };
      const started = performance.now();
      const base = { photo: relative(photosRoot, photo.path), value: photo.value, side: photo.side, valueCovered: photo.valueCovered, mode };
      try {
        const result = await model.recognise({
          instructions: banknoteInstructions(mode === "appearance"),
          imageBase64: request.image.base64,
          expectedCurrency: null,
          signal: AbortSignal.timeout(60_000),
          timeoutMs: 60_000,
        });
        const ms = Math.round(performance.now() - started);
        if (result.kind !== "output") {
          results.push({ ...base, outcome: "rejected", rejection: result.kind, predicted: null, currency: null, uncertainty: null, usedPrintedValue: null, evidence: [], ms, inputTokens: null, outputTokens: null });
        } else {
          const validated = validateBanknoteOutput(result.output, request);
          if (!validated.ok) {
            results.push({ ...base, outcome: "rejected", rejection: validated.reason, raw: result.output, predicted: null, currency: null, uncertainty: null, usedPrintedValue: null, evidence: [], ms, inputTokens: result.inputTokens, outputTokens: result.outputTokens });
          } else {
            const r = validated.response;
            const predicted = r.currency === "AED" ? r.denomination : null;
            const isNoteAnswer = r.isBanknote && r.denomination !== null;
            const outcome: Result["outcome"] = photo.value === null
              ? (isNoteAnswer ? "wrong" : "correct")
              : !isNoteAnswer ? "abstained" : (r.currency === "AED" && r.denomination === photo.value ? "correct" : "wrong");
            results.push({ ...base, outcome, predicted, currency: r.currency, uncertainty: r.uncertainty, usedPrintedValue: r.usedPrintedValue, evidence: r.evidence, ms, inputTokens: result.inputTokens, outputTokens: result.outputTokens });
          }
        }
      } catch {
        results.push({ ...base, outcome: "error", predicted: null, currency: null, uncertainty: null, usedPrintedValue: null, evidence: [], ms: Math.round(performance.now() - started), inputTokens: null, outputTokens: null });
      }
      const last = results[results.length - 1];
      process.stdout.write(`  [${mode}] ${index + 1}/${photos.length} ${basename(photo.path)} → ${last?.outcome ?? "?"}\n`);
    }
  }

  const stamp = new Date().toISOString().replace(/[:.]/gu, "-");
  const outPath = join(root, "TestData", `banknote-eval-${stamp}.json`);
  writeFileSync(outPath, JSON.stringify({ model: modelName, results }, null, 2));
  process.stdout.write(`\n${summarise(results)}\nFull results: ${relative(root, outPath)} (git-ignored)\n`);
}

/// Accuracy, abstention and — most important — confident wrong answers,
/// overall, per mode, with/without the value covered, and per uncertainty.
export function summarise(results: Result[]): string {
  const lines: string[] = [];
  const pct = (n: number, d: number) => (d === 0 ? "—" : `${Math.round((100 * n) / d)}%`);
  const block = (title: string, rows: Result[]) => {
    const notes = rows.filter((r) => r.value !== null);
    const answered = notes.filter((r) => r.outcome === "correct" || r.outcome === "wrong");
    const wrong = notes.filter((r) => r.outcome === "wrong");
    const correct = notes.filter((r) => r.outcome === "correct");
    lines.push(`| ${title} | ${notes.length} | ${pct(correct.length, notes.length)} | ${pct(answered.length, notes.length)} | ${wrong.length} (${pct(wrong.length, answered.length)} of answers) |`);
  };
  lines.push("| Slice | Notes | Correct | Answered | Wrong |", "|---|---|---|---|---|");
  for (const mode of ["withText", "appearance"] as const) {
    const rows = results.filter((r) => r.mode === mode);
    if (rows.length === 0) continue;
    block(`${mode}: all`, rows);
    block(`${mode}: value covered`, rows.filter((r) => r.valueCovered));
    block(`${mode}: value visible`, rows.filter((r) => !r.valueCovered));
    for (const level of ["low", "medium", "high"]) block(`${mode}: uncertainty ${level}`, rows.filter((r) => r.uncertainty === level));
    const negatives = rows.filter((r) => r.value === null);
    if (negatives.length > 0) lines.push(`| ${mode}: not-a-note named as a note | ${negatives.length} | | | ${negatives.filter((r) => r.outcome === "wrong").length} |`);
  }
  const tokensIn = results.reduce((sum, r) => sum + (r.inputTokens ?? 0), 0);
  const tokensOut = results.reduce((sum, r) => sum + (r.outputTokens ?? 0), 0);
  const ms = results.map((r) => r.ms).sort((a, b) => a - b);
  lines.push("", `Requests: ${results.length} · tokens in ${tokensIn}, out ${tokensOut} · median ${ms[Math.floor(ms.length / 2)] ?? 0} ms`);
  return lines.join("\n");
}

await main();
