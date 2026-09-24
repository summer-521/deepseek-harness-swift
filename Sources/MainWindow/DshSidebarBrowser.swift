import AppKit
import CryptoKit
import WebKit

/// The sidebar Browser's real guest: a native `WKWebView` the shell overlays on
/// the panel's placeholder element.
///
/// The Runtime's Browser panel has two carriers. Without a desktop browser
/// bridge it renders an `<iframe>`, and that carrier cannot report a
/// cross-origin page's URL or title, cannot follow a redirect into the address
/// bar, and is refused outright by every site that forbids framing. The other
/// carrier — the one the official desktop uses — drives a `<webview>` element
/// through `window.dshDesktop.browser`, and that is what this pair implements:
/// a JS shim that polyfills the contract (Electron's `<webview>` is a Chromium
/// element, so the shim maps `createElement('webview')` onto a real custom
/// element), and this pane, which owns the actual `WKWebView`, its geometry and
/// its navigation state.
@MainActor
public final class DshSidebarBrowserPane: NSObject, WKScriptMessageHandler {
    /// Script message handler the injected shim posts to.
    public static let messageHandlerName = "dshBrowser"

    /// One approved guest reservation. The partition names the storage account
    /// a workspace browses with; the lease names one attachment of it.
    private struct Lease {
        let partition: String
        let dataStore: WKWebsiteDataStore
    }

    /// One attached element and the web view behind it.
    private final class Guest {
        let id: String
        let lease: String
        let webView: WKWebView
        /// Application-known history. The panel's own navigation state is built
        /// from these readings, and `clearHistory()` needs a floor the read-only
        /// WebKit back/forward list cannot express.
        var history: [String] = []
        var index: Int = -1
        /// The `loadURL()` promise waiting for this navigation to settle.
        var pendingRequest: Int?
        var lastTitle: String = ""

        init(id: String, lease: String, webView: WKWebView) {
            self.id = id
            self.lease = lease
            self.webView = webView
        }

        var currentURL: String? {
            guard index >= 0, index < history.count else { return nil }
            return history[index]
        }

        var canGoBack: Bool { index > 0 }
        var canGoForward: Bool { index >= 0 && index + 1 < history.count }
    }

    private weak var hostView: NSView?
    private weak var pageWebView: WKWebView?
    private var leases: [String: Lease] = [:]
    private var guests: [String: Guest] = [:]
    private var elementIDsByWebView: [ObjectIdentifier: String] = [:]
    private var replySequence = 0

    /// @param hostView - view that carries the guest above the DSH page.
    /// @param pageWebView - the DSH page, which reports CSS-pixel geometry.
    public init(hostView: NSView, pageWebView: WKWebView) {
        self.hostView = hostView
        self.pageWebView = pageWebView
        super.init()
    }

    /// Release every guest. The main window owns this pane for its lifetime, so
    /// this exists for the teardown paths that must not leave a web view behind.
    public func tearDown() {
        for id in guests.keys { removeGuest(id) }
        leases.removeAll()
    }

    // MARK: - Page messages

    public func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        // The shim runs in the DSH document only, and the panel drives exactly
        // one window: anything else is not this bridge.
        guard message.name == Self.messageHandlerName,
              message.webView === pageWebView,
              message.frameInfo.isMainFrame,
              let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }

        switch type {
        case "acquire": handleAcquire(body)
        case "release": handleRelease(body)
        case "attach": handleAttach(body)
        case "frame": handleFrame(body)
        case "detach": handleDetach(body)
        case "command": handleCommand(body)
        default: break
        }
    }

    private func handleAcquire(_ body: [String: Any]) {
        guard let request = requestID(body), let workspace = body["workspace"] as? String else { return }
        let partition = Self.partitionName(for: workspace)
        let dataStore: WKWebsiteDataStore
        if let existing = leases.values.first(where: { $0.partition == partition }) {
            dataStore = existing.dataStore
        } else {
            dataStore = WKWebsiteDataStore(forIdentifier: Self.storeIdentifier(for: partition))
        }
        let lease = UUID().uuidString
        leases[lease] = Lease(partition: partition, dataStore: dataStore)
        reply(request, ok: true, payload: ["lease": lease, "partition": partition])
    }

    private func handleRelease(_ body: [String: Any]) {
        guard let request = requestID(body), let lease = body["lease"] as? String else { return }
        leases.removeValue(forKey: lease)
        for (id, guest) in guests where guest.lease == lease { removeGuest(id) }
        reply(request, ok: true, payload: nil)
    }

    private func handleAttach(_ body: [String: Any]) {
        guard let id = elementID(body),
              let lease = body["lease"] as? String,
              let reservation = leases[lease],
              guests[id] == nil else { return }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = reservation.dataStore
        let guest = WKWebView(frame: .zero, configuration: configuration)
        guest.navigationDelegate = self
        guest.uiDelegate = self
        guest.allowsBackForwardNavigationGestures = true
        guest.autoresizingMask = []
#if DEBUG
        guest.isInspectable = true
#endif
        let entry = Guest(id: id, lease: lease, webView: guest)
        guests[id] = entry
        elementIDsByWebView[ObjectIdentifier(guest)] = id
        if let host = hostView, let page = pageWebView {
            guest.isHidden = true
            host.addSubview(guest, positioned: .above, relativeTo: page)
        }
        applyGeometry(id: id, body: body)
        guest.load(URLRequest(url: URL(string: "about:blank")!))
        // The panel reads the frame only after `dom-ready`; its bootstrap
        // document is the blank one the element's `src` names.
        emit(id: id, event: "dom-ready", detail: stateDetail(entry))
    }

    private func handleFrame(_ body: [String: Any]) {
        guard let id = elementID(body), guests[id] != nil else { return }
        applyGeometry(id: id, body: body)
    }

    private func handleDetach(_ body: [String: Any]) {
        guard let id = elementID(body) else { return }
        removeGuest(id)
    }

    private func handleCommand(_ body: [String: Any]) {
        guard let id = elementID(body), let command = body["command"] as? String,
              let guest = guests[id] else { return }
        switch command {
        case "loadURL":
            guard let raw = body["url"] as? String, Self.isBrowsableURL(raw) else {
                if let request = requestID(body) {
                    reply(request, ok: false, payload: ["code": "ERR_INVALID_URL"])
                }
                return
            }
            guest.pendingRequest = requestID(body)
            guest.webView.load(URLRequest(url: URL(string: raw)!))
        case "goBack":
            guard guest.canGoBack else { return }
            guest.index -= 1
            guest.pendingRequest = nil
            loadCurrent(guest)
        case "goForward":
            guard guest.canGoForward else { return }
            guest.index += 1
            guest.pendingRequest = nil
            loadCurrent(guest)
        case "reload":
            guest.webView.reload()
        case "clearHistory":
            // Keep the current entry as the oldest one the panel may return to:
            // the blank bootstrap document must not become a back target.
            if guest.index > 0 {
                guest.history.removeFirst(guest.index)
                guest.index = 0
            }
        default:
            break
        }
    }

    // MARK: - Guests

    private func removeGuest(_ id: String) {
        guard let guest = guests.removeValue(forKey: id) else { return }
        elementIDsByWebView.removeValue(forKey: ObjectIdentifier(guest.webView))
        guest.webView.stopLoading()
        guest.webView.navigationDelegate = nil
        guest.webView.uiDelegate = nil
        guest.webView.removeFromSuperview()
        if let request = guest.pendingRequest {
            reply(request, ok: false, payload: ["code": "ERR_ABORTED"])
        }
    }

    private func loadCurrent(_ guest: Guest) {
        guard let url = guest.currentURL, let target = URL(string: url) else { return }
        guest.webView.load(URLRequest(url: target))
    }

    /// Turn the page's CSS-pixel rect into this window's coordinates. The page
    /// reports a viewport rect; the guest is a sibling of the DSH web view, so
    /// the conversion has to cross both the view's own (unflipped) bounds and
    /// whatever container the two views share.
    private func applyGeometry(id: String, body: [String: Any]) {
        guard let guest = guests[id],
              let host = hostView,
              let page = pageWebView,
              let rect = body["rect"] as? [String: Any],
              let x = (rect["x"] as? NSNumber)?.doubleValue,
              let y = (rect["y"] as? NSNumber)?.doubleValue,
              let width = (rect["width"] as? NSNumber)?.doubleValue,
              let height = (rect["height"] as? NSNumber)?.doubleValue else { return }
        let visible = (body["visible"] as? Bool) ?? true
        guard width >= 1, height >= 1, visible, x.isFinite, y.isFinite else {
            guest.webView.isHidden = true
            return
        }
        // The page reports a viewport rect: CSS pixels from the document's
        // top-left, which is also how WKWebView's own (flipped) coordinate
        // space is laid out. `convert` therefore translates between the two
        // systems by itself — flipping the rect here as well moves the guest up
        // by its own top offset, over the panel's toolbar.
        let inHost = page.convert(
            CGRect(x: x, y: y, width: width, height: height),
            to: host
        )
        guest.webView.frame = inHost
        guest.webView.isHidden = inHost.intersection(host.bounds).isEmpty
    }

    private func guest(for webView: WKWebView) -> Guest? {
        guard let id = elementIDsByWebView[ObjectIdentifier(webView)] else { return nil }
        return guests[id]
    }

    // MARK: - Events

    private func stateDetail(_ guest: Guest) -> [String: Any] {
        [
            "url": guest.webView.url?.absoluteString ?? guest.currentURL ?? "about:blank",
            "title": guest.webView.title ?? "",
            "canGoBack": guest.canGoBack,
            "canGoForward": guest.canGoForward,
            "loading": guest.webView.isLoading,
        ]
    }

    private func emit(id: String, event: String, detail: [String: Any] = [:]) {
        var payload = detail
        if let guest = guests[id], payload["state"] == nil {
            payload["state"] = stateDetail(guest)
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        evaluate("window.__DSH_BROWSER_EVENT__?.(\(Self.quoted(id)), \(Self.quoted(event)), \(Self.quoted(json)));")
    }

    private func reply(_ request: Int, ok: Bool, payload: [String: Any]?) {
        var json = "null"
        if let payload, let data = try? JSONSerialization.data(withJSONObject: payload),
           let encoded = String(data: data, encoding: .utf8) {
            json = encoded
        }
        evaluate("window.__DSH_BROWSER_REPLY__?.(\(request), \(ok ? "true" : "false"), \(Self.quoted(json)));")
    }

    private func emitOpenRequest(lease: String, url: String) {
        evaluate("window.__DSH_BROWSER_OPEN__?.(\(Self.quoted(lease)), \(Self.quoted(url)));")
    }

    private func evaluate(_ script: String) {
        pageWebView?.evaluateJavaScript(script)
    }

    /// Serialize a Swift string as a JavaScript string literal. Geometry and
    /// URLs come from the page, so the literal has to survive quotes, newlines
    /// and anything else a URL may carry.
    private static func quoted(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              var json = String(data: data, encoding: .utf8) else { return "\"\"" }
        json.removeFirst()
        json.removeLast()
        return json
    }

    // MARK: - Protocol helpers

    private func requestID(_ body: [String: Any]) -> Int? {
        (body["request"] as? NSNumber)?.intValue
    }

    private func elementID(_ body: [String: Any]) -> String? {
        guard let id = body["id"] as? String, !id.isEmpty, id.count <= 64 else { return nil }
        return id
    }

    /// Only the browser's own protocols. A guest is a real web view, so this is
    /// where `file:`, `javascript:` and every other scheme stop.
    static func isBrowsableURL(_ raw: String) -> Bool {
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased() else { return false }
        return (scheme == "http" || scheme == "https") && (url.host?.isEmpty == false)
    }

    /// One storage account per workspace, named after it so the same workspace
    /// keeps its cookies across attachments and app launches.
    static func partitionName(for workspace: String) -> String {
        "persist:" + storeIdentifier(for: workspace).uuidString.lowercased()
    }

    /// A stable UUID derived from the workspace key: `WKWebsiteDataStore` is
    /// addressed by identifier, so the workspace has to name one deterministically.
    static func storeIdentifier(for workspace: String) -> UUID {
        let digest = SHA256.hash(data: Data(workspace.utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5],
                           bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11],
                           bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

// MARK: - Guest navigation

extension DshSidebarBrowserPane: WKNavigationDelegate, WKUIDelegate {
    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard let guest = guest(for: webView) else { return }
        emit(id: guest.id, event: "did-start-loading")
        emit(id: guest.id, event: "did-start-navigation", detail: ["isMainFrame": true])
    }

    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard let guest = guest(for: webView) else { return }
        if let url = webView.url?.absoluteString {
            if guest.currentURL != url {
                if guest.index + 1 < guest.history.count {
                    guest.history.removeSubrange((guest.index + 1)...)
                }
                guest.history.append(url)
                guest.index = guest.history.count - 1
            }
        }
        emit(id: guest.id, event: "did-navigate")
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let guest = guest(for: webView) else { return }
        if let request = guest.pendingRequest {
            guest.pendingRequest = nil
            reply(request, ok: true, payload: nil)
        }
        if webView.title != guest.lastTitle {
            guest.lastTitle = webView.title ?? ""
            emit(id: guest.id, event: "page-title-updated")
        }
        emit(id: guest.id, event: "did-stop-loading")
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failGuest(webView, error: error)
    }

    public func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        failGuest(webView, error: error)
    }

    private func failGuest(_ webView: WKWebView, error: Error) {
        guard let guest = guest(for: webView) else { return }
        let nsError = error as NSError
        let aborted = nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
        if let request = guest.pendingRequest {
            guest.pendingRequest = nil
            reply(
                request,
                ok: false,
                payload: aborted
                    ? ["code": "ERR_ABORTED"]
                    : ["code": String(nsError.code), "description": nsError.localizedDescription]
            )
        }
        emit(id: guest.id, event: "did-fail-load", detail: [
            "isMainFrame": true,
            "errorCode": aborted ? -3 : nsError.code,
            "errorDescription": nsError.localizedDescription,
        ])
        emit(id: guest.id, event: "did-stop-loading")
    }

    /// A popup inside the guest is the panel's to open: report it and let the
    /// Runtime decide, instead of handing an arbitrary URL to the system.
    public func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let guest = guest(for: webView), let url = navigationAction.request.url?.absoluteString {
            emitOpenRequest(lease: guest.lease, url: url)
        }
        return nil
    }
}

/// The JS half of the sidebar Browser bridge.
///
/// Electron's `<webview>` is a Chromium element, so the shim cannot define it
/// under that name (custom element names need a hyphen). It defines
/// `dsh-webview` and maps `document.createElement('webview')` onto it, which is
/// the only place the Runtime touches that name. Everything else is the
/// contract the Runtime's desktop carrier already speaks: `acquire`/`release`/
/// `onOpenRequested` for the guest reservation, and the element methods and
/// events — `loadURL`, `getURL`, `getTitle`, `canGoBack`, `canGoForward`,
/// `reload`, `isLoading`, `clearHistory`, `dom-ready`, `did-navigate`,
/// `did-navigate-in-page`, `did-start-navigation`, `did-start-loading`,
/// `did-stop-loading`, `page-title-updated`, `did-fail-load`.
public enum DshSidebarBrowserScript {
    public static let source = """
    (() => {
      if (window.__DSH_BROWSER_BRIDGE__) return;
      window.__DSH_BROWSER_BRIDGE__ = true;

      const post = (message) => {
        const handlers = window.webkit && window.webkit.messageHandlers;
        const handler = handlers && handlers.dshBrowser;
        if (handler) handler.postMessage(message);
      };

      // One registry serves every request/response pair: a reservation, a
      // release, and each loadURL() promise the panel awaits.
      let requestSequence = 0;
      const requests = new Map();
      const request = (type, payload) => new Promise((resolve, reject) => {
        const id = ++requestSequence;
        requests.set(id, { resolve, reject });
        post(Object.assign({ type, request: id }, payload));
      });
      window.__DSH_BROWSER_REPLY__ = (id, ok, payloadJSON) => {
        const entry = requests.get(id);
        if (!entry) return;
        requests.delete(id);
        let payload;
        try { payload = payloadJSON ? JSON.parse(payloadJSON) : undefined; } catch (error) { payload = undefined; }
        if (ok) entry.resolve(payload);
        else entry.reject(payload);
      };

      const openListeners = new Map();
      window.__DSH_BROWSER_OPEN__ = (lease, url) => {
        const listeners = openListeners.get(lease);
        if (!listeners) return;
        for (const listener of Array.from(listeners)) {
          try { listener(url); } catch (error) {}
        }
      };

      const elements = new Map();
      window.__DSH_BROWSER_EVENT__ = (id, name, detailJSON) => {
        const element = elements.get(id);
        if (!element) return;
        let detail;
        try { detail = detailJSON ? JSON.parse(detailJSON) : {}; } catch (error) { detail = {}; }
        element.__deliver(name, detail);
      };

      window.dshDesktop = window.dshDesktop || {};
      window.dshDesktop.browser = {
        acquire(workspace) {
          return request('acquire', { workspace: String(workspace) });
        },
        release(lease) {
          return request('release', { lease: String(lease) }).then(() => undefined);
        },
        onOpenRequested(lease, listener) {
          const key = String(lease);
          let listeners = openListeners.get(key);
          if (!listeners) { listeners = new Set(); openListeners.set(key, listeners); }
          listeners.add(listener);
          return () => {
            listeners.delete(listener);
            if (listeners.size === 0) openListeners.delete(key);
          };
        },
      };

      const leaseFromSource = (source) => {
        const marker = 'about:blank#';
        return typeof source === 'string' && source.startsWith(marker) ? source.slice(marker.length) : undefined;
      };

      let elementSequence = 0;

      class DshBrowserWebview extends HTMLElement {
        constructor() {
          super();
          this.__id = 'dsh-webview-' + (++elementSequence);
          this.__state = { url: 'about:blank', title: '', canGoBack: false, canGoForward: false, loading: false };
          this.__attached = false;
          this.__frame = undefined;
          this.__pending = undefined;
          elements.set(this.__id, this);
        }

        static get observedAttributes() { return ['src']; }

        connectedCallback() { this.__attach(); }
        attributeChangedCallback(name) { if (name === 'src') this.__attach(); }
        disconnectedCallback() {
          if (!this.__attached) return;
          this.__attached = false;
          this.__frame = undefined;
          if (this.__raf !== undefined) { cancelAnimationFrame(this.__raf); this.__raf = undefined; }
          post({ type: 'detach', id: this.__id });
        }

        __attach() {
          if (this.__attached || !this.isConnected) return;
          const lease = leaseFromSource(this.getAttribute('src'));
          if (lease === undefined) return;
          this.__attached = true;
          this.__frame = this.__rect();
          post({ type: 'attach', id: this.__id, lease, rect: this.__frame, visible: this.__visible() });
          const track = () => {
            if (!this.__attached) return;
            const rect = this.__rect();
            if (!rect || !this.__frame || rect.x !== this.__frame.x || rect.y !== this.__frame.y
              || rect.width !== this.__frame.width || rect.height !== this.__frame.height) {
              this.__frame = rect;
              post({ type: 'frame', id: this.__id, rect, visible: this.__visible() });
            }
            this.__raf = requestAnimationFrame(track);
          };
          this.__raf = requestAnimationFrame(track);
        }

        __rect() {
          // The Runtime styles the guest through its own class, but the panel's
          // *container* is the element the Runtime lays out itself; measuring it
          // keeps placement independent of how the guest is styled.
          const target = this.parentElement instanceof HTMLElement ? this.parentElement : this;
          const rect = target.getBoundingClientRect();
          return { x: rect.x, y: rect.y, width: rect.width, height: rect.height };
        }

        __visible() {
          return this.getClientRects().length > 0 && document.visibilityState === 'visible';
        }

        __deliver(name, detail) {
          if (detail && detail.state) this.__state = Object.assign({}, this.__state, detail.state);
          if (name === 'did-stop-loading' && this.__pending) {
            const pending = this.__pending;
            this.__pending = undefined;
            requests.delete(pending.id);
            pending.resolve();
          }
          if (name === 'did-fail-load' && detail && detail.isMainFrame && detail.errorCode !== -3 && this.__pending) {
            const pending = this.__pending;
            this.__pending = undefined;
            requests.delete(pending.id);
            pending.reject({ code: detail.errorCode, description: detail.errorDescription });
          }
          const event = new Event(name);
          if (detail) {
            for (const key of Object.keys(detail)) {
              try { event[key] = detail[key]; } catch (error) {}
            }
          }
          this.dispatchEvent(event);
        }

        loadURL(url) {
          const target = String(url);
          return new Promise((resolve, reject) => {
            const id = ++requestSequence;
            this.__pending = { id, resolve, reject };
            // The native side answers the same request id when the navigation
            // is refused before it starts; a load that does start settles
            // through the events above.
            requests.set(id, {
              resolve: () => {},
              reject: (error) => {
                requests.delete(id);
                const pending = this.__pending;
                this.__pending = undefined;
                if (pending) pending.reject(error || { code: 'ERR_FAILED' });
              },
            });
            post({ type: 'command', id: this.__id, command: 'loadURL', url: target, request: id });
          });
        }

        getURL() { return this.__state.url || 'about:blank'; }
        getTitle() { return this.__state.title || ''; }
        canGoBack() { return this.__state.canGoBack === true; }
        canGoForward() { return this.__state.canGoForward === true; }
        isLoading() { return this.__state.loading === true; }
        reload() { post({ type: 'command', id: this.__id, command: 'reload' }); }
        goBack() { post({ type: 'command', id: this.__id, command: 'goBack' }); }
        goForward() { post({ type: 'command', id: this.__id, command: 'goForward' }); }
        clearHistory() { post({ type: 'command', id: this.__id, command: 'clearHistory' }); }
      }

      customElements.define('dsh-webview', DshBrowserWebview);

      const createElement = document.createElement.bind(document);
      document.createElement = function (name, options) {
        return String(name).toLowerCase() === 'webview'
          ? createElement('dsh-webview', options)
          : createElement(name, options);
      };
    })();
    """
}
