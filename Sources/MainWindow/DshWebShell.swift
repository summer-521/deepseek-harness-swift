import AppKit
import WebKit

/// The native shell around the DSH Web UI.
///
/// DSH continues to own the page, sessions, plugins and message rendering.
/// This layer owns only the macOS window chrome, WebKit policies and the
/// small bridge used for native window integration.
@MainActor
public final class DshWebShell {
    public let rootView: NSVisualEffectView
    public let webView: WKWebView

    private let bridgeHandler: DshBridgeHandler
    private let userContentController: WKUserContentController
    /// Whether the platform marker is part of the currently installed script
    /// set. Held so a Runtime switch can tell whether the branch has to move.
    private var publishesPlatformMarker = false

#if DEBUG
    private static let developerToolsEnabledByDefault = true
#else
    private static let developerToolsEnabledByDefault = false
#endif

    /// The rules every Runtime needs from this shell, whatever layout it draws
    /// itself: the window's vibrancy has to show through the page, and the
    /// native drag surface needs its cursor and selection suppressed.
    private static let shellSharedCSS = """
    html, body { background: transparent !important; }
    [class*="frame"] {
      background: transparent !important;
    }
    [class*="sidebarCol"] [class*="_root"],
    [class*="sidebarCol"] [class*="listArea"] { background: transparent !important; }
    [class*="sidebarCol"] [class*="footArea"],
    [class*="sidebarCol"] [class*="footerActions"],
    [class*="sidebarCol"] [class*="settingsArea"],
    [class*="sidebarCol"] [class*="fade"] { background: transparent !important; }
    html.dsh-native-window-drag,
    html.dsh-native-window-drag * {
      cursor: default !important;
      -webkit-user-select: none !important;
      user-select: none !important;
    }
    .dsh-native-window-drag-hover,
    .dsh-native-window-drag-hover * {
      cursor: default !important;
    }
    """

    /// The shell's own macOS layout, for a Runtime that draws none
    /// (`supportsNativeMacOSShell`): it collapses the sidebar to a 56px rail
    /// sized for icons, so this shell widens the rail to the traffic-light
    /// gutter and pads the column down past the window buttons.
    ///
    /// Every rule is scoped to the absence of the platform marker, which is
    /// published only for a Runtime that has its own layout. One stylesheet
    /// therefore serves both branches, and a Runtime switch flips between them
    /// through that single attribute — there is no second document to keep in
    /// sync and no stale rule left behind after a switch.
    private static let shellLegacyRailCSS = """
    html:not([data-platform="darwin"]) {
      --dsh-shell-traffic-light-safe-height: 20px;
      --dsh-shell-traffic-light-safe-width: 72px;
      --dsh-shell-sidebar-width: 88px;
    }
    html:not([data-platform="darwin"]) [class*="sidebarCol"] {
      padding-top: var(--dsh-shell-traffic-light-safe-height) !important;
      min-width: var(--dsh-shell-sidebar-width) !important;
      background: color-mix(in srgb, var(--dsw-specific-sidebar-fill) 70%, transparent) !important;
    }
    html:not([data-platform="darwin"]) [data-sidebar-collapsed] {
      grid-template-columns: var(--dsh-shell-sidebar-width) minmax(0px, 1fr) 0px !important;
    }
    html:not([data-platform="darwin"]) [data-sidebar-right-panel="fullscreen"] {
      left: var(--dsh-shell-traffic-light-safe-width) !important;
      width: auto !important;
    }
    html:not([data-platform="darwin"]) [class*="frame"]:has(> [class*="sidebarCol"]) {
      padding-top: 0 !important;
    }
    html:not([data-platform="darwin"]) [class*="centerCol"] {
      background: var(--dsw-alias-bg-base) !important;
      box-sizing: border-box !important;
      padding-top: 0 !important;
    }
    html:not([data-platform="darwin"]) [class*="sidebarCol"] [class*="logoRow"] {
      position: relative !important;
      top: 6px !important;
    }
    html:not([data-platform="darwin"]) [class*="railIn"] [class*="iconButton"],
    html:not([data-platform="darwin"]) [class*="railIn"] [class*="newSession"],
    html:not([data-platform="darwin"]) [class*="railIn"] [class*="searchButton"],
    html:not([data-platform="darwin"]) [class*="railIn"] [class*="headerActions"],
    html:not([data-platform="darwin"]) [class*="railIn"] [class*="search"] {
      margin-left: auto !important;
      margin-right: auto !important;
    }
    /* Keep the Runtime icon centered only when the sidebar is collapsed. */
    html:not([data-platform="darwin"]) [class*="sidebarCol"] [class*="root"][class*="collapsed"] [class*="panelList"]:has([aria-label="插件"], [aria-label="Plugins"]) [class*="panelRow"] {
      align-self: center !important;
    }
    """

    /// The official desktop's platform marker. A Runtime that has a macOS
    /// layout of its own reads it and then owns everything this shell used to
    /// force: the sidebar collapses to zero width with its reopen and New
    /// Session controls moved into the frame's leading seat, a 52px top strip
    /// clears the traffic lights, the sidebar takes its translucent gradient,
    /// and the center column gets its own background and hairline border.
    private static let platformMarkerScript = """
    (() => {
      const mark = () => {
        document.documentElement?.setAttribute('data-platform', 'darwin');
      };
      if (document.documentElement) mark();
      else window.addEventListener('DOMContentLoaded', mark, { once: true });
    })();
    """

    private static let loadingCSS = """
    #dsh-plugin-loading-overlay, [class*="pluginLoading"] {
      display: none !important;
    }
    """

    /// Disable browser-style menus on non-interactive page chrome while
    /// retaining useful editing, link and selected-text menus.
    private static let contextMenuScript = """
    (() => {
      if (window.__DSH_CONTEXT_MENU_POLICY_INSTALLED__) return;
      window.__DSH_CONTEXT_MENU_POLICY_INSTALLED__ = true;
      const interactiveSelector = [
        'a[href]', 'button', 'input', 'select', 'textarea', 'summary',
        '[role="button"]', '[role="menuitem"]', '[role="tab"]',
        '[role="switch"]',
        '[contenteditable]:not([contenteditable="false"])',
        '[data-dsh-context-menu="allow"]'
      ].join(',');
      document.addEventListener('contextmenu', (event) => {
        const target = event.target instanceof Element ? event.target : null;
        const selection = window.getSelection?.()?.toString() ?? '';
        if (target?.closest(interactiveSelector) || selection.length > 0) return;
        event.preventDefault();
        event.stopImmediatePropagation();
      }, true);
    })();
    """

    /// Keep WebKit in charge of titlebar hit testing. A drag starts only
    /// after the pointer moves beyond a small threshold on non-interactive
    /// titlebar content, so buttons and links remain clickable.
    private static let windowDragScript = """
    (() => {
      if (window.__DSH_NATIVE_WINDOW_DRAG_INSTALLED__) return;
      window.__DSH_NATIVE_WINDOW_DRAG_INSTALLED__ = true;
      const titlebarHeight = 52;
      const dragThreshold = 4;
      const interactiveSelector = [
        'a[href]', 'button', 'input', 'select', 'textarea', 'summary',
        '[role="button"]', '[role="tab"]', '[role="menuitem"]',
        '[role="switch"]',
        '[contenteditable]:not([contenteditable="false"])',
        '[tabindex]:not([tabindex="-1"])'
      ].join(',');
      let candidate = null;
      let dragging = false;
      let suppressClick = false;
      let suppressTitlebarSelection = false;
      let hoverElement = null;
      const post = (type) => {
        window.webkit?.messageHandlers?.dshDesktop?.postMessage({ type });
      };
      const isInteractive = (target) => {
        if (!(target instanceof Element)) return false;
        if (target.closest(interactiveSelector)) return true;
        let current = target;
        while (current && current !== document.documentElement) {
          const cursor = window.getComputedStyle(current).cursor;
          if (cursor && cursor !== 'auto' && cursor !== 'default') return true;
          current = current.parentElement;
        }
        return false;
      };
      const isTextEditingTarget = (target) => {
        if (!(target instanceof Element)) return false;
        return Boolean(target.closest('input, textarea, [contenteditable]:not([contenteditable="false"])'));
      };
      const setDragSurfaceActive = (active) => {
        document.documentElement.classList.toggle('dsh-native-window-drag', active);
      };
      const clearHoverElement = () => {
        hoverElement?.classList.remove('dsh-native-window-drag-hover');
        hoverElement = null;
      };
      const updateTitlebarHover = (event) => {
        clearHoverElement();
        if (candidate || event.clientY > titlebarHeight || isInteractive(event.target)) return;
        if (!(event.target instanceof Element)) return;
        hoverElement = event.target;
        hoverElement.classList.add('dsh-native-window-drag-hover');
      };
      const reset = () => {
        candidate = null;
        dragging = false;
        setDragSurfaceActive(false);
      };
      window.__DSH_NATIVE_WINDOW_DRAG_CLEANUP__ = reset;
      document.addEventListener('mousedown', (event) => {
        suppressClick = false;
        clearHoverElement();
        suppressTitlebarSelection = event.clientY <= titlebarHeight && !isTextEditingTarget(event.target);
        setDragSurfaceActive(false);
        if (event.button !== 0 || event.clientY > titlebarHeight || isInteractive(event.target)) {
          candidate = null;
          return;
        }
        event.preventDefault();
        candidate = { x: event.screenX, y: event.screenY };
        setDragSurfaceActive(true);
        post('windowDragPrepare');
      }, { capture: true, passive: false });
      document.addEventListener('mousemove', (event) => {
        updateTitlebarHover(event);
        if (!candidate) return;
        if (!dragging) {
          const distance = Math.hypot(event.screenX - candidate.x, event.screenY - candidate.y);
          if (distance < dragThreshold) return;
          dragging = true;
          suppressClick = true;
          post('windowDragStart');
        }
        event.preventDefault();
        event.stopImmediatePropagation();
        post('windowDragMove');
      }, { capture: true, passive: false });
      document.addEventListener('mouseup', (event) => {
        suppressTitlebarSelection = false;
        if (!candidate) return;
        if (dragging) {
          event.preventDefault();
          event.stopImmediatePropagation();
          post('windowDragEnd');
        }
        reset();
        updateTitlebarHover(event);
      }, { capture: true, passive: false });
      document.addEventListener('click', (event) => {
        if (!suppressClick) return;
        suppressClick = false;
        event.preventDefault();
        event.stopImmediatePropagation();
      }, true);
      document.addEventListener('selectstart', (event) => {
        if (suppressTitlebarSelection) event.preventDefault();
      }, { capture: true, passive: false });
      document.addEventListener('dblclick', (event) => {
        clearHoverElement();
        if (event.button !== 0 || event.clientY > titlebarHeight || isInteractive(event.target)) return;
        event.preventDefault();
        event.stopImmediatePropagation();
        window.getSelection?.()?.removeAllRanges();
        post('windowTitlebarDoubleClick');
      }, true);
      window.addEventListener('blur', () => {
        if (dragging) post('windowDragEnd');
        suppressClick = false;
        suppressTitlebarSelection = false;
        clearHoverElement();
        reset();
      });
      document.addEventListener('mouseleave', clearHoverElement, true);
    })();
    """

    public static let webUIReadinessScript = """
    (() => {
      const body = document.body;
      const text = body && typeof body.textContent === 'string' ? body.textContent.trim() : '';
      const hasAppShell = Boolean(document.querySelector('[class*="sidebarCol"], [class*="railIn"], [class*="centerCol"]'));
      const authenticationRequired = /dsh web authentication required|上游认证|required.*authentication/i.test(text);
      return {
        loading: text.includes('Loading plugins') || text.includes('加载插件'),
        length: text.length,
        hasAppShell,
        authenticationRequired
      };
    })();
    """

    /// Probe the same Remote stream carrier used by the DSH frontend. The
    /// script runs inside the page so WebKit, rather than a native URLSession,
    /// decides which HttpOnly cookies are attached to the handshake.
    public static let webUIConnectionProbeScript = """
    const target = new URL('/api/remote.mux', window.location.href);
    target.protocol = target.protocol === 'https:' ? 'wss:' : 'ws:';
    const timeoutMs = 5000;
    return await new Promise((resolve) => {
      let socket;
      let settled = false;
      const finish = (ok, reason) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        if (socket && socket.readyState === WebSocket.OPEN) {
          socket.close(1000, 'health-check');
        }
        resolve({ ok, reason: reason || '' });
      };
      const timer = setTimeout(() => finish(false, 'timeout'), timeoutMs);
      try {
        socket = new WebSocket(target.toString());
        socket.addEventListener('open', () => finish(true, 'open'), { once: true });
        socket.addEventListener('error', () => finish(false, 'error'), { once: true });
        socket.addEventListener('close', () => finish(false, 'closed-before-open'), { once: true });
      } catch (_) {
        finish(false, 'construct');
      }
    });
    """

    public init(delegate: DshBridgeDelegate) {
        self.rootView = NSVisualEffectView(frame: .zero)
        self.bridgeHandler = DshBridgeHandler()

        let config = WKWebViewConfiguration()
        // DSH owns durable sessions and application data in its Profile. The
        // WebView carries only the current loopback process's short-lived
        // authentication state, so persisting website data across App
        // launches can only retain credentials/cache state for a process that
        // no longer exists. A fresh ephemeral store also gives bounded auth
        // recovery a genuinely new WebKit network session.
        config.websiteDataStore = .nonPersistent()
        config.preferences.setValue(Self.developerToolsEnabledByDefault, forKey: "developerExtrasEnabled")

        let userContent = WKUserContentController()
        self.userContentController = userContent
        self.bridgeHandler.delegate = delegate
        userContent.add(self.bridgeHandler, name: "dshDesktop")
        // A Runtime without its own layout still gets the rail, but the marker
        // is re-derived before every launch, so start from the older branch.
        Self.installUserScripts(into: userContent, publishesPlatformMarker: false)
        config.userContentController = userContent

        self.webView = WKWebView(frame: .zero, configuration: config)
        self.webView.autoresizingMask = [.width, .height]
        self.webView.setValue(false, forKey: "drawsBackground")
#if DEBUG
        self.webView.isInspectable = Self.developerToolsEnabledByDefault
#endif
        configureRootView()
    }

    /// Install the shell's whole script set for one layout branch.
    ///
    /// WebKit can drop every user script at once but not a single one, so a
    /// branch switch rebuilds the set the shell owns instead of adding and
    /// revoking one script. The marker is registered ahead of the stylesheet
    /// that selects on it, so the attribute is already on the document element
    /// when the shell's rules are inserted.
    ///
    /// Every script is main-frame only. The layout, the bridge and the menu
    /// policy belong to the DSH document, and the shell's sub-frames are other
    /// people's pages: the Browser panel's site and the HTML preview's user
    /// document. Injecting into those would let `[class*="fade"]`-style rules
    /// and `html, body { background: transparent }` reach a page that never
    /// agreed to them, and would hand `window.dshDesktop` to a foreign origin
    /// whose messages the bridge rejects anyway.
    private static func installUserScripts(
        into userContent: WKUserContentController,
        publishesPlatformMarker: Bool
    ) {
        userContent.removeAllUserScripts()
        userContent.addUserScript(WKUserScript(
            source: DshBridgeHandler.scriptSource,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        // The sidebar Browser's native carrier. Without it the panel falls back
        // to an iframe, which cannot report a cross-origin page's URL or title
        // and is refused outright by every site that forbids framing.
        userContent.addUserScript(WKUserScript(
            source: DshSidebarBrowserScript.source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        userContent.addUserScript(WKUserScript(
            source: Self.windowDragScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        if publishesPlatformMarker {
            userContent.addUserScript(WKUserScript(
                source: Self.platformMarkerScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            ))
        }
        let styleScript = """
        (() => {
          const style = document.createElement('style');
          style.id = 'dsh-shell-styles';
          style.textContent = `\(Self.shellSharedCSS)\n\(Self.shellLegacyRailCSS)\n\(Self.loadingCSS)`;
          (document.head || document.documentElement).appendChild(style);
        })();
        """
        userContent.addUserScript(WKUserScript(
            source: styleScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        userContent.addUserScript(WKUserScript(
            source: Self.contextMenuScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
    }

    /// Match the injected layout to what the Runtime about to render can do.
    ///
    /// The shell draws the macOS layout only for a Runtime that draws none:
    /// the rail width, the traffic-light padding and the titlebar overrides in
    /// `shellLegacyRailCSS` exist because such a Runtime collapses its sidebar
    /// to a 56px icon rail. A Runtime that supports a native macOS shell
    /// collapses it to zero width and moves the reopen and New Session
    /// controls into the frame's leading seat, so every one of those overrides
    /// has to be off. That is what the platform marker switches: the marker
    /// itself disables exactly those rules, so publishing and revoking it is
    /// the whole decision.
    ///
    /// Called before each navigation rather than once at construction. The
    /// shell keeps one WebView for its lifetime, and the Runtime behind it can
    /// move in either direction — a rollback has to get its rail back — so the
    /// policy is derived from every launch, not from the one that built the
    /// window.
    public func applyRuntimeCapabilities(runtimeVersion: String) {
        let publishesMarker = DshSemanticVersion(runtimeVersion)?.supportsNativeMacOSShell ?? false
        guard publishesMarker != publishesPlatformMarker else { return }
        publishesPlatformMarker = publishesMarker
        Self.installUserScripts(
            into: userContentController,
            publishesPlatformMarker: publishesMarker
        )
    }

    /// Host the sidebar Browser's native guest. The shim that drives it is part
    /// of the injected script set; this registers the handler it posts to.
    public func attachSidebarBrowser(_ pane: DshSidebarBrowserPane) {
        userContentController.add(pane, name: DshSidebarBrowserPane.messageHandlerName)
    }

    /// Bind the native bridge to the current WebKit session. The shell keeps
    /// one WebView for its lifetime, so this must be refreshed for every new
    /// launch/generation and cleared before a restart or failure.
    public func updateBridgeValidationContext(
        launchID: UUID,
        generationID: UUID,
        origin: DshBridgeOrigin,
        allowedMessageTypes: Set<DshBridgeMessageType> = DshBridgeMessageType.normalCapability
    ) {
        bridgeHandler.updateValidationContext(DshBridgeValidationContext(
            webViewIdentity: DshBridgeWebViewIdentity(object: webView),
            launchID: launchID,
            generationID: generationID,
            origin: origin,
            allowedMessageTypes: allowedMessageTypes
        ))
    }

    /// Disable native actions while there is no authenticated live session.
    public func clearBridgeValidationContext() {
        bridgeHandler.updateValidationContext(nil)
    }

    /// Discard every transient artifact owned by the loopback page before a
    /// bounded authentication retry. Cookies alone are insufficient when the
    /// WebKit network process has retained a failed redirect or origin state;
    /// this store is ephemeral and contains no durable DSH user data.
    public func resetWebsiteDataForAuthenticationRecovery() async {
        webView.stopLoading()
        let dataStore = webView.configuration.websiteDataStore
        await withCheckedContinuation { continuation in
            dataStore.removeData(
                ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                modifiedSince: .distantPast
            ) {
                continuation.resume()
            }
        }
    }

    public func syncTheme(_ theme: String) {
        let serialized = theme == "claude" ? "\"claude\"" : "\"default\""
        evaluate("""
        (() => {
          const theme = \(serialized);
          window.__DSH_DESKTOP_UI_THEME__ = theme;
          window.dispatchEvent(new CustomEvent('dsh-desktop-ui-theme-change', { detail: { theme } }));
        })();
        """)
    }

    /// Publish the native traffic-light cluster width as a CSS custom property
    /// so the fullscreen right panel can yield a left gutter for the window
    /// buttons instead of sitting underneath them.
    public func updateTrafficLightSafeWidth(_ width: CGFloat) {
        evaluate("""
        (() => {
          const root = document.documentElement;
          if (!root) return;
          root.style.setProperty('--dsh-shell-traffic-light-safe-width', '\(width)px');
        })();
        """)
    }

    public func enableDeveloperTools() {
#if DEBUG
        webView.configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        webView.isInspectable = true
#endif
    }

    public func closeDeveloperTools() {
        webView.configuration.preferences.setValue(false, forKey: "developerExtrasEnabled")
        webView.isInspectable = false
    }

    private func configureRootView() {
        rootView.material = .sidebar
        rootView.blendingMode = .behindWindow
        rootView.state = .followsWindowActiveState
        rootView.addSubview(webView)
        webView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            webView.topAnchor.constraint(equalTo: rootView.topAnchor),
            webView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor)
        ])
    }

    private func evaluate(_ script: String) {
        webView.evaluateJavaScript(script, completionHandler: nil)
    }
}
