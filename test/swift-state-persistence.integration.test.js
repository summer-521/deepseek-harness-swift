import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import { fileURLToPath } from 'node:url'

const repositoryDirectory = path.join(path.dirname(fileURLToPath(import.meta.url)), '..')
const harnessSources = [
  path.join(repositoryDirectory, 'Sources', 'State', 'DshState.swift'),
  path.join(repositoryDirectory, 'test', 'swift-state-persistence-harness.swift'),
]

function runHarness(binaryPath, mode, root) {
  const run = spawnSync(binaryPath, [mode], {
    env: {
      ...process.env,
      DSH_HOME: path.join(root, 'dsh-home'),
      DSH_TEST_APP_SUPPORT: path.join(root, 'application-support'),
    },
    encoding: 'utf8',
    timeout: 30000,
  })
  assert.equal(run.status, 0, `${mode}: ${run.stderr || run.stdout}`)
  assert.match(run.stdout, new RegExp(`swift state persistence harness passed: ${mode}`))
}

test('primary state persistence distinguishes first install, legacy, corruption, and write failures', () => {
  const testRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-state-persistence-test-'))
  const binaryPath = path.join(testRoot, 'harness')
  const moduleCachePath = path.join(testRoot, 'module-cache')
  try {
    const compile = spawnSync('xcrun', [
      'swiftc', '-D', 'DSH_TESTING', '-module-cache-path', moduleCachePath,
      ...harnessSources, '-o', binaryPath,
    ], { encoding: 'utf8', timeout: 120000 })
    assert.equal(compile.status, 0, compile.stderr || compile.stdout)

    for (const mode of ['first-launch', 'legacy', 'corrupt', 'unreadable', 'write-failure', 'startup-decision', 'idle-transaction-owner', 'install-source']) {
      const root = path.join(testRoot, mode)
      fs.mkdirSync(root, { recursive: true })
      runHarness(binaryPath, mode, root)
    }
  } finally {
    fs.rmSync(testRoot, { recursive: true, force: true })
  }
})

test('service startup treats process-record persistence as a required handoff', () => {
  const serviceSource = fs.readFileSync(
    path.join(repositoryDirectory, 'Sources', 'Service', 'DshService.swift'),
    'utf8',
  )
  assert.match(serviceSource, /try saveProcessRecord\(processRecord\)/)
  assert.match(serviceSource, /catch \{[\s\S]*?await stopAndWait\(\)[\s\S]*?ServiceError\.startupFailed\("无法保存 DSH 服务进程记录/)
  assert.match(serviceSource, /private func saveProcessRecord\(_ record: DshProcessRecord\) throws/)
  assert.doesNotMatch(serviceSource, /Failed to save process record:[\s\S]*?print/)
})

test('corrupt primary state stops startup before recovery and has no reset action', () => {
  const appSource = fs.readFileSync(
    path.join(repositoryDirectory, 'Sources', 'AppDelegate.swift'),
    'utf8',
  )
  const windowSource = fs.readFileSync(
    path.join(repositoryDirectory, 'Sources', 'MainWindow', 'MainWindowController.swift'),
    'utf8',
  )
  assert.ok(
    appSource.indexOf('DshStateStartupDecision.decide')
      < appSource.indexOf('prepareForProfileMutation'),
    'state decision must precede Runtime/Profile recovery',
  )
  assert.match(appSource, /blockStartupForStateFailure\(detail\)/)
  assert.match(appSource, /try await SettingsViewModel\.shared\.recoverPendingProfileSwitch\(\)/)
  assert.match(appSource, /try await SettingsViewModel\.shared\.recoverPendingRuntimeUpdate\(\)/)
  assert.match(windowSource, /public func blockStartupForStateFailure\(_ detail: String\)/)
  assert.match(windowSource, /makeStatePersistenceRecoveryContext\(\)/)
  assert.match(windowSource, /try await SettingsViewModel\.shared\.recordHealthyRuntimeStart\(for: context\)/)
  assert.match(windowSource, /try DshStateManager\.shared\.updateOrThrow/)
  assert.match(windowSource, /未执行重试或修改/)
  assert.doesNotMatch(windowSource, /Button\("重置/)
})
