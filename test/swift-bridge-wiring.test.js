import assert from 'node:assert/strict'
import fs from 'node:fs'
import path from 'node:path'
import test from 'node:test'
import { fileURLToPath } from 'node:url'
import { functionBody, sliceBetween } from './source-assertions.mjs'

const testDirectory = path.dirname(fileURLToPath(import.meta.url))
const handlerSource = fs.readFileSync(
  path.join(testDirectory, '..', 'Sources', 'Bridge', 'DshBridgeHandler.swift'),
  'utf8',
)
const shellSource = fs.readFileSync(
  path.join(testDirectory, '..', 'Sources', 'MainWindow', 'DshWebShell.swift'),
  'utf8',
)
const controllerSource = fs.readFileSync(
  path.join(testDirectory, '..', 'Sources', 'MainWindow', 'MainWindowController.swift'),
  'utf8',
)

test('WK bridge binds WebView, frame, origin and generation before dispatch', () => {
  assert.match(handlerSource, /message\.frameInfo\.isMainFrame/)
  assert.match(handlerSource, /message\.frameInfo\.securityOrigin\.protocol/)
  assert.match(handlerSource, /message\.frameInfo\.securityOrigin\.host/)
  assert.match(handlerSource, /message\.frameInfo\.securityOrigin\.port/)
  assert.match(handlerSource, /message\.webView\.map/)
  assert.match(handlerSource, /validator\.validate\(incoming, context: context\)/)
  assert.match(handlerSource, /updateValidationContext\(_ context: DshBridgeValidationContext\?\)/)
  assert.match(handlerSource, /dictionary\["launchID"\] = context\.launchID\.uuidString/)
  assert.match(handlerSource, /dictionary\["generationID"\] = context\.generationID\.uuidString/)
})

test('page bridge API sends requests only; native shell owns identity binding', () => {
  const script = sliceBetween(handlerSource, 'public static let scriptSource', '    """')
  assert.doesNotMatch(script, /launchID|generationID/)
  assert.match(shellSource, /updateBridgeValidationContext\(/)
  assert.match(shellSource, /clearBridgeValidationContext\(\)/)
  assert.match(controllerSource, /webShell\?\.clearBridgeValidationContext\(\)/)
  assert.match(controllerSource, /updateBridgeValidationContext\(for: session\)/)
})

test('the two halves of the bridge agree on one protocol version', () => {
  const validatorSource = fs.readFileSync(
    path.join(testDirectory, '..', 'Sources', 'Bridge', 'DshBridgeMessageValidator.swift'),
    'utf8',
  )
  const clientSource = fs.readFileSync(
    path.join(testDirectory, '..', 'assets', 'dsh-desktop-host', 'client.js'),
    'utf8',
  )

  // The shell half is compiled into the app; the page half is installed into
  // the Profile. An app update does not update an already-installed page half,
  // so the two constants must be bumped together and the pair must be able to
  // notice when they were not.
  const shellVersion = validatorSource.match(/public static let version = (\d+)/)?.[1]
  const pageVersion = clientSource.match(/var PAGE_BRIDGE_PROTOCOL_VERSION = (\d+)/)?.[1]
  assert.ok(shellVersion, 'DshBridgeProtocol.version must be declared in the validator')
  assert.ok(pageVersion, 'the page half must declare its protocol version')
  assert.equal(pageVersion, shellVersion, 'the shell and page halves must be bumped together')

  const script = sliceBetween(handlerSource, 'public static let scriptSource', '    """')
  assert.match(script, /protocolVersion: \\\(DshBridgeProtocol\.version\)/)
  assert.match(script, /ready: function\(payload\)/)
  assert.match(script, /if \(payload !== undefined && payload !== null\) \{ message\.payload = payload; \}/)

  assert.match(clientSource, /host\.ready\(\{ protocolVersion: PAGE_BRIDGE_PROTOCOL_VERSION \}\)/)
  // A mismatch is a fact about our own artifacts, so it is reported; only
  // untrusted bodies stay silent at the WebKit boundary.
  assert.match(
    handlerSource,
    /if case \.failure\(\.protocolVersionMismatch\(let declared\)\) = validation/,
  )
  assert.match(handlerSource, /does not match shell/)
})

test('restart and safe-mode return invalidate stale bridge context at service boundaries', () => {
  const restartBody = functionBody(controllerSource, 'public func restartDshServiceDuringOperation(')
  const clearIndex = restartBody.indexOf('webShell?.clearBridgeValidationContext()')
  const restartSessionNilIndex = restartBody.indexOf('serviceSession = nil')
  const launchIndex = restartBody.indexOf('launchContext = context')
  const prepareIndex = restartBody.indexOf('prepareForProfileMutation(context: context)')
  assert.ok(clearIndex >= 0 && clearIndex < restartSessionNilIndex)
  assert.ok(launchIndex > clearIndex && launchIndex < prepareIndex)

  const returnBody = functionBody(controllerSource, 'private func returnFromSafeMode()')
  const stopIndex = returnBody.indexOf('DshService.shared.stopAndWait()')
  const firstClearIndex = returnBody.indexOf('webShell?.clearBridgeValidationContext()')
  const sessionNilIndex = returnBody.indexOf('self.serviceSession = nil')
  const secondClearIndex = returnBody.indexOf(
    'webShell?.clearBridgeValidationContext()',
    firstClearIndex + 1,
  )
  const contextGuardIndex = returnBody.indexOf('guard let context = self.makeLaunchContext()')
  assert.ok(firstClearIndex >= 0 && firstClearIndex < stopIndex)
  assert.ok(secondClearIndex > sessionNilIndex && secondClearIndex < contextGuardIndex)
})
