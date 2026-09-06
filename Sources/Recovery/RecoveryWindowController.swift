import AppKit
import SwiftUI

/// Owns the standalone recovery window. Keeping this surface outside the
/// shared WebView window makes it impossible for an unready WebView to show
/// through recovery card margins or receive recovery-window input.
@MainActor
public final class DshRecoveryWindowController: NSWindowController, NSWindowDelegate {
    public static let shared = DshRecoveryWindowController()

    private var hostingController: NSHostingController<DshRecoveryView>?
    private var hasPositionedWindow = false

    private static let contentSize = NSSize(width: 760, height: 680)
    private static let minimumSize = NSSize(width: 700, height: 480)

    private init() {
        let win = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "DSH 启动恢复"
        win.titleVisibility = .visible
        win.titlebarAppearsTransparent = false
        win.isOpaque = true
        win.backgroundColor = .windowBackgroundColor
        win.minSize = Self.minimumSize
        win.isReleasedWhenClosed = false
        win.hasShadow = true
        // AppKit's native titlebar owns movement. Do not make the content
        // background draggable, so buttons and text keep ordinary hit tests.
        win.isMovableByWindowBackground = false

        super.init(window: win)
        win.delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Present or refresh the existing recovery window without changing its
    /// user-selected position during a single recovery episode.
    public func show(viewModel: DshRecoveryViewModel) {
        guard let win = window else { return }
        let root = DshRecoveryView(viewModel: viewModel)
        if let hostingController {
            hostingController.rootView = root
        } else {
            let hostingController = NSHostingController(rootView: root)
            hostingController.view.setAccessibilityElement(true)
            hostingController.view.setAccessibilityRole(.group)
            hostingController.view.setAccessibilityLabel("DSH 启动恢复：重试、打开设置或安全模式")
            win.contentViewController = hostingController
            self.hostingController = hostingController
        }

        if !hasPositionedWindow {
            positionOnVisibleScreen(win, centered: true)
            hasPositionedWindow = true
        } else {
            positionOnVisibleScreen(win, centered: false)
        }
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Close the recovery surface after the recovery owner has transitioned
    /// to another lifecycle state. The next recovery episode is centered
    /// again and receives a fresh hosting root.
    public func hide() {
        window?.orderOut(nil)
        window?.contentViewController = nil
        hostingController = nil
        hasPositionedWindow = false
    }

    /// Closing the recovery window hides it without revealing the main window.
    /// Dock reopen is handled by MainWindowController, which re-presents the
    /// current recovery model when recovery is still unresolved.
    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    private func positionOnVisibleScreen(_ win: NSWindow, centered: Bool) {
        guard let visibleFrame = (win.screen ?? NSScreen.main)?.visibleFrame else {
            win.minSize = Self.minimumSize
            win.setContentSize(Self.contentSize)
            if centered { win.center() }
            return
        }

        // A restored window can be larger than the current screen (for
        // example after moving between a laptop display and a small external
        // display). Resize the content first, then clamp the complete frame;
        // this keeps the titlebar and every control inside visibleFrame.
        let frameForDefaultContent = win.frameRect(
            forContentRect: NSRect(origin: .zero, size: Self.contentSize)
        )
        let horizontalFrameInset = max(0, frameForDefaultContent.width - Self.contentSize.width)
        let verticalFrameInset = max(0, frameForDefaultContent.height - Self.contentSize.height)
        let contentSize = NSSize(
            width: min(Self.contentSize.width, max(1, visibleFrame.width - horizontalFrameInset)),
            height: min(Self.contentSize.height, max(1, visibleFrame.height - verticalFrameInset))
        )
        let minimumSize = NSSize(
            width: min(Self.minimumSize.width, contentSize.width),
            height: min(Self.minimumSize.height, contentSize.height)
        )
        win.minSize = minimumSize
        win.setContentSize(contentSize)

        var frame = win.frame
        if centered {
            frame.origin = NSPoint(
                x: visibleFrame.midX - frame.width / 2,
                y: visibleFrame.midY - frame.height / 2
            )
        }
        frame.origin.x = min(
            max(frame.origin.x, visibleFrame.minX),
            visibleFrame.maxX - frame.width
        )
        frame.origin.y = min(
            max(frame.origin.y, visibleFrame.minY),
            visibleFrame.maxY - frame.height
        )
        win.setFrameOrigin(frame.origin)
    }
}
