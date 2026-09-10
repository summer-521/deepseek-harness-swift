import assert from 'node:assert/strict'
import { spawn, spawnSync } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import { fileURLToPath } from 'node:url'

const testDirectory = path.dirname(fileURLToPath(import.meta.url))
const repositoryDirectory = path.join(testDirectory, '..')
const lockSource = path.join(
  repositoryDirectory,
  'Sources',
  'Service',
  'DshInstanceLock.swift',
)
const harnessSource = path.join(testDirectory, 'swift-instance-lock-harness.swift')
const read = (relative) => fs.readFileSync(path.join(repositoryDirectory, relative), 'utf8')

function run(binaryPath, scenario, lockDirectory, timeout = 20000) {
  return spawnSync(binaryPath, [scenario], {
    env: { ...process.env, DSH_INSTANCE_LOCK_DIR: lockDirectory },
    encoding: 'utf8',
    timeout,
  })
}

function assertRun(binaryPath, scenario, lockDirectory, expected) {
  const result = run(binaryPath, scenario, lockDirectory)
  assert.equal(
    result.status,
    0,
    `${scenario} failed (status ${result.status})\nstdout:\n${result.stdout}\nstderr:\n${result.stderr}`,
  )
  assert.match(result.stdout, new RegExp(expected))
}

function startHolder(binaryPath, lockDirectory) {
  const child = spawn(binaryPath, ['hold'], {
    env: { ...process.env, DSH_INSTANCE_LOCK_DIR: lockDirectory },
    encoding: 'utf8',
  })
  return new Promise((resolve, reject) => {
    let stdout = ''
    let stderr = ''
    const timer = setTimeout(() => {
      child.kill('SIGKILL')
      reject(new Error(`holder never reported the lock\nstdout:${stdout}\nstderr:${stderr}`))
    }, 20000)
    child.stdout.on('data', (chunk) => {
      stdout += chunk
      if (stdout.includes('instance lock held')) {
        clearTimeout(timer)
        resolve(child)
      }
    })
    child.stderr.on('data', (chunk) => {
      stderr += chunk
    })
    child.on('exit', (code) => {
      clearTimeout(timer)
      reject(new Error(`holder exited early (${code})\nstdout:${stdout}\nstderr:${stderr}`))
    })
  })
}

test('the instance lock serializes one Application Support root across processes', async () => {
  const moduleCachePath = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-instance-lock-cache-'))
  const binaryPath = path.join(moduleCachePath, 'harness')
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-instance-lock-'))
  const lockDirectory = path.join(root, 'app-support')
  try {
    const compile = spawnSync('xcrun', [
      'swiftc',
      '-module-cache-path',
      moduleCachePath,
      lockSource,
      harnessSource,
      '-o',
      binaryPath,
    ], { encoding: 'utf8', timeout: 120000 })
    assert.equal(compile.status, 0, compile.stderr || compile.stdout)

    // A free lock is acquirable, and an explicit release frees it again.
    assertRun(binaryPath, 'release-in-process', lockDirectory, 'release and reacquire passed')

    // While a live process holds the lock, a second process must be refused
    // and must receive the holder diagnostics.
    const holder = await startHolder(binaryPath, lockDirectory)
    assertRun(binaryPath, 'expect-held', lockDirectory, 'instance lock held by pid \\d+')

    // SIGKILL must release the kernel-owned lock: no stale-lock state exists.
    holder.kill('SIGKILL')
    await new Promise((resolve) => holder.on('exit', resolve))
    assertRun(binaryPath, 'expect-free', lockDirectory, 'acquired after the holder died')

    // Different Application Support roots stay independent (the test seam).
    assertRun(binaryPath, 'isolated-roots', root, 'scoped per Application Support root')

    // A root the process cannot write reports "unavailable" instead of
    // pretending the lock is held, so the caller may fail open.
    assertRun(
      binaryPath,
      'unavailable-when-readonly',
      root,
      'limited environment instead of blocking startup|permission probe skipped',
    )

    // A lock path occupied by anything but this app's regular file is a hard
    // failure: starting anyway would silently drop the single-instance
    // guarantee that the shared state and rollback snapshots depend on.
    assertRun(
      binaryPath,
      'blocked-when-directory',
      path.join(root, 'blocked-directory'),
      'refuses a directory at the lock path',
    )
    assertRun(
      binaryPath,
      'blocked-when-symlink',
      path.join(root, 'blocked-symlink'),
      'refuses a symlink at the lock path',
    )
    assertRun(
      binaryPath,
      'blocked-when-dangling-symlink',
      path.join(root, 'blocked-dangling-symlink'),
      'refuses a dangling symlink without creating its target',
    )
  } finally {
    fs.rmSync(moduleCachePath, { recursive: true, force: true })
    fs.rmSync(root, { recursive: true, force: true })
  }
})

test('the app takes the instance lock before touching durable state', () => {
  const appSource = read('Sources/AppDelegate.swift')
  const infoPlist = read('Info.plist')
  const acquire = appSource.indexOf('DshInstanceLock.acquire(')
  assert.ok(acquire > 0, 'AppDelegate must acquire the instance lock')
  assert.ok(
    acquire < appSource.indexOf('beginStartupPreparation()'),
    'the lock must be taken before any startup preparation can read state',
  )
  assert.ok(
    acquire < appSource.indexOf('DshStateManager.shared.loadResult'),
    'the lock must be taken before the first durable state read',
  )
  assert.match(appSource, /NSApp\.terminate\(nil\)/, 'a held lock must stop this launch')
  assert.match(appSource, /Instance lock unavailable, continuing without cross-process protection/)
  assert.match(infoPlist, /<key>LSMultipleInstancesProhibited<\/key>\s*\n\s*<true\/>/)

  // T3: a blocked lock path must fail closed (alert + stop), while only a
  // genuinely limited environment may continue without protection.
  const blockedCase = appSource.indexOf('case .blocked(let detail):')
  const unavailableCase = appSource.indexOf('case .unavailable(let detail):')
  assert.ok(blockedCase > 0, 'AppDelegate must handle a blocked instance lock')
  assert.ok(
    blockedCase < unavailableCase,
    'the blocked branch must be separate from the fail-open branch',
  )
  assert.match(
    appSource.slice(blockedCase, unavailableCase),
    /presentBlockedInstanceLockAlert\(detail\)[\s\S]*NSApp\.terminate\(nil\)/,
    'a blocked lock path must present the reason and stop the launch',
  )
  assert.match(
    appSource,
    /private func presentBlockedInstanceLockAlert[\s\S]*DshInstanceLock\.fileName/,
    'the blocked-launch alert must name the lock file the user has to fix',
  )
  assert.match(
    read('Sources/Service/DshInstanceLock.swift'),
    /case EACCES, EPERM, EROFS, ENOSPC:[\s\S]*return \.unavailable/,
    'only permission- and capacity-shaped errors may stay fail-open',
  )
})
