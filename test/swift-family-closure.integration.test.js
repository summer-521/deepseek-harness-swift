import assert from 'node:assert/strict'
import { spawn, spawnSync } from 'node:child_process'
import fs from 'node:fs'
import http from 'node:http'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import { fileURLToPath } from 'node:url'

const testDirectory = path.dirname(fileURLToPath(import.meta.url))
const sources = [
  path.join(testDirectory, '..', 'Sources', 'Versions', 'DshFamilyClosure.swift'),
  path.join(testDirectory, 'swift-family-closure-harness.swift'),
]

function compileHarness() {
  const testRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-family-closure-test-'))
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

test('the plugin family is derived from the registry graph, not a frozen list', () => {
  const { testRoot, binaryPath } = compileHarness()
  try {
    // The harness drives every scenario from in-memory stub registries, so the
    // run needs no network and cannot drift with what npm currently publishes.
    const run = spawnSync(binaryPath, [], { encoding: 'utf8', timeout: 30000 })
    assert.equal(run.status, 0, `${run.stderr || run.stdout}`)
    assert.match(run.stdout, /swift family closure harness passed/)
  } finally {
    fs.rmSync(testRoot, { recursive: true, force: true })
  }
})

// One flat manifest graph per version. The stub registry answers by path, so
// the harness exercises the real URL builder, the real status mapping, and the
// real accept header instead of a fake loader.
const graphs = {
  // A registry that can serve the release except for one 5xx and one 404.
  '1.0.0': {
    '@deepseek-ai/dsh': {
      status: 200,
      body: {
        name: '@deepseek-ai/dsh',
        version: '1.0.0',
        dependencies: {
          '@deepseek-ai/dsh-base': '^1.0.0',
          '@deepseek-ai/dsh-web-app': '^1.0.0',
          '@deepseek-ai/dsh-foo': '^1.0.0',
          '@deepseek-ai/dsh-bar': '^1.0.0',
          '@deepseek-ai/cordis': '^1.0.0',
        },
      },
    },
    '@deepseek-ai/dsh-base': {
      status: 200,
      body: { name: '@deepseek-ai/dsh-base', version: '1.0.0' },
    },
    '@deepseek-ai/dsh-web-app': {
      status: 200,
      body: {
        name: '@deepseek-ai/dsh-web-app',
        version: '1.0.0',
        peerDependencies: { '@deepseek-ai/dsh-peer': '^1.0.0' },
      },
    },
    '@deepseek-ai/dsh-peer': {
      status: 200,
      body: { name: '@deepseek-ai/dsh-peer', version: '1.0.0' },
    },
    '@deepseek-ai/dsh-foo': { status: 500 },
    '@deepseek-ai/dsh-bar': { status: 404 },
  },
  // The same release on a complete registry: every member is published.
  '1.0.0-aligned': {
    '@deepseek-ai/dsh': {
      status: 200,
      body: {
        name: '@deepseek-ai/dsh',
        version: '1.0.0-aligned',
        dependencies: {
          '@deepseek-ai/dsh-base': '^1.0.0',
          '@deepseek-ai/dsh-web-app': '^1.0.0',
          '@deepseek-ai/dsh-foo': '^1.0.0',
          '@deepseek-ai/dsh-bar': '^1.0.0',
          '@deepseek-ai/cordis': '^1.0.0',
        },
      },
    },
    '@deepseek-ai/dsh-base': {
      status: 200,
      body: { name: '@deepseek-ai/dsh-base', version: '1.0.0-aligned' },
    },
    '@deepseek-ai/dsh-web-app': {
      status: 200,
      body: {
        name: '@deepseek-ai/dsh-web-app',
        version: '1.0.0-aligned',
        peerDependencies: { '@deepseek-ai/dsh-peer': '^1.0.0' },
      },
    },
    '@deepseek-ai/dsh-peer': {
      status: 200,
      body: { name: '@deepseek-ai/dsh-peer', version: '1.0.0-aligned' },
    },
    '@deepseek-ai/dsh-foo': {
      status: 200,
      body: { name: '@deepseek-ai/dsh-foo', version: '1.0.0-aligned' },
    },
    '@deepseek-ai/dsh-bar': {
      status: 200,
      body: { name: '@deepseek-ai/dsh-bar', version: '1.0.0-aligned' },
    },
  },
  // A registry that is briefly flaky: this manifest answers only after two 5xx
  // responses, which the loader retries instead of failing the walk.
  '1.0.0-retry': {
    '@deepseek-ai/dsh': {
      status: 200,
      body: {
        name: '@deepseek-ai/dsh',
        version: '1.0.0-retry',
        dependencies: {
          '@deepseek-ai/dsh-base': '^1.0.0',
          '@deepseek-ai/dsh-flaky': '^1.0.0',
        },
      },
    },
    '@deepseek-ai/dsh-base': {
      status: 200,
      body: { name: '@deepseek-ai/dsh-base', version: '1.0.0-retry' },
    },
    '@deepseek-ai/dsh-web-app': {
      status: 200,
      body: { name: '@deepseek-ai/dsh-web-app', version: '1.0.0-retry' },
    },
    '@deepseek-ai/dsh-flaky': {
      status: 200,
      failuresBeforeSuccess: 2,
      body: { name: '@deepseek-ai/dsh-flaky', version: '1.0.0-retry' },
    },
  },
}

test('the registry loader keeps absence, failure, and success apart', async () => {
  const requests = []
  const attempts = new Map()
  const server = http.createServer((request, response) => {
    const segments = decodeURIComponent(request.url).split('/')
    const name = `${segments[1]}/${segments[2]}`
    const version = segments[3]
    requests.push({ path: request.url, accept: request.headers.accept ?? '' })
    const attempt = (attempts.get(request.url) ?? 0) + 1
    attempts.set(request.url, attempt)
    const entry = graphs[version]?.[name]
    if (!entry) {
      response.writeHead(404, { 'content-type': 'application/json' })
      response.end('{"error":"Not found"}')
      return
    }
    const failing = entry.failuresBeforeSuccess !== undefined && attempt <= entry.failuresBeforeSuccess
    const status = failing ? 500 : entry.status
    response.writeHead(status, { 'content-type': 'application/json' })
    response.end(status === 200 ? JSON.stringify(entry.body) : '{"error":"boom"}')
  })

  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve))
  const { testRoot, binaryPath } = compileHarness()
  try {
    const registry = `http://127.0.0.1:${server.address().port}`

    // The probe must not block the event loop: the stub registry runs in this
    // process, so a synchronous spawn would deadlock against it.
    function probe(version) {
      return new Promise((resolve, reject) => {
        const child = spawn(binaryPath, ['registry', registry, version])
        let stdout = ''
        let stderr = ''
        const timer = setTimeout(() => {
          child.kill('SIGKILL')
          reject(new Error(`the registry probe for ${version} timed out`))
        }, 60000)
        child.stdout.on('data', (chunk) => { stdout += chunk })
        child.stderr.on('data', (chunk) => { stderr += chunk })
        child.on('error', reject)
        child.on('close', (code) => {
          clearTimeout(timer)
          assert.equal(code, 0, `${stderr || stdout}`)
          assert.match(stdout, /swift family closure harness passed/)
          const read = (key) => stdout.match(new RegExp(`^${key}=(.*)$`, 'm'))?.[1] ?? ''
          resolve({
            available: read('available').split(',').filter(Boolean),
            missing: read('missing').split(',').filter(Boolean),
            unreachable: read('unreachable').split(',').filter(Boolean),
            unresolvedRoots: read('unresolvedRoots').split(',').filter(Boolean),
            complete: read('complete') === 'true',
          })
        })
      })
    }

    const partial = await probe('1.0.0')
    assert.deepEqual(
      partial.missing,
      ['@deepseek-ai/dsh-bar'],
      'a 404 is the only evidence that a release is incomplete'
    )
    assert.deepEqual(
      partial.unreachable,
      ['@deepseek-ai/dsh-foo'],
      'a 5xx must be reported as unreadable, never as unpublished'
    )
    assert.deepEqual(partial.unresolvedRoots, [], 'the roots resolved')
    assert.deepEqual(
      partial.available,
      ['@deepseek-ai/dsh-base', '@deepseek-ai/dsh-peer', '@deepseek-ai/dsh-web-app'],
      'the family is the declared seam packages; the aggregate and cordis stay out'
    )
    assert.equal(partial.complete, false, 'an incomplete registry must fail closed')

    const aligned = await probe('1.0.0-aligned')
    assert.equal(aligned.complete, true, 'a complete registry passes')
    assert.deepEqual(aligned.missing, [], 'nothing is missing')
    assert.deepEqual(aligned.unreachable, [], 'nothing is unreadable')
    assert.deepEqual(
      aligned.available,
      [
        '@deepseek-ai/dsh-bar',
        '@deepseek-ai/dsh-base',
        '@deepseek-ai/dsh-foo',
        '@deepseek-ai/dsh-peer',
        '@deepseek-ai/dsh-web-app',
      ],
      `five seam members, including the peer-only one: ${aligned.available}`
    )

    // A manifest that fails twice and then answers must not fail the install:
    // one flaky response in a walk of a few hundred requests is not evidence
    // that a release is incomplete.
    const retried = await probe('1.0.0-retry')
    assert.equal(retried.complete, true, 'a transient 5xx must not fail the walk')
    assert.deepEqual(retried.unreachable, [], 'the retried manifest is readable in the end')
    assert.deepEqual(
      retried.available,
      ['@deepseek-ai/dsh-base', '@deepseek-ai/dsh-flaky', '@deepseek-ai/dsh-web-app'],
      `the retried family is complete: ${retried.available}`
    )
    const flakyAttempts = requests.filter(
      (entry) => entry.path === '/@deepseek-ai/dsh-flaky/1.0.0-retry'
    ).length
    assert.equal(flakyAttempts, 3, `the flaky manifest must be retried, saw ${flakyAttempts}`)

    // npm answers 406 when the packument-only install-v1 format is asked of a
    // version-specific URL, which would make every release look unreachable.
    assert.ok(requests.length > 0, 'the harness reached the stub registry')
    for (const request of requests) {
      assert.doesNotMatch(
        request.accept,
        /install-v1/,
        `the version endpoint must not ask for the packument format: ${request.path}`
      )
      assert.match(
        request.path,
        /^\/@deepseek-ai\/[a-z-]+\/[0-9]/,
        `the version endpoint is addressed as <name>/<version>: ${request.path}`
      )
    }
    const requested = new Set(requests.map((entry) => entry.path))
    for (const expected of [
      '/@deepseek-ai/dsh/1.0.0',
      '/@deepseek-ai/dsh-base/1.0.0',
      '/@deepseek-ai/dsh-web-app/1.0.0',
      '/@deepseek-ai/dsh-peer/1.0.0',
      '/@deepseek-ai/dsh-foo/1.0.0',
      '/@deepseek-ai/dsh-bar/1.0.0',
    ]) {
      assert.ok(requested.has(expected), `${expected} must be requested, saw ${[...requested]}`)
    }
  } finally {
    await new Promise((resolve) => server.close(resolve))
    fs.rmSync(testRoot, { recursive: true, force: true })
  }
})
