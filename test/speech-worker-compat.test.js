import test from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtemp, mkdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { installSpeechWorkerCompatibility } from "../assets/dsh-desktop-host/speech-worker-compat.mjs";

test("desktop SenseVoice launch carries long configuration through stdin", async () => {
  const home = await mkdtemp(path.join(tmpdir(), "dsh-speech-compat-"));
  try {
    const packageRoot = path.join(home, "node_modules", "@deepseek-ai", "dsh-experimental-speech-to-text-sensevoice", "lib");
    await mkdir(packageRoot, { recursive: true });
    const worker = path.join(packageRoot, "worker.js");
    await writeFile(worker, "process.stdout.write(JSON.stringify({ argc: process.argv.length, config: JSON.parse(process.argv[2]) }));\n");
    const config = { worker, model: "m".repeat(1200), tokens: "tokens", vad: "vad" };
    installSpeechWorkerCompatibility();
    const child = spawn(process.execPath, [worker, JSON.stringify(config)], {
      stdio: ["ignore", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    child.stdout.setEncoding("utf8").on("data", (chunk) => { stdout += chunk; });
    child.stderr.setEncoding("utf8").on("data", (chunk) => { stderr += chunk; });
    const exit = await new Promise((resolve, reject) => {
      child.once("error", reject);
      child.once("close", (code, signal) => { resolve({ code, signal }); });
    });
    assert.deepEqual(exit, { code: 0, signal: null }, stderr);
    assert.deepEqual(JSON.parse(stdout), { argc: 3, config });
  } finally {
    await rm(home, { recursive: true, force: true });
  }
});
