import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import { fileURLToPath } from 'node:url'

const testDirectory = path.dirname(fileURLToPath(import.meta.url))
const stateSource = path.join(testDirectory, '..', 'Sources', 'State', 'DshState.swift')
const harnessSource = path.join(testDirectory, 'swift-runtime-ui-gate-harness.swift')

test('Swift runtime update leaves plugin and channel UI usable without relaunch', () => {
  const testRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-runtime-ui-gate-'))
  const binaryPath = path.join(testRoot, 'harness')
  try {
    const compile = spawnSync('xcrun', ['swiftc', stateSource, harnessSource, '-o', binaryPath], {
      encoding: 'utf8',
      timeout: 120000,
    })
    assert.equal(compile.status, 0, compile.stderr || compile.stdout)

    const run = spawnSync(binaryPath, [], {
      encoding: 'utf8',
      timeout: 10000,
      env: { ...process.env, DSH_HOME: path.join(testRoot, 'dsh-home') },
    })
    assert.equal(run.status, 0, run.stderr || run.stdout)
    assert.match(run.stdout, /swift runtime UI gate harness passed/)
  } finally {
    fs.rmSync(testRoot, { recursive: true, force: true })
  }
})
