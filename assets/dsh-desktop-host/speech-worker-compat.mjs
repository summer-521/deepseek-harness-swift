import childProcess from "node:child_process";
import { syncBuiltinESMExports } from "node:module";
import { fileURLToPath } from "node:url";

// Legacy SenseVoice workers receive model paths in argv. Rewrite only that
// launch so long desktop install paths cannot prevent Node from starting.
const PRELOAD = fileURLToPath(new URL("./speech-worker-argv.cjs", import.meta.url));
const PACKAGE_PATH = "/@deepseek-ai/dsh-experimental-speech-to-text-sensevoice/lib/worker.js";

function senseVoiceConfig(file, args, options) {
  if (file !== process.execPath || !Array.isArray(args) || args.length < 2) return null;
  if (!Array.isArray(options?.stdio) || options.stdio[0] !== "ignore") return null;
  const worker = args.at(-2);
  const serialized = args.at(-1);
  if (typeof worker !== "string" || !worker.endsWith(PACKAGE_PATH) || typeof serialized !== "string") return null;
  try {
    const config = JSON.parse(serialized);
    return config?.worker === worker && typeof config.model === "string"
      && typeof config.tokens === "string" && typeof config.vad === "string" ? serialized : null;
  } catch {
    return null;
  }
}

export function installSpeechWorkerCompatibility() {
  const originalSpawn = childProcess.spawn;
  childProcess.spawn = function spawn(file, args, options) {
    const config = senseVoiceConfig(file, args, options);
    if (config === null) return originalSpawn.call(this, file, args, options);

    const argv = ["--require", PRELOAD, ...args.slice(0, -1)];
    const stdio = [...options.stdio];
    stdio[0] = "pipe";
    const child = originalSpawn.call(this, file, argv, { ...options, stdio });
    if (!child.stdin) {
      child.kill();
      throw new Error("SenseVoice worker configuration pipe is unavailable");
    }
    child.stdin.on("error", () => {});
    child.stdin.end(config);
    return child;
  };
  syncBuiltinESMExports();
}
