import assert from 'node:assert/strict'
import fs from 'node:fs'
import test from 'node:test'
import { countCalls, sliceBetween } from './source-assertions.mjs'

const read = (path) => fs.readFileSync(new URL(path, import.meta.url), 'utf8')
const shell = read('../Sources/MainWindow/DshWebShell.swift')
const semver = read('../Sources/Versions/DshSemanticVersion.swift')
const windowSource = read('../Sources/MainWindow/MainWindowController.swift')

const PLATFORM_SCOPE = 'html:not([data-platform="darwin"])'
const sharedCSS = sliceBetween(shell, 'private static let shellSharedCSS = """', '\n    """')
const legacyCSS = sliceBetween(shell, 'private static let shellLegacyRailCSS = """', '\n    """')

test('the shell rail is offered only to a Runtime without its own macOS layout', () => {
  // The floor is a capability, not a preference: 0.1.6-alpha.2 already reads
  // the marker for its collapsed width but mounts no leading seat, so a
  // sidebar collapsed under it could not be reopened.
  assert.match(semver, /public var supportsNativeMacOSShell: Bool/)
  assert.match(semver, /nativeMacOSShellMinimum = DshSemanticVersion\("0\.1\.7-alpha\.1"\)!/)
  assert.match(shell, /DshSemanticVersion\(runtimeVersion\)\?\.supportsNativeMacOSShell \?\? false/)
})

test('the platform marker is published per launch and revoked for an older Runtime', () => {
  assert.match(shell, /private static let platformMarkerScript = """/)
  assert.match(shell, /setAttribute\('data-platform', 'darwin'\)/)
  // The marker is a page contract the Runtime reads while it mounts, so it has
  // to land before the document loads and must not leak into sub-frames.
  assert.match(
    shell,
    /source: Self\.platformMarkerScript,\s*injectionTime: \.atDocumentStart,\s*forMainFrameOnly: true/,
  )
  // WebKit drops every user script at once but not a single one, so switching
  // the branch rebuilds the whole set the shell owns.
  assert.match(
    shell,
    /private static func installUserScripts\(\s*into userContent: WKUserContentController,\s*publishesPlatformMarker: Bool\s*\)/,
  )
  assert.match(shell, /userContent\.removeAllUserScripts\(\)/)
  assert.match(shell, /if publishesPlatformMarker \{/)
  assert.match(shell, /publishesPlatformMarker: false\)/)

  const apply = sliceBetween(shell, 'public func applyRuntimeCapabilities(runtimeVersion: String)', '\n    }')
  assert.match(
    apply,
    /Self\.installUserScripts\(\s*into: userContentController,\s*publishesPlatformMarker: publishesMarker\s*\)/,
  )
  // One WebView serves every Runtime the user switches to, so the decision is
  // re-derived per launch rather than taken once at construction.
  assert.equal(countCalls(windowSource, 'applyRuntimeCapabilities'), 2)
  assert.match(windowSource, /applyRuntimeCapabilities\(runtimeVersion: context\.runtimeDescriptor\.version\)/)
  assert.match(windowSource, /applyRuntimeCapabilities\(runtimeVersion: runtimeVersion\)/)
})

test('every rail override is scoped to the absence of the platform marker', () => {
  // The rail exists because a Runtime without its own layout collapses the
  // sidebar to a 56px icon rail; the shell widens it to the traffic-light
  // gutter and pads the column down past the window buttons.
  assert.match(legacyCSS, /--dsh-shell-sidebar-width: 88px/)
  assert.match(legacyCSS, /min-width: var\(--dsh-shell-sidebar-width\) !important/)
  assert.match(
    legacyCSS,
    /grid-template-columns: var\(--dsh-shell-sidebar-width\) minmax\(0px, 1fr\) 0px !important;/,
  )
  assert.match(legacyCSS, /align-self: center !important;/)
  assert.match(legacyCSS, /top: 6px !important;/)

  // Publishing the marker has to disable all of it at once, so no rule may
  // escape the scope: an unscoped one would keep fighting the Runtime.
  const selectors = legacyCSS
    .split('\n')
    .map((line) => line.trim())
    .filter((line) => line.endsWith('{'))
  assert.ok(selectors.length > 0, 'the legacy branch has rules')
  assert.deepEqual(
    selectors.filter((selector) => !selector.startsWith(PLATFORM_SCOPE)),
    [],
    'every legacy rail rule must be scoped to a Runtime without the platform marker',
  )
})

test('the shared stylesheet carries no sidebar or column overrides', () => {
  // What both branches need is only the translucency the native window shows
  // through, plus the drag surface. Anything layout-shaped belongs to one
  // branch or the other, never to both.
  assert.match(sharedCSS, /html, body \{ background: transparent !important; \}/)
  assert.match(sharedCSS, /\[class\*="frame"\] \{\s*background: transparent !important;/)
  assert.match(sharedCSS, /html\.dsh-native-window-drag/)

  assert.equal(sharedCSS.includes('--dsh-shell-sidebar-width'), false)
  assert.equal(sharedCSS.includes('grid-template-columns'), false)
  assert.equal(sharedCSS.includes('data-sidebar-collapsed'), false)
  assert.equal(sharedCSS.includes('data-sidebar-right-panel'), false)
  assert.equal(sharedCSS.includes('centerCol'), false)
  assert.equal(shell.includes('detailsCol'), false, 'the Runtime no longer renders a detailsCol')
})
