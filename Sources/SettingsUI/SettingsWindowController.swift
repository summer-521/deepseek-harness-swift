import AppKit
import SwiftUI

/// Keeps native SwiftUI windows aligned with the color scheme reported by
/// the DSH host. The host can use a theme that is independent of macOS'
/// system appearance, so leaving these windows on the default NSAppearance
/// makes About and Settings disagree with the main page.
public enum DshNativeAppearance {
    public static let didChangeNotification = Notification.Name("dsh.nativeAppearanceDidChange")

    private static var colorScheme: String?

    public static func update(colorScheme: String?) {
        let normalized: String?
        switch colorScheme?.lowercased() {
        case "dark": normalized = "dark"
        case "light": normalized = "light"
        default: normalized = nil
        }

        guard Self.colorScheme != normalized else { return }
        Self.colorScheme = normalized
        NotificationCenter.default.post(
            name: didChangeNotification,
            object: normalized
        )
    }

    public static func apply(to window: NSWindow) {
        switch colorScheme {
        case "dark":
            window.appearance = NSAppearance(named: .darkAqua)
        case "light":
            window.appearance = NSAppearance(named: .aqua)
        default:
            // Nil means inherit the system/application appearance.
            window.appearance = nil
        }

        // Re-resolve this dynamic AppKit color after an appearance change so
        // the opaque window background does not retain the previous mode.
        window.backgroundColor = .windowBackgroundColor
    }
}

public final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    public static let shared = SettingsWindowController()
    private var titleObserver: NSObjectProtocol?
    private var appearanceObserver: NSObjectProtocol?

    private init() {
        let hostingController = NSHostingController(rootView: SettingsView())
        let win = NSWindow(contentViewController: hostingController)
        win.title = "通用设置"
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = false
        win.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        win.setContentSize(NSSize(width: 920, height: 620))
        win.minSize = NSSize(width: 860, height: 560)
        win.center()
        win.isReleasedWhenClosed = false
        win.isOpaque = true
        win.backgroundColor = .windowBackgroundColor
        win.hasShadow = true
        DshNativeAppearance.apply(to: win)
        // Let AppKit own the titlebar hit testing. A full-width custom drag
        // layer used to sit above the SwiftUI settings header on macOS 26 and
        // made the top controls feel unresponsive.
        win.isMovableByWindowBackground = false
        win.toolbarStyle = .unified

        super.init(window: win)
        win.delegate = self
        titleObserver = NotificationCenter.default.addObserver(
            forName: .dshSettingsPanelDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let panel = notification.object as? SettingsPanel else { return }
            self?.updateTitle(for: panel.rawValue)
            // Selecting a row must leave the sidebar focused: otherwise the
            // row highlight stays grey after focus moved to a control in the
            // detail pane. No-op while another window is key.
            self?.focusSidebar()
        }
        appearanceObserver = NotificationCenter.default.addObserver(
            forName: DshNativeAppearance.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyNativeAppearance()
        }
    }

    deinit {
        if let titleObserver {
            NotificationCenter.default.removeObserver(titleObserver)
        }
        if let appearanceObserver {
            NotificationCenter.default.removeObserver(appearanceObserver)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func show() {
        applyNativeAppearance()
        SettingsViewModel.shared.loadFromState()
        updateTitle(for: SettingsViewModel.shared.selectedCategoryIndex)
        Task {
            await SettingsViewModel.shared.refreshCatalog()
            // Auto-follow is a startup policy and is handled by AppDelegate.
            // Opening Settings must not re-apply it after the user manually
            // selects an older installed version.
            await SettingsViewModel.shared.checkPluginUpdates()
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // SwiftUI may select the first TextField when the settings window
        // becomes key. Settings should open as a browsing surface instead of
        // immediately entering port-edit mode — but clearing focus to the
        // window itself makes AppKit mark the sidebar selection unemphasised,
        // which paints the selected row grey even while the window is key.
        // Focusing the sidebar list satisfies both: no text field takes focus,
        // and the selection keeps the accent colour. See focusSidebar().
        focusSidebar()
        DispatchQueue.main.async { [weak self] in
            self?.focusSidebar()
        }
    }

    public func updateTitle(for index: Int) {
        window?.title = SettingsPanel(rawValue: index)?.title ?? "设置"
    }

    /// Focuses the navigation split view's leading list, which is the leftmost
    /// table view in the window.
    ///
    /// The row highlight follows the list's focus, not just the window's key
    /// state: with the window as first responder AppKit reports
    /// `NSTableRowView.isEmphasized == false`, so the capsule renders grey.
    /// Falls back to the previous "clear focus" behaviour if the list cannot
    /// be located.
    private func focusSidebar() {
        guard let window, window.isKeyWindow else { return }
        guard let sidebar = Self.sidebarList(in: window) else {
            window.makeFirstResponder(nil)
            return
        }
        window.makeFirstResponder(sidebar)
    }

    private static func sidebarList(in window: NSWindow) -> NSTableView? {
        guard let contentView = window.contentView else { return nil }
        var best: (table: NSTableView, minX: CGFloat)?
        func walk(_ view: NSView) {
            if let table = view as? NSTableView {
                let minX = table.convert(table.bounds, to: nil).minX
                if best == nil || minX < best!.minX {
                    best = (table, minX)
                }
            }
            for subview in view.subviews { walk(subview) }
        }
        walk(contentView)
        return best?.table
    }

    private func applyNativeAppearance() {
        guard let window else { return }
        DshNativeAppearance.apply(to: window)
    }

}
