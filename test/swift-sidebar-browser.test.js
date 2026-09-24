import assert from 'node:assert/strict'
import fs from 'node:fs'
import test from 'node:test'

const read = (path) => fs.readFileSync(new URL(path, import.meta.url), 'utf8')
const SOURCE = read('../Sources/MainWindow/DshSidebarBrowser.swift')
const SHELL_SOURCE = read('../Sources/MainWindow/DshWebShell.swift')
const WINDOW_SOURCE = read('../Sources/MainWindow/MainWindowController.swift')
const PROJECT_SOURCE = read('../DSH.xcodeproj/project.xcproj')

const shim = SOURCE.slice(
  SOURCE.indexOf('public static let source = """'),
  SOURCE.lastIndexOf('"""'),
)

// The Runtime's Browser panel has two carriers: an `<iframe>`, which cannot
// read a cross-origin page's URL or title and is refused by every site that
// forbids framing, and a native guest driven through `window.dshDesktop.browser`
// — the one the official desktop uses. This pair implements the second: a shim
// that polyfills the contract, and a pane that owns the real `WKWebView`.

test('the desktop browser bridge is published for the panel to find', () => {
  assert.match(shim, /window\.dshDesktop = window\.dshDesktop \|\| \{\};/)
  assert.match(shim, /window\.dshDesktop\.browser = \{/)
  assert.match(shim, /acquire\(workspace\) \{\s*return request\('acquire', \{ workspace: String\(workspace\) \}\);/)
  assert.match(shim, /release\(lease\) \{\s*return request\('release', \{ lease: String\(lease\) \}\)\.then\(\(\) => undefined\);/)
  assert.match(shim, /onOpenRequested\(lease, listener\) \{/)
  // The panel decides its carrier from this object, so it must exist before any
  // plugin module runs — the shim is injected at document start.
  assert.match(SHELL_SOURCE, /source: DshSidebarBrowserScript\.source,\s*injectionTime: \.atDocumentStart,\s*forMainFrameOnly: true/)
})

test('Electron’s webview element is polyfilled under a name the DOM allows', () => {
  // A custom element name needs a hyphen, so `webview` itself cannot be
  // defined: the shim defines its own and maps the one place the Runtime
  // touches that name — createElement — onto it.
  assert.match(shim, /class DshBrowserWebview extends HTMLElement \{/)
  assert.match(shim, /customElements\.define\('dsh-webview', DshBrowserWebview\);/)
  assert.match(shim, /const createElement = document\.createElement\.bind\(document\);/)
  assert.match(shim, /document\.createElement = function \(name, options\) \{\s*return String\(name\)\.toLowerCase\(\) === 'webview'\s*\?\s*createElement\('dsh-webview', options\)\s*:\s*createElement\(name, options\);/)
  // The presentation bootstraps the guest with `about:blank#<lease>`, and the
  // lease is what binds the element to an approved reservation.
  assert.match(shim, /const marker = 'about:blank#';/)
  assert.match(shim, /return typeof source === 'string' && source\.startsWith\(marker\) \? source\.slice\(marker\.length\) : undefined;/)
})

test('the element exposes exactly the API the Runtime carrier calls', () => {
  for (const method of ['loadURL(url)', 'getURL()', 'getTitle()', 'canGoBack()', 'canGoForward()', 'isLoading()', 'reload()', 'goBack()', 'goForward()', 'clearHistory()']) {
    assert.ok(shim.includes(method), `the element must implement ${method}`)
  }
  // Events arrive from the pane with Electron's names and carry their detail as
  // own properties: the Runtime reads `event.isMainFrame`, `event.errorCode`
  // and `event.errorDescription` straight off the event object.
  assert.match(shim, /const event = new Event\(name\);/)
  assert.match(shim, /event\[key\] = detail\[key\];/)
  // loadURL settles through the events, and a refusal before the navigation
  // starts is answered on the same request id.
  assert.match(shim, /if \(name === 'did-stop-loading' && this\.__pending\) \{/)
  assert.match(shim, /pending\.reject\(\{ code: detail\.errorCode, description: detail\.errorDescription \}\);/)
  assert.match(shim, /post\(\{ type: 'command', id: this\.__id, command: 'loadURL', url: target, request: id \}\);/)
})

test('the element reports its own geometry and detaches when it leaves the DOM', () => {
  // The guest is a native view: nothing follows the panel for us, so the
  // element reports every change and the pane places the web view.
  assert.match(shim, /post\(\{ type: 'attach', id: this\.__id, lease, rect: this\.__frame, visible: this\.__visible\(\) \}\);/)
  assert.match(shim, /post\(\{ type: 'frame', id: this\.__id, rect, visible: this\.__visible\(\) \}\);/)
  assert.match(shim, /post\(\{ type: 'detach', id: this\.__id \}\);/)
  assert.match(shim, /this\.__raf = requestAnimationFrame\(track\);/)
  // The panel lays out the container it hands the guest, not the guest's own
  // class, so the box that matters is the container's.
  assert.match(shim, /const target = this\.parentElement instanceof HTMLElement \? this\.parentElement : this;/)
  assert.match(shim, /const rect = target\.getBoundingClientRect\(\);/)
  // First integration pass only: nothing may be left of the geometry probe.
  assert.equal(/__probe|probe:/.test(shim), false)
})

test('the pane admits only the page it was built for', () => {
  assert.match(SOURCE, /public static let messageHandlerName = "dshBrowser"/)
  assert.match(SHELL_SOURCE, /userContentController\.add\(pane, name: DshSidebarBrowserPane\.messageHandlerName\)/)
  assert.match(SOURCE, /guard message\.name == Self\.messageHandlerName,\s*message\.webView === pageWebView,\s*message\.frameInfo\.isMainFrame,/)
  for (const type of ['acquire', 'release', 'attach', 'frame', 'detach', 'command']) {
    assert.ok(SOURCE.includes(`case "${type}":`), `the pane must handle ${type} messages`)
  }
})

test('a guest gets its own storage account and its own web view', () => {
  assert.match(SOURCE, /dataStore = WKWebsiteDataStore\(forIdentifier: Self\.storeIdentifier\(for: partition\)\)/)
  // One account per workspace, named deterministically so cookies outlive an
  // attachment and an app launch.
  assert.match(SOURCE, /static func partitionName\(for workspace: String\) -> String \{\s*"persist:" \+ storeIdentifier\(for: workspace\)\.uuidString\.lowercased\(\)/)
  assert.match(SOURCE, /let digest = SHA256\.hash\(data: Data\(workspace\.utf8\)\)/)
  assert.match(SOURCE, /host\.addSubview\(guest, positioned: \.above, relativeTo: page\)/)
  // A guest is a real browser: only the web's own protocols reach it.
  assert.match(SOURCE, /return \(scheme == "http" \|\| scheme == "https"\) && \(url\.host\?\.isEmpty == false\)/)
  assert.match(SOURCE, /guest\.webView\.stopLoading\(\)/)
  assert.match(SOURCE, /guest\.webView\.removeFromSuperview\(\)/)
})

test('the guest is placed from the page’s own rectangle', () => {
  // The page reports a viewport rect in CSS pixels; the guest is a sibling of
  // the DSH web view, so the conversion has to cross the web view’s unflipped
  // bounds and whatever container the two share.
  // WKWebView's own space is flipped, so `convert` performs the flip: a rect
  // that is flipped here as well lands one top-offset too high and covers the
  // panel's toolbar.
  assert.match(SOURCE, /let inHost = page\.convert\(\s*CGRect\(x: x, y: y, width: width, height: height\),\s*to: host\s*\)/)
  assert.doesNotMatch(SOURCE, /page\.bounds\.height - y - height/)
  assert.match(SOURCE, /guest\.webView\.frame = inHost/)
  assert.match(SOURCE, /guest\.webView\.isHidden = inHost\.intersection\(host\.bounds\)\.isEmpty/)
  // Values that come from the page are serialized as JavaScript literals.
  assert.match(SOURCE, /private static func quoted\(_ value: String\) -> String \{/)
})

test('the pane reports navigation to the page instead of acting on it', () => {
  for (const call of ['__DSH_BROWSER_EVENT__', '__DSH_BROWSER_REPLY__', '__DSH_BROWSER_OPEN__']) {
    assert.ok(SOURCE.includes(`window.${call}?.(`), `the pane must call ${call}`)
  }
  // A popup inside the guest is the panel's to open, not the system's.
  assert.match(SOURCE, /if let guest = guest\(for: webView\), let url = navigationAction\.request\.url\?\.absoluteString \{\s*emitOpenRequest\(lease: guest\.lease, url: url\)/)
  assert.match(SOURCE, /private func emit\(id: String, event: String, detail: \[String: Any\] = \[:\]\) \{/)
  assert.match(SOURCE, /"canGoBack": guest\.canGoBack,/)
  assert.match(SOURCE, /"loading": guest\.webView\.isLoading,/)
})

test('the window hosts the pane and the target compiles it', () => {
  assert.match(WINDOW_SOURCE, /let pane = DshSidebarBrowserPane\(hostView: shell\.rootView, pageWebView: shell\.webView\)/)
  assert.match(WINDOW_SOURCE, /shell\.attachSidebarBrowser\(pane\)/)
  assert.match(WINDOW_SOURCE, /private var sidebarBrowserPane: DshSidebarBrowserPane\?/)
  assert.match(
    PROJECT_SOURCE,
    /"path": "DshSidebarBrowser\.swift", "target-membership": \[ "DSH\/compile-sources" \]/,
  )
})
