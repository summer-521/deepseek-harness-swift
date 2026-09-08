import { startDesktopControl, waitForDesktopBootstrap } from "./dsh-desktop-host/control.js";

function fail(error) {
  const detail = error instanceof Error ? error.message : String(error);
  process.stderr.write(`dsh runtime bootstrap failed: ${detail}\n`);
  process.exitCode = 1;
}

try {
  // The inherited stdin pipe is the only source of the DSH entry path and
  // runtime arguments. No user-controlled equivalent is accepted from argv.
  startDesktopControl();
  const bootstrap = await waitForDesktopBootstrap();

  process.title = "DSH Web Runtime";
  process.argv = [
    process.argv[0],
    bootstrap.entryPath,
    "--profile", bootstrap.profile,
    "--host", bootstrap.host,
    "--port", String(bootstrap.port),
    "--no-open",
  ];

  // Runtimes since 0.1.3-alpha.2 gate the CLI behind `import.meta.main`, so an
  // entry loaded through import() never boots by itself. The exported
  // runCli() re-parses process.argv, which was just set above. Older runtimes
  // export nothing and boot through the import's side effects.
  const entry = await import(bootstrap.entryPath);
  if (typeof entry.runCli === "function") {
    await entry.runCli();
  }
} catch (error) {
  fail(error);
}
