import assert from 'node:assert/strict'
import fs from 'node:fs'
import path from 'node:path'
import test from 'node:test'
import { fileURLToPath } from 'node:url'

import { functionBody } from './source-assertions.mjs'

// The repair itself is covered by `swift-profile-link-repair-harness.swift`.
// What cannot run in a harness is the entry point around it: the app menu item
// and the controller method that decides how much of the Profile root a
// user-triggered repair is allowed to write.

const testDirectory = path.dirname(fileURLToPath(import.meta.url))
const repositoryDirectory = path.join(testDirectory, '..')
const read = (relative) => fs.readFileSync(path.join(repositoryDirectory, relative), 'utf8')

const controller = read(path.join('Sources', 'MainWindow', 'MainWindowController.swift'))
const appDelegate = read(path.join('Sources', 'AppDelegate.swift'))

test('a launch repairs only the Profile it owns', () => {
  assert.match(
    controller,
    /restrictingTo: \[context\.profileDirectory\]/,
    'the launch-time pass stays scoped: another Profile is shared with the CLI',
  )
})

test('the explicit repair covers every Profile and reports what it did', () => {
  const entry = functionBody(controller, 'public func repairAllProfileLinks()')
  assert.match(entry, /Task \{ await performProfileLinkRepair\(\) \}/)

  const body = functionBody(controller, 'private func performProfileLinkRepair() async')
  assert.match(body, /DshProfileLinkRepair\.repairDanglingLinks\(/)
  assert.doesNotMatch(
    body,
    /restrictingTo:/,
    'a user-triggered repair must not be scoped to one Profile',
  )
  assert.match(body, /diagnosticStore\.appendLog\(/, 'the pass is recorded in the launch log')
  assert.match(body, /presentProfileLinkRepairAlert\(/, 'the outcome is reported to the user')
  // Nothing to repair is a normal outcome, not a failure.
  assert.match(body, /outcome\.isNoop/)
  assert.match(
    body,
    /outcome\.unresolved\.isEmpty/,
    'links the Runtime cannot satisfy are reported instead of being dropped silently',
  )
  assert.match(
    body,
    /outcome\.scanFailures/,
    'directories the pass could not read are reported, not treated as empty',
  )
  assert.match(
    body,
    /outcome\.leftProfilePartiallyMoved/,
    'a partly failed rollback is reported instead of being swallowed',
  )
  // Without a launched Runtime there is nothing to re-point at.
  assert.match(body, /guard let context = currentLaunchContext else/)
})

test('the explicit repair is a writer and takes the writer gates', () => {
  const body = functionBody(controller, 'private func performProfileLinkRepair() async')
  // The managed service installs and removes plugins in the same tree; the
  // repair quiesces it exactly like a plugin or Runtime transaction does.
  assert.match(
    body,
    /try await DshService\.shared\.prepareForProfileMutation\(context: context\)/,
    'the pass must stop the service that writes the same tree',
  )
  // And it refuses to run while another transaction is open.
  assert.match(body, /coordinator\.pendingOperation == nil/)
  assert.match(body, /!coordinator\.hasPersistedOperationRecord/)
  // The service was stopped for the repair, so the App is brought back after.
  assert.match(body, /startAndLoadDsh\(\)/)
})

test('the menu exposes the repair and reaches the controller', () => {
  assert.match(appDelegate, /withTitle: "修复 Profile 依赖链接"/)
  assert.match(appDelegate, /#selector\(repairProfileLinks\)/)
  assert.match(
    appDelegate,
    /@objc private func repairProfileLinks\(\) \{\s*\n\s*MainWindowController\.shared\.repairAllProfileLinks\(\)/,
  )
})
