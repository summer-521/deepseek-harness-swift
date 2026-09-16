import assert from 'node:assert/strict'
import fs from 'node:fs'
import path from 'node:path'
import test from 'node:test'
import { fileURLToPath } from 'node:url'

import { groups } from './harness-sources.mjs'

const testDirectory = path.dirname(fileURLToPath(import.meta.url))
const repositoryDirectory = path.join(testDirectory, '..')

test('every shared harness source exists', () => {
  for (const [name, sources] of Object.entries(groups)) {
    assert.ok(sources.length > 0, `${name} is empty`)
    for (const file of sources) {
      assert.ok(
        fs.existsSync(file),
        `${name} names a source that does not exist: ${path.relative(repositoryDirectory, file)}`,
      )
    }
    assert.equal(
      new Set(sources).size,
      sources.length,
      `${name} lists the same file twice`,
    )
  }
})

test('the shared sets grow by addition only', () => {
  const contains = (superset, subset, label) => {
    for (const file of subset) {
      assert.ok(
        superset.includes(file),
        `${label} is missing ${path.relative(repositoryDirectory, file)}`,
      )
    }
  }
  contains(groups.versionSources, groups.runtimeSources, 'versionSources')
  contains(groups.pluginSources, groups.versionSources, 'pluginSources')
  contains(groups.pluginOperationSources, groups.pluginSources, 'pluginOperationSources')
  contains(groups.pluginProductChainSources, groups.pluginOperationSources, 'pluginProductChainSources')
})

test('every source a harness names is a file that exists', () => {
  const harnessTests = fs.readdirSync(testDirectory)
    .filter((name) => name.endsWith('.integration.test.js'))
  assert.ok(harnessTests.length > 0, 'the suite has integration harnesses')

  // Both path styles the harnesses use: `path.join(repositoryDirectory, …)`
  // and `path.join(testDirectory, '..', …)`, with either quote character.
  const literal = /['"]Sources['"]\s*,\s*['"]([A-Za-z]+)['"]\s*,\s*['"]([A-Za-z0-9]+\.swift)['"]/g
  for (const name of harnessTests) {
    const source = fs.readFileSync(path.join(testDirectory, name), 'utf8')
    for (const [, directory, file] of source.matchAll(literal)) {
      const relative = path.join('Sources', directory, file)
      assert.ok(
        fs.existsSync(path.join(repositoryDirectory, relative)),
        `${name} compiles a source that does not exist: ${relative}`,
      )
    }
  }
})

test('a harness that touches the managed runtime spreads a shared set', () => {
  // The runtime/version stack is what every new `Sources` file lands in, so a
  // harness that compiles it must take it from the manifest: a hand-written
  // list would silently miss the next addition. Harnesses with their own
  // unrelated stack (bridge, diagnostics, process I/O) are left alone.
  const runtimeStack = new Set([
    'DshState.swift',
    'NodeChildEnvironment.swift',
    'NodeRuntime.swift',
    'DshLaunchContext.swift',
    'DshSemanticVersion.swift',
    'DshVersionManager.swift',
    'DshFamilyClosure.swift',
    'DshProfileLinkRepair.swift',
  ])
  for (const name of fs.readdirSync(testDirectory).filter((f) => f.endsWith('.integration.test.js'))) {
    const source = fs.readFileSync(path.join(testDirectory, name), 'utf8')
    // Only the compile list counts: a harness may also *read* an app source
    // (as a fixture or a source assertion) without compiling it.
    const block = source.match(/const sources = \[([\s\S]*?)\n\]/)?.[1] ?? ''
    const listed = [...block.matchAll(/['"]Sources['"][^)\n]*['"](\w+\.swift)['"]/g)]
      .map((match) => match[1])
    // A harness is bound by the rule when it takes a shared set, or when it
    // compiles the runtime by hand.
    const takesSharedSet = /\.\.\.\w+Sources\b/.test(block)
    if (!takesSharedSet && !listed.includes('NodeRuntime.swift')) continue
    const handWritten = listed.filter((file) => runtimeStack.has(file))
    assert.deepEqual(
      handWritten,
      [],
      `${name} must spread \`...versionSources\` (or a larger set) instead of naming ${handWritten.join(', ')}`,
    )
  }
})
