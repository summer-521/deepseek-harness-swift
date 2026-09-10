import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import { fileURLToPath } from 'node:url'

const testDirectory = path.dirname(fileURLToPath(import.meta.url))
const repositoryDirectory = path.join(testDirectory, '..')
const gateSource = path.join(
  repositoryDirectory,
  'Sources',
  'Service',
  'DshAsyncOperationGate.swift',
)
const harnessSource = path.join(testDirectory, 'swift-async-operation-gate-harness.swift')

test('the async operation gate honours cancellation without hanging or losing waiters', () => {
  const moduleCachePath = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-gate-cache-'))
  const binaryPath = path.join(moduleCachePath, 'harness')
  try {
    const compile = spawnSync('xcrun', [
      'swiftc',
      '-module-cache-path',
      moduleCachePath,
      gateSource,
      harnessSource,
      '-o',
      binaryPath,
    ], { encoding: 'utf8', timeout: 120000 })
    assert.equal(compile.status, 0, compile.stderr || compile.stdout)

    for (const scenario of ['cancel-before-acquire-free', 'cancel-while-queued', 'fifo-order']) {
      const run = spawnSync(binaryPath, [scenario], { encoding: 'utf8', timeout: 30000 })
      assert.equal(
        run.status,
        0,
        `${scenario} failed (status ${run.status})\nstdout:\n${run.stdout}\nstderr:\n${run.stderr}`,
      )
      assert.match(run.stdout, new RegExp(`async operation gate scenario ${scenario} passed`))
    }
  } finally {
    fs.rmSync(moduleCachePath, { recursive: true, force: true })
  }
})
