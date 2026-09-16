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
  const body = functionBody(controller, 'public func repairAllProfileLinks()')
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
  // Without a launched Runtime there is nothing to re-point at.
  assert.match(body, /guard let context = currentLaunchContext else/)
})

test('the menu exposes the repair and reaches the controller', () => {
  assert.match(appDelegate, /withTitle: "修复 Profile 依赖链接"/)
  assert.match(appDelegate, /#selector\(repairProfileLinks\)/)
  assert.match(
    appDelegate,
    /@objc private func repairProfileLinks\(\) \{\s*\n\s*MainWindowController\.shared\.repairAllProfileLinks\(\)/,
  )
})
