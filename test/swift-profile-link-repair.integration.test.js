import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const sources = [
  path.join(testDirectory, "..", "Sources", "Versions", "DshProfileLinkRepair.swift"),
  path.join(testDirectory, "swift-profile-link-repair-harness.swift"),
];

test("Swift ProfileLinkRepair moves only the links a surviving Runtime can satisfy", () => {
  const binaryPath = path.join(os.tmpdir(), `dsh-profile-link-repair-${process.pid}`);
  try {
    const compile = spawnSync("xcrun", ["swiftc", ...sources, "-o", binaryPath], {
      encoding: "utf8",
      timeout: 120000,
    });
    assert.equal(compile.status, 0, compile.stderr || compile.stdout);

    const run = spawnSync(binaryPath, [], { encoding: "utf8", timeout: 30000 });
    assert.equal(run.status, 0, run.stderr || run.stdout);
    assert.match(run.stdout, /swift profile link repair harness passed/);
  } finally {
    try { fs.unlinkSync(binaryPath); } catch { /* no binary after failed compile */ }
  }
});
