import AppKit
import CryptoKit
import WebKit
import SwiftUI
import Combine
import UniformTypeIdentifiers

private enum DshMainWindowUIMessage {
    static let maximumLength = 600

    static func safe(_ text: String) -> String {
        let redacted = DshSecretRedactor().redact(text)
        guard redacted.count > maximumLength else { return redacted }
        return String(redacted.prefix(maximumLength)) + "…"
    }

    static func safe(_ error: Error) -> String {
        safe(error.localizedDescription)
    }
}

private final class DownloadStatusBanner: NSVisualEffectView {
    private let spinner = NSProgressIndicator()
    private let statusLabel = NSTextField(labelWithString: "")
    private let pathLabel = NSTextField(labelWithString: "")
    private let revealButton = NSButton(title: "在访达中显示", target: nil, action: nil)
    private let closeButton = NSButton(title: "关闭", target: nil, action: nil)

    var onReveal: (() -> Void)?
    var onClose: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        material = .popover
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)

        statusLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        pathLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.maximumNumberOfLines = 1

        revealButton.bezelStyle = .rounded
        revealButton.controlSize = .small
        revealButton.target = self
        revealButton.action = #selector(revealDownload)

        closeButton.bezelStyle = .rounded
        closeButton.controlSize = .small
        closeButton.target = self
        closeButton.action = #selector(closeBanner)

        let textStack = NSStackView(views: [statusLabel, pathLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 3

        let stack = NSStackView(views: [spinner, textStack, revealButton, closeButton])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 12
        addSubview(stack)

        textStack.setHuggingPriority(.defaultLow, for: .horizontal)
        textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        revealButton.setContentHuggingPriority(.required, for: .horizontal)
        closeButton.setContentHuggingPriority(.required, for: .horizontal)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 13),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -13),
            spinner.widthAnchor.constraint(equalToConstant: 16),
            spinner.heightAnchor.constraint(equalToConstant: 16)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(destination: URL, completed: Bool) {
        statusLabel.stringValue = completed ? "下载完成" : "正在下载"
        let fullPath = destination.path
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        pathLabel.stringValue = fullPath.hasPrefix(homePath + "/")
            ? "~" + String(fullPath.dropFirst(homePath.count))
            : fullPath
        pathLabel.toolTip = fullPath

        spinner.isHidden = completed
        if completed {
            spinner.stopAnimation(nil)
        } else {
            spinner.startAnimation(nil)
        }
        revealButton.isHidden = !completed
    }

    @objc private func revealDownload() {
        onReveal?()
    }

    @objc private func closeBanner() {
        onClose?()
    }
}

/// Native progress surface shown while the managed child and WebKit session
/// cross their startup gates. It stays independent from the failure surface so
/// a slow but healthy launch is never presented as an error.
/// Startup progress is rendered by the standalone SwiftUI card in
/// `Sources/Startup/StartupView.swift` and owned by `DshStartupWindowController`.

/// AppKit indicator shown while an isolated recovery service is active.
@MainActor
private final class NativeSafeModeBanner: NSVisualEffectView {
    private let label = NSTextField(labelWithString: "")
    private let returnButton = NSButton(title: "返回普通模式", target: nil, action: nil)
    var onReturn: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .popover
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 10

        label.font = .systemFont(ofSize: 12, weight: .semibold)
        returnButton.bezelStyle = .rounded
        returnButton.controlSize = .small
        returnButton.target = self
        returnButton.action = #selector(returnToNormalMode)

        let stack = NSStackView(views: [label, returnButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(originalProfile: DshAppProfile) {
        label.stringValue = "安全模式 · 原 Profile：\(originalProfile.rawValue) · 仅本次 Renderer 访问"
    }

    @objc private func returnToNormalMode() {
        onReturn?()
    }
}

public final class MainWindowController: NSWindowController, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate, DshBridgeDelegate {
    public static let shared = MainWindowController()

    private var webView: WKWebView?
    private var vibrancyView: NSVisualEffectView?
    private var webShell: DshWebShell?
    private var rendererCookieStore: DshRendererCookieStore?
    private var upstreamCookieStore: DshUpstreamCookieStore?
    private var serviceSession: DshServiceSession?
    /// The context that owns the currently starting/running generation. It is
    /// replaced only at a serialized launch boundary and never by settings
    /// refreshes during the asynchronous startup.
    private var launchContext: DshLaunchContext?
    /// Coalesce menu, settings, and Dock reopen requests while one startup
    /// is already queued on the runtime operation gate. A second request must
    /// not create another healthy-start commit for the same transaction.
    private var startupTask: Task<Void, Never>?
    private var postReadyAuthorizationTask: Task<Void, Never>?
    private var onboardingHostingView: NSView?
    private var webUIReadinessGeneration = 0
    private var pendingWebUINavigation: WKNavigation?
    /// WebKit can deliver a navigation failure after a newer load has
    /// already replaced the page (and after `pendingWebUINavigation` was
    /// cleared). Keep the startup generation attached to every navigation we
    /// initiate so a late callback cannot fail the newer health page.
    private var webUINavigationGenerations: [ObjectIdentifier: Int] = [:]
    private var webUIReadyContinuation: CheckedContinuation<Void, Error>?
    private var webUIReadyTimeoutTask: Task<Void, Never>?
    private var windowDragMouseDownEvent: NSEvent?
    private var isUsingNativeWindowDrag = false
    private var windowDragStartOrigin: NSPoint?
    private var windowDragStartMouseLocation: NSPoint?
    private var downloadDestinations: [ObjectIdentifier: URL] = [:]
    private var downloadStatusBanner: DownloadStatusBanner?
    private let diagnosticStore = DshDiagnosticStore(
        storageURL: DshStateManager.appSupportDirectory.appendingPathComponent("dsh-diagnostics.json")
    )
    private var startupStatusModel = DshStartupStatusModel()
    private var safeModeBanner: NativeSafeModeBanner?
    private var recoveryViewModel: DshRecoveryViewModel?
    private var recoveryProfileManager: DshRecoveryProfileManager?
    private var recoveryLaunch: DshRecoveryLaunch?
    private var persistedRecoveryRecord: DshRecoveryState?
    private var safeModeNormalContext: DshLaunchContext?
    private var isSafeModeActive = false
    private var safeModeUnavailableReason: String?
    /// A startup recovery failure is a durable-operation handoff: do not
    /// silently fall through to normal service startup while its owner record
    /// remains unresolved.
    private var startupRecoveryError: String?
    private var startupRecoveryIsPluginOperation = false
    /// A corrupt/unreadable primary state file is a process-wide startup
    /// blocker. Keep it separate from Runtime/Profile/plugin recovery so a
    /// retry can never accidentally fall through to normal launch.
    private var startupStatePersistenceBlocked = false
    /// A malformed app-owned recovery record has no trustworthy owner ID.
    /// Keep this blocker distinct from an ordinary startup failure so Retry
    /// cannot silently start the user's Profile after the record is rejected.
    private var startupRecoveryRecordCorrupted = false
    /// A recovered plugin mutation is committed only after the next ordinary
    /// healthy launch. Keep its owner ID in memory until that launch passes.
    private var pendingCommittedPluginOperationID: String?
    private let runtimeOperationGate = DshAsyncOperationGate()
    private let runtimeHealthClient = DshRuntimeHealthClient()
    private var runtimeReloadTask: Task<Void, Never>?
    private var trafficLightBaseFrames: [NSWindow.ButtonType: NSRect] = [:]

    private static let trafficLightHorizontalOffset: CGFloat = 7
    private static let trafficLightVerticalOffset: CGFloat = -7
    private static let trafficLightSafeWidthMargin: CGFloat = 8
    private static let maxAutomaticAuthenticationRecoveries = 1
    private enum RuntimeHealthError: LocalizedError {
        case nonHTTPResponse(String)
        case unexpectedStatus(label: String, expected: String, actual: Int)
        case invalidPage
        case malformedBrowserURL
        case malformedLANURL
        case liveAccessPolicyUnavailable
        case authenticationRequired
        case webKitConnectionFailed(String)

        var errorDescription: String? {
            switch self {
            case .nonHTTPResponse(let label):
                return "\(label) 没有返回有效的 HTTP 响应。"
            case .unexpectedStatus(let label, let expected, let actual):
                return "\(label) 健康检查失败：期望 \(expected)，实际 HTTP \(actual)。"
            case .invalidPage:
                return "Renderer 页面健康检查失败：返回内容不是有效的 HTML 页面。"
            case .malformedBrowserURL:
                return "Browser 访问边界检查失败：Host 返回了无效的 loopback URL。"
            case .malformedLANURL:
                return "LAN 访问边界检查失败：Host 返回了无效的局域网 URL。"
            case .liveAccessPolicyUnavailable:
                return "DSH 服务访问策略未被当前启动代际确认。"
            case .authenticationRequired:
                return "DSH 上游认证已失效，需要重新建立认证会话。"
            case .webKitConnectionFailed(let reason):
                return "DSH WebSocket 连接健康检查失败：\(reason)"
            }
        }
    }


    private init() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1440, height: 960),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.title = ""
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.minSize = NSSize(width: 960, height: 640)
        win.center()
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = true
        win.isReleasedWhenClosed = false
        win.isMovableByWindowBackground = true

        super.init(window: win)
        win.delegate = self
        if let closeButton = win.standardWindowButton(.closeButton) {
            closeButton.target = self
            closeButton.action = #selector(hideMainWindow)
        }
        setupContentView(in: win)
        adjustTrafficLights(in: win)
        // NSWindow can become visible as soon as the application activates.
        // Keep the main window explicitly hidden until the DSH page has
        // finished rendering; otherwise the user sees a blank/boot screen
        // while the runtime and bridge plugin are still starting.
        win.orderOut(nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The full-size transparent content view makes AppKit place the traffic
    /// lights too close to the physical top edge. Match the vertical rhythm
    /// of normal macOS titlebars while keeping the content visually fused.
    private func adjustTrafficLights(in win: NSWindow) {
        win.layoutIfNeeded()
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = win.standardWindowButton(type) else { continue }
            let baseFrame = trafficLightBaseFrames[type] ?? button.frame
            trafficLightBaseFrames[type] = baseFrame
            var frame = baseFrame
            frame.origin.x += Self.trafficLightHorizontalOffset
            frame.origin.y += Self.trafficLightVerticalOffset
            button.frame = frame
        }
        publishTrafficLightSafeWidth(in: win)
    }

    /// The traffic-light cluster ends at the right edge of the zoom button.
    /// Publish that edge (plus a small margin) to the page so the fullscreen
    /// right panel can leave a left gutter for the native window buttons.
    private func publishTrafficLightSafeWidth(in win: NSWindow) {
        var maxRight: CGFloat = 0
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = win.standardWindowButton(type) else { continue }
            maxRight = max(maxRight, button.frame.maxX)
        }
        webShell?.updateTrafficLightSafeWidth(maxRight + Self.trafficLightSafeWidthMargin)
    }

    public func windowDidBecomeMain(_ notification: Notification) {
        guard let win = window else { return }
        adjustTrafficLights(in: win)
    }

    private func setupContentView(in win: NSWindow) {
        let shell = DshWebShell(
            delegate: self
        )
        shell.webView.navigationDelegate = self
        shell.webView.uiDelegate = self
        self.webShell = shell
        self.webView = shell.webView
        self.rendererCookieStore = DshRendererCookieStore(dataStore: shell.webView.configuration.websiteDataStore)
        self.upstreamCookieStore = DshUpstreamCookieStore(dataStore: shell.webView.configuration.websiteDataStore)
        self.vibrancyView = shell.rootView
        win.contentView = shell.rootView
    }

    /// Bind the bridge only after DSH has created the current access
    /// generation. The WebView object is stable across reloads, therefore the
    /// launch and generation IDs are refreshed for every service restart.
    private func updateBridgeValidationContext(for session: DshServiceSession) {
        guard let origin = DshBridgeOrigin(url: session.originURL) else {
            webShell?.clearBridgeValidationContext()
            return
        }
        let capabilities = session.context.purpose == .recovery
            ? DshBridgeMessageType.recoveryCapability
            : DshBridgeMessageType.normalCapability
        webShell?.updateBridgeValidationContext(
            launchID: session.context.launchID,
            generationID: session.access.id,
            origin: origin,
            allowedMessageTypes: capabilities
        )
    }

    // MARK: - App Launch & Initialization

    /// Present native progress before AppDelegate begins any persisted-state
    /// recovery. macOS may restore the window independently of our normal
    /// `launch()` path; keeping this opaque surface visible prevents the
    /// underlying, not-yet-navigated WKWebView from appearing as a white
    /// screen during snapshot restoration or dependency preparation.
    public func beginStartupPreparation() {
        hideRecoverySurface()
        showStartupSurface()
        startupStatusModel.phase = .preparing
        startupStatusModel.detail = "正在检查并恢复上次启动状态…"
    }

    public func launch() {
        if startupStatePersistenceBlocked {
            showStatePersistenceRecoverySurface()
            return
        }
        if let detail = DshStateManager.shared.loadResult.failureDescription {
            blockStartupForStateFailure(detail)
            return
        }
        if startupRecoveryRecordCorrupted {
            if let context = launchContext {
                showRecoverySurface(for: context)
            }
            return
        }
        if startupRecoveryError != nil {
            if let context = launchContext ?? makeLaunchContext() {
                launchContext = context
                beginDiagnosticLaunch(for: context)
                showRecoverySurface(for: context)
            }
            return
        }
        if presentPersistedRecoveryIfNeeded() { return }
        let installed = DshVersionManager.shared.listInstalledVersions()
        if installed.isEmpty && DshVersionManager.shared.resolveCurrentEntry() == nil {
            showOnboardingView()
            revealWindow()
        } else {
            showStartupSurface()
            startAndLoadDsh()
        }
    }

    /// A recovery record is an explicit handoff across process death. Do not
    /// silently start the normal Profile while it is present; show the native
    /// entry point so the user can continue isolation or retry cleanup.
    @discardableResult
    private func presentPersistedRecoveryIfNeeded() -> Bool {
        let manager = DshRecoveryProfileManager(
            applicationSupportDirectory: DshStateManager.appSupportDirectory
        )
        switch manager.readState() {
        case .absent:
            persistedRecoveryRecord = nil
            startupRecoveryRecordCorrupted = false
            return false
        case .corrupted(let detail):
            // The record cannot authorize a Profile path or Runtime. Use an
            // isolated diagnostic context even when the primary state is
            // healthy; falling back to `makeLaunchContext()` would let the
            // native recovery surface inspect or mutate personal data.
            let context = makeRecoveryRecordDiagnosticContext()
            persistedRecoveryRecord = nil
            recoveryProfileManager = nil
            startupRecoveryRecordCorrupted = true
            launchContext = context
            beginDiagnosticLaunch(for: context)
            _ = diagnosticStore.appendLog(
                "F06 recovery record corrupted: \(DshMainWindowUIMessage.safe(detail))",
                launchID: context.launchID,
                source: .native
            )
            _ = diagnosticStore.record(
                launchID: context.launchID,
                phase: .preparing,
                code: .unknown,
                summary: "检测到损坏的安全模式恢复记录。",
                technicalDetail: DshMainWindowUIMessage.safe(detail),
                retryability: .notRetryable,
                source: .native
            )
            safeModeUnavailableReason = "恢复记录损坏：\(DshMainWindowUIMessage.safe(detail))"
            showRecoverySurface(for: context)
            recoveryViewModel?.setSafeModeAvailability(false, reason: safeModeUnavailableReason)
            return true
        case .loaded(let state):
            startupRecoveryRecordCorrupted = false
            let context: DshLaunchContext
            if [.returned, .cleanupPending, .cleaned].contains(state.phase) {
                // These phases only need the app-owned cleanup path. They do
                // not need a normal Profile context, and using one here
                // would make diagnostics inspect personal Profile files or
                // make cleanup depend on an invalid primary state.
                context = makeRecoveryRecordDiagnosticContext()
            } else {
                guard let normalContext = makeLaunchContext() else {
                    showErrorAlert("检测到未完成的安全模式恢复记录，请重新启动 DSH。")
                    return true
                }
                context = normalContext
            }
            persistedRecoveryRecord = state
            recoveryProfileManager = manager
            launchContext = context
            beginDiagnosticLaunch(for: context)
            _ = diagnosticStore.appendLog(
                "F06 recovery record resumed: phase=\(state.phase.rawValue) preparation=\(state.preparation.rawValue)",
                launchID: context.launchID,
                source: .native
            )
            showRecoverySurface(for: context)
            return true
        }
    }

    private func makeLaunchContext(from state: DshStateConfig? = nil) -> DshLaunchContext? {
        DshLaunchContext.makeStartup(
            from: state ?? DshStateManager.shared.current
        )
    }

    /// Context of the current authenticated generation, or the generation
    /// currently crossing the startup boundary while WebKit is authenticating.
    public var currentLaunchContext: DshLaunchContext? {
        serviceSession?.context ?? launchContext
    }

    /// A recovery record or active isolated service owns the next launch
    /// decision. Settings uses this as a second guard while the launch
    /// context is temporarily normal during process restoration.
    public var hasUnresolvedRecovery: Bool {
        persistedRecoveryRecord != nil
            || isSafeModeActive
            || safeModeUnavailableReason != nil
            || startupRecoveryRecordCorrupted
            || startupRecoveryError != nil
            || DshPluginOperationCoordinator.shared.pendingOperation != nil
    }

    /// Recover a P01 plugin operation while the caller already owns the
    /// Runtime/Profile gate (normally AppDelegate's startup gate). This
    /// method intentionally does not acquire that gate again.
    @discardableResult
    /// Health hooks shared by startup plugin recovery and the
    /// user-consented verify-and-continue path. Recovery never begins a new
    /// package mutation; ordinary startup health validates both fresh and
    /// restored trees.
    private func makeStartupPluginOperationHooks() -> DshPluginOperationHooks {
        let restartHealth: @Sendable (DshPluginOperationRequest) async throws -> Void = {
            [weak self] request in
            guard let self else {
                throw DshPluginOperationError.recoveryRequired("启动恢复协调器已退出")
            }
            let context = try await MainActor.run {
                try self.makeOrdinaryDesktopStartupContext()
            }
            guard request.profile == context.profile,
                  request.profileDirectory.standardizedFileURL.path
                    == context.profileDirectory.standardizedFileURL.path else {
                throw DshPluginOperationError.recoveryRequired(
                    "插件事务 Profile 与普通 desktop 启动目标不一致"
                )
            }
            // The caller owns runtimeOperationGate. This lower-level entry
            // point is the only legal way to perform the health start here.
            _ = try await self.restartDshServiceWithAuthenticationRecoveryDuringOperation(
                context: context
            )
        }
        return DshPluginOperationHooks(
            mutate: { _ in
                // Recovery never begins a new package mutation. The required
                // placeholder keeps the coordinator's side-effect hooks
                // explicit if a future phase adds a mutation resume path.
            },
            verify: restartHealth,
            verifyRestored: restartHealth
        )
    }

    public func recoverPendingPluginOperationDuringStartup() async throws -> DshPluginOperationResult? {
        let coordinator = DshPluginOperationCoordinator.shared
        if let pending = coordinator.pendingOperation,
           pending.phase != .prepared {
            guard DshStateManager.shared.current.appProfile == .desktop else {
                throw DshPluginOperationError.desktopProfileRequired
            }
        }
        if let pending = coordinator.pendingOperation,
           pending.phase != .prepared,
           pending.phase != .committed {
            _ = try makeOrdinaryDesktopStartupContext()
        }

        let hooks = makeStartupPluginOperationHooks()
        let result = try await coordinator.recoverPendingOperation(hooks: hooks)
        if let result, result.phase == .committed {
            pendingCommittedPluginOperationID = result.operationID
        } else if coordinator.pendingOperation == nil {
            pendingCommittedPluginOperationID = nil
        }
        startupRecoveryError = nil
        startupRecoveryIsPluginOperation = false
        return result
    }

    /// Preserve a startup recovery failure for the native recovery surface.
    /// AppDelegate calls this after leaving the operation gate, before
    /// `launch()` decides whether a normal service start is allowed.
    public func blockStartupForRecovery(_ error: Error) {
        startupStatePersistenceBlocked = false
        startupRecoveryRecordCorrupted = false
        let safeMessage = DshMainWindowUIMessage.safe(error)
        startupRecoveryError = safeMessage
        startupRecoveryIsPluginOperation = error is DshPluginOperationError
            || coordinatorHasPendingPluginOperation
            || (error as NSError).domain == "DshPluginOperation"
        guard let context = makeLaunchContext() else {
            print("[MainWindowController] Startup recovery blocked:", safeMessage)
            return
        }
        launchContext = context
        beginDiagnosticLaunch(for: context)
        recordStartupFailure(
            error,
            context: context
        )
    }

    /// Retain the committed P01 owner when only its app-owned snapshot
    /// cleanup fails. The package mutation is already live, but the durable
    /// owner must continue through the plugin recovery/diagnostic surface
    /// until the snapshot and record are both cleared.
    public func markCommittedPluginCleanupFailure(
        operationID: String,
        error: Error
    ) {
        pendingCommittedPluginOperationID = operationID
        let recoveryError = DshPluginOperationError.recoveryRequired(
            "插件事务已提交，但快照清理失败：\(DshMainWindowUIMessage.safe(error))"
        )
        blockStartupForRecovery(recoveryError)
        // Keep this explicit even for a future error type that does not carry
        // the coordinator's domain or happen while the record is readable.
        startupRecoveryIsPluginOperation = true
        if let context = launchContext {
            showRecoverySurface(for: context)
        }
    }

    /// Stop startup on an invalid primary state file and present the native
    /// diagnostic/recovery page. The context points at an app-owned isolated
    /// directory and is never allowed to become a normal Profile launch.
    public func blockStartupForStateFailure(_ detail: String) {
        startupRecoveryRecordCorrupted = false
        let alreadyBlocked = startupStatePersistenceBlocked
        startupStatePersistenceBlocked = true
        startupRecoveryIsPluginOperation = false
        let safeDetail = DshMainWindowUIMessage.safe(detail)
        let error = DshStatePersistenceError.stateUnavailable(safeDetail)
        startupRecoveryError = safeDetail
        // A normal launch context may already exist when a later state commit
        // fails. Do not reuse it for the diagnostic surface: the state-failure
        // path must remain isolated from the user's Profile. Reuse only the
        // synthetic context created by an earlier invocation.
        let context = alreadyBlocked
            ? (launchContext ?? makeStatePersistenceRecoveryContext())
            : makeStatePersistenceRecoveryContext()
        launchContext = context
        beginDiagnosticLaunch(for: context)
        recordStartupFailure(error, context: context)
        showRecoverySurface(for: context)
    }

    private func showStatePersistenceRecoverySurface() {
        guard let context = launchContext else { return }
        beginDiagnosticLaunch(for: context)
        showRecoverySurface(for: context)
    }

    private func makeStatePersistenceRecoveryContext() -> DshLaunchContext {
        let launchID = UUID()
        let profileName = "dsh-recovery-\(launchID.uuidString.lowercased())"
        let recoveryHome = DshStateManager.appSupportDirectory
            .appendingPathComponent("dsh-state-recovery-\(launchID.uuidString.lowercased())", isDirectory: true)
        let profileDirectory = DshLaunchContext.profileDirectory(
            forName: profileName,
            dshHome: recoveryHome
        )
        return DshLaunchContext.makeRecovery(
            launchID: launchID,
            runtimeDescriptor: NpmRuntimeDescriptor(
                version: "unknown",
                registry: DshVersionManager.defaultRegistry
            ),
            profile: .desktop,
            profileName: profileName,
            profileDirectory: profileDirectory,
            effectiveDshHome: recoveryHome,
            originalProfile: .desktop,
            transactionID: nil,
            port: 3080
        )
    }

    /// A malformed recovery record has no trustworthy Profile, Runtime, or
    /// recovery ID. Present its diagnostics against a fresh app-owned
    /// synthetic context instead of reusing the normal launch context, which
    /// would expose the user's Profile to inspection or a recovery action.
    private func makeRecoveryRecordDiagnosticContext() -> DshLaunchContext {
        makeStatePersistenceRecoveryContext()
    }

    private var coordinatorHasPendingPluginOperation: Bool {
        DshPluginOperationCoordinator.shared.pendingOperation != nil
    }

    /// Build the ordinary desktop context used by P01 recovery health hooks.
    /// A settled Runtime/Profile state or a Runtime update in its confirmed
    /// cleanup window is compatible with an ordinary desktop start: .confirmed
    /// keeps the previous Runtime only until the second healthy start, and
    /// plugin recovery must be able to health-start during it
    /// (DshRuntimeMutationGate allows plugin mutations in .confirmed).
    /// Requiring .idle here deadlocks startup when a plugin crash lands inside
    /// that cleanup window, because the plugin recovery hooks need this
    /// context and the cleanup needs an ordinary start to finalize.
    private func makeOrdinaryDesktopStartupContext() throws -> DshLaunchContext {
        let state = DshStateManager.shared.current
        let runtimeState = state.runtimeState
        let transactionShapeIsCompatible: Bool
        switch runtimeState.phase {
        case .idle:
            transactionShapeIsCompatible = runtimeState.previous == nil
                && runtimeState.pending == nil
                && runtimeState.transactionID == nil
                && runtimeState.webProfileSnapshotID == nil
        case .confirmed:
            // The previous Runtime and transaction owner are retained for the
            // two-start cleanup window; both must match a persisted transaction
            // so the context never fabricates one. A retained web Profile
            // snapshot only marks pending cleanup and does not block a
            // plugin-health start (no restore runs for a confirmed phase).
            transactionShapeIsCompatible = runtimeState.previous != nil
                && runtimeState.transactionID != nil
                && runtimeState.pending == nil
        default:
            transactionShapeIsCompatible = false
        }
        guard state.appProfile == .desktop,
              state.pendingProfileSwitch == nil,
              runtimeState.profile == .desktop,
              transactionShapeIsCompatible,
              runtimeState.active != nil,
              let context = DshLaunchContext.makeStartup(from: state),
              context.profile == .desktop,
              context.purpose == .normal else {
            throw DshPluginOperationError.runtimeOrProfileRecoveryPending
        }
        try context.validate()
        return context
    }

    public func startAndLoadDsh() {
        if startupStatePersistenceBlocked {
            showStatePersistenceRecoverySurface()
            return
        }
        if let detail = DshStateManager.shared.loadResult.failureDescription {
            blockStartupForStateFailure(detail)
            return
        }
        if startupRecoveryRecordCorrupted {
            if let context = launchContext {
                showRecoverySurface(for: context)
            }
            return
        }
        if startupRecoveryError != nil {
            if let context = launchContext ?? makeLaunchContext() {
                launchContext = context
                beginDiagnosticLaunch(for: context)
                showRecoverySurface(for: context)
            }
            return
        }
        guard startupTask == nil else {
            // A launch is already in flight; bring its progress surface to
            // the front instead of silently swallowing the request.
            showStartupSurface()
            return
        }
        hideOnboardingView()
        hideRecoverySurface()
        showStartupSurface()
        startupTask = Task { @MainActor in
            defer { self.startupTask = nil }
            do {
                _ = try await withRuntimeOperation {
                    // Capture one state snapshot only after entering the
                    // operation gate. A queued launch must never retain the
                    // Profile/Runtime selected before an earlier operation
                    // committed its transaction.
                    guard let context = self.makeLaunchContext() else {
                        throw DshLaunchContextError.invalidProfileName
                    }
                    self.launchContext = context
                    let session = try await self.restartDshServiceWithAuthenticationRecoveryDuringOperation(
                        context: context
                    )
                    print("[MainWindowController] DSH service ready at \(session.originURL)")
                    SettingsViewModel.shared.refreshPlugins(for: context)
                    switch context.purpose {
                    case .normal:
                        try await SettingsViewModel.shared.recordHealthyRuntimeStart(for: context)
                    case .runtimeRollback:
                        try await SettingsViewModel.shared.finalizeRecoveredRuntimeAfterSuccessfulStart(for: context)
                    case .profileSwitch:
                        try await SettingsViewModel.shared.retryPendingProfileSwitchCleanup(for: context)
                    case .profileRollback:
                        try await SettingsViewModel.shared.retryPendingProfileSwitchCleanup(for: context)
                    case .runtimeVerification, .recovery:
                        // Verification and recovery starts only establish that
                        // this generation is available. Their success cannot
                        // commit a candidate or a Profile transaction.
                        break
                    }
                    if context.purpose == .normal,
                       context.profile == .desktop,
                       let operationID = self.pendingCommittedPluginOperationID {
                        // A committed plugin snapshot is deliberately kept
                        // until this extra ordinary launch is healthy.
                        do {
                            try await DshPluginOperationCoordinator.shared
                                .finalizeCommittedOperation(operationID: operationID)
                        } catch {
                            self.markCommittedPluginCleanupFailure(
                                operationID: operationID,
                                error: error
                            )
                            throw error
                        }
                        self.pendingCommittedPluginOperationID = nil
                        SettingsViewModel.shared.synchronizePersistedPluginOperationState()
                    }
                    return session
                }
            } catch {
                print("[MainWindowController] Service start failed:", DshMainWindowUIMessage.safe(error))
                if error is DshStatePersistenceError {
                    await DshService.shared.stopAndWait()
                    self.serviceSession = nil
                    self.webShell?.clearBridgeValidationContext()
                    self.blockStartupForStateFailure(error.localizedDescription)
                    return
                }
                let committedPluginOwnerFailure =
                    self.pendingCommittedPluginOperationID != nil
                    && DshPluginOperationCoordinator.shared.hasPersistedOperationRecord
                if committedPluginOwnerFailure {
                    // The committed plugin owner still exists even when the
                    // extra ordinary health start failed before cleanup was
                    // attempted. Keep retry on the plugin recovery path.
                    if self.startupRecoveryError == nil {
                        self.blockStartupForRecovery(error)
                    }
                    if let context = self.launchContext {
                        self.showRecoverySurface(for: context)
                    }
                } else if let context = self.launchContext {
                    self.recordStartupFailure(error, context: context)
                    self.showRecoverySurface(for: context)
                } else {
                    self.showErrorAlert(DshMainWindowUIMessage.safe(error))
                }
            }
        }
    }

    /// Restart the service and wait until the selected runtime is ready. The
    /// settings version switch uses this throwing form so it can restore the
    /// previous selection if the new runtime fails to boot.
    public func restartDshService() async throws -> DshServiceSession {
        try await withRuntimeOperation {
            try await self.restartDshServiceDuringOperation()
        }
    }

    /// Serialize the entire Runtime/Profile transaction, not only the final
    /// process restart. This prevents startup, auto-update, manual update and
    /// plugin mutations from interleaving profile changes or replacing the
    /// shared Web UI continuation.
    public func withRuntimeOperation<T>(_ operation: () async throws -> T) async throws -> T {
        try await runtimeOperationGate.acquire()
        defer { runtimeOperationGate.release() }
        return try await operation()
    }

    /// Called by a caller that already holds `withRuntimeOperation`.
    public func restartDshServiceDuringOperation(
        context providedContext: DshLaunchContext? = nil
    ) async throws -> DshServiceSession {
        if let detail = DshStateManager.shared.loadResult.failureDescription {
            throw DshStatePersistenceError.stateUnavailable(detail)
        }
        // Both the default and explicit paths use a single state snapshot
        // while the caller owns runtimeOperationGate. Explicit contexts must
        // still describe the transaction that is current at this boundary.
        let stateSnapshot = DshStateManager.shared.current
        let context: DshLaunchContext
        if let providedContext {
            context = providedContext
            guard context.isFresh(in: stateSnapshot) else {
                throw DshLaunchContextError.staleContext
            }
        } else {
            guard let freshContext = makeLaunchContext(from: stateSnapshot) else {
                throw DshLaunchContextError.invalidProfileName
            }
            context = freshContext
        }
        try context.validate()
        beginDiagnosticLaunch(for: context)
        setDiagnosticPhase(.dependencyCheck, launchID: context.launchID)
        // Invalidate the previous bridge before any stop or profile mutation
        // can cross the old service boundary. A failed preparation must not
        // leave the old WebView context authorized.
        webShell?.clearBridgeValidationContext()
        serviceSession = nil
        launchContext = context
        // Profile recovery and snapshot operations must never race a Node
        // child left behind by a force-quit. This is intentionally before any
        // package or snapshot mutation below.
        try await DshService.shared.prepareForProfileMutation(context: context)

        // DSH 0.1.5 reserves the literal `desktop` profile for Electron.
        // Migrate the Swift shell's previous isolated tree before the first
        // inspection of its new App-owned profile. The legacy tree is retained
        // so this migration cannot destroy user data or Electron state.
        let migratedLegacyDesktopProfile: Bool
        if context.purpose != .recovery, context.profile == .desktop {
            migratedLegacyDesktopProfile = try DshPluginManager.shared.migrateLegacyDesktopProfileIfNeeded(
                to: context.profileDirectory
            )
        } else {
            migratedLegacyDesktopProfile = false
        }

        let runtimeState = stateSnapshot.runtimeState
        guard context.purpose == .recovery
            || runtimeState.profile == context.profile
            || runtimeState.pending == nil else {
            throw NSError(
                domain: "DshLaunchContext",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Runtime 事务所属 Profile 与启动上下文不一致。"]
            )
        }
        // A rollback restores the baseline Profile (web snapshot) BEFORE the
        // read-only F03 gate: the tree on disk may still carry the
        // candidate's bridge/dependency shape from the interrupted update,
        // and inspecting that polluted tree first would block the rollback on
        // exactly what the restore is about to remove.
        if context.purpose != .recovery,
           runtimeState.phase == .rollingBack,
           let snapshotID = runtimeState.webProfileSnapshotID {
            guard context.purpose == .runtimeRollback,
                  context.transactionID != nil,
                  context.transactionID == runtimeState.transactionID,
                  context.profile == runtimeState.profile else {
                throw NSError(
                    domain: "DshRuntimeUpdate",
                    code: -5,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Runtime 回滚需要恢复 \(runtimeState.profile.rawValue) Profile，但启动上下文目标不一致；为保护 Profile 数据，已暂停启动。"
                    ]
                )
            }
            // Record the cleanup debt before the restore can displace the live
            // Profile, then settle it with the completion proof the restore
            // itself cannot write (it runs off-main and owns no state).
            SettingsViewModel.shared.beginProfileRestoreCleanup(
                profile: context.profile,
                snapshotID: snapshotID,
                displacedPath: DshPluginManager.displacedProfileRestoreURL(
                    profileDirectory: context.profileDirectory,
                    snapshotID: snapshotID
                )
            )
            let restoreOutcome = try await DshPluginManager.shared.restoreWebProfileSnapshot(
                snapshotID,
                profile: context.profile,
                profileDirectory: context.profileDirectory
            ) { progress in
                Task { @MainActor in
                    SettingsViewModel.shared.installProgressPhase = DshMainWindowUIMessage.safe(progress.phase)
                    SettingsViewModel.shared.installProgressDetail = progress.detail.map(DshMainWindowUIMessage.safe)
                }
            }
            SettingsViewModel.shared.finishProfileRestoreCleanup(
                profile: context.profile,
                snapshotID: snapshotID,
                leftover: restoreOutcome.displacedLeftover
            )
            // The Profile is restored either way; a displaced leftover is
            // reported because nothing reclaims an unreferenced displaced tree
            // automatically (R12).
            if let leftover = restoreOutcome.displacedLeftover {
                SettingsViewModel.shared.alertMessage =
                    "web Profile 已恢复，但旧的 displaced 副本删除失败，仍保留在：\(DshMainWindowUIMessage.safe(leftover.path))。确认不需要后可在访达中手动删除。"
            }
        }

        // F03 is deliberately a read-only gate. It runs before any manifest,
        // bridge, or dependency repair write. Only a genuinely empty Profile
        // can proceed to bootstrap; existing Profiles with incomplete,
        // uncertain, unavailable, or erroneous evidence remain blocked.
        if !migratedLegacyDesktopProfile {
            try await inspectDependenciesBeforeMutation(for: context)
        }

        if context.purpose != .recovery,
           [.switching, .verifying].contains(runtimeState.phase),
           runtimeState.pending != nil,
           runtimeState.webProfileSnapshotID == nil {
            guard context.purpose == .runtimeVerification,
                  context.transactionID != nil,
                  context.transactionID == runtimeState.transactionID,
                  context.profile == runtimeState.profile else {
                throw NSError(
                    domain: "DshLaunchContext",
                    code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "Runtime 验证事务与启动上下文不一致。"]
                )
            }
            // Freeze the shared Profile before taking its snapshot. The copy
            // itself runs off-main, but stopping the old service first also
            // prevents it from mutating package metadata during the clone.
            await DshService.shared.stopAndWait()
            let snapshotID = try await DshPluginManager.shared.createWebProfileSnapshot(
                profile: context.profile,
                profileDirectory: context.profileDirectory
            ) { progress in
                Task { @MainActor in
                    SettingsViewModel.shared.installProgressPhase = DshMainWindowUIMessage.safe(progress.phase)
                    SettingsViewModel.shared.installProgressDetail = progress.detail.map(DshMainWindowUIMessage.safe)
                }
            }
            try DshStateManager.shared.updateOrThrow { state in
                guard state.runtimeState.pending?.version == runtimeState.pending?.version,
                      state.runtimeState.transactionID == context.transactionID,
                      [.switching, .verifying].contains(state.runtimeState.phase) else { return }
                state.runtimeState = DshRuntimeTransaction.attachWebProfileSnapshot(
                    state.runtimeState,
                    id: snapshotID,
                    profile: context.profile
                )
            }
        }

        if context.purpose != .recovery {
            // The profile must be complete and the access-control bundle must
            // be mounted before Node starts. An isolated recovery launch skips
            // these writes so an unresolved transaction cannot mutate the
            // original Profile.
            try DshPluginManager.shared.bootstrapWebProfileManifestIfMissing(
                at: context.profileDirectory,
                profile: context.profile
            )
            _ = try await DshPluginManager.shared.ensureDesktopHostPlugin(
                registry: context.runtimeDescriptor.registry,
                profileDirectory: context.profileDirectory,
                profile: context.profile,
                runtimeVersion: context.runtimeDescriptor.version
            )
            _ = try await DshPluginManager.shared.repairProfileDependenciesIfNeeded(
                registry: context.runtimeDescriptor.registry,
                profileDirectory: context.profileDirectory,
                profile: context.profile
            )
        }
        setDiagnosticPhase(.startingService, launchID: context.launchID)
        let session = try await DshService.shared.start(context: context)
        _ = diagnosticStore.bindGeneration(session.access.id, launchID: context.launchID)
        setDiagnosticPhase(.authentication, launchID: context.launchID, generationID: session.access.id)
        guard let rendererCookieStore, let upstreamCookieStore else {
            DshService.shared.stop()
            throw DshRendererCookieStore.CookieError.writeFailed
        }

        do {
            try await upstreamCookieStore.prepareForNewSession(for: session)
            try await rendererCookieStore.install(for: session)
        } catch {
            // A service without its current Renderer credential must never be
            // left reachable after startup, even if Cookie installation fails.
            DshService.shared.stop()
            throw error
        }

        serviceSession = session
        updateBridgeValidationContext(for: session)
        setDiagnosticPhase(.loadingInterface, launchID: context.launchID, generationID: session.access.id)
        webUIReadinessGeneration &+= 1
        pendingWebUINavigation = nil
        let firstNavigationURL = session.endpoint.bootstrapURL ?? session.originURL
        // Install the continuation before calling load. A fast local page can
        // finish its redirect before the next suspension point otherwise.
        let webUIReadyTask = Task { @MainActor in
            try await self.waitForWebUIReady()
        }
        await Task.yield()
        // The bootstrap URL is a one-shot credential exchange. Never satisfy
        // it from WebKit's document cache, especially after the same loopback
        // authority has belonged to a previous Runtime/Profile generation.
        let bootstrapRequest = URLRequest(
            url: firstNavigationURL,
            cachePolicy: .reloadIgnoringLocalCacheData
        )
        guard let navigation = self.webView?.load(bootstrapRequest) else {
            let error = NSError(
                domain: "DshWebUI",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "无法加载 DSH 页面"]
            )
            completeWebUIReadiness(.failure(error))
            webShell?.clearBridgeValidationContext()
            DshService.shared.stop()
            throw error
        }
        pendingWebUINavigation = navigation
        webUINavigationGenerations[ObjectIdentifier(navigation)] = webUIReadinessGeneration
        do {
            try await webUIReadyTask.value
            let upstreamCookies = try await upstreamCookieStore.waitForAuthenticatedCookies(for: session)
            let authenticatedSession = DshServiceSession(
                endpoint: session.endpoint.withoutBootstrap(),
                access: session.access,
                context: session.context
            )
            // Do not retain the bearer-bearing bootstrap URL after WebKit has
            // exchanged it for the HttpOnly upstream cookie.
            serviceSession = authenticatedSession
            setDiagnosticPhase(.connectionValidation, launchID: context.launchID, generationID: session.access.id)
            try await verifyRuntimeHealth(session: authenticatedSession, upstreamCookies: upstreamCookies)
            // The state may change while WebKit is loading. A healthy process
            // is usable only when the complete launch context still matches
            // the durable state; otherwise stop it and let the caller retry
            // with a fresh transaction snapshot.
            guard authenticatedSession.context == context,
                  context.isFresh(in: DshStateManager.shared.current) else {
                webShell?.clearBridgeValidationContext()
                DshService.shared.stop()
                serviceSession = nil
                throw DshLaunchContextError.staleContext
            }
            setDiagnosticPhase(.ready, launchID: context.launchID, generationID: session.access.id)
            hideStartupSurface()
            // The standalone startup card is gone; the main window can now
            // take over. A running restart leaves it already visible, so this
            // is a no-op there.
            revealWindow()
            schedulePostReadyNotificationAuthorization(for: context)
            return authenticatedSession
        } catch {
            webShell?.clearBridgeValidationContext()
            serviceSession = nil
            pendingWebUINavigation = nil
            webUIReadinessGeneration &+= 1
            DshService.shared.stop()
            throw error
        }
    }

    /// A managed restart can begin while the existing WebView is still
    /// reacting to the previous process disappearing. If that
    /// stale navigation wins the race, WebKit can display the old
    /// authentication-required response even though the newly issued
    /// bootstrap URL is valid. Retry that specific failure once so the next
    /// launch gets a fresh Runtime generation, Renderer cookie, upstream
    /// token, and navigation. The caller already owns runtimeOperationGate.
    public func restartDshServiceWithAuthenticationRecoveryDuringOperation(
        context: DshLaunchContext
    ) async throws -> DshServiceSession {
        var recoveryCount = 0
        while true {
            do {
                return try await restartDshServiceDuringOperation(context: context)
            } catch {
                guard isAuthenticationRecoveryFailure(error),
                      recoveryCount < Self.maxAutomaticAuthenticationRecoveries else {
                    throw error
                }
                recoveryCount += 1
                await webShell?.resetWebsiteDataForAuthenticationRecovery()
            }
        }
    }

    /// Offer the notification authorization prompt right after the startup
    /// card is gone and the main window appears (short grace so the prompt
    /// does not race the reveal animation). Gated to clean normal desktop
    /// launches: recovery/verify starts never schedule it, and a newer
    /// launch or a recovery surface appearing first cancels the pending
    /// offer. The startup surfaces are already hidden at this point, so the
    /// macOS 26 safe-area constraint loop is not re-entered.
    private func schedulePostReadyNotificationAuthorization(for context: DshLaunchContext) {
        postReadyAuthorizationTask?.cancel()
        postReadyAuthorizationTask = nil
        guard context.purpose == .normal, context.profile == .desktop else { return }
        let launchID = context.launchID
        postReadyAuthorizationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard let self,
                  !Task.isCancelled,
                  self.launchContext?.launchID == launchID,
                  self.startupRecoveryError == nil,
                  self.recoveryViewModel == nil,
                  DshStateManager.shared.current.appProfile == .desktop else { return }
            NotificationManager.shared.requestAuthorizationIfNeeded()
        }
    }

    private func inspectDependenciesBeforeMutation(
        for context: DshLaunchContext,
        allowDedicatedRecoveryPreparation: Bool = false
    ) async throws {
        let runtimeEntry = DshVersionManager.shared.resolveEntry(for: context.runtimeDescriptor)
        let runtimeRoot = runtimeEntry.map { entry in
            URL(fileURLWithPath: entry)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
        } ?? DshStateManager.versionsDirectory
        let nodeBinary = NodeRuntime.shared.resolveNodeBinary().map(URL.init(fileURLWithPath:))
        let inspector = DshPluginInspector(
            profileDirectory: context.profileDirectory,
            runtime: DshPluginInspectorRuntimeDescriptor(
                root: runtimeRoot,
                nodeBinary: nodeBinary,
                integrityVerified: runtimeEntry != nil
            )
        )
        let result = await inspector.inspectAsync()
        let readiness = DshPluginManager.shared.bootstrapReadiness(at: context.profileDirectory)
        let expectedFreshProfileIssue = { (issue: DshPluginInspectionIssue) in
            readiness == .freshEmpty && issue.code == "profileManifestMissing"
        }
        let inspectionHasErrors = result.issues.contains { issue in
            issue.severity == .error && !expectedFreshProfileIssue(issue)
        }
        let inspectionHasUnknowns = !result.uncertainties.isEmpty
            || result.items.contains { item in
                item.kind == .unknown
                    || item.status == .unavailable
                    || item.status == .uncertain
                    || item.confidence == .unknown
            }
        let startupGate: DshPluginStartupGateDecision
        if allowDedicatedRecoveryPreparation, context.purpose == .recovery {
            // The recovery seed intentionally has no Profile node_modules yet.
            // A manager-authorized first materialization is the only write
            // window that may proceed with that expected, incomplete shape.
            startupGate = .allowProfileMutation
        } else {
            startupGate = DshPluginManagerStartupGate.decision(
                profileReadiness: readiness,
                inspectionIsComplete: result.isComplete || readiness == .freshEmpty,
                inspectionHasErrors: inspectionHasErrors,
                inspectionHasUnknowns: inspectionHasUnknowns
            )
        }
        let evidenceSummary = inspectionSummary(result)
        _ = diagnosticStore.appendLog(
            "F03 dependency inspection: readiness=\(readiness.rawValue) gate=\(startupGate.rawValue) \(evidenceSummary)",
            launchID: context.launchID,
            source: .pluginInspector
        )
        setDiagnosticPhase(
            .dependencyCheck,
            launchID: context.launchID,
            detail: "只读检查完成：扫描 \(result.scannedFileCount) 个文件"
        )

        guard startupGate != .blockProfileMutation else {
            let blockingIssues = result.issues.filter { issue in
                issue.severity == .error && !expectedFreshProfileIssue(issue)
            }
            let uncertainItems = result.items.filter { item in
                item.kind == .unknown
                    || item.status == .unavailable
                    || item.status == .uncertain
                    || item.confidence == .unknown
            }
            let details = blockingIssues.map { issue in
                let location = issue.file.map { "（\($0)" + (issue.line.map { ":\($0)" } ?? "") + "）" } ?? ""
                return "\(issue.code)\(location)：\(issue.detail)"
            } + uncertainItems.map { item in
                "\(item.name)：\(item.status.rawValue)\(item.detail.map { "：\($0)" } ?? "")"
            }
            let detail = details.isEmpty
                ? "检查结果不完整或无法确认 Profile 依赖状态。"
                : details.joined(separator: "；")
            let evidence = blockingIssues.prefix(8).map { issue in
                return DshDiagnosticEvidence(
                    source: .pluginInspector,
                    confidence: .confirmed,
                    summary: "\(issue.code)：\(issue.detail)",
                    pluginName: issue.file,
                    generationID: diagnosticStore.currentContext?.generationID
                )
            }
            let uncertainEvidence = uncertainItems.prefix(max(0, 8 - evidence.count)).map { item in
                let confidence: DshDiagnosticConfidence
                switch item.confidence {
                case .confirmed: confidence = .confirmed
                case .suspected: confidence = .suspected
                case .unknown: confidence = .unknown
                }
                return DshDiagnosticEvidence(
                    source: .pluginInspector,
                    confidence: confidence,
                    summary: "\(item.name)：\(item.status.rawValue)",
                    pluginName: item.name,
                    generationID: diagnosticStore.currentContext?.generationID
                )
            }
            _ = diagnosticStore.record(
                launchID: context.launchID,
                phase: .dependencyCheck,
                code: inspectionHasErrors ? .pluginConfigurationInvalid : .unknown,
                summary: "Profile 依赖检查未达到可安全写入的条件。",
                technicalDetail: detail,
                retryability: .retryable,
                source: .pluginInspector,
                evidence: Array(evidence + uncertainEvidence)
            )
            throw NSError(
                domain: "DshPluginManager",
                code: -24,
                userInfo: [NSLocalizedDescriptionKey: "Profile 依赖检查未通过：\(detail)"]
            )
        }
    }

    private func inspectionSummary(_ result: DshPluginInspectionResult) -> String {
        let itemCounts = Dictionary(grouping: result.items, by: { $0.status.rawValue })
            .map { "\($0.key)=\($0.value.count)" }
            .sorted()
            .joined(separator: ",")
        let issueCodes = result.issues.map(\.code).sorted().joined(separator: ",")
        let uncertaintyCount = result.uncertainties.count
        return "items[\(itemCounts)] issues[\(issueCodes)] uncertainties=\(uncertaintyCount) complete=\(result.isComplete)"
    }

    /// Verify the parts of the runtime contract that are stable in the
    /// currently installed npm release. This deliberately uses the same
    /// protected loopback carrier as WebKit, so a green service handshake
    /// cannot mask a broken Renderer cookie or an accidentally open route.
    ///
    /// The current Runtime packages do not expose a stable read-only RPC such
    /// as workspace.list; that optional capability is therefore not invented
    /// here. When upstream exposes one, it can be added as another
    /// capability-specific probe without weakening these mandatory checks.
    private func verifyRuntimeHealth(
        session: DshServiceSession,
        upstreamCookies: [HTTPCookie]
    ) async throws {
        let rendererRequest = runtimeHealthRequest(
            url: session.originURL,
            method: "GET"
        )
        let rendererResponse = try await runtimeHealthResponse(
            for: rendererRequest,
            label: "Renderer 页面",
            credentials: healthCredentials(
                rendererToken: session.access.rendererToken,
                upstreamCookies: upstreamCookies
            ),
            requireCleanFinalURL: true
        )
        guard (200...299).contains(rendererResponse.statusCode) else {
            throw RuntimeHealthError.unexpectedStatus(
                label: "Renderer 页面",
                expected: "2xx",
                actual: rendererResponse.statusCode
            )
        }
        guard DshRuntimeHealthClient.isHTMLPage(rendererResponse) else {
            throw RuntimeHealthError.invalidPage
        }

        let anonymousRequest = runtimeHealthRequest(url: session.originURL)
        let anonymousResponse = try await runtimeHealthResponse(
            for: anonymousRequest,
            label: "匿名 loopback",
            credentials: .anonymous,
            requireCleanFinalURL: true
        )
        guard anonymousResponse.statusCode == 403 else {
            throw RuntimeHealthError.unexpectedStatus(
                label: "匿名 loopback",
                expected: "403",
                actual: anonymousResponse.statusCode
            )
        }

        // The launch context is immutable. Settings may update the running
        // process after startup, so the boundary probes must use the policy
        // ACKed by this exact live generation. DshService returns nil for a
        // stopped/replaced process or a generation mismatch; fail closed
        // instead of falling back to the frozen startup context.
        guard let liveAccessPolicy = DshService.shared.currentAccessPolicy(for: session.access.id) else {
            throw RuntimeHealthError.liveAccessPolicyUnavailable
        }
        try await verifyBrowserAccessBoundary(
            session: session,
            accessPolicy: liveAccessPolicy
        )
        if liveAccessPolicy.networkExposure == .lan {
            try await verifyLANAccessBoundary(
                session: session,
                accessPolicy: liveAccessPolicy
            )
        }

        // Alpha Runtimes carry the actual application Remote stream over this
        // WebSocket. Run the probe in the page so WebKit's real HttpOnly
        // cookie state, rather than a manually assembled native Cookie header,
        // is tested before a Runtime is accepted as healthy.
        try await verifyWebKitConnection(session: session)
    }

    private func verifyWebKitConnection(session: DshServiceSession) async throws {
        guard session.endpoint.authMode == .browserTokenCookie else { return }
        guard let webView,
              let currentURL = webView.url,
              isCurrentRuntimeWebURL(currentURL) else {
            throw RuntimeHealthError.webKitConnectionFailed("WebKit 当前页面不属于本次 Runtime")
        }

        let result: Any
        do {
            guard let evaluated = try await webView.callAsyncJavaScript(
                DshWebShell.webUIConnectionProbeScript,
                arguments: [:],
                in: nil,
                contentWorld: .page
            ) else {
                throw RuntimeHealthError.webKitConnectionFailed("WebKit 未返回连接探针结果")
            }
            result = evaluated
        } catch {
            throw RuntimeHealthError.webKitConnectionFailed("WebKit 无法执行连接探针")
        }

        guard let state = result as? [String: Any],
              (state["ok"] as? NSNumber)?.boolValue == true else {
            let reason = (result as? [String: Any])?["reason"] as? String ?? "握手未打开"
            throw RuntimeHealthError.webKitConnectionFailed(reason)
        }
    }

    private func verifyBrowserAccessBoundary(
        session: DshServiceSession,
        accessPolicy: DshEffectiveAccessPolicy
    ) async throws {
        let routeURL = session.originURL.appendingPathComponent("__dsh_swift/browser-url")
        var request = runtimeHealthRequest(
            url: routeURL,
            method: "POST"
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let response = try await runtimeHealthResponse(
            for: request,
            label: "Browser URL 路由",
            credentials: healthCredentials(rendererToken: session.access.rendererToken)
        )
        let browserEnabled = accessPolicy.browserAccessEnabled

        guard browserEnabled else {
            guard response.statusCode == 403 else {
                throw RuntimeHealthError.unexpectedStatus(
                    label: "关闭状态的 Browser URL 路由",
                    expected: "403",
                    actual: response.statusCode
                )
            }
            return
        }

        guard response.statusCode == 200 else {
            throw RuntimeHealthError.unexpectedStatus(
                label: "开启状态的 Browser URL 路由",
                expected: "200",
                actual: response.statusCode
            )
        }
        struct BrowserURLResponse: Decodable {
            let url: URL
        }
        guard let payload = try? JSONDecoder().decode(BrowserURLResponse.self, from: response.body),
              payload.url.scheme == "http",
              payload.url.host == "127.0.0.1",
              payload.url.port == session.originURL.port,
              isBrowserHandoffURL(payload.url) else {
            throw RuntimeHealthError.malformedBrowserURL
        }

        guard let handoff = browserHandoffCredentials(from: payload.url) else {
            throw RuntimeHealthError.malformedBrowserURL
        }
        let browserPageResponse = try await runtimeHealthResponse(
            for: runtimeHealthRequest(url: payload.url),
            label: "Browser 鉴权页面",
            credentials: DshRuntimeHealthCredentials(cookieHeader: "dsh_browser_auth=\(handoff.browserToken)"),
            requireCleanFinalURL: true,
            requireCleanRedirectTargets: false,
            maxRedirects: 2
        )
        if (200...299).contains(browserPageResponse.statusCode) {
            guard DshRuntimeHealthClient.isHTMLPage(browserPageResponse) else {
                throw RuntimeHealthError.invalidPage
            }
            return
        }

        guard browserPageResponse.statusCode == 401,
              let expectedCookieName = try? DshUpstreamCookieStore.expectedCookieName(for: session),
              let upstreamCookie = upstreamCookiePair(from: browserPageResponse, expectedName: expectedCookieName) else {
            throw RuntimeHealthError.unexpectedStatus(
                label: "Browser 鉴权页面",
                expected: "2xx",
                actual: browserPageResponse.statusCode
            )
        }
        let authenticatedPage = try await runtimeHealthResponse(
            for: runtimeHealthRequest(url: session.originURL),
            label: "Browser 上游 Cookie 页面",
            credentials: DshRuntimeHealthCredentials(cookieHeader: "dsh_browser_auth=\(handoff.browserToken); \(upstreamCookie)"),
            requireCleanFinalURL: true,
            maxRedirects: 0
        )
        guard (200...299).contains(authenticatedPage.statusCode),
              DshRuntimeHealthClient.isHTMLPage(authenticatedPage) else {
            throw RuntimeHealthError.unexpectedStatus(
                label: "Browser 上游 Cookie 页面",
                expected: "2xx HTML",
                actual: authenticatedPage.statusCode
            )
        }
    }

    private func verifyLANAccessBoundary(
        session: DshServiceSession,
        accessPolicy: DshEffectiveAccessPolicy
    ) async throws {
        guard accessPolicy.networkExposure == .lan,
              accessPolicy.browserAccessEnabled else {
            throw RuntimeHealthError.liveAccessPolicyUnavailable
        }
        let routeURL = session.originURL.appendingPathComponent("__dsh_swift/lan-url")
        var request = runtimeHealthRequest(
            url: routeURL,
            method: "POST"
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let response = try await runtimeHealthResponse(
            for: request,
            label: "LAN URL 路由",
            credentials: healthCredentials(rendererToken: session.access.rendererToken)
        )
        guard response.statusCode == 200 else {
            throw RuntimeHealthError.unexpectedStatus(
                label: "开启状态的 LAN URL 路由",
                expected: "200",
                actual: response.statusCode
            )
        }
        struct LANURLResponse: Decodable {
            let url: URL
        }
        guard let payload = try? JSONDecoder().decode(LANURLResponse.self, from: response.body),
              payload.url.scheme == "http",
              let host = payload.url.host,
              !host.isEmpty,
              host != "127.0.0.1",
              host != "localhost",
              payload.url.port != nil else {
            throw RuntimeHealthError.malformedLANURL
        }

        let lanPageResponse = try await runtimeHealthResponse(
            for: runtimeHealthRequest(url: payload.url),
            label: "LAN 实际入口",
            credentials: .anonymous,
            maxRedirects: 0
        )
        guard (200...299).contains(lanPageResponse.statusCode),
              DshRuntimeHealthClient.isHTMLPage(lanPageResponse) else {
            throw RuntimeHealthError.unexpectedStatus(
                label: "LAN 实际入口",
                expected: "2xx HTML",
                actual: lanPageResponse.statusCode
            )
        }
    }

    private func runtimeHealthRequest(
        url: URL,
        method: String = "GET"
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("application/json, text/html;q=0.9, */*;q=0.1", forHTTPHeaderField: "Accept")
        return request
    }

    private func healthCredentials(
        rendererToken: String? = nil,
        upstreamCookies: [HTTPCookie] = []
    ) -> DshRuntimeHealthCredentials {
        var fields: [String] = []
        if let rendererToken {
            fields.append("dsh_swift_renderer=\(rendererToken)")
        }
        fields.append(contentsOf: upstreamCookies.map { "\($0.name)=\($0.value)" })
        return DshRuntimeHealthCredentials(cookieHeader: fields.isEmpty ? nil : fields.joined(separator: "; "))
    }

    private func runtimeHealthResponse(
        for request: URLRequest,
        label: String,
        credentials: DshRuntimeHealthCredentials,
        requireCleanFinalURL: Bool = false,
        requireCleanRedirectTargets: Bool? = nil,
        maxRedirects: Int = 3
    ) async throws -> DshRuntimeHealthResponse {
        return try await runtimeHealthClient.perform(
            request: request,
            credentials: credentials,
            label: label,
            requireCleanFinalURL: requireCleanFinalURL,
            requireCleanRedirectTargets: requireCleanRedirectTargets,
            maxRedirects: maxRedirects
        )
    }

    private func isBrowserHandoffURL(_ url: URL) -> Bool {
        guard url.path == "/__dsh_swift/browser-handoff" else { return false }
        let allowed = Set(["dsh-auth", "dsh-browser-ticket"])
        let names = Set(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name) ?? [])
        return names == allowed
    }

    private func browserHandoffCredentials(from url: URL) -> (browserToken: String, ticket: String)? {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        let browserValues = items.filter { $0.name == "dsh-auth" }.compactMap(\.value)
        let ticketValues = items.filter { $0.name == "dsh-browser-ticket" }.compactMap(\.value)
        guard browserValues.count == 1, ticketValues.count == 1,
              !browserValues[0].isEmpty, !ticketValues[0].isEmpty else { return nil }
        return (browserValues[0], ticketValues[0])
    }

    private func upstreamCookiePair(from response: DshRuntimeHealthResponse, expectedName: String) -> String? {
        let pairs = response.setCookieHeaders.compactMap { header -> String? in
            let pair = header.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? ""
            guard let separator = pair.firstIndex(of: "="),
                  String(pair[..<separator]) == expectedName,
                  pair[separator...].count > 1 else { return nil }
            return pair
        }
        return pairs.count == 1 ? pairs[0] : nil
    }

    public enum BrowserURLError: Error, LocalizedError {
        case serviceUnavailable
        case accessDisabled
        case requestFailed(Int)
        case invalidResponse
        case openFailed

        public var errorDescription: String? {
            switch self {
            case .serviceUnavailable:
                return "DSH 服务尚未就绪，暂时无法生成浏览器访问地址。"
            case .accessDisabled:
                return "请先开启浏览器访问。"
            case .requestFailed(let status):
                return "生成浏览器访问地址失败（HTTP \(status)）。"
            case .invalidResponse:
                return "DSH 返回的浏览器访问地址无效。"
            case .openFailed:
                return "无法打开默认浏览器。"
            }
        }
    }

    /// Ask the Host-side bridge for a short-lived authenticated URL. The
    /// Renderer cookie is attached only to this in-memory request and the URL
    /// is never persisted or printed by the native app.
    public func fetchAuthenticatedBrowserURL() async throws -> URL {
        guard let session = serviceSession else {
            throw BrowserURLError.serviceUnavailable
        }
        // The launch context is immutable by design. Settings can change the
        // live policy after startup, so authorization must use the policy
        // acknowledged by this exact service generation instead of the stale
        // startup snapshot.
        guard let livePolicy = DshService.shared.currentAccessPolicy(for: session.access.id) else {
            throw BrowserURLError.serviceUnavailable
        }
        guard livePolicy.browserAccessEnabled else {
            throw BrowserURLError.accessDisabled
        }

        var request = URLRequest(url: session.originURL.appendingPathComponent("__dsh_swift/browser-url"))
        request.httpMethod = "POST"
        request.setValue("dsh_swift_renderer=\(session.access.rendererToken)", forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")

        let response: DshRuntimeHealthResponse
        do {
            response = try await runtimeHealthClient.perform(
                request: request,
                credentials: healthCredentials(rendererToken: session.access.rendererToken),
                label: "Browser URL 签发",
                maxRedirects: 0
            )
        } catch {
            throw BrowserURLError.invalidResponse
        }
        guard response.statusCode == 200 else {
            throw BrowserURLError.requestFailed(response.statusCode)
        }

        struct BrowserURLResponse: Decodable {
            let url: URL
        }
        guard let payload = try? JSONDecoder().decode(BrowserURLResponse.self, from: response.body),
              payload.url.scheme == "http",
              payload.url.host == "127.0.0.1",
              payload.url.port == session.originURL.port,
              isBrowserHandoffURL(payload.url),
              browserHandoffCredentials(from: payload.url) != nil else {
            throw BrowserURLError.invalidResponse
        }
        return payload.url
    }

    public enum LANURLError: Error, LocalizedError {
        case serviceUnavailable
        case accessDisabled
        case networkAccessDisabled
        case requestFailed(Int)
        case invalidResponse

        public var errorDescription: String? {
            switch self {
            case .serviceUnavailable:
                return "DSH 服务尚未就绪，暂时无法生成局域网访问地址。"
            case .accessDisabled:
                return "请先开启浏览器访问。"
            case .networkAccessDisabled:
                return "请先开启局域网访问。"
            case .requestFailed(let status):
                return "生成局域网访问地址失败（HTTP \(status)）。"
            case .invalidResponse:
                return "DSH 返回的局域网访问地址无效。"
            }
        }
    }

    /// Ask the Host for a short-lived LAN URL. The URL remains in memory on
    /// the native side; the first HTTP navigation exchanges its query token
    /// for a session cookie at the LAN ingress.
    public func fetchLANURL() async throws -> URL {
        guard let session = serviceSession else { throw LANURLError.serviceUnavailable }
        guard let policy = DshService.shared.currentAccessPolicy(for: session.access.id) else {
            throw LANURLError.serviceUnavailable
        }
        guard policy.browserAccessEnabled else { throw LANURLError.accessDisabled }
        guard policy.networkExposure == .lan else { throw LANURLError.networkAccessDisabled }

        var request = URLRequest(url: session.originURL.appendingPathComponent("__dsh_swift/lan-url"))
        request.httpMethod = "POST"
        request.setValue("dsh_swift_renderer=\(session.access.rendererToken)", forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")

        let response: DshRuntimeHealthResponse
        do {
            response = try await runtimeHealthClient.perform(
                request: request,
                credentials: healthCredentials(rendererToken: session.access.rendererToken),
                label: "LAN URL 签发",
                maxRedirects: 0
            )
        } catch {
            throw LANURLError.invalidResponse
        }
        guard response.statusCode == 200 else {
            throw LANURLError.requestFailed(response.statusCode)
        }

        struct LANURLResponse: Decodable {
            let url: URL
        }
        guard let payload = try? JSONDecoder().decode(LANURLResponse.self, from: response.body),
              payload.url.scheme == "http",
              let host = payload.url.host,
              !host.isEmpty,
              host != "127.0.0.1",
              host != "localhost",
              payload.url.port != nil else {
            throw LANURLError.invalidResponse
        }
        return payload.url
    }

    /// Reveal the native window only after DSH has replaced its plugin boot
    /// screen with real UI. The bridge activation callback is intentionally
    /// not used as the sole signal: Cordis can activate the desktop-host
    /// plugin before the page has finished rendering.
    private func waitForWebUIReady(timeout: TimeInterval = 30) async throws {
        try await withCheckedThrowingContinuation { continuation in
            webUIReadyContinuation = continuation
            webUIReadyTimeoutTask?.cancel()
            webUIReadyTimeoutTask = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                } catch {
                    return
                }
                guard let self, self.webUIReadyContinuation != nil else { return }
                self.webUIReadinessGeneration &+= 1
                self.completeWebUIReadiness(.failure(NSError(
                    domain: "DshWebUI",
                    code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "DSH 页面加载超时，请重启 DSH 服务后重试。"]
                )))
            }
        }
    }

    private func completeWebUIReadiness(_ result: Result<Void, Error>) {
        let continuation = webUIReadyContinuation
        webUIReadyContinuation = nil
        webUIReadyTimeoutTask?.cancel()
        webUIReadyTimeoutTask = nil
        continuation?.resume(with: result)
    }

    private func beginDiagnosticLaunch(for context: DshLaunchContext) {
        if diagnosticStore.currentContext?.launchID != context.launchID {
            diagnosticStore.beginLaunch(DshDiagnosticLaunchContext(
                launchID: context.launchID,
                runtimeVersion: context.runtimeDescriptor.version,
                profile: context.profileName,
                startedAt: Date()
            ))
        }
        setDiagnosticPhase(.preparing, launchID: context.launchID)
    }

    private func setDiagnosticPhase(
        _ phase: DshLaunchPhase,
        launchID: UUID,
        generationID: UUID? = nil,
        detail: String? = nil
    ) {
        _ = diagnosticStore.setPhase(
            phase,
            launchID: launchID,
            generationID: generationID
        )
        guard launchContext?.launchID == launchID else { return }
        startupStatusModel.phase = phase
        startupStatusModel.detail = detail.map(DshMainWindowUIMessage.safe)
    }

    private func showStartupSurface() {
        DshStartupWindowController.shared.show(status: startupStatusModel)
        startupStatusModel.phase = .preparing
    }

    private func hideStartupSurface() {
        DshStartupWindowController.shared.hide()
    }

    private func recordStartupFailure(_ error: Error, context: DshLaunchContext) {
        guard launchContext?.launchID == context.launchID else { return }
        let classification = diagnosticClassification(for: error)
        let safeDetail = DshMainWindowUIMessage.safe(error)
        let generationID = diagnosticStore.currentContext?.generationID
        _ = diagnosticStore.appendLog(
            safeDetail,
            launchID: context.launchID,
            generationID: generationID,
            source: classification.source
        )
        _ = diagnosticStore.record(
            launchID: context.launchID,
            generationID: generationID,
            phase: diagnosticStore.currentPhase ?? .preparing,
            code: classification.code,
            summary: classification.summary,
            technicalDetail: safeDetail,
            retryability: classification.retryability,
            source: classification.source,
            evidence: interruptedTransactionEvidence(for: error)
        )
    }

    /// Attach transaction evidence when a startup failure is caused by an
    /// interrupted plugin operation. The resolver stays purely attributive:
    /// confidence never reaches confirmed, so no removal plan can be
    /// enabled by this evidence alone. Without it the recovery panel and
    /// the resolver report "unknown" for a transaction the app fully knows.
    private func interruptedTransactionEvidence(for error: Error) -> [DshDiagnosticEvidence] {
        guard let operationError = error as? DshPluginOperationError,
              case .operationInterruptedDuringMutation = operationError,
              let operation = DshPluginOperationCoordinator.shared.pendingOperation,
              operation.phase == .recoveryRequired else {
            return []
        }
        let target = operation.targetPackage ?? operation.targetPackages.first
        let actionName: String
        switch operation.action {
        case .install:
            actionName = "安装"
        case .update:
            actionName = "更新"
        case .updateAll:
            actionName = "批量更新"
        case .remove:
            actionName = "卸载"
        }
        let targetText = target.map { "「\($0)」" } ?? "插件"
        return [DshDiagnosticEvidence(
            source: .native,
            confidence: .suspected,
            summary: "插件事务\(actionName)\(targetText)在包变更阶段中断，包变更效果无法证明；该包与失败的因果关系尚未确定",
            pluginName: target
        )]
    }

    private func diagnosticClassification(for error: Error) -> (
        code: DshDiagnosticCode,
        summary: String,
        retryability: DshDiagnosticRetryability,
        source: DshDiagnosticSource
    ) {
        if error is DshStatePersistenceError {
            return (.dependencyMissing, "DSH 主状态不可读或损坏，普通启动已停止。", .notRetryable, .native)
        }
        if let error = error as? DshProcessIOError {
            switch error {
            case .timedOut:
                return (.startupTimeout, "等待 DSH 服务就绪超时。", .retryable, .processOutput)
            case .processExited:
                return (.processExited, "DSH 服务在完成启动握手前退出。", .retryable, .processOutput)
            case .generationMismatch:
                return (.generationMismatch, "DSH 服务报告了过期的启动代际。", .notRetryable, .controlProtocol)
            case .policyMismatch:
                return (.policyMismatch, "DSH 服务确认的访问策略与本次启动不一致。", .retryable, .controlProtocol)
            case .endpointConflict:
                return (.endpointConflict, "DSH 服务报告了相互冲突的 Web 地址。", .retryable, .processOutput)
            case .invalidEndpoint:
                return (.invalidEndpoint, "DSH 服务报告了无效的 Web 地址。", .notRetryable, .processOutput)
            }
        }
        if let error = error as? DshService.ServiceError {
            switch error {
            case .dshEntryNotFound:
                return (.runtimeEntryMissing, "找不到已选 Runtime 的入口。", .notRetryable, .native)
            case .nodeNotFound:
                return (.nodeMissing, "找不到 Node.js 运行时。", .notRetryable, .native)
            case .runtimeBootstrapNotFound:
                return (.bootstrapMissing, "找不到 Runtime 启动器。", .notRetryable, .native)
            case .portInUse:
                return (.portConflict, "DSH 服务端口已被占用。", .retryable, .native)
            case .serviceNotRunning:
                return (.connectionFailed, "DSH 服务当前不可用。", .retryable, .native)
            case .startupFailed:
                return (.processExited, "DSH 服务启动失败。", .retryable, .processOutput)
            }
        }
        if let error = error as? RuntimeHealthError {
            switch error {
            case .authenticationRequired:
                return (.authenticationFailed, "DSH 上游认证失败，需要重新建立认证会话。", .retryable, .healthCheck)
            case .webKitConnectionFailed:
                return (.connectionFailed, "WebKit 与 DSH 的连接验证失败。", .retryable, .webKit)
            case .invalidPage:
                return (.pageLoadFailed, "Renderer 返回的页面内容无效。", .retryable, .healthCheck)
            case .malformedBrowserURL, .malformedLANURL:
                return (.invalidEndpoint, "访问边界返回了无效地址。", .notRetryable, .healthCheck)
            case .liveAccessPolicyUnavailable:
                return (.generationMismatch, "DSH 服务访问策略未被当前启动代际确认。", .retryable, .controlProtocol)
            case .nonHTTPResponse, .unexpectedStatus:
                return (.connectionFailed, "DSH 健康检查未通过。", .retryable, .healthCheck)
            }
        }
        if let error = error as? DshLaunchContextError {
            switch error {
            case .staleContext:
                return (.generationMismatch, "启动目标已变化，本次启动已停止。", .retryable, .native)
            case .invalidProfileName, .profileDirectoryMismatch, .invalidRecoveryContext, .invalidPort:
                return (.dependencyMissing, "启动上下文无效。", .notRetryable, .native)
            }
        }
        if let error = error as? DshPluginOperationError {
            switch error {
            case .runtimeOrProfileRecoveryPending:
                return (.dependencyMissing, "Runtime 或 Profile 恢复事务尚未完成，插件事务已暂停。", .retryable, .native)
            case .externalModification:
                return (.pluginConfigurationInvalid, "检测到插件 Profile 外部修改，事务已暂停以保护现有数据。", .notRetryable, .pluginInspector)
            case .operationInterruptedDuringMutation:
                return (.pluginConfigurationInvalid, "插件事务在包变更阶段中断，已保留现场；普通启动已停止，请按恢复页指引处理。", .retryable, .native)
            case .recoveryRequired, .persistenceConflict:
                return (.pluginConfigurationInvalid, "插件事务恢复未完成，已停止普通启动。", .retryable, .native)
            case .snapshotCapacityInsufficient:
                return (.pluginConfigurationInvalid, "插件事务快照空间不足，已停止普通启动。", .retryable, .native)
            case .desktopProfileRequired, .unsafeProfileDirectory, .staleProfileChanged,
                 .operationAlreadyPending, .invalidTransition:
                return (.pluginConfigurationInvalid, "插件事务目标或阶段无效，已停止普通启动。", .notRetryable, .native)
            }
        }
        let nsError = error as NSError
        if nsError.domain == "DshWebUI" {
            if nsError.code == -401 {
                return (.authenticationFailed, "DSH 页面认证失败。", .retryable, .webKit)
            }
            if nsError.code == -2 {
                return (.startupTimeout, "DSH 页面加载超时。", .retryable, .webKit)
            }
            return (.pageLoadFailed, "DSH 页面加载失败。", .retryable, .webKit)
        }
        if nsError.domain == "DshPluginManager" {
            switch nsError.code {
            case -1, -19:
                return (.nodeMissing, "插件操作需要应用自带的 Node.js 和 pnpm。", .notRetryable, .native)
            case -2, -3, -4, -6, -13, -14, -20, -21:
                return (.processExited, "插件操作中的 pnpm 进程未成功完成。", .retryable, .processOutput)
            case -7:
                return (.pluginPackageMissing, "npm Registry 中找不到请求的插件包。", .notRetryable, .pluginInspector)
            case -9:
                return (.connectionFailed, "无法从 npm Registry 检查插件更新。", .retryable, .pluginInspector)
            case -10, -11, -17, -23:
                return (.pluginConfigurationInvalid, "DSH Profile 的插件配置格式无效。", .retryable, .pluginInspector)
            case -12, -16:
                return (.bootstrapMissing, "应用自带的桌面桥接组件缺失或不完整。", .notRetryable, .native)
            case -15, -22:
                return (.pluginConfigurationInvalid, "桌面桥接插件未能正确物化到 DSH Profile。", .retryable, .pluginInspector)
            case -18:
                let detail = nsError.localizedDescription
                if detail.contains("无法确定当前 DSH 版本") {
                    return (.runtimeEntryMissing, "无法确定当前 DSH Runtime，未启动桌面桥接。", .notRetryable, .native)
                }
                return (.pluginConfigurationInvalid, "web Profile 的桌面桥接清理失败。", .retryable, .pluginInspector)
            case -5, -8:
                return (.pluginConfigurationInvalid, "该插件是 DSH 内部依赖，不能由用户直接变更。", .notRetryable, .pluginInspector)
            case -30, -31, -32, -33, -34, -35, -36:
                return (.dependencyMissing, "web Profile 更新快照不可用，暂未继续启动。", .retryable, .native)
            default:
                // An unrecognized manager error is not evidence that a
                // plugin is corrupt. Keep it unknown until its operation
                // supplies an explicit stable code.
                return (.unknown, "DSH 插件操作失败，原因尚未分类。", .unknown, .unknown)
            }
        }
        return (.unknown, "DSH 启动失败。", .unknown, .native)
    }

    private func showRecoverySurface(for context: DshLaunchContext) {
        guard launchContext?.launchID == context.launchID else { return }

        // Recovery owns a separate native window. Hide the WebView window
        // before changing the recovery model so an unready/white WebView can
        // never flash through while AppKit installs the new SwiftUI root.
        window?.orderOut(nil)
        let matchingPluginInspection: DshPluginInspectionResult?
        if context.profile == .desktop,
           let inspection = SettingsViewModel.shared.pluginInspectionResult,
           inspection.profileDirectory == context.profileDirectory.path {
            matchingPluginInspection = inspection
        } else {
            matchingPluginInspection = nil
        }
        hideStartupSurface()
        recoveryViewModel = nil
        let viewModel = DshRecoveryViewModel(
            launchID: context.launchID,
            snapshot: diagnosticStore.snapshot(for: context.launchID),
            actions: DshRecoveryActions(
                retry: { [weak self] request in
                    self?.handleRecoveryRetry(request, context: context)
                },
                openSettings: { [weak self] request in
                    self?.handleRecoveryOpenSettings(request, context: context)
                },
                startSafeMode: { [weak self] request in
                    self?.handleRecoverySafeMode(request, context: context)
                },
                removePluginAndRetry: { [weak self] request in
                    self?.handleRecoveryPluginRemoval(request, context: context)
                },
                adoptInterruptedTransaction: { [weak self] request in
                    self?.adoptInterruptedPluginOperation(request, context: context)
                },
                rollbackRuntime: { [weak self] request in
                    self?.handleRecoveryRollbackRuntime(request, context: context)
                },
                copyDiagnosticSummary: { [weak self] summary in
                    self?.copyDiagnosticSummary(summary)
                },
                saveDiagnosticExport: { [weak self] plan in
                    self?.saveDiagnosticExport(plan)
                }
            ),
            diagnosticMetadata: diagnosticExportMetadata(for: context),
            // Reuse only a read-only inspector snapshot that names this exact
            // desktop Profile; stale/web results are discarded above.
            pluginInspection: matchingPluginInspection,
            originalProfilePath: context.profileDirectory.path,
            readAdoptableInterruptedTransaction: {
                DshPluginOperationCoordinator.shared.pendingOperation.flatMap(
                    DshPluginOperationCoordinator.adoptableInterruptedTransaction(from:)
                )
            }
        )
        let safeMode = safeModeAvailability(for: context)
        viewModel.setSafeModeAvailability(safeMode.available, reason: safeMode.reason)
        let rollback = runtimeRollbackAvailability(for: context)
        viewModel.setRuntimeRollbackAvailability(rollback.available, reason: rollback.reason)
        recoveryViewModel = viewModel
        DshRecoveryWindowController.shared.show(viewModel: viewModel)
    }

    /// Whether "恢复到上一个 Runtime" is available: only for a desktop
    /// confirmed Runtime transaction whose previous version is still
    /// installed and with no Profile switch in flight. The recovery surface
    /// recomputes this for every presentation, so a state change between
    /// presentations refreshes the button.
    private func runtimeRollbackAvailability(for context: DshLaunchContext) -> (available: Bool, reason: String) {
        let state = DshStateManager.shared.current
        guard state.appProfile == .desktop,
              context.profile == .desktop,
              state.pendingProfileSwitch == nil,
              state.runtimeState.profile == .desktop,
              state.runtimeState.phase == .confirmed,
              state.runtimeState.transactionID != nil,
              let previous = state.runtimeState.previous else {
            return (false, "仅当新 Runtime 已确认且上一个版本仍安装时才可回退。")
        }
        guard DshVersionManager.shared.isVersionInstalled(previous.version) else {
            return (false, "上一个 Runtime \(previous.version) 已不在本地，无法回退。")
        }
        return (true, "将放弃当前 Runtime，恢复到 \(previous.version) 并重新启动服务。")
    }

    /// User-initiated rollback from the recovery surface after a confirmed
    /// Runtime fails its ordinary second start. The rollingBack transition is
    /// persisted first (durable decision), then the ordinary restart runs the
    /// standard rollback path — restoring the retained web Profile snapshot
    /// and settling the transaction on the first healthy start.
    private func handleRecoveryRollbackRuntime(
        _ request: DshRecoveryActionRequest,
        context: DshLaunchContext
    ) {
        let state = DshStateManager.shared.current
        let availability = runtimeRollbackAvailability(for: context)
        guard request.launchID == context.launchID,
              availability.available else {
            recoveryViewModel?.finishAction(request, message: "暂不能回退到上一个 Runtime：\(availability.reason)")
            return
        }
        // Availability is computed from the live state; the presented context
        // must also belong to the same launch. Report that separately instead
        // of reusing the "available" reason (which would contradict the
        // refusal).
        guard state.runtimeState.transactionID == context.transactionID else {
            recoveryViewModel?.finishAction(
                request,
                message: "暂不能回退到上一个 Runtime：当前界面属于另一次启动，请重试或重启应用。"
            )
            return
        }
        guard let previous = state.runtimeState.previous else {
            recoveryViewModel?.finishAction(request, message: "暂不能回退到上一个 Runtime：\(availability.reason)")
            return
        }
        do {
            try DshStateManager.shared.updateOrThrow { state in
                guard state.runtimeState.phase == .confirmed,
                      state.runtimeState.transactionID == context.transactionID else { return }
                state.selectedVersion = previous.version
                state.runtimeState = DshRuntimeTransaction.beginRollback(state.runtimeState)
            }
        } catch {
            recoveryViewModel?.finishAction(request, message: "回退状态写入失败：\(DshMainWindowUIMessage.safe(error))。请重启应用后重试。")
            return
        }
        recoveryViewModel?.finishAction(request, message: "已准备回退到 \(previous.version)，正在重新启动服务…")
        startAndLoadDsh()
    }

    /// Build export metadata from the captured recovery Profile. No chat,
    /// cookies, environment variables, or registry responses are included.
    private func diagnosticExportMetadata(for context: DshLaunchContext) -> DshDiagnosticExportMetadata {
        let info = Bundle.main.infoDictionary
        let plugins = DshPluginManager.shared.listPlugins(at: context.profileDirectory).map {
            DshDiagnosticExportPlugin(name: $0.name, version: $0.version)
        }
        return DshDiagnosticExportMetadata(
            appVersion: info?["CFBundleShortVersionString"] as? String,
            buildNumber: info?["CFBundleVersion"] as? String,
            runtimeVersion: context.runtimeDescriptor.version,
            systemArchitecture: DshDiagnosticExportMetadata.defaultArchitecture,
            operatingSystem: nil,
            plugins: plugins
        )
    }

    private func copyDiagnosticSummary(_ summary: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(summary, forType: .string)
    }

    /// Present an explicit native save panel. A failed write only reports the
    /// error; the RecoveryViewModel keeps its snapshot and preview in memory.
    private func saveDiagnosticExport(_ plan: DshDiagnosticExportPlan) {
        let panel = NSSavePanel()
        panel.title = "保存 DSH 诊断"
        panel.nameFieldStringValue = plan.suggestedFilename
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = false
        panel.begin { [weak self] response in
            guard response == .OK, let destination = panel.url else { return }
            do {
                try plan.writeAtomically(to: destination)
            } catch {
                DispatchQueue.main.async {
                    self?.showDiagnosticExportError(error)
                }
            }
        }
    }

    private func showDiagnosticExportError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "保存诊断失败"
        alert.informativeText = DshMainWindowUIMessage.safe(error)
        alert.addButton(withTitle: "确定")
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    private func safeModeAvailability(for context: DshLaunchContext) -> (available: Bool, reason: String) {
        if let safeModeUnavailableReason {
            return (false, DshMainWindowUIMessage.safe(safeModeUnavailableReason))
        }
        guard !isSafeModeActive else {
            return (false, "安全模式已经在运行。")
        }
        guard context.purpose != .recovery else {
            return (false, "当前已经处于隔离恢复启动。")
        }
        let pluginCoordinator = DshPluginOperationCoordinator.shared
        guard pluginCoordinator.pendingOperation == nil,
              !pluginCoordinator.hasPersistedOperationRecord else {
            return (false, "插件事务尚未完成恢复，暂不能进入安全模式。")
        }
        if let persistedRecoveryRecord,
           [.returned, .cleanupPending, .cleaned].contains(persistedRecoveryRecord.phase) {
            return (false, "上次安全模式仍有待清理记录，请先重试清理。")
        }
        guard DshVersionManager.shared.resolveEntry(for: context.runtimeDescriptor) != nil else {
            return (false, "当前 Runtime 未安装或无法通过完整性检查。")
        }
        guard NodeRuntime.shared.resolveNodeBinary() != nil,
              NodeRuntime.shared.resolvePnpmBinary() != nil else {
            return (false, "安全模式需要应用自带的 Node.js 和 pnpm。")
        }
        guard NodeRuntime.shared.resolveDesktopHostBundlePath() != nil else {
            return (false, "找不到受保护的桌面桥接组件。")
        }
        guard context.runtimeDescriptor.version == "0.1.2-alpha.5" else {
            return (false, "安全模式只支持已验证的 Runtime 版本，当前所选版本尚未验证；可在设置中切换 Runtime 后重试。")
        }
        return (true, "")
    }

    private func hideRecoverySurface() {
        DshRecoveryWindowController.shared.hide()
        recoveryViewModel = nil
    }

    private func showSafeModeIndicator(originalProfile: DshAppProfile) {
        guard let vibrancyView else { return }
        safeModeBanner?.removeFromSuperview()
        let banner = NativeSafeModeBanner(frame: .zero)
        banner.translatesAutoresizingMaskIntoConstraints = false
        banner.update(originalProfile: originalProfile)
        banner.onReturn = { [weak self] in
            self?.returnFromSafeMode()
        }
        vibrancyView.addSubview(banner, positioned: .above, relativeTo: webView)
        NSLayoutConstraint.activate([
            banner.leadingAnchor.constraint(equalTo: vibrancyView.leadingAnchor, constant: 56),
            banner.topAnchor.constraint(equalTo: vibrancyView.topAnchor, constant: 10),
            banner.trailingAnchor.constraint(lessThanOrEqualTo: vibrancyView.trailingAnchor, constant: -16)
        ])
        safeModeBanner = banner
    }

    private func hideSafeModeIndicator() {
        safeModeBanner?.removeFromSuperview()
        safeModeBanner = nil
    }

    private func returnFromSafeMode() {
        guard isSafeModeActive,
              let manager = recoveryProfileManager,
              let launch = recoveryLaunch else { return }
        let fallbackContext = safeModeNormalContext
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let normalContext = try await self.withRuntimeOperation { () throws -> DshLaunchContext in
                    // Returning from safe mode invalidates the old bridge
                    // before stopping its service, and again after clearing
                    // the session, so no stale generation can be accepted.
                    self.webShell?.clearBridgeValidationContext()
                    await DshService.shared.stopAndWait()
                    self.serviceSession = nil
                    self.webShell?.clearBridgeValidationContext()
                    guard let context = self.makeLaunchContext() else {
                        throw DshLaunchContextError.invalidProfileName
                    }
                    _ = try await self.restartDshServiceDuringOperation(context: context)
                    switch context.purpose {
                    case .normal:
                        try await SettingsViewModel.shared.recordHealthyRuntimeStart(for: context)
                    case .runtimeRollback:
                        try await SettingsViewModel.shared.finalizeRecoveredRuntimeAfterSuccessfulStart(for: context)
                    case .profileSwitch, .profileRollback:
                        try await SettingsViewModel.shared.retryPendingProfileSwitchCleanup(for: context)
                    case .runtimeVerification, .recovery:
                        break
                    }
                    return context
                }
                self.isSafeModeActive = false
                try manager.markReturned(recoveryID: launch.state.recoveryID)
                try manager.cleanup(recoveryID: launch.state.recoveryID)
                self.recoveryProfileManager = nil
                self.recoveryLaunch = nil
                self.safeModeNormalContext = nil
                self.hideSafeModeIndicator()
                self.launchContext = normalContext
            } catch {
                if error is DshStatePersistenceError {
                    await DshService.shared.stopAndWait()
                    self.serviceSession = nil
                    self.webShell?.clearBridgeValidationContext()
                    self.blockStartupForStateFailure(error.localizedDescription)
                    return
                }
                self.isSafeModeActive = true
                self.launchContext = fallbackContext ?? self.launchContext
                self.recordStartupFailure(error, context: self.launchContext ?? (fallbackContext ?? launch.context))
                if let context = self.launchContext {
                    self.showRecoverySurface(for: context)
                }
            }
        }
    }

    private func handleRecoveryRetry(_ request: DshRecoveryActionRequest, context: DshLaunchContext) {
        guard request.launchID == context.launchID,
              recoveryViewModel?.launchID == context.launchID else { return }
        if startupStatePersistenceBlocked {
            _ = recoveryViewModel?.finishAction(
                request,
                message: "主状态文件不可读或已损坏，未执行重试或修改。请修复后重启 DSH，并可先导出诊断。"
            )
            showStatePersistenceRecoverySurface()
            return
        }
        if startupRecoveryRecordCorrupted {
            retryCorruptedRecoveryRecord(request, context: context)
            return
        }
        if startupRecoveryIsPluginOperation {
            Task { @MainActor [weak self] in
                await self?.retryPendingPluginOperation(request, context: context)
            }
            return
        }
        if let persistedRecoveryRecord,
           [.returned, .cleanupPending, .cleaned].contains(persistedRecoveryRecord.phase) {
            Task { @MainActor [weak self] in
                await self?.retryPersistedRecoveryCleanup(request, context: context)
            }
            return
        }
        if persistedRecoveryRecord != nil {
            Task { @MainActor [weak self] in
                await self?.startSafeMode(from: request, failedContext: context)
            }
            return
        }
        _ = recoveryViewModel?.finishAction(request)
        hideRecoverySurface()
        showStartupSurface()
        safeModeUnavailableReason = nil
        // startAndLoadDsh creates a fresh launch ID at the serialized boundary.
        startAndLoadDsh()
    }

    /// Re-read a previously rejected record after the user has repaired it
    /// outside the app. This path performs no write and never treats a
    /// missing record as permission to launch the personal Profile.
    private func retryCorruptedRecoveryRecord(
        _ request: DshRecoveryActionRequest,
        context: DshLaunchContext
    ) {
        let manager = DshRecoveryProfileManager(
            applicationSupportDirectory: DshStateManager.appSupportDirectory
        )
        switch manager.readState() {
        case .loaded:
            startupRecoveryRecordCorrupted = false
            _ = recoveryViewModel?.finishAction(request, message: "恢复记录已重新读取，正在显示可验证的恢复步骤。")
            _ = presentPersistedRecoveryIfNeeded()
        case .corrupted(let detail):
            _ = recoveryViewModel?.finishAction(
                request,
                message: "恢复记录仍然损坏，已停止普通启动：\(DshMainWindowUIMessage.safe(detail))"
            )
            showRecoverySurface(for: context)
        case .absent:
            _ = recoveryViewModel?.finishAction(
                request,
                message: "恢复记录无法验证，已停止普通启动；请保留诊断并重新启动 DSH。"
            )
            showRecoverySurface(for: context)
        }
    }

    /// Retry the startup-side P01 handoff from the recovery surface. The
    /// Runtime/Profile gate is acquired exactly once here; the nested health
    /// callbacks use restartDshServiceDuringOperation directly.
    private func retryPendingPluginOperation(
        _ request: DshRecoveryActionRequest,
        context: DshLaunchContext
    ) async {
        guard request.launchID == context.launchID,
              recoveryViewModel?.launchID == context.launchID else { return }
        do {
            try await withRuntimeOperation {
                let context = try self.makeOrdinaryDesktopStartupContext()
                try await DshService.shared.prepareForProfileMutation(context: context)
                _ = try await self.recoverPendingPluginOperationDuringStartup()
            }
            startupRecoveryError = nil
            startupRecoveryIsPluginOperation = false
            _ = recoveryViewModel?.finishAction(request)
            hideRecoverySurface()
            showStartupSurface()
            startAndLoadDsh()
        } catch {
            _ = recoveryViewModel?.finishAction(
                request,
                message: "插件事务仍未恢复：\(DshMainWindowUIMessage.safe(error))"
            )
            if error is DshStatePersistenceError {
                await DshService.shared.stopAndWait()
                serviceSession = nil
                webShell?.clearBridgeValidationContext()
                blockStartupForStateFailure(error.localizedDescription)
            } else {
                blockStartupForRecovery(error)
            }
            if let newContext = launchContext {
                showRecoverySurface(for: newContext)
            }
        }
    }

    /// Run the user-consented verify-and-continue for an interrupted
    /// plugin transaction. A healthy current tree commits and launches;
    /// an unhealthy tree is restored from the retained snapshot by the
    /// coordinator. Either way the app never keeps an unverified tree.
    private func adoptInterruptedPluginOperation(
        _ request: DshRecoveryAdoptRequest,
        context: DshLaunchContext
    ) {
        guard request.launchID == context.launchID,
              recoveryViewModel?.launchID == context.launchID else { return }
        guard let viewModel = recoveryViewModel,
              viewModel.adoptInterruptedTransactionRequest == request else {
            _ = recoveryViewModel?.finishAdoptInterruptedTransaction(request)
            return
        }
        Task { @MainActor [weak self] in
            await self?.runAdoptInterruptedPluginOperation(request, context: context)
        }
    }

    private func runAdoptInterruptedPluginOperation(
        _ request: DshRecoveryAdoptRequest,
        context: DshLaunchContext
    ) async {
        guard request.launchID == context.launchID,
              recoveryViewModel?.launchID == context.launchID else { return }
        do {
            let result = try await withRuntimeOperation {
                let context = try self.makeOrdinaryDesktopStartupContext()
                try await DshService.shared.prepareForProfileMutation(context: context)
                return try await DshPluginOperationCoordinator.shared.adoptInterruptedTransaction(
                    operationID: request.operationID,
                    hooks: self.makeStartupPluginOperationHooks()
                )
            }
            if result.phase == .committed {
                pendingCommittedPluginOperationID = result.operationID
            } else if DshPluginOperationCoordinator.shared.pendingOperation == nil {
                pendingCommittedPluginOperationID = nil
            }
            startupRecoveryError = nil
            startupRecoveryIsPluginOperation = false
            _ = recoveryViewModel?.finishAdoptInterruptedTransaction(request)
            hideRecoverySurface()
            showStartupSurface()
            safeModeUnavailableReason = nil
            startAndLoadDsh()
        } catch {
            _ = recoveryViewModel?.finishAdoptInterruptedTransaction(
                request,
                message: "验证当前状态失败，仍未恢复：\(DshMainWindowUIMessage.safe(error))"
            )
            if error is DshStatePersistenceError {
                await DshService.shared.stopAndWait()
                serviceSession = nil
                webShell?.clearBridgeValidationContext()
                blockStartupForStateFailure(error.localizedDescription)
            } else {
                blockStartupForRecovery(error)
            }
            if let newContext = launchContext {
                showRecoverySurface(for: newContext)
            }
        }
    }

    private func retryPersistedRecoveryCleanup(
        _ request: DshRecoveryActionRequest,
        context: DshLaunchContext
    ) async {
        guard request.launchID == context.launchID,
              let manager = recoveryProfileManager,
              let state = persistedRecoveryRecord,
              [.returned, .cleanupPending, .cleaned].contains(state.phase) else {
            _ = recoveryViewModel?.finishAction(request, message: "恢复记录当前不能清理。")
            return
        }
        do {
            _ = try manager.cleanup(recoveryID: state.recoveryID)
            persistedRecoveryRecord = nil
            recoveryProfileManager = nil
            safeModeUnavailableReason = nil
            _ = recoveryViewModel?.finishAction(request, message: "安全模式恢复记录已清理，请重试普通启动。")
            showRecoverySurface(for: context)
        } catch {
            _ = recoveryViewModel?.finishAction(request, message: "恢复记录清理失败：\(DshMainWindowUIMessage.safe(error))")
        }
    }

    private func handleRecoveryOpenSettings(_ request: DshRecoveryActionRequest, context: DshLaunchContext) {
        guard request.launchID == context.launchID,
              recoveryViewModel?.launchID == context.launchID else { return }
        _ = recoveryViewModel?.finishAction(request)
        SettingsWindowController.shared.show()
    }

    private func handleRecoverySafeMode(_ request: DshRecoveryActionRequest, context: DshLaunchContext) {
        guard request.launchID == context.launchID,
              recoveryViewModel?.launchID == context.launchID else { return }
        let availability = safeModeAvailability(for: context)
        guard availability.available else {
            _ = recoveryViewModel?.finishAction(request, message: availability.reason)
            return
        }
        Task { @MainActor [weak self] in
            await self?.startSafeMode(from: request, failedContext: context)
        }
    }

    private func handleRecoveryPluginRemoval(
        _ request: DshRecoveryPluginRemovalRequest,
        context: DshLaunchContext
    ) {
        guard request.isExecutable,
              request.launchID == context.launchID,
              recoveryViewModel?.launchID == context.launchID,
              let recoveryViewModel,
              recoveryViewModel.isFreshPluginRemovalRequest(request),
              let plan = recoveryViewModel.pluginRemovalPlan(for: request),
              context.profile == .desktop,
              context.originalProfile == .desktop,
              request.originalProfile == DshAppProfile.desktop.runtimeProfileName,
              request.originalProfilePath == context.profileDirectory.standardizedFileURL.path,
              context.profileDirectory.standardizedFileURL.path
                == DshLaunchContext.profileDirectory(for: .desktop).standardizedFileURL.path,
              diagnosticStore.currentContext?.launchID == context.launchID,
              diagnosticStore.currentContext?.generationID == request.generationID else {
            _ = self.recoveryViewModel?.finishPluginRemoval(
                request,
                message: "插件移除计划已失效，仅保留只读恢复。"
            )
            return
        }
        Task { @MainActor [weak self] in
            await self?.performRecoveryPluginRemoval(
                request,
                plan: plan,
                failedContext: context
            )
        }
    }

    private func performRecoveryPluginRemoval(
        _ request: DshRecoveryPluginRemovalRequest,
        plan: DshPluginRemovalPlanPreview,
        failedContext: DshLaunchContext
    ) async {
        do {
            if isSafeModeActive {
                try await stopSafeModeForPluginRemoval(expectedContext: failedContext)
            }
            guard !isSafeModeActive,
                  launchContext?.launchID == failedContext.launchID else {
                throw DshPluginOperationError.runtimeOrProfileRecoveryPending
            }
            let result = try await SettingsViewModel.shared.removePluginFromRecovery(
                plan: plan,
                request: request,
                context: failedContext
            )
            // P01 keeps the committed snapshot until one more ordinary,
            // healthy launch has finalized it.
            pendingCommittedPluginOperationID = result.operationID
            startupRecoveryError = nil
            startupRecoveryIsPluginOperation = false
            _ = recoveryViewModel?.finishPluginRemoval(
                request,
                message: "插件已移除并通过普通健康验证，正在完成启动。"
            )
            hideRecoverySurface()
            showStartupSurface()
            startAndLoadDsh()
        } catch {
            // P01 either restored the baseline or retained an explicit durable
            // recovery record.  Only the latter blocks a fresh normal retry.
            let hasDurableRecovery = DshPluginOperationCoordinator.shared
                .hasPersistedOperationRecord
            startupRecoveryError = hasDurableRecovery
                ? DshMainWindowUIMessage.safe(error)
                : nil
            startupRecoveryIsPluginOperation = hasDurableRecovery
            isSafeModeActive = false
            hideSafeModeIndicator()
            launchContext = failedContext
            _ = recoveryViewModel?.finishPluginRemoval(
                request,
                message: hasDurableRecovery
                    ? "插件移除未完成，事务需要恢复：\(DshMainWindowUIMessage.safe(error))"
                    : "插件移除失败，已回滚原 Profile：\(DshMainWindowUIMessage.safe(error))"
            )
            recordStartupFailure(error, context: failedContext)
            showRecoverySurface(for: failedContext)
        }
    }

    /// Stop and clean the isolated recovery service before handing the exact
    /// original desktop launch context to P01.  No normal service is started
    /// here; P01's ordinary health hook owns that boundary.
    private func stopSafeModeForPluginRemoval(
        expectedContext: DshLaunchContext
    ) async throws {
        guard isSafeModeActive,
              let manager = recoveryProfileManager,
              let launch = recoveryLaunch,
              let normalContext = safeModeNormalContext,
              normalContext == expectedContext else {
            throw DshPluginOperationError.runtimeOrProfileRecoveryPending
        }
        do {
            try await withRuntimeOperation {
                await DshService.shared.stopAndWait()
                self.serviceSession = nil
                self.webShell?.clearBridgeValidationContext()
                // From this point the recovery child is stopped. If the
                // durable record transition below fails, leave the app in a
                // blocked-but-not-running state so cleanup can be retried
                // without falsely claiming a live recovery service.
                self.isSafeModeActive = false
                self.launchContext = expectedContext
                try manager.markReturned(recoveryID: launch.state.recoveryID)
                try manager.cleanup(recoveryID: launch.state.recoveryID)
            }
        } catch {
            if case .loaded(let state) = manager.readState() {
                persistedRecoveryRecord = state
            }
            safeModeUnavailableReason = DshMainWindowUIMessage.safe(error)
            throw error
        }
        recoveryProfileManager = nil
        recoveryLaunch = nil
        persistedRecoveryRecord = nil
        safeModeNormalContext = nil
        isSafeModeActive = false
        hideSafeModeIndicator()
        launchContext = expectedContext
    }

    private func makeRecoveryTemplate(
        for runtime: NpmRuntimeDescriptor
    ) throws -> DshRecoveryProfileTemplate {
        let package: [String: Any] = [
            "name": "dsh-recovery-profile",
            "private": true,
            "dependencies": [String: String](),
            "dsh": ["profile": ["bundles": ["@deepseek-ai/dsh-base", "@deepseek-ai/dsh-web-app"]]]
        ]
        let packageData = try JSONSerialization.data(withJSONObject: package, options: [.prettyPrinted, .sortedKeys])
        let bridgeMarker: [String: String] = [
            "bridge": DshPluginManager.desktopHostPluginName,
            "runtime": runtime.version,
            "scope": "app-owned-recovery"
        ]
        let bridgeData = try JSONSerialization.data(withJSONObject: bridgeMarker, options: [.prettyPrinted, .sortedKeys])
        return DshRecoveryProfileTemplate(
            officialBaseWebAppFiles: ["package.json": packageData],
            bridgeConfigurationFiles: ["dsh-bridge/bridge.json": bridgeData]
        )
    }

    private func makeRecoveryPreparationProof(
        for launch: DshRecoveryLaunch
    ) throws -> DshRecoveryPreparationProof {
        let profileDirectory = launch.context.profileDirectory
        guard let runtimeEntry = DshVersionManager.shared.resolveEntry(
            for: launch.context.runtimeDescriptor
        ) else {
            throw NSError(
                domain: "DshRecovery",
                code: -6,
                userInfo: [NSLocalizedDescriptionKey: "找不到受管 Runtime，拒绝生成恢复准备证明"]
            )
        }
        let managedRuntimeRoot = DshStateManager.versionsDirectory
            .appendingPathComponent(launch.context.runtimeDescriptor.version, isDirectory: true)
            .standardizedFileURL
        let managedNodeModules = managedRuntimeRoot
            .appendingPathComponent("node_modules", isDirectory: true)
            .standardizedFileURL
        let managedDshRoot = managedNodeModules
            .appendingPathComponent("@deepseek-ai", isDirectory: true)
            .appendingPathComponent("dsh", isDirectory: true)
            .standardizedFileURL
        let runtimeEntryURL = URL(fileURLWithPath: runtimeEntry).standardizedFileURL
        let isSymbolicLink: (URL) -> Bool = { url in
            (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false
        }
        let isDirectory: (URL) -> Bool = { url in
            var directory = ObjCBool(false)
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory)
                && directory.boolValue
        }
        guard runtimeEntryURL.path.hasPrefix(managedDshRoot.path + "/"),
              FileManager.default.fileExists(atPath: managedNodeModules.path),
              isDirectory(managedRuntimeRoot),
              isDirectory(managedNodeModules),
              !isSymbolicLink(managedRuntimeRoot),
              !isSymbolicLink(managedNodeModules) else {
            throw NSError(
                domain: "DshRecovery",
                code: -7,
                userInfo: [NSLocalizedDescriptionKey: "受管 Runtime 路径不符合恢复准备边界"]
            )
        }
        let packageProofs = try DshRecoveryProfileManager.requiredPreparationPackageNames
            .sorted()
            .map { name -> DshRecoveryPackageProof in
                let relativePath = "node_modules/\(name)/package.json"
                let source: DshRecoveryPackageProofSource =
                    DshRecoveryProfileManager.managedRuntimePreparationPackageNames.contains(name)
                        ? .managedRuntime
                        : .recoveryProfile
                let root = source == .managedRuntime ? managedNodeModules : profileDirectory
                let manifestURL = root.appendingPathComponent(
                    relativePath.replacingOccurrences(of: "node_modules/", with: "", options: [.anchored])
                )
                guard FileManager.default.fileExists(atPath: manifestURL.path),
                      !isDirectory(manifestURL),
                      !isSymbolicLink(manifestURL) else {
                    throw NSError(
                        domain: "DshRecovery",
                        code: -8,
                        userInfo: [NSLocalizedDescriptionKey: "恢复包 manifest 不存在或不是普通文件：\(name)"]
                    )
                }
                let data = try Data(contentsOf: manifestURL, options: [.mappedIfSafe])
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      object["name"] as? String == name,
                      let version = object["version"] as? String,
                      !version.isEmpty else {
                    throw NSError(
                        domain: "DshRecovery",
                        code: -4,
                        userInfo: [NSLocalizedDescriptionKey: "恢复包 manifest 与包身份不匹配：\(name)"]
                    )
                }
                return DshRecoveryPackageProof(
                    name: name,
                    version: version,
                    manifestRelativePath: relativePath,
                    source: source
                )
            }

        let bridgeRelativePath = "dsh-bridge/bridge.json"
        let bridgeURL = profileDirectory.appendingPathComponent(bridgeRelativePath)
        let bridgeData = try Data(contentsOf: bridgeURL, options: [.mappedIfSafe])
        guard (try JSONSerialization.jsonObject(with: bridgeData)) is [String: Any] else {
            throw NSError(
                domain: "DshRecovery",
                code: -5,
                userInfo: [NSLocalizedDescriptionKey: "恢复 bridge manifest 不是合法 JSON"]
            )
        }
        let fingerprint = SHA256.hash(data: bridgeData)
            .map { String(format: "%02x", $0) }
            .joined()
        return DshRecoveryPreparationProof(
            runtimeVersion: launch.context.runtimeDescriptor.version,
            packageManifests: packageProofs,
            bridge: DshRecoveryBridgeProof(
                manifestRelativePath: bridgeRelativePath,
                fingerprint: fingerprint,
                manifestBytes: bridgeData
            )
        )
    }

    private func startSafeMode(
        from request: DshRecoveryActionRequest,
        failedContext: DshLaunchContext
    ) async {
        guard request.launchID == failedContext.launchID else { return }
        let availability = safeModeAvailability(for: failedContext)
        guard availability.available else {
            recoveryViewModel?.setSafeModeAvailability(false, reason: availability.reason)
            _ = recoveryViewModel?.finishAction(request, message: availability.reason)
            return
        }

        do {
            let result = try await withRuntimeOperation { () throws -> (DshRecoveryProfileManager, DshRecoveryLaunch, DshLaunchContext, DshServiceSession) in
                let manager = DshRecoveryProfileManager(
                    applicationSupportDirectory: DshStateManager.appSupportDirectory,
                    hasActiveReference: { [weak self] directory in
                        guard let self else { return false }
                        return self.isSafeModeActive
                            && self.serviceSession?.context.profileDirectory.standardizedFileURL.path
                                == directory.standardizedFileURL.path
                    }
                )
                var launch: DshRecoveryLaunch
                switch manager.readState() {
                case .absent:
                    let template = try makeRecoveryTemplate(for: failedContext.runtimeDescriptor)
                    launch = try manager.enterRecovery(
                        originalProfile: failedContext.profile,
                        originalDshHome: failedContext.effectiveDshHome,
                        runtimeDescriptor: failedContext.runtimeDescriptor,
                        transactionID: failedContext.transactionID,
                        port: failedContext.port,
                        template: template,
                        launchID: UUID(),
                        recoveryID: UUID()
                    )
                case .loaded(let persisted):
                    guard persisted.originalProfile == failedContext.profile,
                          [.entered, .launched].contains(persisted.phase) else {
                        throw NSError(
                            domain: "DshRecovery",
                            code: -1,
                            userInfo: [NSLocalizedDescriptionKey: "已有安全模式记录正在返回或清理，不能重新启动。"]
                        )
                    }
                    let context = try manager.makeRecoveryContext(
                        from: persisted,
                        launchID: UUID(),
                        port: failedContext.port
                    )
                    launch = DshRecoveryLaunch(
                        state: persisted,
                        context: context,
                        recoveryHomeDirectory: manager.recoveryHomeDirectory,
                        preparation: persisted.preparation,
                        sessionReuseCapability: manager.validatePersistedSessionReuseCapability(for: persisted)
                    )
                case .corrupted(let detail):
                    throw NSError(
                        domain: "DshRecovery",
                        code: -2,
                        userInfo: [NSLocalizedDescriptionKey: "安全模式恢复记录损坏：\(detail)"]
                    )
                }
                do {
                    if launch.preparation == .requiresPreparation {
                        let expectedTemplate = try makeRecoveryTemplate(
                            for: launch.context.runtimeDescriptor
                        )
                        try manager.validateRecoveryPreparationTarget(
                            state: launch.state,
                            context: launch.context,
                            expectedTemplate: expectedTemplate
                        )
                        let verifiedSessionReuse = manager.validatePersistedSessionReuseCapability(
                            for: launch.state
                        )
                        guard verifiedSessionReuse.isAvailable else {
                            throw NSError(
                                domain: "DshRecovery",
                                code: -3,
                                userInfo: [NSLocalizedDescriptionKey: verifiedSessionReuse.reason
                                    ?? "安全模式会话接口不可用。"]
                            )
                        }
                        launch = DshRecoveryLaunch(
                            state: launch.state,
                            context: launch.context,
                            recoveryHomeDirectory: launch.recoveryHomeDirectory,
                            preparation: launch.preparation,
                            sessionReuseCapability: verifiedSessionReuse
                        )
                        // The seed Profile is intentionally incomplete until
                        // the coordinator installs the managed Runtime base/
                        // web packages and the recovery bridge. The dedicated
                        // preparation exception is valid only after the
                        // manager checks above have matched the durable record,
                        // app-owned path, and exact seed bytes.
                        try await inspectDependenciesBeforeMutation(
                            for: launch.context,
                            allowDedicatedRecoveryPreparation: true
                        )
                        try DshPluginManager.shared.bootstrapWebProfileManifestIfMissing(
                            at: launch.context.profileDirectory,
                            profile: launch.context.profile
                        )
                        _ = try await DshPluginManager.shared.ensureDesktopHostPlugin(
                            registry: failedContext.runtimeDescriptor.registry,
                            profileDirectory: launch.context.profileDirectory,
                            profile: launch.context.profile,
                            runtimeVersion: failedContext.runtimeDescriptor.version
                        )
                        _ = try await DshPluginManager.shared.repairProfileDependenciesIfNeeded(
                            registry: failedContext.runtimeDescriptor.registry,
                            profileDirectory: launch.context.profileDirectory,
                            profile: launch.context.profile
                        )
                        let proof = try makeRecoveryPreparationProof(for: launch)
                        let prepared = try manager.markPrepared(
                            recoveryID: launch.state.recoveryID,
                            proof: proof
                        )
                        let preparedContext = try manager.makeRecoveryContext(
                            from: prepared,
                            launchID: launch.context.launchID,
                            port: failedContext.port
                        )
                        launch = DshRecoveryLaunch(
                            state: prepared,
                            context: preparedContext,
                            recoveryHomeDirectory: manager.recoveryHomeDirectory,
                            preparation: prepared.preparation,
                            sessionReuseCapability: manager.validatePersistedSessionReuseCapability(for: prepared)
                        )
                    } else {
                        try await inspectDependenciesBeforeMutation(for: launch.context)
                    }
                    guard launch.sessionReuseCapability.isAvailable else {
                        throw NSError(
                            domain: "DshRecovery",
                            code: -3,
                            userInfo: [NSLocalizedDescriptionKey: launch.sessionReuseCapability.reason ?? "安全模式会话接口不可用。"]
                        )
                    }
                    if launch.state.phase == .entered {
                        let launched = try manager.markLaunched(recoveryID: launch.state.recoveryID)
                        launch = DshRecoveryLaunch(
                            state: launched,
                            context: launch.context,
                            recoveryHomeDirectory: launch.recoveryHomeDirectory,
                            preparation: launched.preparation,
                            sessionReuseCapability: launch.sessionReuseCapability
                        )
                    }
                    let session = try await restartDshServiceDuringOperation(context: launch.context)
                    return (manager, launch, launch.context, session)
                } catch {
                    // Ownership is persisted before the recovery tree is
                    // materialized. Preserve the record and profile so a
                    // later launch can retry preparation or cleanup.
                    throw error
                }
            }
            recoveryProfileManager = result.0
            recoveryLaunch = result.1
            persistedRecoveryRecord = nil
            safeModeNormalContext = failedContext
            launchContext = result.2
            isSafeModeActive = true
            safeModeUnavailableReason = nil
            showSafeModeIndicator(originalProfile: failedContext.profile)
            hideRecoverySurface()
            hideStartupSurface()
            _ = recoveryViewModel?.finishAction(request)
        } catch {
            launchContext = failedContext
            safeModeUnavailableReason = DshMainWindowUIMessage.safe(error)
            recordStartupFailure(error, context: failedContext)
            showRecoverySurface(for: failedContext)
            recoveryViewModel?.setSafeModeAvailability(false, reason: DshMainWindowUIMessage.safe(error))
        }
    }

    private func beginWebUIReadinessCheck(timeout: TimeInterval = 30) {
        webUIReadinessGeneration &+= 1
        let generation = webUIReadinessGeneration
        let deadline = Date().addingTimeInterval(timeout)

        var check: (() -> Void)!
        check = { [weak self] in
            guard let self,
                  self.webUIReadinessGeneration == generation,
                  let webView = self.webView else { return }

            webView.evaluateJavaScript(DshWebShell.webUIReadinessScript) { [weak self] result, _ in
                DispatchQueue.main.async {
                    guard let self,
                          self.webUIReadinessGeneration == generation else { return }

                    let state = result as? [String: Any]
                    let loading = (state?["loading"] as? NSNumber)?.boolValue ?? true
                    let length = (state?["length"] as? NSNumber)?.intValue ?? 0
                    let hasAppShell = (state?["hasAppShell"] as? NSNumber)?.boolValue ?? false
                    let authenticationRequired = (state?["authenticationRequired"] as? NSNumber)?.boolValue ?? false
                    if authenticationRequired {
                        let error = NSError(
                            domain: "DshWebUI",
                            code: -401,
                            userInfo: [NSLocalizedDescriptionKey: RuntimeHealthError.authenticationRequired.localizedDescription]
                        )
                        if self.webUIReadyContinuation != nil {
                            self.webUIReadinessGeneration &+= 1
                            self.completeWebUIReadiness(.failure(error))
                        } else {
                            // The Runtime may reach this page after its
                            // BrowserAuth cookie expires during an otherwise
                            // healthy session. Re-enter the bounded recovery
                            // path so the service issues a fresh bootstrap
                            // URL instead of replaying the old token.
                            self.reloadDsh()
                        }
                        return
                    }
                    if !loading && length > 120 && hasAppShell {
                        self.revealWindow()
                        self.completeWebUIReadiness(.success(()))
                        return
                    }
                    if Date() >= deadline {
                        if loading || length == 0 || !hasAppShell {
                            let error = NSError(
                                domain: "DshWebUI",
                                code: -2,
                                userInfo: [NSLocalizedDescriptionKey: "DSH 页面加载超时，请重启 DSH 服务后重试。"]
                            )
                            if self.webUIReadyContinuation != nil {
                                self.webUIReadinessGeneration &+= 1
                                self.completeWebUIReadiness(.failure(error))
                            } else {
                                self.showErrorAlert(DshMainWindowUIMessage.safe(error))
                            }
                        } else {
                            self.revealWindow()
                            self.completeWebUIReadiness(.success(()))
                        }
                        return
                    }

                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: check)
                }
            }
        }
        check()
    }

    public func revealWindow() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let win = self.window else { return }
            // The recovery page has its own window. A queued startup/UI
            // callback must not re-expose the unready WebView behind it.
            if let recoveryViewModel = self.recoveryViewModel {
                DshRecoveryWindowController.shared.show(viewModel: recoveryViewModel)
                return
            }
            if !win.isVisible {
                win.alphaValue = 0
                win.makeKeyAndOrderFront(nil)
                self.adjustTrafficLights(in: win)
                NSApp.activate(ignoringOtherApps: true)
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.25
                    win.animator().alphaValue = 1.0
                }
            }
        }
    }

    /// Treat the red traffic-light button as hide, like a utility window. The
    /// application stays alive and can be brought back from the Dock, the app
    /// menu, or applicationShouldHandleReopen.
    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        hideMainWindow()
        return false
    }

    @objc private func hideMainWindow() {
        window?.orderOut(nil)
    }

    public func showMainWindow() {
        if let recoveryViewModel {
            DshRecoveryWindowController.shared.show(viewModel: recoveryViewModel)
            return
        }
        revealWindow()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Whether the main DSH window is the window the user is currently using.
    /// Settings/About can be key windows while the main window remains
    /// visible, so notification suppression must inspect this window directly.
    public var isFocusedForNotifications: Bool {
        guard let win = window else { return false }
        return NSApp.isActive && win.isVisible && !win.isMiniaturized && win.isKeyWindow
    }

    public func reloadDsh() {
        guard webView?.url != nil else {
            startAndLoadDsh()
            return
        }
        guard runtimeReloadTask == nil else { return }
        runtimeReloadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.runtimeReloadTask = nil }
            do {
                try await self.withRuntimeOperation {
                    await self.reloadDshWithAuthenticationRecovery()
                }
            } catch {
                self.revealWindow()
                self.showErrorAlert(DshMainWindowUIMessage.safe(error))
            }
        }
    }

    private func reloadDshWithAuthenticationRecovery() async {
        guard let session = serviceSession,
              let currentURL = webView?.url else {
            startAndLoadDsh()
            return
        }

        var recoveryCount = 0
        while true {
            do {
                if await currentRuntimeAuthenticationNeedsRecovery(session: session) {
                    throw RuntimeHealthError.authenticationRequired
                }
                try await reloadWebUI(at: currentURL)
                try await verifyWebKitConnection(session: session)
                return
            } catch {
                guard isAuthenticationRecoveryFailure(error),
                      recoveryCount < Self.maxAutomaticAuthenticationRecoveries else {
                    revealWindow()
                    showErrorAlert(DshMainWindowUIMessage.safe(error))
                    return
                }

                recoveryCount += 1
                do {
                    await webShell?.resetWebsiteDataForAuthenticationRecovery()
                    // DshService.start() creates a new access generation and
                    // receives a fresh `dsh web:?token=...` URL. The old
                    // bootstrap URL is never retained or replayed.
                    // The caller already owns runtimeOperationGate. Calling
                    // the public wrapper here would acquire it a second time
                    // and deadlock the recovery task.
                    _ = try await restartDshServiceDuringOperation()
                    return
                } catch {
                    revealWindow()
                    showErrorAlert("DSH 自动重新认证失败：\(DshMainWindowUIMessage.safe(error))")
                    return
                }
            }
        }
    }

    private func currentRuntimeAuthenticationNeedsRecovery(session: DshServiceSession) async -> Bool {
        guard session.endpoint.authMode == .browserTokenCookie else { return false }
        guard let upstreamCookieStore else { return true }

        do {
            let upstreamCookies = try await upstreamCookieStore.authenticatedCookies(for: session)
            let response = try await runtimeHealthResponse(
                for: runtimeHealthRequest(url: session.originURL),
                label: "当前 Runtime 认证",
                credentials: healthCredentials(
                    rendererToken: session.access.rendererToken,
                    upstreamCookies: upstreamCookies
                ),
                requireCleanFinalURL: true,
                maxRedirects: 0
            )
            return !(200...299).contains(response.statusCode)
                || !DshRuntimeHealthClient.isHTMLPage(response)
        } catch {
            return true
        }
    }

    private func reloadWebUI(at url: URL) async throws {
        webUIReadinessGeneration &+= 1
        pendingWebUINavigation = nil
        let webUIReadyTask = Task { @MainActor in
            try await self.waitForWebUIReady()
        }
        await Task.yield()
        guard let navigation = webView?.load(URLRequest(url: url)) else {
            let error = NSError(
                domain: "DshWebUI",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "无法重新加载 DSH 页面"]
            )
            completeWebUIReadiness(.failure(error))
            throw error
        }
        pendingWebUINavigation = navigation
        webUINavigationGenerations[ObjectIdentifier(navigation)] = webUIReadinessGeneration
        do {
            try await webUIReadyTask.value
        } catch {
            pendingWebUINavigation = nil
            webUIReadinessGeneration &+= 1
            throw error
        }
    }

    private func isAuthenticationRecoveryFailure(_ error: Error) -> Bool {
        if let healthError = error as? RuntimeHealthError {
            switch healthError {
            case .authenticationRequired, .webKitConnectionFailed(_):
                return true
            default:
                return false
            }
        }
        let nsError = error as NSError
        return nsError.domain == "DshWebUI" && nsError.code == -401
    }

    // MARK: - Onboarding View

    private func showOnboardingView() {
        guard let vibrancy = vibrancyView else { return }
        let onboarding = OnboardingView { [weak self] in
            self?.startAndLoadDsh()
        }
        let hosting = NSHostingView(rootView: onboarding)
        hosting.frame = vibrancy.bounds
        hosting.autoresizingMask = [.width, .height]
        vibrancy.addSubview(hosting)
        self.onboardingHostingView = hosting
    }

    private func hideOnboardingView() {
        onboardingHostingView?.removeFromSuperview()
        onboardingHostingView = nil
    }

    private func showErrorAlert(_ message: String) {
        let safeMessage = DshMainWindowUIMessage.safe(message)
        if let context = launchContext,
           diagnosticStore.currentContext?.launchID == context.launchID {
            let error = NSError(
                domain: "DshWebUI",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: safeMessage]
            )
            recordStartupFailure(error, context: context)
            showRecoverySurface(for: context)
            return
        }
        let alert = NSAlert()
        alert.messageText = "DSH 启动失败"
        alert.informativeText = safeMessage
        alert.addButton(withTitle: "打开设置")
        alert.addButton(withTitle: "退出")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            SettingsWindowController.shared.show()
        } else {
            NSApp.terminate(nil)
        }
    }

    // MARK: - Styling & Theme Injection

    public func syncUiTheme() {
        let externalTheme = DshPluginManager.shared.detectExternalTheme()
        let theme = externalTheme == nil ? DshStateManager.shared.current.uiTheme : "default"
        webShell?.syncTheme(theme)
    }

    // MARK: - WKNavigationDelegate

    private func isLocalWebURL(_ url: URL) -> Bool {
        url.host == "127.0.0.1" || url.host == "localhost"
    }

    private func isCurrentRuntimeWebURL(_ url: URL) -> Bool {
        guard let origin = serviceSession?.originURL else { return false }
        return url.scheme == origin.scheme
            && url.host == origin.host
            && url.port == origin.port
    }

    private func isExpectedNavigationInterruption(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled {
            return true
        }
        // WebKit uses its legacy policy-change error when a frame navigation
        // is intentionally converted into a WKDownload.
        return error.domain == "WebKitErrorDomain" && error.code == 102
    }

    /// Match a callback to the current navigation generation. A missing map
    /// entry is allowed for user-initiated navigations after startup, but a
    /// navigation that we tracked must still belong to the current readiness
    /// generation. This prevents an old WebKit `didFail` delivered after a
    /// reload from clearing the new page's readiness waiter.
    private func isCurrentWebUINavigation(_ navigation: WKNavigation!) -> Bool {
        guard let navigation else { return false }
        let identifier = ObjectIdentifier(navigation)
        if let generation = webUINavigationGenerations[identifier] {
            guard generation == webUIReadinessGeneration else { return false }
        }
        return pendingWebUINavigation == nil || navigation === pendingWebUINavigation
    }

    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }

        if isCurrentRuntimeWebURL(url) && navigationAction.shouldPerformDownload {
            decisionHandler(.download)
        } else if isCurrentRuntimeWebURL(url) {
            decisionHandler(.allow)
        } else if isLocalWebURL(url) {
            // A loopback URL is not automatically trusted: localhost and a
            // different port are different authorities for BrowserAuth.
            decisionHandler(.cancel)
        } else {
            if navigationAction.navigationType == .linkActivated {
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel)
        }
    }

    public func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        guard let url = navigationResponse.response.url,
              isCurrentRuntimeWebURL(url) else {
            decisionHandler(.cancel)
            return
        }

        let contentDisposition = (navigationResponse.response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Disposition")?
            .lowercased()
        if contentDisposition?.contains("attachment") == true || !navigationResponse.canShowMIMEType {
            decisionHandler(.download)
        } else {
            decisionHandler(.allow)
        }
    }

    public func webView(_ webView: WKWebView, navigationAction: WKNavigationAction,
                        didBecome download: WKDownload) {
        download.delegate = self
    }

    public func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse,
                        didBecome download: WKDownload) {
        download.delegate = self
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard isCurrentWebUINavigation(navigation) else { return }
        syncUiTheme()
        pendingWebUINavigation = nil
        beginWebUIReadinessCheck()
    }

    @objc public func enableDeveloperTools() {
        webShell?.enableDeveloperTools()
    }

    @objc public func closeDeveloperTools() {
        webShell?.closeDeveloperTools()
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if isExpectedNavigationInterruption(error) {
            print("[MainWindowController] Ignored expected navigation interruption:", DshMainWindowUIMessage.safe(error))
            return
        }
        guard isCurrentWebUINavigation(navigation) else { return }
        pendingWebUINavigation = nil
        let hadReadinessWaiter = webUIReadyContinuation != nil
        completeWebUIReadiness(.failure(error))
        guard !hadReadinessWaiter else { return }
        revealWindow()
        showErrorAlert("页面加载失败：\(DshMainWindowUIMessage.safe(error))")
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if isExpectedNavigationInterruption(error) {
            print("[MainWindowController] Ignored expected provisional navigation interruption:", DshMainWindowUIMessage.safe(error))
            return
        }
        guard isCurrentWebUINavigation(navigation) else { return }
        pendingWebUINavigation = nil
        let hadReadinessWaiter = webUIReadyContinuation != nil
        completeWebUIReadiness(.failure(error))
        guard !hadReadinessWaiter else { return }
        revealWindow()
        showErrorAlert("页面加载失败：\(DshMainWindowUIMessage.safe(error))")
    }

    // MARK: - WKDownloadDelegate

    private func downloadSelectionDefaults(suggestedFilename: String) throws -> (directory: URL, filename: String) {
        let fileManager = FileManager.default
        guard let downloadsDirectory = fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            throw NSError(
                domain: "DSHDownload",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "无法找到用户下载目录。"]
            )
        }
        try fileManager.createDirectory(at: downloadsDirectory, withIntermediateDirectories: true)

        let lastPathComponent = (suggestedFilename as NSString).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let filename = lastPathComponent.isEmpty || lastPathComponent == "." || lastPathComponent == ".."
            ? "download"
            : lastPathComponent
        return (downloadsDirectory, filename)
    }

    private func showDownloadError(_ message: String) {
        dismissDownloadStatus()
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "下载失败"
        alert.informativeText = DshMainWindowUIMessage.safe(message)
        alert.addButton(withTitle: "好的")
        alert.beginSheetModal(for: window)
    }

    private func showDownloadStatus(destination: URL, completed: Bool) {
        guard let vibrancyView else { return }

        let banner: DownloadStatusBanner
        if let existing = downloadStatusBanner {
            banner = existing
        } else {
            banner = DownloadStatusBanner(frame: .zero)
            banner.translatesAutoresizingMaskIntoConstraints = false
            vibrancyView.addSubview(banner, positioned: .above, relativeTo: nil)
            NSLayoutConstraint.activate([
                banner.trailingAnchor.constraint(equalTo: vibrancyView.trailingAnchor, constant: -20),
                banner.bottomAnchor.constraint(equalTo: vibrancyView.bottomAnchor, constant: -20),
                banner.widthAnchor.constraint(equalToConstant: 500)
            ])
            downloadStatusBanner = banner
        }

        banner.onReveal = {
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        }
        banner.onClose = { [weak self, weak banner] in
            guard let self, self.downloadStatusBanner === banner else { return }
            self.dismissDownloadStatus()
        }
        banner.update(destination: destination, completed: completed)
    }

    private func dismissDownloadStatus() {
        downloadStatusBanner?.removeFromSuperview()
        downloadStatusBanner = nil
    }

    public func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                         suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        do {
            let defaults = try downloadSelectionDefaults(suggestedFilename: suggestedFilename)
            guard let window else {
                throw NSError(
                    domain: "DSHDownload",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "主窗口当前不可用。"]
                )
            }

            let panel = NSSavePanel()
            panel.title = "保存 Session 导出"
            panel.message = "选择 Session ZIP 文件的保存位置。"
            panel.prompt = "保存"
            panel.directoryURL = defaults.directory
            panel.nameFieldStringValue = defaults.filename
            panel.canCreateDirectories = true
            panel.isExtensionHidden = false

            panel.beginSheetModal(for: window) { [weak self] response in
                guard let self else {
                    completionHandler(nil)
                    return
                }
                guard response == .OK, let destination = panel.url else {
                    completionHandler(nil)
                    return
                }

                do {
                    // NSSavePanel has already asked the user to confirm an
                    // overwrite. WKDownload requires that its destination
                    // does not exist when the transfer begins.
                    if FileManager.default.fileExists(atPath: destination.path) {
                        try FileManager.default.removeItem(at: destination)
                    }
                    self.downloadDestinations[ObjectIdentifier(download)] = destination
                    self.showDownloadStatus(destination: destination, completed: false)
                    completionHandler(destination)
                } catch {
                    completionHandler(nil)
                    self.showDownloadError(DshMainWindowUIMessage.safe(error))
                }
            }
        } catch {
            completionHandler(nil)
            showDownloadError(DshMainWindowUIMessage.safe(error))
        }
    }

    public func downloadDidFinish(_ download: WKDownload) {
        if let destination = downloadDestinations.removeValue(forKey: ObjectIdentifier(download)) {
            print("[MainWindowController] Download completed:", destination.path)
            showDownloadStatus(destination: destination, completed: true)
        }
    }

    public func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        downloadDestinations.removeValue(forKey: ObjectIdentifier(download))
        if isExpectedNavigationInterruption(error) {
            print("[MainWindowController] Download cancelled")
            return
        }
        print("[MainWindowController] Download failed:", DshMainWindowUIMessage.safe(error))
        showDownloadError(DshMainWindowUIMessage.safe(error))
    }

    // MARK: - WKUIDelegate

    /// WebKit deliberately disables file uploads on macOS unless its UI
    /// delegate implements this callback. The DSH attachment button is a
    /// normal HTML `<input type="file">`, so without this bridge WebKit
    /// treats the click exactly like a cancelled picker and the page gives
    /// the user no visible feedback.
    public func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping ([URL]?) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.title = "上传附件"
        panel.prompt = "选择"
        panel.canChooseFiles = true
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.resolvesAliases = true
        panel.canCreateDirectories = false

        // The WebView can be temporarily detached while the main window is
        // being restored or replaced. Prefer the actual owner of the view,
        // then fall back to this controller's window. A sheet attached to a
        // different key window can appear behind DSH and make a working
        // picker look like a no-op.
        let parentWindow = webView.window ?? window
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK else {
                completionHandler(nil)
                return
            }

            // Keep the URLs returned by NSOpenPanel intact. macOS grants the
            // app the user-selected security scope for these URLs (when the
            // app is sandboxed), and WebKit uses that grant while it reads
            // the upload. Copying them or releasing a manually-started
            // scope here would race the WebContent process.
            completionHandler(panel.urls)
        }

        if let parentWindow, parentWindow.isVisible {
            panel.beginSheetModal(for: parentWindow, completionHandler: finish)
        } else {
            // There is no sheet owner during a window restoration edge case.
            // An app-modal panel still gives WebKit a valid completion path;
            // returning nil would silently cancel the attachment instead.
            panel.begin(completionHandler: finish)
        }
    }

    public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            if !isCurrentRuntimeWebURL(url) {
                NSWorkspace.shared.open(url)
            }
        }
        return nil
    }

    // MARK: - DshBridgeDelegate

    public func bridgeDidReceiveReady() {
        print("[MainWindowController] DSH Web UI ready signal received")
        syncUiTheme()
    }

    public func bridgeDidReceiveTheme(colorScheme: String?, externalTheme: String?) {
        // The manifest is the authoritative source for whether the native
        // theme control is available. Re-read it when the bridge publishes a
        // theme snapshot so the settings page follows plugin changes quickly.
        Task { @MainActor in
            DshNativeAppearance.update(colorScheme: colorScheme)
            SettingsViewModel.shared.refreshExternalThemeFromBridge()
        }
    }
    public func bridgeDidReceiveLocale(language: String) {}

    public func bridgeDidPrepareWindowDrag() {
        isUsingNativeWindowDrag = false
        windowDragStartOrigin = nil
        windowDragStartMouseLocation = nil

        guard let event = NSApp.currentEvent,
              event.type == .leftMouseDown else {
            windowDragMouseDownEvent = nil
            return
        }
        windowDragMouseDownEvent = event
    }

    public func bridgeDidStartWindowDrag() {
        guard let window else { return }
        if let mouseDownEvent = windowDragMouseDownEvent {
            windowDragMouseDownEvent = nil
            isUsingNativeWindowDrag = true
            window.performDrag(with: mouseDownEvent)
            webView?.evaluateJavaScript("window.__DSH_NATIVE_WINDOW_DRAG_CLEANUP__?.()", completionHandler: nil)
            return
        }

        windowDragStartOrigin = window.frame.origin
        windowDragStartMouseLocation = NSEvent.mouseLocation
    }

    public func bridgeDidMoveWindowDrag() {
        guard !isUsingNativeWindowDrag else { return }
        guard let window,
              let startOrigin = windowDragStartOrigin,
              let startMouseLocation = windowDragStartMouseLocation else { return }
        let currentMouseLocation = NSEvent.mouseLocation
        window.setFrameOrigin(NSPoint(
            x: startOrigin.x + currentMouseLocation.x - startMouseLocation.x,
            y: startOrigin.y + currentMouseLocation.y - startMouseLocation.y
        ))
    }

    public func bridgeDidEndWindowDrag() {
        windowDragMouseDownEvent = nil
        isUsingNativeWindowDrag = false
        windowDragStartOrigin = nil
        windowDragStartMouseLocation = nil
    }

    public func bridgeDidDoubleClickWindowTitlebar() {
        bridgeDidEndWindowDrag()
        guard let window else { return }

        let globalDefaults = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)
        let configuredAction = (globalDefaults?["AppleActionOnDoubleClick"] as? String)?.lowercased()
        let legacyMiniaturize = (globalDefaults?["AppleMiniaturizeOnDoubleClick"] as? NSNumber)?.boolValue ?? false

        if configuredAction == "none" {
            return
        }
        if configuredAction == "minimize" || (configuredAction == nil && legacyMiniaturize) {
            window.performMiniaturize(nil)
        } else {
            // AppKit toggles between the standard zoomed frame and the
            // previous frame, restoring the user's former centered position.
            window.performZoom(nil)
        }
    }
}

// MARK: - Onboarding View Model & View

@MainActor
final class OnboardingViewModel: ObservableObject {
    @Published var statusText = "首次启动，正在准备 DSH 运行时..."
    @Published var detailText = ""
    @Published var isInstalling = false
    @Published var selectedRegistry = DshStateManager.shared.current.npmRegistry ?? DshVersionManager.defaultRegistry
    @Published var errorMessage: String?

    func startInitialInstall(onFinished: @escaping () -> Void) {
        isInstalling = true
        errorMessage = nil
        let registry = selectedRegistry
        DshStateManager.shared.update { $0.npmRegistry = registry }

        Task { [self] in
            do {
                let catalog = try await DshVersionManager.shared.fetchCatalog(registry: registry)
                guard let latest = catalog.latest ?? catalog.versions.first?.version else {
                    throw NSError(domain: "Onboarding", code: -1, userInfo: [NSLocalizedDescriptionKey: "未能获取到最新版本号"])
                }
                guard let latestIntegrity = catalog.versions.first(where: { $0.version == latest })?.integrity else {
                    throw NSError(domain: "Onboarding", code: -2, userInfo: [NSLocalizedDescriptionKey: "npm 版本目录缺少 DSH integrity，已拒绝安装"])
                }

                await MainActor.run {
                    self.statusText = "正在下载 DSH \(latest)..."
                }

                _ = try await DshVersionManager.shared.installVersion(
                    version: latest,
                    registry: registry,
                    expectedIntegrity: latestIntegrity
                ) { progress in
                    Task { @MainActor in
                        self.statusText = DshMainWindowUIMessage.safe(progress.phase)
                        self.detailText = DshMainWindowUIMessage.safe(progress.detail ?? "")
                    }
                }

                DshStateManager.shared.update { state in
                    state.selectedVersion = latest
                    state.runtimeState.active = NpmRuntimeDescriptor(
                        version: latest,
                        registry: DshVersionManager.normalizedRegistry(registry),
                        integrity: latestIntegrity
                    )
                    state.runtimeState.pending = nil
                    state.runtimeState.phase = .idle
                }

                await MainActor.run {
                    onFinished()
                }
            } catch {
                await MainActor.run {
                    self.isInstalling = false
                    self.errorMessage = DshMainWindowUIMessage.safe(error)
                }
            }
        }
    }
}

struct OnboardingView: View {
    let onFinished: () -> Void
    @ObservedObject private var vm = OnboardingViewModel()

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "cube.transparent")
                .resizable()
                .scaledToFit()
                .frame(width: 64, height: 64)
                .foregroundColor(.accentColor)

            VStack(spacing: 8) {
                Text("欢迎使用 DeepSeek Harness")
                    .font(.title2)
                    .fontWeight(.bold)
                Text("正在配置运行环境与下载最新版本的 DSH")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            if vm.isInstalling {
                VStack(spacing: 12) {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle())
                        .scaleEffect(1.2)
                    Text(vm.statusText)
                        .font(.body)
                    if !vm.detailText.isEmpty {
                        Text(vm.detailText)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding()
                .frame(maxWidth: 400)
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    Picker("下载镜像源：", selection: Binding(
                        get: { vm.selectedRegistry },
                        set: { vm.selectedRegistry = $0 }
                    )) {
                        Text("官方 npm (registry.npmjs.org)").tag(DshVersionManager.defaultRegistry)
                        Text("淘宝镜像 (registry.npmmirror.com)").tag(DshVersionManager.mirrorRegistry)
                    }
                    .pickerStyle(RadioGroupPickerStyle())

                    if let err = vm.errorMessage {
                        Text(err)
                            .font(.caption)
                            .foregroundColor(.red)
                    }

                    Button(action: {
                        vm.startInitialInstall(onFinished: onFinished)
                    }) {
                        HStack {
                            Spacer()
                            Text("开始准备并启动")
                                .fontWeight(.medium)
                            Spacer()
                        }
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                .padding(24)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .windowBackgroundColor).opacity(0.8)))
                .frame(maxWidth: 420)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
    }
}
