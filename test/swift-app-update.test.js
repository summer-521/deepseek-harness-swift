import assert from 'node:assert/strict'
import fs from 'node:fs'
import path from 'node:path'
import test from 'node:test'
import { fileURLToPath } from 'node:url'

// Sparkle's install hooks cannot run in a harness: the updater is an app-target
// dependency, and its driver only calls the delegate during a real install.
// These assertions therefore pin the wiring in the source, which is the same
// shape the rest of the app-lifecycle checks use.

const testDirectory = path.dirname(fileURLToPath(import.meta.url))
const repositoryDirectory = path.join(testDirectory, '..')
const read = (relative) => fs.readFileSync(path.join(repositoryDirectory, relative), 'utf8')

const updateSource = read(path.join('Sources', 'Updates', 'AppUpdateManager.swift'))
const appDelegateSource = read(path.join('Sources', 'AppDelegate.swift'))

test('the update install path stops the managed service before the bundle is replaced', () => {
  assert.match(updateSource, /final class AppUpdateDelegate: NSObject, SPUUpdaterDelegate/)
  assert.match(
    updateSource,
    /func updater\(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem\)/,
    'the immediate-install hook is the one Sparkle calls before replacing the bundle',
  )
  assert.match(
    updateSource,
    /DshService\.shared\.stop\(\)/,
    'the install hook must stop the same service the quit path stops',
  )
})

test('the updater is constructed with the install gate, not a nil delegate', () => {
  assert.match(updateSource, /private let updateDelegate: AppUpdateDelegate/)
  assert.match(
    updateSource,
    /updaterDelegate: updateDelegate/,
    'a nil delegate would silently drop the stop-before-install guarantee',
  )
  assert.doesNotMatch(updateSource, /updaterDelegate: nil/)
  // Sparkle's delegate property is weak; a local that only lives for the init
  // body would be deallocated before the first update cycle.
  assert.match(updateSource, /self\.updateDelegate = updateDelegate/)
})

test('the ordinary quit path still stops the service', () => {
  assert.match(
    appDelegateSource,
    /func applicationWillTerminate\(_ notification: Notification\) \{\s*\n\s*DshService\.shared\.stop\(\)/,
    'the terminate callback remains the quit-path owner of the stop',
  )
})
