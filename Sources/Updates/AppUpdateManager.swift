import Combine
import Sparkle

/// The single Sparkle updater owned by the native app.
///
/// The Swift shell uses one updater instance for automatic checks, the app
/// menu, and the About settings page. DSH service versions and plugin versions
/// remain managed by their existing version managers.
public final class AppUpdateManager: ObservableObject {
    public static let shared = AppUpdateManager()

    public let updaterController: SPUStandardUpdaterController

    /// Sparkle holds its updater delegate weakly, so the install gate is owned
    /// here for the app's lifetime.
    private let updateDelegate: AppUpdateDelegate

    private init() {
        let updateDelegate = AppUpdateDelegate()
        self.updateDelegate = updateDelegate
        updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: updateDelegate,
            userDriverDelegate: nil
        )
        // M1 packages are ad-hoc signed and are not publishable Sparkle
        // artifacts. A persisted automatic-check preference can otherwise
        // launch Sparkle's SwiftUI user-driver window during application
        // startup; on macOS 26 that window currently enters an AppKit
        // safe-area constraint loop and aborts the host process. Keep manual
        // “Check for Updates” available without presenting update UI on boot.
        updaterController.updater.automaticallyChecksForUpdates = false
        updaterController.startUpdater()
    }

    public var updater: SPUUpdater {
        updaterController.updater
    }
}

/// Stops the managed service before Sparkle replaces the bundle.
///
/// Sparkle installs while the bundle is no longer running, but the install path
/// is not guaranteed to pass through `applicationWillTerminate` first: the
/// installer tool reports the pending install to the host driver when it
/// reaches its second stage, which may be after the target has already been
/// asked to terminate and may equally be before it. Owning the stop here makes
/// the update path independent of the quit path, and it is safe to do twice —
/// `DshService.stop()` takes the managed process before signalling, so a quit
/// that already ran the terminate callback leaves this a no-op.
final class AppUpdateDelegate: NSObject, SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        DshService.shared.stop()
    }
}


/// Publishes Sparkle's KVO-backed check availability for SwiftUI controls.
public final class CheckForUpdatesViewModel: ObservableObject {
    @Published public private(set) var canCheckForUpdates = false

    public init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .assign(to: &$canCheckForUpdates)
    }
}
