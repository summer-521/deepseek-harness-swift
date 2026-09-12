import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const projectRoot = path.join(testDirectory, "..");
const sources = [
  path.join(projectRoot, "Sources", "SettingsUI", "SettingsSidebarIcon.swift"),
  path.join(testDirectory, "swift-sidebar-icon-harness.swift"),
];

test("Swift sidebar icons keep their fixed colour and reject template tinting", () => {
  const workDirectory = fs.mkdtempSync(path.join(os.tmpdir(), "dsh-sidebar-icon-"));
  const moduleCachePath = fs.mkdtempSync(path.join(os.tmpdir(), "dsh-sidebar-icon-cache-"));
  const binaryPath = path.join(workDirectory, "harness");
  try {
    const compile = spawnSync(
      "xcrun",
      ["swiftc", ...sources, "-module-cache-path", moduleCachePath, "-o", binaryPath],
      { encoding: "utf8", timeout: 120000 },
    );
    assert.equal(compile.status, 0, compile.stderr || compile.stdout);

    const run = spawnSync(binaryPath, [], { encoding: "utf8", timeout: 60000 });
    assert.equal(run.status, 0, run.stderr || run.stdout);
    assert.match(run.stdout, /swift sidebar icon harness passed/);
  } finally {
    try { fs.unlinkSync(binaryPath); } catch { /* no binary after a failed compile */ }
    fs.rmSync(workDirectory, { recursive: true, force: true });
    fs.rmSync(moduleCachePath, { recursive: true, force: true });
  }
});
