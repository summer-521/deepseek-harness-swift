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
  assert.match(
    body,
    /outcome\.conflicts/,
    'links another writer replaced underneath the pass are reported, not overwritten',
  )
  assert.match(body, /conflicts=\\\(outcome\.conflicts\.count\)/, 'the launch log carries the conflict count')
  // Without a launched Runtime there is nothing to re-point at.
  assert.match(body, /guard let context = currentLaunchContext else/)
})

test('the explicit repair is a writer and takes the writer gates', () => {
  const body = functionBody(controller, 'private func performProfileLinkRepair() async')
  // Checking the coordinator is not enough: a Runtime update, a Profile switch
  // or a start can begin while the await above is suspended. The pass therefore
  // runs under the same serial gate every Runtime/Profile transaction takes.
  assert.match(
    body,
    /try await withRuntimeOperation \{/,
    'the pass must hold the runtime operation gate, not only observe the coordinator',
  )
  // The managed service installs and removes plugins in the same tree; the
  // repair quiesces it exactly like a plugin or Runtime transaction does.
  assert.match(
    body,
    /try await DshService\.shared\.prepareForProfileMutation\(context: context\)/,
    'the pass must stop the service that writes the same tree',
  )
  // The service was stopped for the repair, so the App is brought back after.
  assert.match(body, /startAndLoadDsh\(\)/)
})

test('the preconditions are checked again while the gate is held', () => {
  const body = functionBody(controller, 'private func performProfileLinkRepair() async')
  const gate = body.slice(body.indexOf('withRuntimeOperation {'))
  // Everything read before the wait may be stale by the time the gate is
  // acquired: a Runtime switch or a plugin transaction that finished in the
  // meantime would leave the pass re-pointing links at a Runtime nobody runs.
  assert.match(
    gate,
    /try validateProfileLinkRepair\(context: context\)/,
    'the checks must run inside the gate, not only before it',
  )
  assert.ok(
    gate.indexOf('validateProfileLinkRepair') < gate.indexOf('prepareForProfileMutation'),
    'the context is validated before the service is stopped for the write',
  )

  // The same check is made before the gate is requested, so a user who clicks
  // while a plugin transaction holds it gets an answer instead of waiting.
  const early = body.slice(0, body.indexOf('withRuntimeOperation {'))
  assert.match(early, /try validateProfileLinkRepair\(context: context\)/)

  const validator = functionBody(controller, 'private func validateProfileLinkRepair(context: DshLaunchContext) throws')
  assert.match(validator, /coordinator\.pendingOperation == nil/)
  assert.match(validator, /!coordinator\.hasPersistedOperationRecord/)
  assert.match(
    validator,
    /context\.isFresh\(in: DshStateManager\.shared\.current\)/,
    'a Runtime or Profile transaction that completed during the wait must be caught',
  )
  // A stale context and an open plugin transaction are different answers for the
  // user, so they are different failure kinds.
  assert.match(validator, /throw DshLaunchContextError\.staleContext/)
  assert.match(validator, /throw ProfileLinkRepairUnavailable\.pluginOperationInProgress/)
  assert.match(controller, /enum ProfileLinkRepairUnavailable: Error, LocalizedError/)
})

test('the menu exposes the repair and reaches the controller', () => {
  assert.match(appDelegate, /withTitle: "修复 Profile 依赖链接"/)
  assert.match(appDelegate, /#selector\(repairProfileLinks\)/)
  assert.match(
    appDelegate,
    /@objc private func repairProfileLinks\(\) \{\s*\n\s*MainWindowController\.shared\.repairAllProfileLinks\(\)/,
  )
})

test('the repair re-reads each link before it replaces it', () => {
  // `runtimeOperationGate` serializes this App, and nothing else: the terminal's
  // `dsh` and the `pnpm` it runs write the shared web Profile too. The linkage
  // that closes that window is a fresh read compared with what the scan planned
  // against, so it is pinned here — the window itself cannot be forced in the
  // harness.
  const repair = read(path.join('Sources', 'Versions', 'DshProfileLinkRepair.swift'))
  const forwardGuard = repair.indexOf('currentDestination(of: move.link, fileManager: fileManager) == move.original')
  const forwardSwap = repair.indexOf(
    'try replaceLink(at: move.link, withDestination: move.next, fileManager: fileManager)',
  )
  assert.ok(forwardGuard > 0, 'the forward swap must compare the link with the scanned destination')
  assert.ok(forwardSwap > forwardGuard, 'and compare it before replacing anything')
  assert.match(
    repair,
    /guard currentDestination\(of: move\.link, fileManager: fileManager\) == move\.original else \{\s*\n\s*conflicts\.append/,
    'a changed link becomes a conflict rather than being overwritten',
  )

  const rollbackGuard = repair.indexOf('currentDestination(of: move.link, fileManager: fileManager) == move.next')
  const rollbackSwap = repair.indexOf(
    'try replaceLink(at: move.link, withDestination: move.original, fileManager: fileManager)',
  )
  assert.ok(rollbackGuard > 0, 'the rollback must compare the link too')
  assert.ok(rollbackSwap > rollbackGuard, 'and must not restore over a newer external write')
  assert.match(
    repair,
    /guard currentDestination\(of: move\.link, fileManager: fileManager\) == move\.next else \{\s*\n\s*conflicts\.append/,
  )

  // The read is compared with a value that is never nil, so an unreadable link
  // can only ever become a conflict — never look like an unchanged one.
  assert.match(
    repair,
    /private static func currentDestination\(of link: URL, fileManager: FileManager\) -> String\? \{\s*\n\s*try\? fileManager\.destinationOfSymbolicLink/,
  )
  assert.match(repair, /var conflicts: \[String\] = \[\]/)
})

test('the Runtime prefix is resolved without depending on the canonical-path cache', () => {
  // `URL.resolvingSymlinksInPath()` caches canonical paths per process and can
  // hand back an unresolved answer for a path whose symlink appeared after an
  // earlier lookup — the same input, two answers, in one pass. `realpath(3)`
  // answers at the kernel, and the longest existing prefix is resolved so that
  // dangling links (the usual case here) still resolve their parents.
  const repair = read(path.join('Sources', 'Versions', 'DshProfileLinkRepair.swift'))
  assert.match(repair, /static func canonicalPath\(of path: String\) -> String \{/)
  assert.match(repair, /if let buffer = realpath\(candidate, nil\)/)
  assert.match(repair, /trailing\.insert\(/)
  assert.doesNotMatch(
    repair,
    /\.resolvingSymlinksInPath\(\)/,
    'the comparison must not go through Foundation\'s cached resolution',
  )
  // The resolved comparison is not conditional on the root having changed.
  const suffix = functionBody(repair, 'func suffix(of target: String) -> String?')
  assert.doesNotMatch(suffix, /guard let resolved/, 'a canonical root must not switch the comparison off')
  assert.match(suffix, /if let value = Self\.relative\(target, under: literal\) \{ return value \}/)
  assert.match(suffix, /return Self\.relative\(DshProfileLinkRepair\.canonicalPath\(of: target\), under: resolved\)/)
})
