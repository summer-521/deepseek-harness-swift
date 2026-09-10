import AppKit
import Sparkle
import WebKit

private enum DshAppDelegateLog {
    static let maximumLength = 600

    static func safe(_ error: Error) -> String {
        let redacted = DshSecretRedactor().redactDiagnostic(error.localizedDescription)
        guard redacted.count > maximumLength else { return redacted }
        return String(redacted.prefix(maximumLength)) + "…"
    }
}

/// Marks only failures thrown by the P01 recovery handoff. Runtime/Profile
/// recovery runs in the same operation gate, but its errors must continue
/// through the original M1 startup/retry path even when a plugin record also
/// exists on disk.
private enum DshStartupRecoveryError: Error {
    case pluginOperation(Error)
}

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Held for the process lifetime; the kernel releases it on exit.
    private var instanceLock: DshInstanceLock?

    /// Explain why this launch stops instead of silently exiting: the user
    /// almost always started a second copy by accident, and the data risk is
    /// not obvious.
    private func presentAlreadyRunningInstanceAlert(_ holder: DshInstanceLock.Holder?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "DSH 已在运行"
        var details: [String] = []
        if let holder {
            details.append("占用者：进程 \(holder.pid)，DSH \(holder.appVersion)")
            details.append("DSH_HOME：\(holder.dshHome)")
            details.append("占用开始：\(Self.holderTimestampFormatter.string(from: holder.acquiredAt))")
        } else {
            details.append("另一个 DSH 实例正在使用同一份应用数据。")
        }
        alert.informativeText = """
        检测到另一个 DSH 实例正在使用同一份应用数据：
        \(details.joined(separator: "\n"))

        同时运行两个实例会互相覆盖状态、并发修改同一份 Profile，并可能删除对方的事务回滚点，因此本次启动已停止。

        如果那个实例已经无响应，请先在“活动监视器”中结束它，然后重新打开 DSH。
        """
        alert.addButton(withTitle: "退出")
        alert.addButton(withTitle: "复制诊断信息")
        let response = alert.runModal()
        if response == .alertSecondButtonReturn {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(
                (details + ["应用数据：\(DshStateManager.appSupportDirectory.path)"]).joined(separator: "\n"),
                forType: .string
            )
        }
    }

    /// The lock path exists but cannot be this app's lock file (a directory or
    /// symlink planted at `dsh-instance.lock`, or an unexpected `open`/`flock`
    /// failure). This is deliberately fatal: starting anyway would run without
    /// the single-instance protection that the state file, the shared Profile
    /// tree and the rollback snapshots depend on.
    private func presentBlockedInstanceLockAlert(_ detail: String) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "无法建立实例锁，已停止启动"
        alert.informativeText = """
        \(detail)

        应用数据目录中的 \(DshInstanceLock.fileName) 不是 DSH 创建的普通锁文件，或锁调用异常，因此无法保证“同一份应用数据只有一个实例”。

        继续启动会让两个实例互相覆盖状态、并发修改同一份 Profile，并可能删除对方的事务回滚点，所以本次启动已停止。

        请在“访达”中前往 \(DshStateManager.appSupportDirectory.path)，删除或重命名该对象后重新打开 DSH。若该对象不是你有意创建的，请先确认是否有其他程序在干预该目录。
        """
        alert.addButton(withTitle: "退出")
        alert.addButton(withTitle: "复制诊断信息")
        if alert.runModal() == .alertSecondButtonReturn {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(detail, forType: .string)
        }
    }

    private static let holderTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return formatter
    }()

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // Before anything reads or writes durable state: exactly one instance
        // may own this Application Support root. A second instance would
        // overwrite `dsh-state.json` (whole-file last-writer-wins), race the
        // same Profile tree and port, and its startup sweeps could delete the
        // peer's only rollback snapshot. The kernel releases the `flock` on
        // exit, crash or SIGKILL, so a leftover lock file is harmless.
        switch DshInstanceLock.acquire(
            at: DshStateManager.appSupportDirectory,
            holder: DshInstanceLock.Holder(
                pid: ProcessInfo.processInfo.processIdentifier,
                appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
                dshHome: DshLaunchContext.defaultDshHome.path,
                acquiredAt: Date()
            )
        ) {
        case .acquired(let instanceLock):
            self.instanceLock = instanceLock
        case .heldBy(let holder):
            presentAlreadyRunningInstanceAlert(holder)
            NSApp.terminate(nil)
            return
        case .blocked(let detail):
            // Fail closed: the lock path is occupied by something that is not
            // this app's lock file, or the lock call failed for an unexpected
            // reason. Continuing would silently drop the single-instance
            // guarantee that protects the shared state, Profile tree, port and
            // rollback snapshots, and a blocked path is actionable for the
            // user (unlike a limited environment, see `.unavailable`).
            presentBlockedInstanceLockAlert(detail)
            NSApp.terminate(nil)
            return
        case .unavailable(let detail):
            // Fail open: a genuinely limited environment (read-only volume, no
            // write permission, no space) must not make the app impossible to
            // start, and a second instance could not persist its state either.
            // The double-instance risk is recorded so it stays diagnosable.
            print("[AppDelegate] Instance lock unavailable, continuing without cross-process protection:", detail)
        }
        // Keep one updater for the whole app. Sparkle starts its automatic
        // checker from the Info.plist settings and the same controller backs
        // the menu item and About settings row.
        _ = AppUpdateManager.shared
        setupAppMenu()
        Task { @MainActor in
            // Recovery work begins before MainWindowController.launch(). Show
            // the native progress surface now so AppKit state restoration can
            // never expose the empty WKWebView underneath it.
            MainWindowController.shared.beginStartupPreparation()
            // Do not let the in-memory default stand in for an existing but
            // unreadable/corrupt primary state file. This guard must precede
            // every Runtime, Profile, and plugin recovery hook because those
            // hooks can otherwise write using the fallback config.
            switch DshStateStartupDecision.decide(for: DshStateManager.shared.loadResult) {
            case .proceed:
                break
            case .block(let detail):
                MainWindowController.shared.blockStartupForStateFailure(detail)
                return
            }
            // Recovery and Profile cleanup can touch thousands of files. Keep
            // the UI responsive and let MainWindowController perform the one
            // actual snapshot restore immediately before the old Runtime is
            // started.
            // Profile switches are persisted separately from Runtime update
            // transactions. Recover them first so a force-quit during a
            // failed web switch can never make startup retry the bad Profile.
            // Reclaim an orphaned Node process before any recovery path can
            // touch package.json, pnpm-lock.yaml, or node_modules.
            var startupRecoveryError: Error?
            var startupPersistenceError: DshStatePersistenceError?
            do {
                // Startup recovery, snapshot cleanup, and the first launch
                // share one operation gate. This prevents MainWindow from
                // queueing a start between the stale-process check and a
                // recovery write.
                try await MainWindowController.shared.withRuntimeOperation {
                    try await DshService.shared.prepareForProfileMutation()
                    try await SettingsViewModel.shared.recoverPendingProfileSwitch()
                    try await SettingsViewModel.shared.recoverPendingRuntimeUpdate()
                    try await SettingsViewModel.shared.retryRetainedWebProfileSnapshotCleanup()
                    // A displaced Profile tree is only reclaimed when the
                    // restore provably finished and the canonical Profile is
                    // back; otherwise it is kept and reported (R12).
                    try await SettingsViewModel.shared.retryPendingProfileRestoreCleanup()

                    // P01 recovery runs inside this already-held Runtime /
                    // Profile gate. Its health hooks call
                    // restartDshServiceDuringOperation directly, so a
                    // pending plugin transaction cannot race the first
                    // ordinary launch or deadlock by reacquiring this gate.
                    do {
                        _ = try await MainWindowController.shared
                            .recoverPendingPluginOperationDuringStartup()
                    } catch {
                        // Preserve the exact stage. The outer catch must not
                        // infer plugin ownership from the mere presence of a
                        // durable record: a preceding Runtime/Profile step
                        // may have been the operation that actually failed.
                        throw DshStartupRecoveryError.pluginOperation(error)
                    }

                    _ = await Task.detached(priority: .utility) {
                        DshVersionManager.shared.cleanupUnreferencedVersions()
                    }.value
                    _ = await DshPluginManager.shared.cleanupOrphanedWebProfileSnapshots(
                        keeping: DshStateManager.shared.current.runtimeState.webProfileSnapshotID
                    )
                    // Runs after P01 recovery so a resolved record's snapshots
                    // are not swept; only unreferenced/partial trees are
                    // removed, and only with ownership or structural proof.
                    _ = await DshPluginManager.shared.cleanupOrphanedPluginOperationSnapshots(
                        keeping: DshPluginOperationCoordinator.shared.pendingOperation?.operationID
                    )
                    // Disposable staging/migration/bridge leftovers stranded
                    // by a force-quit; never touches live trees (see manager).
                    _ = await DshPluginManager.shared.cleanupOrphanedStagingDirectories()
                }
            } catch {
                // Keep M1's original MainWindow startup classification for
                // ordinary Runtime/Profile failures. Only the explicitly
                // marked P01 handoff failure blocks normal launch.
                if case let .pluginOperation(pluginError) = error as? DshStartupRecoveryError {
                    startupRecoveryError = pluginError
                }
                if let persistenceError = error as? DshStatePersistenceError {
                    startupPersistenceError = persistenceError
                }
                print("[AppDelegate] Profile recovery deferred until the DSH port is safe:", DshAppDelegateLog.safe(error))
            }
            if let startupPersistenceError {
                // A failed recovery commit is itself a startup blocker. Do
                // not continue into launch with an in-memory state that was
                // never durably written.
                MainWindowController.shared.blockStartupForStateFailure(
                    startupPersistenceError.localizedDescription
                )
                return
            }
            // Settings may have restored a verifying banner before recovery
            // ran. Re-read the durable result so a committed recovery is
            // shown as success, while corrupt records remain fail-closed.
            SettingsViewModel.shared.synchronizePersistedPluginOperationState()
            if let startupRecoveryError {
                // Do not continue into a normal launch after an unresolved
                // Runtime/Profile/plugin recovery condition. The native
                // surface retains the redacted diagnostic and exposes only
                // explicit recovery actions.
                MainWindowController.shared.blockStartupForRecovery(startupRecoveryError)
            }
            MainWindowController.shared.launch()
            await SettingsViewModel.shared.refreshCatalog()
            await SettingsViewModel.shared.followLatestIfEnabled()
        }
    }

    public func applicationWillTerminate(_ notification: Notification) {
        DshService.shared.stop()
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Settings is a separate visible window. Reopening from the Dock must
        // still restore the main window even while Settings remains open.
        MainWindowController.shared.showMainWindow()
        return true
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - App Menu Setup

    private func setupAppMenu() {
        let mainMenu = NSMenu()

        // 1. App Menu (DSH)
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        let aboutItem = appMenu.addItem(withTitle: "关于 DSH", action: #selector(openAbout), keyEquivalent: "")
        aboutItem.target = self
        appMenu.addItem(NSMenuItem.separator())
        let settingsItem = appMenu.addItem(withTitle: "设置与版本管理...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        let restartItem = appMenu.addItem(withTitle: "重启 DSH 服务", action: #selector(restartService), keyEquivalent: "r")
        restartItem.target = self

        let checkForUpdatesItem = NSMenuItem(
            title: "检查更新…",
            action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
            keyEquivalent: ""
        )
        checkForUpdatesItem.target = AppUpdateManager.shared.updaterController
        appMenu.addItem(checkForUpdatesItem)

        appMenu.addItem(NSMenuItem.separator())

        let servicesItem = NSMenuItem(title: "服务", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu()
        NSApp.servicesMenu = servicesMenu
        servicesItem.submenu = servicesMenu
        appMenu.addItem(servicesItem)
        appMenu.addItem(NSMenuItem.separator())

        appMenu.addItem(withTitle: "隐藏 DSH", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = NSMenuItem(title: "隐藏其他", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(withTitle: "显示全部", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())

        appMenu.addItem(withTitle: "退出 DSH", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // 2. Edit Menu
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redoItem = NSMenuItem(title: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(redoItem)
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // 3. View / Control Menu
        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "视图")
        viewMenu.addItem(withTitle: "重新加载页面", action: #selector(reloadPage), keyEquivalent: "R")
        viewMenu.addItem(NSMenuItem.separator())
        viewMenu.addItem(withTitle: "进入全屏幕", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
#if DEBUG
        viewMenu.addItem(NSMenuItem.separator())
        viewMenu.addItem(withTitle: "启用开发者工具", action: #selector(MainWindowController.enableDeveloperTools), keyEquivalent: "")
        viewMenu.addItem(withTitle: "关闭开发者工具", action: #selector(MainWindowController.closeDeveloperTools), keyEquivalent: "")
#endif
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        // 4. Window Menu
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "缩放", action: #selector(NSWindow.zoom(_:)), keyEquivalent: "")
        windowMenu.addItem(NSMenuItem.separator())
        windowMenu.addItem(withTitle: "前置全部窗口", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        // 5. Help Menu
        let helpMenuItem = NSMenuItem()
        let helpMenu = NSMenu(title: "帮助")
        let helpItem = helpMenu.addItem(withTitle: "DSH 帮助文档与源码", action: #selector(openHelp), keyEquivalent: "")
        helpItem.target = self
        helpMenuItem.submenu = helpMenu
        mainMenu.addItem(helpMenuItem)

        NSApp.mainMenu = mainMenu
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.show()
    }

    @objc private func openAbout() {
        AboutWindowController.shared.show()
    }

    @objc private func restartService() {
        MainWindowController.shared.startAndLoadDsh()
    }

    @objc private func reloadPage() {
        MainWindowController.shared.reloadDsh()
    }

    @objc private func openHelp() {
        if let url = URL(string: "https://github.com/summer-521/deepseek-harness-desktop") {
            NSWorkspace.shared.open(url)
        }
    }
}
