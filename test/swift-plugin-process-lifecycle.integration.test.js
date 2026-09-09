import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import { fileURLToPath } from 'node:url'

const testDirectory = path.dirname(fileURLToPath(import.meta.url))
const repositoryDirectory = path.join(testDirectory, '..')
const sources = [
  path.join(repositoryDirectory, 'Sources', 'State', 'DshState.swift'),
  path.join(repositoryDirectory, 'Sources', 'Versions', 'DshSemanticVersion.swift'),
  path.join(repositoryDirectory, 'Sources', 'Service', 'NodeRuntime.swift'),
  path.join(repositoryDirectory, 'Sources', 'Service', 'DshLaunchContext.swift'),
  path.join(repositoryDirectory, 'Sources', 'Service', 'DshSecretRedactor.swift'),
  path.join(repositoryDirectory, 'Sources', 'Versions', 'DshVersionManager.swift'),
  path.join(repositoryDirectory, 'Sources', 'Plugins', 'DshPluginOperationState.swift'),
  path.join(repositoryDirectory, 'Sources', 'Plugins', 'DshPluginManager.swift'),
  path.join(testDirectory, 'swift-plugin-process-lifecycle-harness.swift'),
]

const fakePnpm = `#!${process.execPath}
import { spawn } from 'node:child_process'

const mode = process.env.DSH_FAKE_PNPM_MODE || ''
if (mode === 'silent-delay') {
  await new Promise(resolve => setTimeout(resolve, 1500))
  process.exit(0)
} else if (mode === 'child-holds-pipe') {
  // Keep both inherited output descriptors open after the parent exits. The
  // Swift collector must bound its post-exit drain instead of waiting for EOF.
  spawn(process.execPath, ['-e', 'setTimeout(() => {}, 2000)'], { stdio: 'inherit' })
  process.exit(0)
} else if (mode === 'large-output') {
  process.stdout.write('o'.repeat(2 * 1024 * 1024))
  process.stderr.write('e'.repeat(2 * 1024 * 1024))
  process.exitCode = 17
  await new Promise(resolve => setTimeout(resolve, 50))
} else if (mode === 'bridge-timeout') {
  // A profile-switch bridge install must have its own bounded wall clock;
  // this models pnpm wedging without producing output.
  setInterval(() => {}, 60_000)
  await new Promise(() => {})
} else {
  process.exit(0)
}
`

test('Swift pnpm process lifecycle drains and bounds dynamic child output', () => {
  const testRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-plugin-process-lifecycle-'))
  const binaryPath = path.join(testRoot, 'harness')
  const moduleCachePath = path.join(testRoot, 'module-cache')
  const assetsRoot = path.join(testRoot, 'assets')
  const hostRoot = path.join(assetsRoot, 'dsh-desktop-host')
  fs.mkdirSync(path.join(assetsRoot, 'bin'), { recursive: true })
  fs.mkdirSync(path.join(assetsRoot, 'node', 'bin'), { recursive: true })
  fs.mkdirSync(hostRoot, { recursive: true })
  fs.writeFileSync(path.join(hostRoot, 'package.json'), JSON.stringify({
    name: 'dsh-desktop-host',
    version: '1.0.0',
    exports: { './webserver': './webserver.js' },
  }))
  for (const file of [
    'index.js', 'client.js', 'webserver.js', 'browser-url-route.js',
    'lan-url-route.js', 'lan-http-ingress.js', 'upstream-session-broker.js',
    'control.js', 'access-state.js', 'cordis.patch.yml',
  ]) fs.writeFileSync(path.join(hostRoot, file), `controlled-${file}\n`)
  fs.writeFileSync(path.join(assetsRoot, 'bin', 'pnpm'), fakePnpm, { mode: 0o755 })
  fs.writeFileSync(path.join(assetsRoot, 'node', 'bin', 'node'), '#!/bin/sh\nexit 0\n', { mode: 0o755 })
  try {
    const compile = spawnSync('xcrun', [
      'swiftc', '-D', 'DSH_TESTING', '-module-cache-path', moduleCachePath,
      ...sources, '-o', binaryPath,
    ], { encoding: 'utf8', timeout: 120000 })
    assert.equal(compile.status, 0, compile.stderr || compile.stdout)

    for (const mode of ['silent-delay', 'child-holds-pipe', 'large-output', 'bridge-timeout']) {
      const root = fs.mkdtempSync(path.join(testRoot, `${mode}-`))
      try {
        const run = spawnSync(binaryPath, [], {
          env: {
            ...process.env,
            DSH_HOME: path.join(root, 'dsh-home'),
            DSH_TEST_APP_SUPPORT: path.join(root, 'app-support'),
            DSH_FAKE_PNPM_MODE: mode,
            ...(mode === 'bridge-timeout' ? { DSH_TEST_PROFILE_BRIDGE_TIMEOUT: '0.5' } : {}),
          },
          encoding: 'utf8',
          timeout: 15000,
        })
        assert.equal(run.status, 0, `${mode} failed\nstdout:\n${run.stdout}\nstderr:\n${run.stderr}`)
        assert.match(run.stdout, new RegExp(`swift plugin process lifecycle ${mode} harness passed`))
      } finally {
        fs.rmSync(root, { recursive: true, force: true })
      }
    }
  } finally {
    fs.rmSync(testRoot, { recursive: true, force: true })
  }
})
