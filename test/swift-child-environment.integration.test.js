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
  path.join(repositoryDirectory, 'Sources', 'Service', 'NodeChildEnvironment.swift'),
  path.join(testDirectory, 'swift-child-environment-harness.swift'),
]

function compileHarness() {
  const testRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-child-environment-test-'))
  const binaryPath = path.join(testRoot, 'harness')
  const compile = spawnSync('xcrun', [
    'swiftc', '-D', 'DSH_TESTING', '-module-cache-path', path.join(testRoot, 'module-cache'),
    ...sources, '-o', binaryPath,
  ], { encoding: 'utf8', timeout: 120000 })
  assert.equal(compile.status, 0, compile.stderr || compile.stdout)
  assert.equal(
    compile.stderr.trim(),
    '',
    'the harness must compile without warnings so a Swift 6 regression is visible here'
  )
  return { testRoot, binaryPath }
}

test('the child environment drops the launching shell package-manager session', () => {
  const { testRoot, binaryPath } = compileHarness()
  try {
    // The harness classifies a polluted environment in-process; it needs no
    // shell, no bundled Node, and no package manager.
    const run = spawnSync(binaryPath, [], { encoding: 'utf8', timeout: 30000 })
    assert.equal(run.status, 0, `${run.stderr || run.stdout}`)
    assert.match(run.stdout, /swift child environment harness passed/)
  } finally {
    fs.rmSync(testRoot, { recursive: true, force: true })
  }
})

test('the managed runtime builds its child environment through the sanitizer', () => {
  const runtimeSource = fs.readFileSync(
    path.join(repositoryDirectory, 'Sources', 'Service', 'NodeRuntime.swift'),
    'utf8',
  )
  assert.match(
    runtimeSource,
    /NodeChildEnvironment\.sanitized\(ProcessInfo\.processInfo\.environment\)/,
    'buildEnvironment must sanitize the inherited environment',
  )
  assert.doesNotMatch(
    runtimeSource,
    /env\["NODE_OPTIONS"\]/,
    'the sanitizer owns NODE_OPTIONS; buildEnvironment must not silently re-add it',
  )
  // The values the child genuinely needs are assigned explicitly, after
  // sanitizing, so the sanitizer cannot take configuration away from the app.
  assert.match(runtimeSource, /env\["PATH"\] = resolveUserPath\(\)/)
  assert.match(runtimeSource, /env\["DSH_DESKTOP"\] = "1"/)
  assert.match(runtimeSource, /env\["DSH_NODE_BIN"\] = nodeBin/)
})
