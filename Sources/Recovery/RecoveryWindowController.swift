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

    private static let contentSize = NSSize(width: 620, height: 460)
    private static let minimumSize = NSSize(width: 620, height: 360)

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
        let root = DshRecoveryView(
            viewModel: viewModel,
            onContentHeightChange: { [weak self] height in
                self?.resizeWindow(toContentHeight: height)
            }
        )
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

        fitWindowToContent(win)
        if !hasPositionedWindow {
            positionOnVisibleScreen(win, centered: true)
            hasPositionedWindow = true
        } else {
            positionOnVisibleScreen(win, centered: false)
        }
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Size the window to the SwiftUI content's ideal height (clamped to the
    /// visible screen and the configured minimum) so the recovery card does
    /// not float inside a tall, mostly-empty window.
    private func fitWindowToContent(_ win: NSWindow) {
        guard let hostingController else { return }
        let fitting = hostingController.view.fittingSize
        let visibleFrame = (win.screen ?? NSScreen.main)?.visibleFrame
        let availableHeight = visibleFrame.map { $0.height } ?? Self.contentSize.height
        let contentHeight = min(max(fitting.height, Self.minimumSize.height), availableHeight)
        win.setContentSize(NSSize(width: Self.contentSize.width, height: contentHeight))
    }

    /// Grow or shrink the window to follow the recovery card when a disclosure
    /// expands or collapses, keeping the window's center stable and clamping
    /// the frame to the visible screen. The resize is applied immediately so
    /// the window tracks the content without a laggy animation.
    private func resizeWindow(toContentHeight height: CGFloat) {
        guard let win = window else { return }
        let visibleFrame = (win.screen ?? NSScreen.main)?.visibleFrame
        let availableHeight = visibleFrame.map { $0.height } ?? Self.contentSize.height
        let contentHeight = min(max(height, Self.minimumSize.height), availableHeight)
        let currentContentSize = win.contentRect(forFrameRect: win.frame).size
        guard abs(contentHeight - currentContentSize.height) > 1 else { return }

        let oldCenter = NSPoint(x: win.frame.midX, y: win.frame.midY)
        win.setContentSize(NSSize(width: currentContentSize.width, height: contentHeight))
        var origin = NSPoint(x: oldCenter.x - win.frame.width / 2, y: oldCenter.y - win.frame.height / 2)
        if let visibleFrame {
            origin.x = min(max(origin.x, visibleFrame.minX), visibleFrame.maxX - win.frame.width)
            origin.y = min(max(origin.y, visibleFrame.minY), visibleFrame.maxY - win.frame.height)
        }
        win.setFrameOrigin(origin)
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
            if centered { win.center() }
            return
        }

        // Use the window's current content size (already fitted by
        // fitWindowToContent) so we do not reset a content-driven height back
        // to the fixed default. A restored window can be larger than the
        // current screen (for example after moving between a laptop display
        // and a small external display). Resize the content first, then clamp
        // the complete frame; this keeps the titlebar and every control inside
        // visibleFrame.
        let currentContentSize = win.contentRect(forFrameRect: win.frame).size
        let frameForContent = win.frameRect(
            forContentRect: NSRect(origin: .zero, size: currentContentSize)
        )
        let horizontalFrameInset = max(0, frameForContent.width - currentContentSize.width)
        let verticalFrameInset = max(0, frameForContent.height - currentContentSize.height)
        let contentSize = NSSize(
            width: min(currentContentSize.width, max(1, visibleFrame.width - horizontalFrameInset)),
            height: min(currentContentSize.height, max(1, visibleFrame.height - verticalFrameInset))
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
