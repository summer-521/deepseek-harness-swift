import AppKit
import SwiftUI

/// Owns the standalone startup window. It shows only the SwiftUI startup card
/// in a small, borderless, opaque window (window-background fill) instead of
/// overlaying the large main window. The window is sized to the card and
/// centered on the visible screen; it is hidden when the main window is ready
/// to take over.
@MainActor
public final class DshStartupWindowController: NSWindowController {
    public static let shared = DshStartupWindowController()

    private var hostingController: NSHostingController<DshStartupView>?

    private static let contentSize = NSSize(width: 500, height: 440)
    private static let minimumSize = NSSize(width: 500, height: 320)

    private init() {
        let win = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // A completely normal macOS window (system rounded corners, border
        // and drop shadow) without a title: hidden title, transparent
        // titlebar, content fills to the top like the main window.
        win.title = ""
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.isOpaque = true
        win.backgroundColor = .windowBackgroundColor
        win.hasShadow = true
        win.isReleasedWhenClosed = false
        win.isMovableByWindowBackground = true

        super.init(window: win)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Present or refresh the startup card. The status model is shared with
    /// `MainWindowController`, which advances the phase/detail as launch
    /// proceeds; the view observes it directly.
    public func show(status: DshStartupStatusModel) {
        guard let win = window else { return }
        let root = DshStartupView(status: status)
        if let hostingController {
            hostingController.rootView = root
        } else {
            let hostingController = NSHostingController(rootView: root)
            win.contentViewController = hostingController
            self.hostingController = hostingController
        }

        fitWindowToContent(win)
        positionOnVisibleScreen(win)
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Hide the startup card after the main window is ready (or when recovery
    /// takes over). A later startup episode presents a fresh card again.
    public func hide() {
        window?.orderOut(nil)
    }

    /// Size the window to the SwiftUI card's ideal height (clamped to the
    /// visible screen and the configured minimum) so the card is the window,
    /// not a small card floating in a tall empty surface.
    private func fitWindowToContent(_ win: NSWindow) {
        guard let hostingController else { return }
        let fitting = hostingController.view.fittingSize
        let visibleFrame = (win.screen ?? NSScreen.main)?.visibleFrame
        let availableHeight = visibleFrame.map { $0.height } ?? Self.contentSize.height
        let contentHeight = min(max(fitting.height, Self.minimumSize.height), availableHeight)
        win.setContentSize(NSSize(width: Self.contentSize.width, height: contentHeight))
    }

    /// Center the borderless card on the visible screen.
    private func positionOnVisibleScreen(_ win: NSWindow) {
        guard let visibleFrame = (win.screen ?? NSScreen.main)?.visibleFrame else {
            win.center()
            return
        }
        var frame = win.frame
        frame.origin = NSPoint(
            x: visibleFrame.midX - frame.width / 2,
            y: visibleFrame.midY - frame.height / 2
        )
        win.setFrameOrigin(frame.origin)
    }
}
