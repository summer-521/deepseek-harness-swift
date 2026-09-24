import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import { fileURLToPath } from 'node:url'
import { versionSources } from './harness-sources.mjs'

const testDirectory = path.dirname(fileURLToPath(import.meta.url))
const sources = [
  ...versionSources,
  path.join(testDirectory, 'swift-shell-runtime-capability-harness.swift'),
]

// The shell gives the Runtime its own macOS layout only where the Runtime can
// actually honour it. The real releases are what make that boundary a fact
// rather than a guess: `npm latest` is still 0.1.5-rc.3, and 0.1.6-alpha.2
// takes the collapsed width from the marker without mounting the leading seat
// that reopens the sidebar.
test('the shell rail applies to every Runtime that cannot draw the macOS layout itself', () => {
  const testRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-shell-runtime-capability-test-'))
  const binaryPath = path.join(testRoot, 'harness')
  const moduleCachePath = path.join(testRoot, 'module-cache')
  try {
    const compile = spawnSync('xcrun', [
      'swiftc', '-D', 'DSH_TESTING', '-module-cache-path', moduleCachePath,
      ...sources, '-o', binaryPath,
    ], { encoding: 'utf8', timeout: 120000 })
    assert.equal(compile.status, 0, compile.stderr || compile.stdout)

    const run = spawnSync(binaryPath, [], { encoding: 'utf8', timeout: 10000 })
    assert.equal(run.status, 0, run.stderr || run.stdout)
    assert.match(run.stdout, /swift shell runtime capability harness passed/)
  } finally {
    fs.rmSync(testRoot, { recursive: true, force: true })
  }
})
