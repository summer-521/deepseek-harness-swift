import test from "node:test";
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { mkdtemp, readFile, rm, writeFile, mkdir } from "node:fs/promises";
import { readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const execFileAsync = promisify(execFile);
const ROOT = path.join(path.dirname(fileURLToPath(import.meta.url)), "..");
const BOOTSTRAP_SOURCE_PATH = path.join(ROOT, "assets", "dsh-runtime-bootstrap.mjs");
const BOOTSTRAP_SOURCE = readFileSync(BOOTSTRAP_SOURCE_PATH, "utf8");

// A runtime entry that gates its CLI behind `import.meta.main` the same way
// @deepseek-ai/dsh 0.1.3-alpha.2 does: importing it boots nothing by itself,
// and only the exported runCli() starts the profile.
const GATED_ENTRY_SOURCE = `\
import { writeFileSync } from "node:fs";
export let topLevelBooted = false;
if (import.meta.main) {
  topLevelBooted = true;
  writeFileSync(process.env.BOOT_MARKER, "top-level");
}
export async function runCli() {
  writeFileSync(process.env.BOOT_MARKER, topLevelBooted ? "top-level+runCli" : "runCli");
}
`;

// A legacy runtime entry that runs the CLI unconditionally at import time and
// exports nothing, matching pre-0.1.3 runtimes.
const SIDE_EFFECT_ENTRY_SOURCE = `\
import { writeFileSync } from "node:fs";
writeFileSync(process.env.BOOT_MARKER, "top-level");
`;

// Minimal stand-in for assets/dsh-desktop-host/control.js: resolves the
// bootstrap promise immediately without touching real stdin.
const STUB_CONTROL_SOURCE = `\
export function startDesktopControl() {}
export async function waitForDesktopBootstrap() {
  return {
    entryPath: process.env.REPRO_ENTRY,
    profile: "desktop",
    host: "127.0.0.1",
    port: 3080,
  };
}
`;

async function runBootstrapScenario({ entrySource, entryName }) {
  const home = await mkdtemp(path.join(tmpdir(), "dsh-bootstrap-test-"));
  try {
    await mkdir(path.join(home, "dsh-desktop-host"));
    const entryPath = path.join(home, entryName);
    const bootMarker = path.join(home, "boot-marker.txt");
    await writeFile(path.join(home, "dsh-desktop-host", "control.js"), STUB_CONTROL_SOURCE);
    await writeFile(entryPath, entrySource);
    await writeFile(path.join(home, "bootstrap.mjs"), BOOTSTRAP_SOURCE);
    await writeFile(bootMarker, "");

    let stderr = "";
    try {
      await execFileAsync(
        process.execPath,
        [path.join(home, "bootstrap.mjs")],
        {
          env: {
            ...process.env,
            BOOT_MARKER: bootMarker,
            REPRO_ENTRY: entryPath,
          },
          timeout: 15_000,
        },
      );
    } catch (error) {
      stderr = error.stderr ?? "";
      assert.fail(`bootstrap exited with failure: ${error.message}\n${stderr}`);
    }
    assert.equal(
      stderr.includes("dsh runtime bootstrap failed"),
      false,
      `bootstrap reported a failure: ${stderr}`,
    );
    return await readFile(bootMarker, "utf8");
  } finally {
    await rm(home, { recursive: true, force: true });
  }
}

test("runtime bootstrap keeps the plain import before the gated-CLI fallback", () => {
  const importIndex = BOOTSTRAP_SOURCE.indexOf("const entry = await import(bootstrap.entryPath)");
  assert.ok(importIndex >= 0, "bootstrap must import the runtime entry");
  const argvIndex = BOOTSTRAP_SOURCE.indexOf('process.argv = [');
  assert.ok(argvIndex >= 0 && argvIndex < importIndex, "bootstrap must inject argv before importing the entry");
  assert.match(BOOTSTRAP_SOURCE, /typeof entry\.runCli === "function"/);
  assert.match(BOOTSTRAP_SOURCE, /await entry\.runCli\(\)/);
});

test("bootstrap boots import.meta.main-gated runtimes through the exported runCli", async () => {
  const marker = await runBootstrapScenario({ entrySource: GATED_ENTRY_SOURCE, entryName: "gated-entry.mjs" });
  // The regression: a gated entry never boots through import() alone, so the
  // marker must prove the explicit runCli() fallback ran.
  assert.equal(marker, "runCli");
});

test("bootstrap leaves legacy side-effect runtimes untouched", async () => {
  const marker = await runBootstrapScenario({ entrySource: SIDE_EFFECT_ENTRY_SOURCE, entryName: "legacy-entry.mjs" });
  assert.equal(marker, "top-level");
});
