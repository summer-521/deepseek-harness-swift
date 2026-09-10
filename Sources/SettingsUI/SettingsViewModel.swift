import Foundation
import AppKit
import SwiftUI
import Combine

public extension Notification.Name {
    static let dshSettingsPanelDidChange = Notification.Name("dsh.settingsPanelDidChange")
}

private enum DshRuntimeUpdateFailure: LocalizedError {
    case candidateInstall(version: String, detail: String)
    case runtimeStartup(version: String, detail: String)

    var errorDescription: String? {
        switch self {
        case .candidateInstall(let version, let detail):
            return "candidate Runtime \(version) 安装失败，当前仍使用原版本：\(detail)"
        case .runtimeStartup(let version, let detail):
            return "新 Runtime \(version) 启动或健康检查失败，已尝试恢复旧版本：\(detail)"
        }
    }
}

private enum DshSettingsUIMessage {
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

/// The settings surface deliberately exposes transaction stages, not made-up
/// percentages.  `prepared` is shown as preparation because the coordinator
/// has established its durable baseline and has not started package mutation.
public enum DshPluginOperationDisplayPhase: Equatable, Sendable {
    case preparing
    case changing(action: DshPluginOperationAction)
    case verifying
    case restoring
    case completed
    case recoveryRequired

    public var title: String {
        switch self {
        case .preparing: return "准备插件操作"
        case .changing(let action):
            switch action {
            case .install: return "正在安装插件"
            case .update: return "正在更新插件"
            case .updateAll: return "正在更新全部插件"
            case .remove: return "正在卸载插件"
            }
        case .verifying: return "正在验证插件状态"
        case .restoring: return "正在恢复原插件状态"
        case .completed: return "插件操作完成"
        case .recoveryRequired: return "插件操作需要恢复"
        }
    }

    public var systemImage: String {
        switch self {
        case .preparing: return "hourglass"
        case .changing: return "arrow.triangle.2.circlepath"
        case .verifying: return "checkmark.shield"
        case .restoring: return "arrow.uturn.backward.circle"
        case .completed: return "checkmark.circle.fill"
        case .recoveryRequired: return "exclamationmark.triangle.fill"
        }
    }
}

/// The outcome is separate from the phase so a failed mutation that was
/// safely rolled back can be distinguished from an unresolved or externally
/// modified Profile.
public enum DshPluginOperationOutcome: Equatable, Sendable {
    case succeeded
    case restored
    case recoveryRequired
    case externalModification

    public var title: String {
        switch self {
        case .succeeded: return "已完成"
        case .restored: return "操作失败，已恢复原插件状态"
        case .recoveryRequired: return "操作失败，仍需恢复"
        case .externalModification: return "检测到外部修改，未覆盖当前状态"
        }
    }

    public var systemImage: String {
        switch self {
        case .succeeded: return "checkmark.circle.fill"
        case .restored: return "arrow.uturn.backward.circle.fill"
        case .recoveryRequired: return "exclamationmark.triangle.fill"
        case .externalModification: return "hand.raised.fill"
        }
    }
}

/// The plugin list deliberately keeps the four operational categories visible
/// even when the user is searching.  `exception` is derived from the latest
/// read-only inspector result and never inferred from a pnpm exit code.
public enum DshPluginListCategory: String, CaseIterable, Identifiable, Sendable {
    case managed = "受管理"
    case local = "本地"
    case regular = "普通"
    case exception = "异常"

    public var id: String { rawValue }
}

/// A retry is an in-memory UI affordance, not a second durable transaction.
/// The coordinator creates a fresh operation ID when the retry is accepted.
public struct DshPluginRetryRequest: Equatable, Sendable {
    public let action: DshPluginOperationAction
    public let targetPackage: String?

    public init(action: DshPluginOperationAction, targetPackage: String? = nil) {
        self.action = action
        self.targetPackage = targetPackage
    }
}

private extension DshPluginOperationAction {
    var settingsPreparationDetail: String {
        switch self {
        case .install: return "正在准备安装事务…"
        case .update: return "正在准备更新事务…"
        case .updateAll: return "正在准备批量更新事务…"
        case .remove: return "正在准备卸载事务…"
        }
    }
}

@MainActor
public final class SettingsViewModel: ObservableObject {
    public static let shared = SettingsViewModel()
    private static let selectedPanelDefaultsKey = "dsh.settings.selectedPanel"

    @Published public var availableVersions: [DshVersionItem] = []
    @Published public var installedVersions: [String] = []
    @Published public var selectedVersion: String? = nil
    @Published public var selectedCategoryIndex: Int = 0
    @Published public var latestVersion: String? = nil
    @Published public var nextVersion: String? = nil
    @Published public var alphaVersion: String? = nil
    @Published public var autoFollowLatest: Bool = false
    @Published public var runtimeChannel: DshRuntimeChannel = .latest
    @Published public var npmRegistry: String = DshVersionManager.defaultRegistry
    @Published public var appProfile: DshAppProfile = .desktop
    @Published public var dshPort: Int = 3080
    @Published public var browserAccessEnabled: Bool = false
    @Published public var networkExposure: DshNetworkExposure = .loopback
    @Published public var isUpdatingBrowserAccess: Bool = false
    @Published public var isUpdatingNetworkExposure: Bool = false
    @Published public private(set) var lanURL: URL?
    @Published public var isLoadingLANURL: Bool = false
    @Published public var isOpeningBrowser: Bool = false
    @Published public var uiTheme: String = "default"
    @Published public private(set) var externalTheme: String?

    @Published public var installedPlugins: [DshPluginItem] = []
    @Published public var outdatedPluginsMap: [String: String] = [:]
    @Published public var pluginSearchText: String = ""
    @Published public var pluginExceptionsOnly: Bool = false
    @Published public private(set) var pluginInspectionResult: DshPluginInspectionResult?
    @Published public private(set) var isInspectingPlugins = false
    @Published public private(set) var pluginInspectionMessage: String?

    @Published public var isInstallingVersion: Bool = false
    @Published public var isUpdatingRuntime: Bool = false
    /// A failed Runtime rollback remains blocked until startup recovery has
    /// verified the previous Runtime. Keeping this published prevents the
    /// Profile picker from becoming active when the update task has already
    /// returned an error.
    @Published public private(set) var isRuntimeRecoveryPending: Bool = false
    @Published public var installingVersionName: String? = nil
    @Published public var installProgressPhase: String = ""
    @Published public var installProgressDetail: String? = nil

    @Published public var isLoadingCatalog: Bool = false
    @Published public var isRefreshingPlugins: Bool = false
    @Published public var isCheckingPluginUpdates: Bool = false
    @Published public var isOperatingPlugin: Bool = false
    @Published public var isSwitchingProfile: Bool = false
    @Published public var operatingPluginName: String? = nil
    @Published public private(set) var pendingPluginInstallSpec: String? = nil
    @Published public private(set) var pendingPluginUpdate: DshPendingPluginUpdate? = nil
    @Published public private(set) var pendingPluginDowngrade: DshPendingPluginDowngrade? = nil
    @Published public private(set) var pluginOperationProgressText: String? = nil
    @Published public var pluginStatusMessage: String? = nil
    @Published public private(set) var pluginOperationPhase: DshPluginOperationDisplayPhase?
    @Published public private(set) var pluginOperationOutcome: DshPluginOperationOutcome?
    @Published public private(set) var pluginOperationDetail: String?
    @Published public private(set) var retryablePluginOperation: DshPluginRetryRequest?
    @Published public var alertMessage: String? = nil

    /// Plugin and ordinary settings mutations are suspended while a recovery
    /// transaction is unresolved or the service is serving an isolated
    /// recovery Profile. A confirmed Runtime is intentionally allowed here:
    /// its previous install is retained only until the next healthy-start
    /// cleanup, and must not freeze unrelated controls in the meantime.
    public var pluginMutationsAllowed: Bool {
        let state = DshStateManager.shared.current
        guard DshStateManager.shared.loadResult.isUsable,
              DshRuntimeMutationGate.allowsPluginMutation(state) else { return false }
        let coordinator = DshPluginOperationCoordinator.shared
        guard !MainWindowController.shared.hasUnresolvedRecovery,
              coordinator.pendingOperation == nil,
              !coordinator.hasPersistedOperationRecord else { return false }
        return MainWindowController.shared.currentLaunchContext?.purpose != .recovery
    }

    /// A confirmed Runtime still retains its previous install until a second
    /// healthy start. Keep that cleanup safety window from accepting another
    /// Runtime update, which would replace the recorded previous descriptor.
    /// Plugin and ordinary settings mutations remain available during it.
    public var runtimeUpdateAllowed: Bool {
        let state = DshStateManager.shared.current
        return pluginMutationsAllowed
            && state.appProfile == .desktop
            && appProfile == .desktop
            && DshRuntimeMutationGate.allowsRuntimeUpdate(state)
    }

    /// Plugin writes are intentionally narrower than the general settings
    /// mutation gate.  The web Profile is shared with `dsh web`, so Settings
    /// may inspect it and may switch back to desktop, but it must never
    /// install, update, or remove packages in that shared tree.
    public var pluginWritesAllowed: Bool {
        pluginMutationsAllowed
            && DshStateManager.shared.current.appProfile == .desktop
            && appProfile == .desktop
    }

    /// Keep the reason next to the disabled controls so the user can tell a
    /// shared web Profile from a generic recovery/operation lock.
    public var pluginMutationUnavailableReason: String? {
        guard !pluginWritesAllowed else { return nil }
        let state = DshStateManager.shared.current
        if state.appProfile == .web || appProfile == .web {
            return "当前为 web Profile：与终端 dsh web 共享插件目录，插件安装、更新和卸载已禁用；请切回 desktop Profile。"
        }
        if !pluginMutationsAllowed {
            return "插件写操作暂不可用，请先完成当前恢复或正在进行的操作。"
        }
        return "插件写操作暂不可用。"
    }

    /// The filtered view is derived from the current list and the latest
    /// inspector result, so filtering stays read-only and cannot mutate the
    /// Profile. Search covers the fields users can actually recognize in the
    /// row: package name, version and description.
    public var filteredInstalledPlugins: [DshPluginItem] {
        let query = pluginSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return installedPlugins.filter { plugin in
            if pluginExceptionsOnly && pluginCategory(for: plugin) != .exception {
                return false
            }
            guard !query.isEmpty else { return true }
            return [plugin.name, plugin.version, plugin.description]
                .compactMap { $0 }
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    public func plugins(in category: DshPluginListCategory) -> [DshPluginItem] {
        filteredInstalledPlugins.filter { pluginCategory(for: $0) == category }
    }

    public func pluginCategory(for plugin: DshPluginItem) -> DshPluginListCategory {
        if isPluginException(plugin) { return .exception }
        if plugin.isManaged { return .managed }
        if plugin.isLocal { return .local }
        return .regular
    }

    /// A retry is safe only after the previous operation reached a terminal
    /// UI result that proves rollback completed.  A committed record, a
    /// recoveryRequired record, a corrupt record, or a pending age override
    /// must make the affordance disappear. The actual attempt always uses the
    /// normal release-age policy and can therefore reopen the one-time
    /// confirmation if npm rejects it again.
    public var canRetryPluginOperation: Bool {
        guard pluginOperationPhase == .completed,
              pluginOperationOutcome == .restored,
              retryablePluginOperation != nil,
              pendingPluginInstallSpec == nil,
              pendingPluginUpdate == nil,
              pendingPluginDowngrade == nil,
              !isOperatingPlugin,
              !isSwitchingProfile else { return false }
        guard case .absent = DshPluginOperationCoordinator.shared.persistedStatus else {
            return false
        }
        return pluginWritesAllowed
    }

    public func retryLastPluginOperation() {
        guard canRetryPluginOperation, let request = retryablePluginOperation else {
            return
        }
        let accepted: Bool
        switch request.action {
        case .install:
            guard let spec = request.targetPackage else { return }
            accepted = startPluginInstall(spec: spec, ignoringMinimumReleaseAge: false)
        case .update:
            guard let name = request.targetPackage else { return }
            accepted = startPluginUpdate(name: name, ignoringMinimumReleaseAge: false)
        case .updateAll:
            accepted = startPluginUpdateAll(ignoringMinimumReleaseAge: false)
        case .remove:
            guard let name = request.targetPackage else { return }
            accepted = startPluginRemove(name: name)
        }
        if accepted {
            retryablePluginOperation = nil
        }
    }

    private func isPluginException(_ plugin: DshPluginItem) -> Bool {
        guard let result = pluginInspectionResult else { return false }
        return result.items.contains { item in
            guard item.name == plugin.name else { return false }
            switch item.status {
            case .healthy, .disabled:
                return false
            case .missingPackage, .notComposed, .patchReferenceMissing,
                 .duplicateBundle, .unavailable, .uncertain:
                return true
            }
        }
    }

    private func markRetryablePluginOperation(
        action: DshPluginOperationAction,
        targetPackage: String?
    ) {
        guard pluginOperationPhase == .completed,
              pluginOperationOutcome == .restored,
              pendingPluginInstallSpec == nil,
              pendingPluginUpdate == nil,
              case .absent = DshPluginOperationCoordinator.shared.persistedStatus else {
            retryablePluginOperation = nil
            return
        }
        retryablePluginOperation = DshPluginRetryRequest(
            action: action,
            targetPackage: targetPackage
        )
    }

    private func clearRetryablePluginOperation() {
        retryablePluginOperation = nil
    }

    private var isFollowingLatest = false
    private var catalogRequestGeneration = 0
    private var pluginUpdateRequestGeneration = 0
    private struct OutdatedPluginsContext: Equatable {
        let profile: DshAppProfile
        let registry: String
    }
    private var outdatedPluginsContext: OutdatedPluginsContext?
    private var pluginStatusDismissTask: Task<Void, Never>?
    private var pluginStatusGeneration = 0
    private var pluginOperationProgressTask: Task<Void, Never>?
    private var lastPluginOperationProgressUpdate = Date.distantPast
    private var pluginOperationDismissTask: Task<Void, Never>?
    private var pluginOperationDisplayGeneration = 0

    private var currentAppVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
    }

    /// Capture the desktop launch boundary once, while the caller owns
    /// MainWindowController's wider Runtime/Profile operation gate. Plugin
    /// mutations never follow the currently selected Profile after this
    /// point, and recovery/web contexts are rejected before any service stop.
    private func makeDesktopPluginOperationContext() throws -> DshLaunchContext {
        let state = DshStateManager.shared.current
        guard state.appProfile == .desktop,
              let context = DshLaunchContext.makeStartup(from: state),
              context.profile == .desktop,
              context.purpose == .normal else {
            throw DshPluginOperationError.desktopProfileRequired
        }
        try context.validate()
        return context
    }

    /// Execute one desktop plugin mutation through the durable P01
    /// coordinator. The ordinary restart path is the health gate for both
    /// the new tree and a restored baseline; no UI success state is published
    /// until `perform` has reached `committed`.
    private func executeDesktopPluginOperation(
        context: DshLaunchContext,
        action: DshPluginOperationAction,
        targetPackage: String? = nil,
        targetPackages: [String] = [],
        ignoringMinimumReleaseAge: Bool = false
    ) async throws -> DshPluginOperationResult {
        guard context.isFresh(in: DshStateManager.shared.current) else {
            throw DshLaunchContextError.staleContext
        }
        let request = DshPluginOperationRequest(
            action: action,
            profile: .desktop,
            profileDirectory: context.profileDirectory,
            targetPackage: targetPackage,
            targetPackages: targetPackages
        )
        // Plugin update checks and mutations follow the registry selected in
        // Settings.  The active Runtime descriptor may still carry the
        // registry used to install that Runtime, so using it here could
        // apply a stale update result to a different Registry.
        let registry = DshVersionManager.normalizedRegistry(npmRegistry)
        guard registry == DshVersionManager.normalizedRegistry(
            DshStateManager.shared.current.npmRegistry
        ) else {
            throw DshLaunchContextError.staleContext
        }
        let hooks = DshPluginOperationHooks(
            prepareForMutation: {
                // Use the complete Profile mutation boundary: it stops the
                // managed child, reaps an orphaned process, and confirms the
                // selected port is safe before the snapshot is taken.
                try await DshService.shared.prepareForProfileMutation(context: context)
            },
            mutate: { request in
                switch request.action {
                case .install:
                    guard let spec = request.targetPackage else {
                        throw DshPluginOperationError.recoveryRequired("安装事务缺少插件 spec")
                    }
                    try await DshPluginManager.shared.addPlugin(
                        spec: spec,
                        ignoringMinimumReleaseAge: ignoringMinimumReleaseAge,
                        profileDirectory: request.profileDirectory,
                        profile: request.profile,
                        registry: registry,
                        progress: { line in
                            Task { @MainActor in
                                self.notePluginOperationProgress(line)
                            }
                        },
                    )
                case .update:
                    guard let name = request.targetPackage else {
                        throw DshPluginOperationError.recoveryRequired("更新事务缺少插件名称")
                    }
                    try await DshPluginManager.shared.updatePlugin(
                        name: name,
                        ignoringMinimumReleaseAge: ignoringMinimumReleaseAge,
                        profileDirectory: request.profileDirectory,
                        profile: request.profile,
                        registry: registry,
                        progress: { line in
                            Task { @MainActor in
                                self.notePluginOperationProgress(line)
                            }
                        },
                    )
                case .updateAll:
                    try await DshPluginManager.shared.updateAllPlugins(
                        packageNames: request.targetPackages,
                        ignoringMinimumReleaseAge: ignoringMinimumReleaseAge,
                        profileDirectory: request.profileDirectory,
                        profile: request.profile,
                        registry: registry,
                        progress: { line in
                            Task { @MainActor in
                                self.notePluginOperationProgress(line)
                            }
                        },
                    )
                case .remove:
                    guard let name = request.targetPackage else {
                        throw DshPluginOperationError.recoveryRequired("卸载事务缺少插件名称")
                    }
                    try await DshPluginManager.shared.removePlugin(
                        name: name,
                        profileDirectory: request.profileDirectory,
                        profile: request.profile,
                        registry: registry
                    )
                }
            },
            verify: { _ in
                _ = try await MainWindowController.shared
                    .restartDshServiceWithAuthenticationRecoveryDuringOperation(context: context)
            },
            verifyRestored: { _ in
                _ = try await MainWindowController.shared
                    .restartDshServiceWithAuthenticationRecoveryDuringOperation(context: context)
            }
        )
        let coordinator = DshPluginOperationCoordinator.shared
        let result = try await coordinator.perform(request, hooks: hooks)
        guard result.phase == .committed else {
            throw DshPluginOperationError.recoveryRequired("插件事务未提交")
        }
        // The verify hook above has completed an ordinary desktop health
        // start. Clear the retained commit record before publishing success,
        // otherwise the mutation gate would leave every subsequent plugin
        // action disabled until the whole app was restarted. A force-quit
        // before this cleanup still leaves the durable committed record for
        // startup recovery to finalize.
        do {
            try await coordinator.finalizeCommittedOperation(operationID: result.operationID)
        } catch {
            // A committed mutation is already live; only its app-owned
            // snapshot cleanup failed. Keep the owner ID and hand the error
            // to MainWindowController so the next retry uses the native
            // plugin-recovery/diagnostic path instead of a generic failure.
            MainWindowController.shared.markCommittedPluginCleanupFailure(
                operationID: result.operationID,
                error: error
            )
            throw error
        }
        return result
    }

    private func pluginOperationFailureMessage(
        actionDescription: String,
        error: Error
    ) -> String {
        let safeError = DshSettingsUIMessage.safe(error)
        if let pending = DshPluginOperationCoordinator.shared.pendingOperation {
            if pending.requiresRecovery {
                return "\(actionDescription)失败，自动恢复未完成，事务已保留，请重启 DSH 后继续恢复：\(safeError)"
            }
            if pending.phase == .committed {
                return "\(actionDescription)已提交，但事务快照尚未清理，请重启 DSH 后继续插件恢复：\(safeError)"
            }
        }
        if let operationError = error as? DshPluginOperationError {
            switch operationError {
            case .recoveryRequired, .externalModification, .operationInterruptedDuringMutation:
                return "\(actionDescription)失败，自动恢复未完成，事务已保留，请重启 DSH 后继续恢复：\(safeError)"
            default:
                break
            }
        }
        return "\(actionDescription)失败，已恢复原插件状态：\(safeError)"
    }

    /// The coordinator intentionally has no UI dependency. Polling its
    /// read-only durable record lets the settings view follow real phase
    /// transitions, including the small window before `prepared` is written.
    private func beginPluginOperationProgress(action: DshPluginOperationAction) {
        pluginOperationDisplayGeneration &+= 1
        pluginOperationDismissTask?.cancel()
        pluginOperationDismissTask = nil
        pluginOperationProgressTask?.cancel()
        pluginOperationProgressTask = nil
        pluginOperationPhase = .preparing
        pluginOperationOutcome = nil
        pluginOperationDetail = nil
        pluginOperationProgressText = nil
        lastPluginOperationProgressUpdate = .distantPast

        pluginOperationProgressTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let coordinator = DshPluginOperationCoordinator.shared
                if let operation = coordinator.pendingOperation {
                    self.applyPluginOperationState(operation)
                } else if !self.isOperatingPlugin {
                    // A startup recovery or another owner can clear the
                    // durable record after the local operation has finished.
                    // While `isOperatingPlugin` is true, absence is the normal
                    // preparation window before the coordinator persists its
                    // first record; clearing here would hide progress and
                    // cancel this polling task before it observes mutating.
                    self.synchronizePersistedPluginOperationState()
                }
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
        }
        // The first read is useful when snapshot creation has already
        // completed before SwiftUI gets its next rendering pass.
        if let operation = DshPluginOperationCoordinator.shared.pendingOperation {
            applyPluginOperationState(operation)
        } else {
            pluginOperationDetail = action.settingsPreparationDetail
        }
    }

    private func applyPluginOperationState(_ operation: DshPluginOperationState) {
        switch operation.phase {
        case .prepared:
            pluginOperationPhase = .preparing
            pluginOperationOutcome = nil
        case .mutating:
            pluginOperationPhase = .changing(action: operation.action)
            pluginOperationOutcome = nil
        case .verifying:
            pluginOperationPhase = .verifying
            pluginOperationOutcome = nil
        case .committed:
            pluginOperationPhase = .completed
            pluginOperationOutcome = .succeeded
        case .restoring:
            pluginOperationPhase = .restoring
            pluginOperationOutcome = nil
        case .recoveryRequired:
            pluginOperationPhase = .recoveryRequired
            pluginOperationOutcome = operation.lastError?.contains("外部修改") == true
                ? .externalModification
                : .recoveryRequired
        }
        pluginOperationDetail = operation.lastError.map(DshSettingsUIMessage.safe)
    }

    /// Reconcile the in-memory settings banner with the durable P01 owner
    /// record after startup recovery or post-health finalization. The record
    /// can disappear after a committed operation is finalized; in that case
    /// retain an already-published terminal banner until its normal dismissal
    /// rather than resurrecting or clearing an active verifying state.
    public func synchronizePersistedPluginOperationState() {
        let coordinator = DshPluginOperationCoordinator.shared
        switch coordinator.persistedStatus {
        case .loaded(let operation):
            pluginOperationDismissTask?.cancel()
            pluginOperationDismissTask = nil
            applyPluginOperationState(operation)
            if operation.phase == .committed {
                // A retained commit is a success even before its snapshot is
                // removed by the extra ordinary health-start check.
                schedulePluginOperationSuccessDismissal()
            }

        case .corrupt(let detail):
            finishPluginOperationProgress()
            pluginOperationDisplayGeneration &+= 1
            pluginOperationDismissTask?.cancel()
            pluginOperationDismissTask = nil
            pluginOperationPhase = .recoveryRequired
            pluginOperationOutcome = .recoveryRequired
            pluginOperationDetail = DshSettingsUIMessage.safe(detail)
            clearRetryablePluginOperation()

        case .absent:
            // A terminal result is owned by the UI for its short display
            // lifetime, not by the file that has just been finalized. An
            // active phase, however, must never survive record cleanup.
            guard pluginOperationPhase == .completed,
                  pluginOperationOutcome == .succeeded || pluginOperationOutcome == .restored else {
                finishPluginOperationProgress()
                pluginOperationDisplayGeneration &+= 1
                pluginOperationDismissTask?.cancel()
                pluginOperationDismissTask = nil
                pluginOperationPhase = nil
                pluginOperationOutcome = nil
                pluginOperationDetail = nil
                clearRetryablePluginOperation()
                return
            }
        }
    }

    private func finishPluginOperationProgress() {
        pluginOperationProgressTask?.cancel()
        pluginOperationProgressTask = nil
        pluginOperationProgressText = nil
    }

    /// A release-age prompt raised by the read-only resolver is not a failed
    /// P01 operation. Clear transient progress so the confirmation can appear
    /// immediately, without showing a misleading rollback result.
    private func finishPluginUpdatePreflight(_ pending: DshPendingPluginUpdate) {
        isOperatingPlugin = false
        operatingPluginName = nil
        pluginOperationDisplayGeneration &+= 1
        pluginOperationDismissTask?.cancel()
        pluginOperationDismissTask = nil
        finishPluginOperationProgress()
        pluginOperationPhase = nil
        pluginOperationOutcome = nil
        pluginOperationDetail = nil
        clearRetryablePluginOperation()
        pendingPluginUpdate = pending
    }

    private func schedulePluginOperationSuccessDismissal() {
        pluginOperationDisplayGeneration &+= 1
        let generation = pluginOperationDisplayGeneration
        pluginOperationDismissTask?.cancel()
        pluginOperationDismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled,
                  let self,
                  self.pluginOperationDisplayGeneration == generation,
                  self.pluginOperationPhase == .completed,
                  self.pluginOperationOutcome == .succeeded,
                  !self.isOperatingPlugin else { return }
            self.pluginOperationPhase = nil
            self.pluginOperationOutcome = nil
            self.pluginOperationDetail = nil
            self.pluginOperationDismissTask = nil
        }
    }

    private func finishPluginOperationSuccessfully(_ detail: String) {
        finishPluginOperationProgress()
        pluginOperationPhase = .completed
        pluginOperationOutcome = .succeeded
        pluginOperationDetail = detail
        schedulePluginOperationSuccessDismissal()
    }

    private func finishPluginOperationFailed(actionDescription: String, error: Error) {
        pluginOperationDisplayGeneration &+= 1
        pluginOperationDismissTask?.cancel()
        pluginOperationDismissTask = nil
        let pending = DshPluginOperationCoordinator.shared.pendingOperation
        let outcome: DshPluginOperationOutcome
        if let operationError = error as? DshPluginOperationError,
           case .externalModification = operationError {
            outcome = .externalModification
        } else if pending?.lastError?.contains("外部修改") == true {
            outcome = .externalModification
        } else if pending?.phase == .committed {
            // The package mutation succeeded; only owner/snapshot cleanup
            // remains. This is an unresolved plugin transaction, not a
            // rollback result, so the UI must route it to recovery/diagnosis.
            outcome = .recoveryRequired
        } else if pending?.requiresRecovery == true {
            outcome = .recoveryRequired
        } else if let operationError = error as? DshPluginOperationError {
            switch operationError {
            case .recoveryRequired, .operationInterruptedDuringMutation, .persistenceConflict:
                outcome = .recoveryRequired
            default:
                outcome = .restored
            }
        } else {
            outcome = .restored
        }

        finishPluginOperationProgress()
        switch outcome {
        case .externalModification, .recoveryRequired:
            pluginOperationPhase = .recoveryRequired
        case .restored:
            pluginOperationPhase = .completed
        case .succeeded:
            pluginOperationPhase = .completed
        }
        pluginOperationOutcome = outcome
        let safeError = DshSettingsUIMessage.safe(error)
        pluginOperationDetail = "\(actionDescription)：\(safeError)"
    }

    /// After a failed plugin operation that left no durable recovery record,
    /// the pre-mutation service stop may not have been undone (snapshot
    /// capacity, stale Profile digest and similar failures happen after the
    /// stop but before any record exists). Bring the service back so the app
    /// stays usable. Operations with a durable record stay down until the
    /// user resolves them on the recovery surface.
    private func restoreServiceAfterFailedPluginOperationIfNeeded() {
        guard DshPluginOperationCoordinator.shared.pendingOperation == nil,
              !MainWindowController.shared.hasUnresolvedRecovery,
              !DshService.shared.isServiceRunning else { return }
        Task { @MainActor in
            do {
                try await MainWindowController.shared.restartDshService()
                showPluginStatus("插件操作失败，DSH 服务已自动恢复")
            } catch {
                self.alertMessage = "插件操作失败后尝试恢复 DSH 服务失败：\(DshSettingsUIMessage.safe(error))"
            }
        }
    }

    private init() {
        if let savedPanel = UserDefaults.standard.object(forKey: Self.selectedPanelDefaultsKey) as? Int,
           SettingsPanel(rawValue: savedPanel) != nil {
            self.selectedCategoryIndex = savedPanel
        }
        loadFromState()
    }

    public func rememberSelectedPanel(_ panel: SettingsPanel) {
        selectedCategoryIndex = panel.rawValue
        UserDefaults.standard.set(panel.rawValue, forKey: Self.selectedPanelDefaultsKey)
        NotificationCenter.default.post(name: .dshSettingsPanelDidChange, object: panel)
    }

    public func loadFromState() {
        let state = DshStateManager.shared.current
        let hasPendingRuntimeRecovery = state.runtimeState.pending != nil
        let transactionProfile = state.runtimeState.profile
        let effectiveProfile = hasPendingRuntimeRecovery ? transactionProfile : state.appProfile
        if hasPendingRuntimeRecovery, state.appProfile != transactionProfile {
            // This can only be encountered when an older build persisted a
            // profile switch while rollback was pending. Repair it before any
            // service launch so the retained snapshot is restored only to its
            // owning Profile.
            DshStateManager.shared.update { state in
                guard state.runtimeState.pending != nil,
                      state.runtimeState.profile == transactionProfile else { return }
                state.appProfile = transactionProfile
            }
            self.alertMessage = "检测到未完成的 Runtime 回滚，已切回 \(transactionProfile.rawValue) Profile 以保护 Profile 数据。"
        }
        self.selectedVersion = DshVersionManager.shared.ensureSelection()
        self.appProfile = effectiveProfile
        self.isRuntimeRecoveryPending = hasPendingRuntimeRecovery
        self.runtimeChannel = state.runtimeState.channel
        self.autoFollowLatest = self.appProfile == .desktop
            && self.runtimeChannel == .latest
            && state.runtimeState.updatePolicy == .automaticStable
        self.npmRegistry = state.npmRegistry ?? DshVersionManager.defaultRegistry
        self.dshPort = state.dshPort ?? 3080
        self.browserAccessEnabled = state.browserAccessEnabled
        self.networkExposure = state.networkExposure
        if state.networkExposure != .lan { self.lanURL = nil }
        self.uiTheme = state.uiTheme
        let settingsProfileDirectory = DshLaunchContext.profileDirectory(for: effectiveProfile)
        self.externalTheme = DshPluginManager.shared.detectExternalTheme(at: settingsProfileDirectory)
        self.installedVersions = DshVersionManager.shared.listInstalledVersions()
        if outdatedPluginsContext?.profile != effectiveProfile
            || outdatedPluginsContext?.registry
                != DshVersionManager.normalizedRegistry(self.npmRegistry) {
            invalidateOutdatedPlugins(refreshList: false)
        }
        self.installedPlugins = DshPluginManager.shared.listPlugins(
            at: settingsProfileDirectory,
            outdatedMap: validOutdatedPluginsMap(
                profile: effectiveProfile,
                registry: self.npmRegistry
            )
        )
        synchronizePersistedPluginOperationState()

        if let diagnostic = DshStateManager.shared.current.runtimeState.lastDiagnostic {
            self.alertMessage = diagnostic
            DshStateManager.shared.update { $0.runtimeState.lastDiagnostic = nil }
        }
    }

    private func syncRuntimeRecoveryState() {
        isRuntimeRecoveryPending = DshStateManager.shared.current.runtimeState.pending != nil
    }

    /// Recover a Profile switch that was interrupted by force-quitting the
    /// app, a crash, or a failed in-process restore. The persisted
    /// `appProfile` is the target while a switch is in flight, so startup must
    /// always return to the Profile that was healthy before the transaction.
    /// Cleanup is limited to the web bridge artifacts owned by this app; user
    /// plugins and shared credentials are never removed.
    public func recoverPendingProfileSwitch() async throws {
        let state = DshStateManager.shared.current
        guard let transaction = state.pendingProfileSwitch else { return }
        let capturedRegistry = DshVersionManager.normalizedRegistry(state.npmRegistry)

        // When leaving web, the desktop target is already healthy once the
        // transaction reaches finalizing; only the source cleanup remains.
        // Before that point, keep the original web Profile intact so it can
        // still be restored safely.
        let targetWasHealthy = transaction.phase == .finalizing
            && state.appProfile == transaction.to
        let restoreProfile = targetWasHealthy ? transaction.to : transaction.from
        let requiresWebCleanup = transaction.to == .web
            || (transaction.from == .web && transaction.to == .desktop && targetWasHealthy)

        // Make the safe Profile durable before touching the shared web tree.
        // If cleanup is interrupted, the next launch still starts the known
        // healthy Profile and retries only the app-owned cleanup.
        try DshStateManager.shared.updateOrThrow { state in
            guard state.pendingProfileSwitch == transaction else { return }
            state.appProfile = restoreProfile
        }
        self.appProfile = restoreProfile
        self.isSwitchingProfile = false

        var cleanupError: Error?
        if requiresWebCleanup {
            do {
                try await DshPluginManager.shared.removeDesktopHostArtifacts(
                    from: .web,
                    registry: capturedRegistry
                )
            } catch {
                cleanupError = error
            }
        }

        if cleanupError == nil {
            try DshStateManager.shared.updateOrThrow { state in
                guard state.pendingProfileSwitch == transaction else { return }
                state.pendingProfileSwitch = nil
            }
        }

        // Refresh all published settings after the durable state transition;
        // this also keeps the Profile picker and plugin list consistent before
        // MainWindowController starts the service.
        loadFromState()
        if let cleanupError {
            alertMessage = "检测到未完成的 Profile 切换，已恢复 \(restoreProfile.rawValue)，但 web 桥接清理失败，将在下次启动重试：\(DshSettingsUIMessage.safe(cleanupError))"
        } else {
            alertMessage = "检测到未完成的 Profile 切换，已恢复 \(restoreProfile.rawValue)。"
        }
    }

    public func retryPendingProfileSwitchCleanup(for context: DshLaunchContext) async throws {
        let state = DshStateManager.shared.current
        guard context.isFresh(in: state),
              context.purpose == .profileSwitch || context.purpose == .profileRollback,
              let contextTransactionID = context.transactionID,
              let transaction = state.pendingProfileSwitch,
              transaction.transactionID == contextTransactionID,
              context.profile == state.appProfile,
              context.originalProfile == transaction.from else { return }
        if context.purpose == .profileRollback {
            guard context.profile == transaction.from,
                  state.appProfile == transaction.from else { return }
            do {
                // A failed switch may have partially materialized the target
                // Profile. Clean only that target, then clear its transaction;
                // the source Profile is the one that just passed health checks.
                try await DshPluginManager.shared.removeDesktopHostArtifacts(
                    from: transaction.to,
                    profileDirectory: DshLaunchContext.profileDirectory(for: transaction.to),
                    registry: context.runtimeDescriptor.registry
                )
                try DshStateManager.shared.updateOrThrow { state in
                    guard state.pendingProfileSwitch == transaction,
                          state.appProfile == transaction.from else { return }
                    state.pendingProfileSwitch = nil
                }
            } catch let error as DshStatePersistenceError {
                throw error
            } catch {
                alertMessage = "目标 \(transaction.to.rawValue) Profile 清理仍失败，将在下次启动重试：\(DshSettingsUIMessage.safe(error))"
            }
            return
        }
        let targetWasHealthy = transaction.phase == .finalizing
            && state.appProfile == transaction.to
        let desktopSourceFailure = transaction.from == .desktop
            && transaction.to == .web
            && state.appProfile == .desktop
        guard targetWasHealthy || desktopSourceFailure else { return }

        do {
            try await DshPluginManager.shared.removeDesktopHostArtifacts(
                from: .web,
                registry: context.runtimeDescriptor.registry
            )
            try DshStateManager.shared.updateOrThrow { state in
                guard state.pendingProfileSwitch == transaction else { return }
                state.pendingProfileSwitch = nil
            }
        } catch let error as DshStatePersistenceError {
            throw error
        } catch {
            alertMessage = "web 桥接清理仍失败，将在下次启动重试：\(DshSettingsUIMessage.safe(error))"
        }
    }

    /// Refresh the profile-based theme state after plugin changes or when the
    /// general settings page becomes visible.
    public func refreshExternalTheme() {
        let directory = DshLaunchContext.profileDirectory(for: appProfile)
        refreshExternalTheme(at: directory)
    }

    public func refreshExternalTheme(for context: DshLaunchContext) {
        refreshExternalTheme(at: context.profileDirectory)
    }

    private func refreshExternalTheme(at directory: URL) {
        let detected = DshPluginManager.shared.detectExternalTheme(at: directory)
        guard externalTheme != detected else { return }
        externalTheme = detected
        MainWindowController.shared.syncUiTheme()
    }

    /// The bridge can report the active theme, but the package manifest is the
    /// stable source used by Electron for settings availability. Re-read it so
    /// a stale bridge snapshot cannot keep the native control locked.
    public func refreshExternalThemeFromBridge() {
        refreshExternalTheme()
    }

    public func refreshCatalog() async {
        let registry = DshVersionManager.normalizedRegistry(npmRegistry)
        catalogRequestGeneration &+= 1
        let requestGeneration = catalogRequestGeneration
        isLoadingCatalog = true
        let startedAt = Date()
        defer {
            if requestGeneration == catalogRequestGeneration {
                isLoadingCatalog = false
            }
        }
        do {
            let res = try await DshVersionManager.shared.fetchCatalog(registry: registry)
            guard requestGeneration == catalogRequestGeneration,
                  DshVersionManager.normalizedRegistry(npmRegistry) == registry else { return }
            self.latestVersion = res.latest
            self.nextVersion = res.next
            self.alphaVersion = res.alpha
            self.availableVersions = res.versions
            self.installedVersions = DshVersionManager.shared.listInstalledVersions()
        } catch {
            if requestGeneration == catalogRequestGeneration,
               DshVersionManager.normalizedRegistry(npmRegistry) == registry {
                self.alertMessage = DshSettingsUIMessage.safe(error)
            }
        }
        await holdRefreshAnimation(since: startedAt)
    }

    public func refreshPlugins() {
        let directory = DshLaunchContext.profileDirectory(for: appProfile)
        refreshPlugins(at: directory)
    }

    public func refreshPlugins(for context: DshLaunchContext) {
        refreshPlugins(
            at: context.profileDirectory,
            profile: context.profile,
            registry: npmRegistry
        )
    }

    private func refreshPlugins(at directory: URL) {
        refreshPlugins(at: directory, profile: appProfile, registry: npmRegistry)
    }

    private func refreshPlugins(
        at directory: URL,
        profile: DshAppProfile,
        registry: String
    ) {
        self.installedPlugins = DshPluginManager.shared.listPlugins(
            at: directory,
            outdatedMap: validOutdatedPluginsMap(
                profile: profile,
                registry: registry
            )
        )
        refreshExternalTheme(at: directory)
    }

    /// `pnpm outdated` is a snapshot of one exact Profile/Registry pair. Do
    /// not let a result from a previous Profile or mirror annotate the new
    /// list, because those annotations become the targets for updateAll.
    private func validOutdatedPluginsMap(
        profile: DshAppProfile,
        registry: String
    ) -> [String: String] {
        guard let context = outdatedPluginsContext,
              context.profile == profile,
              context.registry == DshVersionManager.normalizedRegistry(registry) else {
            return [:]
        }
        return outdatedPluginsMap
    }

    /// Invalidate both the visible badges and the request generation. A
    /// request already in flight must not repopulate old results after a
    /// Profile/Registry change or a failed check.
    private func invalidateOutdatedPlugins(refreshList: Bool = true) {
        pluginUpdateRequestGeneration &+= 1
        outdatedPluginsContext = nil
        outdatedPluginsMap = [:]
        if refreshList {
            refreshPlugins()
        }
    }

    public func refreshPluginList() async {
        guard !isRefreshingPlugins else { return }
        isRefreshingPlugins = true
        let startedAt = Date()
        defer { isRefreshingPlugins = false }
        refreshPlugins()
        await holdRefreshAnimation(since: startedAt)
    }

    /// Run the F03 dependency inspection against one captured launch context.
    /// The operation is read-only and publishes only if the state still points
    /// at that same Profile and Runtime when the detached scan returns.
    public func inspectPlugins() async {
        guard !isInspectingPlugins else { return }
        isInspectingPlugins = true
        pluginInspectionMessage = nil
        defer { isInspectingPlugins = false }

        do {
            let inspected = try await MainWindowController.shared.withRuntimeOperation {
                guard let context = DshLaunchContext.makeStartup(from: DshStateManager.shared.current) else {
                    throw DshLaunchContextError.invalidProfileName
                }
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
                let result = await DshPluginInspector(
                    profileDirectory: context.profileDirectory,
                    runtime: DshPluginInspectorRuntimeDescriptor(
                        root: runtimeRoot,
                        nodeBinary: nodeBinary,
                        integrityVerified: runtimeEntry != nil
                    )
                ).inspectAsync()
                return (context, result)
            }
            guard inspected.0.isFresh(in: DshStateManager.shared.current) else { return }
            pluginInspectionResult = inspected.1
            let message = Self.pluginInspectionMessage(for: inspected.1)
            pluginInspectionMessage = message
            // A passing check is transient feedback; dismiss it after a few
            // seconds so it does not linger. Problem reports stay until the
            // next inspection because they require user action.
            if message == Self.pluginInspectionPassedMessage {
                let shown = message
                Task {
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    if !isInspectingPlugins, pluginInspectionMessage == shown {
                        pluginInspectionMessage = nil
                    }
                }
            }
        } catch {
            pluginInspectionResult = nil
            pluginInspectionMessage = "无法完成插件一致性检查：\(DshSettingsUIMessage.safe(error))"
        }
    }

    public static let pluginInspectionPassedMessage = "插件依赖一致性检查通过。"

    public static func pluginInspectionMessage(for result: DshPluginInspectionResult) -> String? {
        if result.items.contains(where: { $0.status == .missingPackage }) {
            return "发现包缺失；为保护现有 Profile，启动准备已阻止写入，请修复后重试。"
        }
        if result.items.contains(where: { $0.status == .notComposed }) {
            return "发现已安装但未组合的 Bundle；为保护现有 Profile，启动准备已阻止写入。"
        }
        if result.items.contains(where: { $0.status == .duplicateBundle }) {
            return "发现重复 Bundle 引用；归属无法唯一确认，未自动修改。"
        }
        if result.items.contains(where: { $0.status == .unavailable || $0.status == .uncertain })
            || result.issues.contains(where: { $0.code == "patchInspectionUnavailable" }) {
            return "部分插件配置无法确认；启动准备已阻止写入，请查看详情后重试。"
        }
        if result.hasProblems {
            return "发现插件配置引用失效，请查看详情后重试。"
        }
        return pluginInspectionPassedMessage
    }

    public func checkPluginUpdates() async {
        guard !isCheckingPluginUpdates else { return }
        isCheckingPluginUpdates = true
        let startedAt = Date()
        pluginUpdateRequestGeneration &+= 1
        let requestGeneration = pluginUpdateRequestGeneration
        // Never leave badges from a previous check visible while this
        // request is unresolved. An error must therefore fail closed to an
        // ordinary plugin list with no update targets.
        outdatedPluginsContext = nil
        outdatedPluginsMap = [:]
        refreshPlugins()
        defer { isCheckingPluginUpdates = false }
        do {
            let checked = try await MainWindowController.shared.withRuntimeOperation {
                guard let context = DshLaunchContext.makeStartup(from: DshStateManager.shared.current) else {
                    throw DshLaunchContextError.invalidProfileName
                }
                let registry = DshVersionManager.normalizedRegistry(self.npmRegistry)
                let map = try await DshPluginManager.shared.checkOutdatedPlugins(
                    at: context.profileDirectory,
                    profile: context.profile,
                    registry: registry
                )
                return (context, registry, map)
            }
            let state = DshStateManager.shared.current
            guard requestGeneration == pluginUpdateRequestGeneration,
                  checked.0.isFresh(in: state),
                  state.appProfile == checked.0.profile,
                  DshVersionManager.normalizedRegistry(state.npmRegistry) == checked.1,
                  DshVersionManager.normalizedRegistry(npmRegistry) == checked.1 else {
                return
            }
            outdatedPluginsContext = OutdatedPluginsContext(
                profile: checked.0.profile,
                registry: checked.1
            )
            outdatedPluginsMap = checked.2
            refreshPlugins(
                at: checked.0.profileDirectory,
                profile: checked.0.profile,
                registry: checked.1
            )
        } catch {
            guard requestGeneration == pluginUpdateRequestGeneration else { return }
            invalidateOutdatedPlugins(refreshList: true)
            self.alertMessage = "检测插件更新失败：\(DshSettingsUIMessage.safe(error))"
        }
        await holdRefreshAnimation(since: startedAt)
    }

    public func updatePlugin(name: String) {
        guard pluginWritesAllowed else {
            alertMessage = pluginMutationUnavailableReason
            return
        }
        startPluginUpdate(name: name, ignoringMinimumReleaseAge: false)
    }

    public func updateAllPlugins() {
        guard pluginWritesAllowed else {
            alertMessage = pluginMutationUnavailableReason
            return
        }
        startPluginUpdateAll(ignoringMinimumReleaseAge: false)
    }

    public func confirmPendingPluginUpdate() {
        guard let request = pendingPluginUpdate else { return }
        guard pluginWritesAllowed else {
            alertMessage = "插件更新仍在等待恢复完成；请求已保留，请完成恢复后重试。"
            return
        }
        guard !isOperatingPlugin, !isSwitchingProfile else {
            alertMessage = "当前已有插件操作排队，请稍后重试。"
            return
        }
        let queued: Bool
        switch request {
        case .plugin(let name):
            queued = startPluginUpdate(name: name, ignoringMinimumReleaseAge: true)
        case .all:
            queued = startPluginUpdateAll(ignoringMinimumReleaseAge: true)
        }
        if queued {
            pendingPluginUpdate = nil
        }
    }

    public func cancelPendingPluginUpdate() {
        pendingPluginUpdate = nil
    }

    public var pendingPluginUpdateMessage: String? {
        guard let request = pendingPluginUpdate else { return nil }
        switch request {
        case .plugin(let name):
            return "更新插件 \(name) 时，npm 检测到依赖版本发布时间过近。继续更新将仅对本次操作使用 --config.minimum-release-age=0，不会修改全局 pnpm 配置。"
        case .all:
            return "批量更新插件时，npm 检测到依赖版本发布时间过近。继续更新将仅对本次操作使用 --config.minimum-release-age=0，不会修改全局 pnpm 配置。"
        }
    }

    @discardableResult
    private func startPluginUpdate(name: String, ignoringMinimumReleaseAge: Bool) -> Bool {
        guard pluginWritesAllowed else {
            alertMessage = "插件更新暂不可用；请求已保留，请完成恢复后重试。"
            return false
        }
        guard !isOperatingPlugin, !isSwitchingProfile else {
            alertMessage = "当前已有插件操作排队，请稍后重试。"
            return false
        }
        clearRetryablePluginOperation()
        isOperatingPlugin = true
        clearPluginStatus()
        operatingPluginName = DshSettingsUIMessage.safe("正在更新 \(name)…")
        beginPluginOperationProgress(action: .update)
        Task {
            do {
                if !ignoringMinimumReleaseAge {
                    let preflight = try await MainWindowController.shared.withRuntimeOperation {
                        let context = try self.makeDesktopPluginOperationContext()
                        return try await DshPluginManager.shared.preflightPluginUpdate(
                            name: name,
                            profileDirectory: context.profileDirectory,
                            profile: context.profile,
                            registry: DshVersionManager.normalizedRegistry(self.npmRegistry)
                        )
                    }
                    if preflight == .minimumReleaseAgeViolation {
                        self.finishPluginUpdatePreflight(.plugin(name))
                        return
                    }
                }
                _ = try await MainWindowController.shared.withRuntimeOperation {
                    let context = try self.makeDesktopPluginOperationContext()
                    return try await self.executeDesktopPluginOperation(
                        context: context,
                        action: .update,
                        targetPackage: name,
                        ignoringMinimumReleaseAge: ignoringMinimumReleaseAge
                    )
                }
                self.isOperatingPlugin = false
                self.operatingPluginName = nil
                self.finishPluginOperationSuccessfully("插件 \(name) 已验证并提交")
                self.outdatedPluginsMap.removeValue(forKey: name)
                self.refreshPlugins()
                self.showPluginStatus("插件 \(name) 更新成功，服务已重启")
            } catch {
                self.isOperatingPlugin = false
                self.operatingPluginName = nil
                self.finishPluginOperationFailed(actionDescription: "插件 \(name) 更新", error: error)
                if !ignoringMinimumReleaseAge,
                   DshPluginManager.isMinimumReleaseAgeViolation(error) {
                    clearRetryablePluginOperation()
                    self.pendingPluginUpdate = .plugin(name)
                    return
                }
                markRetryablePluginOperation(action: .update, targetPackage: name)
                self.alertMessage = self.pluginOperationFailureMessage(
                    actionDescription: "插件 \(name) 更新",
                    error: error
                )
                self.restoreServiceAfterFailedPluginOperationIfNeeded()
            }
        }
        return true
    }

    @discardableResult
    private func startPluginUpdateAll(ignoringMinimumReleaseAge: Bool) -> Bool {
        guard pluginWritesAllowed else {
            alertMessage = "插件更新暂不可用；请求已保留，请完成恢复后重试。"
            return false
        }
        guard !isOperatingPlugin, !isSwitchingProfile else {
            alertMessage = "当前已有插件操作排队，请稍后重试。"
            return false
        }
        let targetPackages = installedPlugins
            .filter { $0.hasUpdate && !$0.isManaged && !$0.isLocal }
            .map(\.name)
        guard !targetPackages.isEmpty else {
            // A stale/failed update check must never turn into an empty P01
            // transaction. In particular, do not show progress, restart the
            // service, or publish a successful result for a no-op.
            pluginStatusMessage = "当前没有可更新的第三方插件。"
            return false
        }
        let count = targetPackages.count
        clearRetryablePluginOperation()
        isOperatingPlugin = true
        clearPluginStatus()
        operatingPluginName = DshSettingsUIMessage.safe(
            "正在更新插件（共 \(count) 个）…"
        )
        beginPluginOperationProgress(action: .updateAll)
        // The former “插件更新完成，正在重启 DSH 服务…” progress phase is
        // now owned by the coordinator's verify hook; it cannot be published
        // as success before the transaction reaches committed.
        Task {
            do {
                if !ignoringMinimumReleaseAge {
                    let preflight = try await MainWindowController.shared.withRuntimeOperation {
                        let context = try self.makeDesktopPluginOperationContext()
                        return try await DshPluginManager.shared.preflightAllPluginUpdates(
                            packageNames: targetPackages,
                            profileDirectory: context.profileDirectory,
                            profile: context.profile,
                            registry: DshVersionManager.normalizedRegistry(self.npmRegistry)
                        )
                    }
                    if preflight == .minimumReleaseAgeViolation {
                        self.finishPluginUpdatePreflight(.all)
                        return
                    }
                }
                _ = try await MainWindowController.shared.withRuntimeOperation {
                    let context = try self.makeDesktopPluginOperationContext()
                    return try await self.executeDesktopPluginOperation(
                        context: context,
                        action: .updateAll,
                        targetPackages: targetPackages,
                        ignoringMinimumReleaseAge: ignoringMinimumReleaseAge
                    )
                }
                self.isOperatingPlugin = false
                self.operatingPluginName = nil
                self.finishPluginOperationSuccessfully("全部插件已验证并提交")
                self.outdatedPluginsMap.removeAll()
                self.refreshPlugins()
                self.showPluginStatus("全部插件已更新至最新版本，服务已重启")
            } catch {
                self.isOperatingPlugin = false
                self.operatingPluginName = nil
                self.finishPluginOperationFailed(actionDescription: "全部插件更新", error: error)
                if !ignoringMinimumReleaseAge,
                   DshPluginManager.isMinimumReleaseAgeViolation(error) {
                    clearRetryablePluginOperation()
                    self.pendingPluginUpdate = .all
                    return
                }
                markRetryablePluginOperation(action: .updateAll, targetPackage: nil)
                self.alertMessage = self.pluginOperationFailureMessage(
                    actionDescription: "全部插件更新",
                    error: error
                )
                self.restoreServiceAfterFailedPluginOperationIfNeeded()
            }
        }
        return true
    }

    /// Start a one-way update to the selected npm `latest` version. The
    /// settings UI deliberately has no arbitrary install/switch/downgrade
    /// action anymore.
    public func updateToLatest() {
        updateToChannel(.latest)
    }

    public func updateToSelectedChannel() {
        updateToChannel(runtimeChannel)
    }

    private func updateToChannel(_ channel: DshRuntimeChannel) {
        guard runtimeUpdateAllowed else {
            alertMessage = "DSH 当前正在恢复未完成状态，请先完成恢复后再升级 Runtime。"
            return
        }
        guard appProfile == .desktop else {
            alertMessage = "web Profile 与终端共享，暂不允许升级 DSH Runtime；请切回 desktop Profile。"
            return
        }
        let targetVersion: String?
        switch channel {
        case .latest:
            targetVersion = latestVersion
        case .next:
            targetVersion = nextVersion
        case .alpha:
            targetVersion = alphaVersion
        }
        guard let targetVersion,
              let item = availableVersions.first(where: { $0.version == targetVersion }) else {
            alertMessage = "尚未获取到可用的 npm 更新。"
            return
        }
        Task { [self] in await runRuntimeUpdate(item) }
    }

    /// Update to a catalog version only when it is strictly newer than the
    /// active runtime. This remains separate from the UI so future channels
    /// can reuse the same transaction without restoring arbitrary switching.
    public func updateToVersion(_ version: String) {
        guard runtimeUpdateAllowed else {
            alertMessage = "DSH 当前正在恢复未完成状态，请先完成恢复后再升级 Runtime。"
            return
        }
        guard appProfile == .desktop else {
            alertMessage = "web Profile 与终端共享，暂不允许升级 DSH Runtime；请切回 desktop Profile。"
            return
        }
        let selectedTarget: String?
        switch runtimeChannel {
        case .latest:
            selectedTarget = latestVersion
        case .next:
            selectedTarget = nextVersion
        case .alpha:
            selectedTarget = alphaVersion
        }
        guard version == selectedTarget,
              let item = availableVersions.first(where: { $0.version == version }) else {
            alertMessage = "只能更新到当前选定通道的 npm tag 版本。"
            return
        }
        Task { [self] in await runRuntimeUpdate(item) }
    }

    /// Match startup auto-follow behavior while using the same persisted
    /// transaction as a manual update.
    public func followLatestIfEnabled() async {
        let state = DshStateManager.shared.current
        guard state.appProfile == .desktop,
              autoFollowLatest,
              state.runtimeState.channel == .latest,
              state.runtimeState.pending == nil,
              !isFollowingLatest,
              let latest = latestVersion,
              let item = availableVersions.first(where: { $0.version == latest }),
              !(state.runtimeState.dismissedVersion == latest
                  && state.runtimeState.dismissedAppVersion == currentAppVersion),
              let current = state.selectedVersion,
              DshVersionManager.shared.isVersionInstalled(current),
              DshVersionManager.shared.isVersionNewer(latest, than: current) else { return }

        isFollowingLatest = true
        defer { isFollowingLatest = false }
        await runRuntimeUpdate(item, isAutomatic: true)
    }

    /// If the app was terminated during an update, restore the last known
    /// active runtime before the next service launch. A confirmed transaction
    /// is simply finalized; all earlier phases are treated as unconfirmed.
    public func recoverPendingRuntimeUpdate() async throws {
        let state = DshStateManager.shared.current
        let installedVersions = Set(DshVersionManager.shared.listInstalledVersions())
        guard let action = DshRuntimeRecoveryPlanner.plan(
            state: state,
            installedVersions: installedVersions
        ) else { return }

        switch action {
        case .finalizeConfirmed(let active):
            try DshStateManager.shared.updateOrThrow { state in
                state.runtimeState.pending = nil
                // Keep confirmed until the next healthy start can count
                // toward previous/Profile cleanup.
                state.runtimeState.phase = .confirmed
                state.runtimeState.active = active
                state.runtimeState.healthyStartCount = 1
            }
            syncRuntimeRecoveryState()

        case .rollback(let active, _):
            let message = "检测到上次 Runtime 更新在\(recoveryPhaseDescription(state.runtimeState.phase))中断，将恢复到 \(active.version)。"
            try DshStateManager.shared.updateOrThrow { state in
                state.selectedVersion = active.version
                state.runtimeState.active = active
                state.runtimeState = DshRuntimeTransaction.recordRollbackFailure(
                    state.runtimeState,
                    diagnostic: message
                )
            }

            // Keep rollingBack/previous/pending until the previous Runtime
            // actually passes the normal startup health gate. MainWindowController
            // owns the single restore operation immediately before that start;
            // doing it here as well would restore the 4 GB Profile twice.
            self.alertMessage = "\(message) 已准备恢复，正在验证旧 Runtime。"
            syncRuntimeRecoveryState()

        case .reset(let candidate):
            let message = "检测到上次 Runtime 更新在\(recoveryPhaseDescription(state.runtimeState.phase))中断，且没有可用的回滚 Runtime，请重新安装。"
            let snapshotID = state.runtimeState.webProfileSnapshotID
            let snapshotProfile = state.runtimeState.profile
            guard state.appProfile == snapshotProfile else {
                let diagnostic = "\(message) 但快照属于 \(snapshotProfile.rawValue) Profile，当前为 \(state.appProfile.rawValue)，为保护 Profile 数据暂不恢复。"
                self.alertMessage = diagnostic
                syncRuntimeRecoveryState()
                return
            }
            if let snapshotID {
                do {
                    try await DshPluginManager.shared.restoreWebProfileSnapshot(
                        snapshotID,
                        profile: snapshotProfile
                    ) { progress in
                        Task { @MainActor in
                            self.installProgressPhase = DshSettingsUIMessage.safe(progress.phase)
                            self.installProgressDetail = progress.detail.map(DshSettingsUIMessage.safe)
                        }
                    }
                } catch {
                    let diagnostic = "\(message) 但 web Profile 恢复失败，事务仍保留待下次启动重试：\(DshSettingsUIMessage.safe(error))"
                    try DshStateManager.shared.updateOrThrow { state in
                        state.runtimeState = DshRuntimeTransaction.recordRollbackFailure(
                            state.runtimeState,
                            diagnostic: diagnostic
                        )
                    }
                    self.alertMessage = diagnostic
                    syncRuntimeRecoveryState()
                    return
                }
            }
            try DshStateManager.shared.updateOrThrow { state in
                state.selectedVersion = nil
                state.runtimeState.active = nil
                state.runtimeState.pending = nil
                state.runtimeState.previous = nil
                state.runtimeState.phase = .idle
                state.runtimeState.webProfileSnapshotID = nil
                state.runtimeState.healthyStartCount = 0
                state.runtimeState.lastDiagnostic = message
            }
            var finalMessage = message
            do {
                try DshVersionManager.shared.discardInstalledVersion(candidate.version)
            } catch {
                finalMessage += " Candidate \(candidate.version) 清理失败：\(DshSettingsUIMessage.safe(error))"
                try DshStateManager.shared.updateOrThrow { $0.runtimeState.lastDiagnostic = finalMessage }
            }
            if let snapshotID {
                do {
                    try await DshPluginManager.shared.deleteWebProfileSnapshot(snapshotID)
                } catch {
                    finalMessage += " web Profile 快照清理失败：\(DshSettingsUIMessage.safe(error))"
                    try DshStateManager.shared.updateOrThrow { state in
                        state.runtimeState.webProfileSnapshotID = snapshotID
                        state.runtimeState.lastDiagnostic = finalMessage
                    }
                }
            }
            self.alertMessage = finalMessage
            syncRuntimeRecoveryState()
        }
    }

    private func recoveryPhaseDescription(_ phase: DshRuntimeTransactionPhase) -> String {
        switch phase {
        case .staging:
            return " candidate 安装阶段"
        case .switching, .verifying:
            return "新 Runtime 启动/健康验证阶段"
        case .rollingBack:
            return "回滚阶段"
        case .confirmed:
            return "确认阶段"
        case .idle:
            return "未知阶段"
        }
    }

    private func runtimeTransactionMatches(
        _ state: DshStateConfig,
        phase: DshRuntimeTransactionPhase,
        selectedVersion: String?,
        activeVersion: String?,
        previousVersion: String?,
        pendingVersion: String?,
        snapshotID: String?,
        transactionID: String?
    ) -> Bool {
        guard let transactionID else { return false }
        return state.selectedVersion == selectedVersion
            && state.runtimeState.phase == phase
            && state.runtimeState.active?.version == activeVersion
            && state.runtimeState.previous?.version == previousVersion
            && state.runtimeState.pending?.version == pendingVersion
            && state.runtimeState.webProfileSnapshotID == snapshotID
            && state.runtimeState.transactionID == transactionID
    }

    /// Count a successful app/service start after an update. Keep the old
    /// runtime until the new one has survived two starts, then remove only
    /// the exact recorded previous directory.
    public func recordHealthyRuntimeStart(for context: DshLaunchContext) async throws {
        let state = DshStateManager.shared.current
        guard context.isFresh(in: state),
              context.purpose == .normal,
              let contextTransactionID = context.transactionID,
              state.runtimeState.transactionID == contextTransactionID,
              context.profile == state.runtimeState.profile,
              context.runtimeDescriptor.version == state.runtimeState.active?.version,
              state.runtimeState.phase == .confirmed,
              let previous = state.runtimeState.previous else { return }

        let expectedSelectedVersion = state.selectedVersion
        let expectedActiveVersion = state.runtimeState.active?.version
        let expectedPreviousVersion = previous.version
        let expectedPendingVersion = state.runtimeState.pending?.version
        let expectedSnapshotID = state.runtimeState.webProfileSnapshotID
        let expectedTransactionID = contextTransactionID
        let nextCount = state.runtimeState.healthyStartCount + 1
        guard nextCount >= 2 else {
            try DshStateManager.shared.updateOrThrow { state in
                guard self.runtimeTransactionMatches(
                    state,
                    phase: .confirmed,
                    selectedVersion: expectedSelectedVersion,
                    activeVersion: expectedActiveVersion,
                    previousVersion: expectedPreviousVersion,
                    pendingVersion: expectedPendingVersion,
                    snapshotID: expectedSnapshotID,
                    transactionID: expectedTransactionID
                ), state.runtimeState.healthyStartCount == nextCount - 1 else { return }
                state.runtimeState.healthyStartCount = nextCount
            }
            return
        }

        let snapshotID = expectedSnapshotID
        var snapshotCleanupError: Error?
        if let snapshotID {
            do {
                try await DshPluginManager.shared.deleteWebProfileSnapshot(snapshotID)
            } catch {
                snapshotCleanupError = error
            }
        }

        let stateAfterSnapshotCleanup = DshStateManager.shared.current
        guard runtimeTransactionMatches(
            stateAfterSnapshotCleanup,
            phase: .confirmed,
            selectedVersion: expectedSelectedVersion,
            activeVersion: expectedActiveVersion,
            previousVersion: expectedPreviousVersion,
            pendingVersion: expectedPendingVersion,
            snapshotID: expectedSnapshotID,
            transactionID: expectedTransactionID
        ), stateAfterSnapshotCleanup.runtimeState.healthyStartCount == nextCount - 1 else { return }

        do {
            try DshVersionManager.shared.discardInstalledVersion(previous.version)
            var didCommit = false
            try DshStateManager.shared.updateOrThrow { state in
                guard self.runtimeTransactionMatches(
                    state,
                    phase: .confirmed,
                    selectedVersion: expectedSelectedVersion,
                    activeVersion: expectedActiveVersion,
                    previousVersion: expectedPreviousVersion,
                    pendingVersion: expectedPendingVersion,
                    snapshotID: expectedSnapshotID,
                    transactionID: expectedTransactionID
                ), state.runtimeState.healthyStartCount == nextCount - 1 else { return }
                didCommit = true
                state.runtimeState.previous = nil
                state.runtimeState.healthyStartCount = 0
                state.runtimeState.phase = .idle
                state.runtimeState.transactionID = nil
                state.runtimeState.webProfileSnapshotID = snapshotCleanupError == nil ? nil : snapshotID
                state.runtimeState.lastDiagnostic = snapshotCleanupError.map {
                    "旧 Runtime 已清理，但 web Profile 快照清理失败：\(DshSettingsUIMessage.safe($0))"
                }
            }
            guard didCommit else { return }
        } catch let error as DshStatePersistenceError {
            throw error
        } catch {
            try DshStateManager.shared.updateOrThrow { state in
                guard self.runtimeTransactionMatches(
                    state,
                    phase: .confirmed,
                    selectedVersion: expectedSelectedVersion,
                    activeVersion: expectedActiveVersion,
                    previousVersion: expectedPreviousVersion,
                    pendingVersion: expectedPendingVersion,
                    snapshotID: expectedSnapshotID,
                    transactionID: expectedTransactionID
                ) else { return }
                state.runtimeState.healthyStartCount = nextCount
            }
            self.alertMessage = "新 Runtime 已连续启动，但旧 Runtime 清理失败：\(DshSettingsUIMessage.safe(error))"
        }
    }

    /// Retry a snapshot deletion that previously failed after the Runtime
    /// transaction itself had already settled. Keep the ID in state until the
    /// delete really succeeds so startup cleanup never turns a multi-GB
    /// snapshot into an untracked leak.
    public func retryRetainedWebProfileSnapshotCleanup() async throws {
        let state = DshStateManager.shared.current
        guard state.runtimeState.pending == nil,
              state.runtimeState.phase == .idle,
              let snapshotID = state.runtimeState.webProfileSnapshotID else { return }

        do {
            try await DshPluginManager.shared.deleteWebProfileSnapshot(snapshotID)
            try DshStateManager.shared.updateOrThrow { state in
                guard state.runtimeState.pending == nil,
                      state.runtimeState.webProfileSnapshotID == snapshotID else { return }
                state.runtimeState.webProfileSnapshotID = nil
                state.runtimeState.lastDiagnostic = nil
            }
        } catch let error as DshStatePersistenceError {
            throw error
        } catch {
            alertMessage = "web Profile 快照清理仍失败，将在下次启动继续重试：\(DshSettingsUIMessage.safe(error))"
        }
    }

    /// Finish a rollback that was left pending because the previous process
    /// could not be started during the original update attempt. The next app
    /// launch restores the Profile before starting the previous Runtime; once
    /// that start is healthy, this method can safely settle the transaction.
    public func finalizeRecoveredRuntimeAfterSuccessfulStart(for context: DshLaunchContext) async throws {
        let state = DshStateManager.shared.current
        guard context.isFresh(in: state),
              context.purpose == .runtimeRollback,
              let contextTransactionID = context.transactionID,
              state.runtimeState.transactionID == contextTransactionID,
              context.profile == state.runtimeState.profile,
              context.runtimeDescriptor.version == state.runtimeState.previous?.version,
              state.runtimeState.phase == .rollingBack,
              let active = state.runtimeState.previous,
              let candidate = state.runtimeState.pending,
              state.selectedVersion == active.version else { return }

        let expectedSelectedVersion = state.selectedVersion
        let expectedActiveVersion = state.runtimeState.active?.version
        let expectedPreviousVersion = active.version
        let expectedPendingVersion = candidate.version
        let snapshotID = state.runtimeState.webProfileSnapshotID
        let expectedTransactionID = contextTransactionID
        var cleanupErrors: [String] = []
        do {
            try DshVersionManager.shared.discardInstalledVersion(candidate.version)
        } catch {
            cleanupErrors.append("candidate 清理失败：\(DshSettingsUIMessage.safe(error))")
        }

        var retainedSnapshotID: String?
        if let snapshotID {
            do {
                try await DshPluginManager.shared.deleteWebProfileSnapshot(snapshotID)
            } catch {
                retainedSnapshotID = snapshotID
                cleanupErrors.append("web Profile 快照清理失败：\(DshSettingsUIMessage.safe(error))")
            }
        }

        let stateBeforeCommit = DshStateManager.shared.current
        guard runtimeTransactionMatches(
            stateBeforeCommit,
            phase: .rollingBack,
            selectedVersion: expectedSelectedVersion,
            activeVersion: expectedActiveVersion,
            previousVersion: expectedPreviousVersion,
            pendingVersion: expectedPendingVersion,
            snapshotID: snapshotID,
            transactionID: expectedTransactionID
        ) else { return }

        let diagnostic = cleanupErrors.isEmpty ? nil : cleanupErrors.joined(separator: "；")
        var didCommit = false
        try DshStateManager.shared.updateOrThrow { state in
            guard self.runtimeTransactionMatches(
                state,
                phase: .rollingBack,
                selectedVersion: expectedSelectedVersion,
                activeVersion: expectedActiveVersion,
                previousVersion: expectedPreviousVersion,
                pendingVersion: expectedPendingVersion,
                snapshotID: snapshotID,
                transactionID: expectedTransactionID
            ) else { return }
            didCommit = true
            state.runtimeState = DshRuntimeTransaction.finishRollback(
                state.runtimeState,
                active: active,
                retainedWebProfileSnapshotID: retainedSnapshotID
            )
            state.runtimeState.lastDiagnostic = diagnostic
        }
        guard didCommit else { return }
        syncRuntimeRecoveryState()
        if let diagnostic {
            alertMessage = "已恢复到 \(active.version)，但\(diagnostic)"
        }
    }

    private func runRuntimeUpdate(_ item: DshVersionItem, isAutomatic: Bool = false) async {
        guard pluginMutationsAllowed, !isUpdatingRuntime else { return }
        guard runtimeUpdateAllowed else { return }
        guard DshStateManager.shared.current.appProfile == .desktop else {
            alertMessage = "web Profile 与终端共享，暂不允许升级 DSH Runtime；请切回 desktop Profile。"
            return
        }
        guard DshStateManager.shared.current.runtimeState.pending == nil else {
            alertMessage = "上一次 Runtime 更新尚未完成恢复，请重启 DSH 后再重试。"
            return
        }
        guard let currentVersion = DshStateManager.shared.current.selectedVersion,
              DshVersionManager.shared.isVersionInstalled(currentVersion) else {
            alertMessage = "当前没有可用于升级的 DSH Runtime。"
            return
        }
        guard DshVersionManager.shared.isVersionNewer(item.version, than: currentVersion) else {
            alertMessage = "当前已经是该 Registry 中不低于目标版本的 Runtime。"
            return
        }

        if isAutomatic {
            let state = DshStateManager.shared.current
            guard !(state.runtimeState.dismissedVersion == item.version
                && state.runtimeState.dismissedAppVersion == currentAppVersion) else { return }
        } else {
            // The update button is the explicit user retry path for a
            // previously suppressed candidate.
            DshStateManager.shared.update { state in
                state.runtimeState.dismissedVersion = nil
                state.runtimeState.dismissedAppVersion = nil
            }
        }

        isUpdatingRuntime = true
        isInstallingVersion = true
        installingVersionName = item.version
        installProgressPhase = "准备更新 DSH \(item.version)..."
        installProgressDetail = nil

        do {
            try await performRuntimeUpdate(item, currentVersion: currentVersion)
            loadFromState()
            await refreshCatalog()
        } catch {
            // performRuntimeUpdate includes the active/candidate versions and
            // whether rollback or cleanup also failed. Keep that diagnostic
            // intact instead of prefixing it with a duplicate failure label.
            DshStateManager.shared.update { state in
                state.runtimeState.dismissedVersion = item.version
                state.runtimeState.dismissedAppVersion = currentAppVersion
            }
            syncRuntimeRecoveryState()
            alertMessage = DshSettingsUIMessage.safe(error)
        }

        isUpdatingRuntime = false
        isInstallingVersion = false
        installingVersionName = nil
    }

    private func performRuntimeUpdate(_ item: DshVersionItem, currentVersion: String) async throws {
        try await MainWindowController.shared.withRuntimeOperation {
            try await self.performRuntimeUpdateDuringOperation(item, currentVersion: currentVersion)
        }
    }

    private func performRuntimeUpdateDuringOperation(_ item: DshVersionItem, currentVersion: String) async throws {
        let registry = DshVersionManager.normalizedRegistry(npmRegistry)
        let state = DshStateManager.shared.current
        guard let integrity = item.integrity else {
            throw NSError(
                domain: "DshRuntimeUpdate",
                code: -4,
                userInfo: [NSLocalizedDescriptionKey: "npm 版本目录缺少 DSH integrity，已拒绝更新"]
            )
        }
        let active = state.runtimeState.active ?? NpmRuntimeDescriptor(
            version: currentVersion,
            registry: registry,
            integrity: nil
        )
        let candidate = NpmRuntimeDescriptor(
            version: item.version,
            registry: registry,
            integrity: integrity
        )

        let transaction = DshRuntimeTransaction.begin(
            active: active,
            candidate: candidate,
            updatePolicy: state.runtimeState.updatePolicy,
            channel: state.runtimeState.channel,
            profile: state.appProfile
        )
        // The transaction must be durable before any install or file work
        // starts. A write failure here means the update cannot be recovered
        // deterministically, so fail closed before mutating anything.
        try DshStateManager.shared.updateOrThrow { state in
            state.runtimeState = transaction
        }

        var candidateActivated = false
        do {
            do {
                try await DshVersionManager.shared.installCandidate(
                    version: item.version,
                    registry: registry,
                    expectedIntegrity: integrity
                ) { progress in
                    Task { @MainActor in
                        self.installProgressPhase = DshSettingsUIMessage.safe(progress.phase)
                        self.installProgressDetail = progress.detail.map(DshSettingsUIMessage.safe)
                    }
                }
            } catch {
                throw DshRuntimeUpdateFailure.candidateInstall(
                    version: item.version,
                    detail: DshSettingsUIMessage.safe(error)
                )
            }

            try DshStateManager.shared.updateOrThrow { state in
                state.selectedVersion = item.version
                state.runtimeState = DshRuntimeTransaction.activateCandidate(state.runtimeState)
            }
            candidateActivated = true
            try DshStateManager.shared.updateOrThrow { state in
                state.runtimeState = DshRuntimeTransaction.beginVerification(state.runtimeState)
            }
            do {
                try await restartDshServiceDuringOperationAndWait()
            } catch {
                throw DshRuntimeUpdateFailure.runtimeStartup(
                    version: item.version,
                    detail: DshSettingsUIMessage.safe(error)
                )
            }

            try DshStateManager.shared.updateOrThrow { state in
                state.runtimeState = DshRuntimeTransaction.confirm(state.runtimeState)
            }
        } catch {
            let failureDescription = DshSettingsUIMessage.safe(error)
            // The rollback decision must be durable before any file mutation:
            // deleting the web snapshot while state still references it would
            // leave a startup restore that can never succeed. Fail closed when
            // the transition itself cannot be persisted.
            do {
                try DshStateManager.shared.updateOrThrow { state in
                    state.selectedVersion = currentVersion
                    state.runtimeState = DshRuntimeTransaction.beginRollback(state.runtimeState)
                }
            } catch {
                throw NSError(
                    domain: "DshRuntimeUpdate",
                    code: -6,
                    userInfo: [NSLocalizedDescriptionKey: "更新到 \(item.version) 失败，且回滚状态写入失败：\(DshSettingsUIMessage.safe(error))。请重启应用完成恢复。"]
                )
            }
            var rollbackError: Error?
            if candidateActivated {
                // Do not let pnpm or a running candidate keep files open while
                // the pre-transaction Profile snapshot is being restored.
                DshService.shared.stop()
                do {
                    try await restartDshServiceDuringOperationAndWait()
                } catch {
                    rollbackError = error
                }
            }
            if let rollbackError {
                let diagnostic = "Runtime 回滚失败：\(DshSettingsUIMessage.safe(rollbackError))"
                do {
                    try DshStateManager.shared.updateOrThrow { state in
                        state.runtimeState = DshRuntimeTransaction.recordRollbackFailure(
                            state.runtimeState,
                            diagnostic: diagnostic
                        )
                        state.runtimeState.dismissedVersion = item.version
                        state.runtimeState.dismissedAppVersion = currentAppVersion
                    }
                } catch {
                    throw NSError(
                        domain: "DshRuntimeUpdate",
                        code: -8,
                        userInfo: [NSLocalizedDescriptionKey: "更新到 \(item.version) 失败：\(failureDescription)；自动恢复 \(active.version) 也失败：\(diagnostic)；恢复状态写入也失败：\(DshSettingsUIMessage.safe(error))。"]
                    )
                }
                throw NSError(
                    domain: "DshRuntimeUpdate",
                    code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "更新到 \(item.version) 失败：\(failureDescription)；自动恢复 \(active.version) 也失败：\(DshSettingsUIMessage.safe(rollbackError))"]
                )
            }

            var cleanupErrors: [String] = []
            do {
                try DshVersionManager.shared.discardInstalledVersion(item.version)
            } catch {
                cleanupErrors.append("candidate 清理失败：\(DshSettingsUIMessage.safe(error))")
            }

            // Commit the settled rollback state BEFORE deleting the retained
            // web Profile snapshot. State that points at a deleted snapshot is
            // an unrecoverable startup restore; the reference is cleared only
            // after the delete succeeds, and a failed delete keeps the ID
            // retained for the next-launch retry
            // (retryRetainedWebProfileSnapshotCleanup).
            let snapshotID = DshStateManager.shared.current.runtimeState.webProfileSnapshotID
            do {
                try DshStateManager.shared.updateOrThrow { state in
                    state.runtimeState = DshRuntimeTransaction.finishRollback(
                        state.runtimeState,
                        active: active,
                        retainedWebProfileSnapshotID: snapshotID
                    )
                    state.runtimeState.dismissedVersion = item.version
                    state.runtimeState.dismissedAppVersion = currentAppVersion
                    state.runtimeState.lastDiagnostic = cleanupErrors.isEmpty ? nil : cleanupErrors.joined(separator: "；")
                }
            } catch {
                throw NSError(
                    domain: "DshRuntimeUpdate",
                    code: -9,
                    userInfo: [NSLocalizedDescriptionKey: "更新到 \(item.version) 失败，已尝试回滚，但回滚提交写入失败：\(DshSettingsUIMessage.safe(error))。请重启应用完成恢复。"]
                )
            }

            if let snapshotID {
                do {
                    try await DshPluginManager.shared.deleteWebProfileSnapshot(snapshotID)
                    // Clear the retained reference only after the delete
                    // really succeeded.
                    try DshStateManager.shared.updateOrThrow { state in
                        guard state.runtimeState.webProfileSnapshotID == snapshotID,
                              state.runtimeState.phase == .idle else { return }
                        state.runtimeState.webProfileSnapshotID = nil
                    }
                } catch {
                    cleanupErrors.append("web Profile 快照清理失败：\(DshSettingsUIMessage.safe(error))")
                    do {
                        try DshStateManager.shared.updateOrThrow { state in
                            guard state.runtimeState.webProfileSnapshotID == snapshotID else { return }
                            state.runtimeState.lastDiagnostic = cleanupErrors.joined(separator: "；")
                        }
                    } catch {
                        // The reference stays retained; next-launch cleanup
                        // will retry the deletion.
                    }
                }
            }
            if !cleanupErrors.isEmpty {
                throw NSError(
                    domain: "DshRuntimeUpdate",
                    code: -3,
                    userInfo: [NSLocalizedDescriptionKey: "更新到 \(item.version) 失败，已恢复 \(active.version)，但\(cleanupErrors.joined(separator: "；"))"]
                )
            }
            throw NSError(
                domain: "DshRuntimeUpdate",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "更新到 \(item.version) 失败，已自动恢复 \(active.version)：\(failureDescription)"]
            )
        }
    }

    public func addPlugin(spec: String) {
        guard pluginWritesAllowed, pendingPluginInstallSpec == nil else {
            alertMessage = pluginMutationUnavailableReason
            return
        }
        startPluginInstall(spec: spec, ignoringMinimumReleaseAge: false)
    }

    public func confirmPendingPluginInstall() {
        guard let spec = pendingPluginInstallSpec else { return }
        guard pluginWritesAllowed else {
            alertMessage = "插件安装仍在等待恢复完成；请求已保留，请完成恢复后重试。"
            return
        }
        guard !isOperatingPlugin, !isSwitchingProfile else {
            alertMessage = "当前已有插件操作排队，请稍后重试。"
            return
        }
        if startPluginInstall(spec: spec, ignoringMinimumReleaseAge: true) {
            pendingPluginInstallSpec = nil
        }
    }

    public func cancelPendingPluginInstall() {
        pendingPluginInstallSpec = nil
    }

    public func confirmPendingPluginDowngrade() {
        guard let pending = pendingPluginDowngrade else { return }
        guard pluginWritesAllowed else {
            alertMessage = "插件安装仍在等待恢复完成；请求已保留，请完成恢复后重试。"
            return
        }
        guard !isOperatingPlugin, !isSwitchingProfile else {
            alertMessage = "当前已有插件操作排队，请稍后重试。"
            return
        }
        if startPluginInstall(spec: pending.spec, ignoringMinimumReleaseAge: false, allowingDowngrade: true) {
            pendingPluginDowngrade = nil
        }
    }

    public func cancelPendingPluginDowngrade() {
        pendingPluginDowngrade = nil
    }

    public var pendingPluginDowngradeMessage: String? {
        guard let pending = pendingPluginDowngrade else { return nil }
        return "安装 \(pending.spec) 会把已安装的 \(pending.installedVersion) 降级到 \(pending.candidateVersion)（npm latest 标签当前指向旧版本）。降级后插件可能无法通过健康检查并触发回滚，确认继续吗？"
    }

    /// Resolve what an install spec would put down and compare it with the
    /// installed version. Returns a pending confirmation only for a strict
    /// downgrade; every unresolvable or unparsable case fails open so the
    /// normal P01 verify/rollback net stays the source of truth.
    private func pendingInstallDowngrade(spec: String) async -> DshPendingPluginDowngrade? {
        let registry = DshVersionManager.normalizedRegistry(npmRegistry)
        guard let candidate = await DshPluginManager.shared.resolveInstallCandidateVersion(spec: spec, registry: registry),
              let installed = installedPlugins.first(where: { $0.name == candidate.name })?.version,
              DshPluginOperationInputValidation.isInstallDowngrade(installed: installed, candidate: candidate.version) == true else {
            return nil
        }
        return DshPendingPluginDowngrade(
            spec: spec,
            name: candidate.name,
            installedVersion: installed,
            candidateVersion: candidate.version
        )
    }

    /// A downgrade gate hit is not a failed operation: clear transient
    /// progress exactly like the release-age preflight gate so the
    /// confirmation appears without a misleading rollback result.
    private func finishPluginInstallDowngradeGate(_ pending: DshPendingPluginDowngrade) {
        isOperatingPlugin = false
        operatingPluginName = nil
        pluginOperationDisplayGeneration &+= 1
        pluginOperationDismissTask?.cancel()
        pluginOperationDismissTask = nil
        finishPluginOperationProgress()
        pluginOperationPhase = nil
        pluginOperationOutcome = nil
        pluginOperationDetail = nil
        pluginOperationProgressText = nil
        clearRetryablePluginOperation()
        pendingPluginDowngrade = pending
    }

    /// A release-age prompt raised by the install preflight is not a
    /// failed P01 operation. Reuses the existing install confirmation: the
    /// one-time override stays scoped to the confirmed install.
    private func finishPluginInstallPreflight(spec: String) {
        isOperatingPlugin = false
        operatingPluginName = nil
        pluginOperationDisplayGeneration &+= 1
        pluginOperationDismissTask?.cancel()
        pluginOperationDismissTask = nil
        finishPluginOperationProgress()
        pluginOperationPhase = nil
        pluginOperationOutcome = nil
        pluginOperationDetail = nil
        pluginOperationProgressText = nil
        clearRetryablePluginOperation()
        pendingPluginInstallSpec = spec
    }

    /// Live pnpm progress line handler (MainActor): surface download
    /// summaries while a mutation runs, throttled so the UI stays quiet.
    private func notePluginOperationProgress(_ line: String) {
        guard isOperatingPlugin else { return }
        let now = Date()
        let significant = line.contains("added")
        guard significant || now.timeIntervalSince(lastPluginOperationProgressUpdate) >= 2.0 else { return }
        lastPluginOperationProgressUpdate = now
        var text = DshSecretRedactor().redact(line)
        if text.count > 140 {
            text = String(text.prefix(140)) + "…"
        }
        pluginOperationProgressText = text
    }

    public var pendingPluginInstallMessage: String? {
        guard let spec = pendingPluginInstallSpec else { return nil }
        return "安装插件 \(spec) 时，npm 检测到依赖版本发布时间过近。继续安装将仅对本次操作使用 --config.minimum-release-age=0，不会修改全局 pnpm 配置。"
    }

    @discardableResult
    private func startPluginInstall(spec: String, ignoringMinimumReleaseAge: Bool, allowingDowngrade: Bool = false) -> Bool {
        let trimmedSpec = spec.trimmingCharacters(in: .whitespacesAndNewlines)
        guard pluginWritesAllowed else {
            alertMessage = "插件安装暂不可用；请求已保留，请完成恢复后重试。"
            return false
        }
        guard !isOperatingPlugin, !isSwitchingProfile else {
            alertMessage = "当前已有插件操作排队，请稍后重试。"
            return false
        }
        guard !trimmedSpec.isEmpty else { return false }
        clearRetryablePluginOperation()
        isOperatingPlugin = true
        clearPluginStatus()
        operatingPluginName = DshSettingsUIMessage.safe("正在安装插件 \(trimmedSpec)…")
        beginPluginOperationProgress(action: .install)
        Task {
            do {
                if !allowingDowngrade,
                   let pending = await self.pendingInstallDowngrade(spec: trimmedSpec) {
                    self.finishPluginInstallDowngradeGate(pending)
                    return
                }
                if !ignoringMinimumReleaseAge {
                    let preflight = try await MainWindowController.shared.withRuntimeOperation {
                        let context = try self.makeDesktopPluginOperationContext()
                        return try await DshPluginManager.shared.preflightInstallPluginUpdate(
                            spec: trimmedSpec,
                            profileDirectory: context.profileDirectory,
                            profile: context.profile,
                            registry: DshVersionManager.normalizedRegistry(self.npmRegistry)
                        )
                    }
                    if preflight == .minimumReleaseAgeViolation {
                        self.finishPluginInstallPreflight(spec: trimmedSpec)
                        return
                    }
                }
                _ = try await MainWindowController.shared.withRuntimeOperation {
                    let context = try self.makeDesktopPluginOperationContext()
                    return try await self.executeDesktopPluginOperation(
                        context: context,
                        action: .install,
                        targetPackage: trimmedSpec,
                        ignoringMinimumReleaseAge: ignoringMinimumReleaseAge
                    )
                }
                self.isOperatingPlugin = false
                self.operatingPluginName = nil
                self.finishPluginOperationSuccessfully("插件 \(trimmedSpec) 已验证并提交")
                self.refreshPlugins()
                self.showPluginStatus("插件 \(trimmedSpec) 安装成功，服务已重启")
            } catch {
                self.isOperatingPlugin = false
                self.operatingPluginName = nil
                self.finishPluginOperationFailed(actionDescription: "插件 \(trimmedSpec) 安装", error: error)
                if !ignoringMinimumReleaseAge,
                   DshPluginManager.isMinimumReleaseAgeViolation(error) {
                    clearRetryablePluginOperation()
                    self.pendingPluginInstallSpec = trimmedSpec
                    return
                }
                markRetryablePluginOperation(action: .install, targetPackage: trimmedSpec)
                self.alertMessage = self.pluginOperationFailureMessage(
                    actionDescription: "插件 \(trimmedSpec) 安装",
                    error: error
                )
                self.restoreServiceAfterFailedPluginOperationIfNeeded()
            }
        }
        return true
    }

    public func removePlugin(name: String) {
        _ = startPluginRemove(name: name)
    }

    /// Execute a resolver-approved recovery removal through the same P01
    /// coordinator used by Settings. This boundary intentionally does not
    /// consult pluginMutationsAllowed: the recovery surface is the caller of
    /// this narrowly-scoped method, and it has already proven the launch
    /// identities. Every mutable state and Profile path is revalidated here
    /// before P01 is allowed to stop the service and snapshot the Profile.
    public func removePluginFromRecovery(
        plan: DshPluginRemovalPlanPreview,
        request: DshRecoveryPluginRemovalRequest,
        context: DshLaunchContext
    ) async throws -> DshPluginOperationResult {
        let state = DshStateManager.shared.current
        let expectedProfilePath = DshLaunchContext
            .profileDirectory(for: .desktop)
            .standardizedFileURL
            .path
        let requestPath = request.originalProfilePath
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard request.isExecutable,
              plan.allowed,
              plan.requiresExplicitConfirmation,
              plan.pluginName == request.pluginName,
              request.originalProfile == DshAppProfile.desktop.runtimeProfileName,
              context.launchID == request.launchID,
              context.profile == .desktop,
              context.originalProfile == .desktop,
              context.purpose == .normal,
              context.profileDirectory.standardizedFileURL.path == requestPath,
              context.profileDirectory.standardizedFileURL.path == expectedProfilePath,
              state.appProfile == .desktop,
              state.runtimeState.phase == .idle,
              state.runtimeState.previous == nil,
              state.runtimeState.pending == nil,
              state.runtimeState.transactionID == nil,
              state.runtimeState.webProfileSnapshotID == nil,
              state.pendingProfileSwitch == nil,
              context.isFresh(in: state),
              DshPluginOperationCoordinator.shared.persistedStatus == .absent,
              !isOperatingPlugin,
              !isSwitchingProfile else {
            throw DshPluginOperationError.runtimeOrProfileRecoveryPending
        }

        clearRetryablePluginOperation()
        isOperatingPlugin = true
        clearPluginStatus()
        operatingPluginName = DshSettingsUIMessage.safe(
            "正在从恢复界面卸载插件 \(request.pluginName)…"
        )
        beginPluginOperationProgress(action: .remove)
        do {
            // No minimum-release-age override exists on remove. The only
            // mutation is the P01 remove transaction below.
            let result = try await MainWindowController.shared.withRuntimeOperation {
                try await self.executeDesktopPluginOperation(
                    context: context,
                    action: .remove,
                    targetPackage: request.pluginName
                )
            }
            isOperatingPlugin = false
            operatingPluginName = nil
            finishPluginOperationSuccessfully(
                "插件 \(request.pluginName) 已移除并通过普通健康验证"
            )
            outdatedPluginsMap.removeValue(forKey: request.pluginName)
            refreshPlugins(for: context)
            showPluginStatus("插件 \(request.pluginName) 已卸载，服务已重启")
            return result
        } catch {
            isOperatingPlugin = false
            operatingPluginName = nil
            finishPluginOperationFailed(
                actionDescription: "恢复操作卸载插件 \(request.pluginName)",
                error: error
            )
            markRetryablePluginOperation(
                action: .remove,
                targetPackage: request.pluginName
            )
            alertMessage = pluginOperationFailureMessage(
                actionDescription: "恢复操作卸载插件 \(request.pluginName)",
                error: error
            )
            throw error
        }
    }

    @discardableResult
    private func startPluginRemove(name: String) -> Bool {
        guard pluginMutationsAllowed, !isOperatingPlugin, !isSwitchingProfile else { return false }
        clearRetryablePluginOperation()
        isOperatingPlugin = true
        clearPluginStatus()
        operatingPluginName = DshSettingsUIMessage.safe("正在卸载插件 \(name)…")
        beginPluginOperationProgress(action: .remove)
        Task {
            do {
                _ = try await MainWindowController.shared.withRuntimeOperation {
                    let context = try self.makeDesktopPluginOperationContext()
                    return try await self.executeDesktopPluginOperation(
                        context: context,
                        action: .remove,
                        targetPackage: name
                    )
                }
                self.isOperatingPlugin = false
                self.operatingPluginName = nil
                self.finishPluginOperationSuccessfully("插件 \(name) 已验证并提交")
                self.outdatedPluginsMap.removeValue(forKey: name)
                self.refreshPlugins()
                self.showPluginStatus("插件 \(name) 已卸载，服务已重启")
            } catch {
                self.isOperatingPlugin = false
                self.operatingPluginName = nil
                self.finishPluginOperationFailed(actionDescription: "插件 \(name) 卸载", error: error)
                self.markRetryablePluginOperation(action: .remove, targetPackage: name)
                self.alertMessage = self.pluginOperationFailureMessage(
                    actionDescription: "插件 \(name) 卸载",
                    error: error
                )
                self.restoreServiceAfterFailedPluginOperationIfNeeded()
            }
        }
        return true
    }

    public func saveGeneralSettings() {
        let stateBeforeSave = DshStateManager.shared.current
        let profileMutationAllowed = pluginMutationsAllowed
        if !profileMutationAllowed, appProfile != stateBeforeSave.appProfile {
            // A binding or an older caller may have changed the published
            // value before reaching this persistence boundary. Restore the
            // durable Profile while still allowing unrelated appearance and
            // access settings to be saved.
            appProfile = stateBeforeSave.appProfile
        }
        let profileToPersist = profileMutationAllowed ? appProfile : stateBeforeSave.appProfile
        let persistedExposure = browserAccessEnabled ? networkExposure : .loopback
        if networkExposure != persistedExposure {
            networkExposure = persistedExposure
        }
        if (runtimeChannel != .latest || appProfile == .web), autoFollowLatest {
            autoFollowLatest = false
        }
        let normalizedRegistry = DshVersionManager.normalizedRegistry(npmRegistry)
        let previousRegistry = DshVersionManager.normalizedRegistry(
            DshStateManager.shared.current.npmRegistry
        )
        let profileChanged = profileToPersist != stateBeforeSave.appProfile
        let registryChanged = normalizedRegistry != previousRegistry
        if profileChanged || registryChanged {
            catalogRequestGeneration &+= 1
            availableVersions = []
            latestVersion = nil
            nextVersion = nil
            alphaVersion = nil
            invalidateOutdatedPlugins(refreshList: false)
        }
        npmRegistry = normalizedRegistry
        DshStateManager.shared.update { state in
            state.dshPort = dshPort
            state.appProfile = profileToPersist
            state.npmRegistry = normalizedRegistry
            state.uiTheme = uiTheme
            state.autoFollowLatest = autoFollowLatest
            state.runtimeState.updatePolicy = autoFollowLatest ? .automaticStable : .notify
            state.runtimeState.channel = runtimeChannel
            state.networkExposure = persistedExposure
        }
        if profileChanged || registryChanged {
            // Remove old latest-version annotations immediately; otherwise a
            // failed check or a Profile switch can still make updateAll use
            // targets from the previous context.
            refreshPlugins()
        }
        MainWindowController.shared.syncUiTheme()
    }

    /// Switch the app's DSH profile and restart the managed service. The
    /// default desktop profile is isolated from terminal `dsh web`; selecting
    /// web is an explicit opt-in to sharing its plugin and dependency tree.
    public func setAppProfile(_ profile: DshAppProfile) {
        guard pluginMutationsAllowed,
              profile != appProfile,
              !isSwitchingProfile,
              !isOperatingPlugin,
              !isUpdatingRuntime,
              !isInstallingVersion else { return }

        let state = DshStateManager.shared.current
        guard state.pendingProfileSwitch == nil else {
            alertMessage = "上一次 Profile 切换尚未完成恢复，请重启 DSH 后再试。"
            return
        }
        if state.runtimeState.pending != nil,
           profile != state.runtimeState.profile {
            alertMessage = "Runtime 回滚尚未完成，只能使用 \(state.runtimeState.profile.rawValue) Profile；为保护 Profile 数据，暂不允许切换。"
            return
        }

        let previous = appProfile
        // A check result belongs to the old Profile. Invalidate it before
        // publishing the new selection so no stale badge can enable a write
        // while the switch is being prepared.
        invalidateOutdatedPlugins(refreshList: false)
        let leavingSharedWeb = previous == .web && profile == .desktop
        let transaction = DshProfileSwitchTransaction(from: previous, to: profile)

        // Persist the transaction together with the target Profile before any
        // pnpm or Node work begins. A force-quit after this point can therefore
        // be repaired deterministically during the next app launch.
        var didPersistTransaction = false
        switch DshStateManager.shared.update { state in
            guard state.appProfile == previous, state.pendingProfileSwitch == nil else { return }
            state.appProfile = profile
            state.pendingProfileSwitch = transaction
            didPersistTransaction = true
        } {
        case .success:
            break
        case .failure(let error):
            loadFromState()
            alertMessage = "Profile 切换事务写入失败，已取消本次切换：\(DshSettingsUIMessage.safe(error))"
            return
        }
        guard didPersistTransaction else {
            loadFromState()
            return
        }
        appProfile = profile
        refreshPlugins()
        saveGeneralSettings()
        isSwitchingProfile = true
        clearPluginStatus()

        Task { [self] in
            do {
                let cleanupError = try await MainWindowController.shared.withRuntimeOperation { () -> Error? in
                    guard let context = DshLaunchContext.makeStartup(from: DshStateManager.shared.current) else {
                        throw DshLaunchContextError.invalidProfileName
                    }
                    if leavingSharedWeb {
                        await DshService.shared.stopAndWait()
                    }
                    // A Profile switch replaces the service while the shared
                    // WebView may still be completing navigation for the old
                    // Profile. Give that stale authentication response the
                    // same single bounded recovery used by ordinary starts,
                    // Runtime updates and plugin verification.
                    _ = try await MainWindowController.shared
                        .restartDshServiceWithAuthenticationRecoveryDuringOperation(context: context)

                    var cleanupError: Error?
                    var finalizingTransaction = transaction
                    if leavingSharedWeb {
                        // The desktop target is already healthy. Mark this
                        // phase before touching the shared web tree so a
                        // force-quit can keep desktop and retry cleanup.
                        finalizingTransaction.phase = .finalizing
                        try DshStateManager.shared.updateOrThrow { state in
                            guard state.pendingProfileSwitch == transaction else { return }
                            state.pendingProfileSwitch = finalizingTransaction
                        }
                        do {
                            try await DshPluginManager.shared.removeDesktopHostArtifacts(
                                from: .web,
                                registry: context.runtimeDescriptor.registry
                            )
                        } catch {
                            cleanupError = error
                        }
                    }

                    // Commit only after the target Profile has passed the
                    // complete startup and health gate. This closes the small
                    // window where a successful restart could be followed by
                    // a force-quit before the UI task resumes.
                    try DshStateManager.shared.updateOrThrow { state in
                        guard let pending = state.pendingProfileSwitch,
                              pending.from == transaction.from,
                              pending.to == transaction.to,
                              pending.transactionID == transaction.transactionID else { return }
                        state.appProfile = profile
                        state.pendingProfileSwitch = cleanupError == nil ? nil : finalizingTransaction
                    }
                    return cleanupError
                }
                self.refreshPlugins()
                self.isSwitchingProfile = false
                if let cleanupError {
                    self.alertMessage = "已切换到 \(profile.rawValue) Profile，服务已重启，但 web 桥接清理失败，将在下次启动重试：\(DshSettingsUIMessage.safe(cleanupError))"
                } else {
                    self.showPluginStatus("已切换到 \(profile.rawValue) Profile，服务已重启")
                }
            } catch {
                // Keep the transaction marker while restoring. If this task
                // is interrupted, startup will still know to return to the
                // previous Profile and retry web cleanup.
                do {
                    try DshStateManager.shared.updateOrThrow { state in
                        guard state.pendingProfileSwitch == transaction else { return }
                        state.appProfile = previous
                    }
                } catch {
                    // Do not continue the in-process restore against a
                    // persisted state that still claims the target Profile:
                    // the rollback restart would launch the wrong Profile.
                    // Next-launch recovery restores the healthy Profile from
                    // the retained transaction marker.
                    self.isSwitchingProfile = false
                    self.alertMessage = "切换到 \(profile.rawValue) Profile 失败，且回滚标记写入失败：\(DshSettingsUIMessage.safe(error))。请重启应用，启动时会自动恢复 \(previous.rawValue) Profile。"
                    return
                }
                self.appProfile = previous
                self.saveGeneralSettings()
                var restoreError: Error?
                var restoreCleanupError: Error?
                do {
                    restoreCleanupError = try await MainWindowController.shared.withRuntimeOperation { () -> Error? in
                        guard let context = DshLaunchContext.makeStartup(from: DshStateManager.shared.current) else {
                            throw DshLaunchContextError.invalidProfileName
                        }
                        await DshService.shared.stopAndWait()
                        var cleanupError: Error?
                        if profile == .web && previous == .desktop {
                            do {
                                try await DshPluginManager.shared.removeDesktopHostArtifacts(
                                    from: .web,
                                    registry: context.runtimeDescriptor.registry
                                )
                            } catch {
                                // Bridge cleanup is app-owned housekeeping. It
                                // must not prevent the known-good desktop
                                // service from coming back; leave the marker
                                // pending so startup can retry the cleanup.
                                cleanupError = error
                            }
                        }
                        // Rollback crosses the same WebKit generation boundary
                        // as the forward switch. A stale response must not
                        // prevent the known-good Profile from being restored.
                        _ = try await MainWindowController.shared
                            .restartDshServiceWithAuthenticationRecoveryDuringOperation(context: context)
                        try DshStateManager.shared.updateOrThrow { state in
                            guard state.pendingProfileSwitch == transaction else { return }
                            state.appProfile = previous
                            state.pendingProfileSwitch = cleanupError == nil ? nil : transaction
                        }
                        return cleanupError
                    }
                    self.refreshPlugins()
                } catch {
                    restoreError = error
                }
                self.isSwitchingProfile = false
                if let restoreError {
                    self.alertMessage = "切换到 \(profile.rawValue) Profile 失败，原 Profile 也无法恢复：\(DshSettingsUIMessage.safe(restoreError))"
                } else if let restoreCleanupError {
                    self.alertMessage = "切换到 \(profile.rawValue) Profile 失败，已恢复 \(previous.rawValue) Profile，但 web 桥接清理失败，将在下次启动重试：\(DshSettingsUIMessage.safe(restoreCleanupError))"
                } else {
                    self.alertMessage = "切换到 \(profile.rawValue) Profile 失败，已恢复 \(previous.rawValue) Profile：\(DshSettingsUIMessage.safe(error))"
                }
            }
        }
    }

    /// Change the live Node policy and persist the setting in the order
    /// required by the browser-access contract. A failed policy update rolls
    /// both the UI and disk state back to the previous value.
    public func setBrowserAccessEnabled(_ enabled: Bool) {
        guard !isUpdatingBrowserAccess, enabled != browserAccessEnabled else { return }

        let previous = browserAccessEnabled
        browserAccessEnabled = enabled
        isUpdatingBrowserAccess = true
        Task { [self] in
            do {
                if enabled {
                    DshStateManager.shared.update { $0.browserAccessEnabled = true }
                    try await DshService.shared.setBrowserAccessEnabled(true)
                } else {
                    try await DshService.shared.setBrowserAccessEnabled(false)
                    DshStateManager.shared.update {
                        $0.browserAccessEnabled = false
                        $0.networkExposure = .loopback
                    }
                    self.networkExposure = .loopback
                    self.lanURL = nil
                }
            } catch {
                DshStateManager.shared.update { $0.browserAccessEnabled = previous }
                self.browserAccessEnabled = previous
                self.alertMessage = "更新浏览器访问设置失败：\(DshSettingsUIMessage.safe(error))"
            }
            self.isUpdatingBrowserAccess = false
        }
    }

    /// Toggle the separate LAN HTTP ingress. It is available only while the
    /// ordinary browser gate is enabled; the live policy is acknowledged
    /// before the state file is changed.
    public func setNetworkExposure(_ enabled: Bool) {
        let target: DshNetworkExposure = enabled ? .lan : .loopback
        guard !isUpdatingNetworkExposure,
              target != networkExposure else { return }
        guard browserAccessEnabled else {
            alertMessage = "请先开启浏览器访问。"
            return
        }

        let previous = networkExposure
        networkExposure = target
        isUpdatingNetworkExposure = true
        Task { [self] in
            do {
                try await DshService.shared.setNetworkExposure(target)
                DshStateManager.shared.update { $0.networkExposure = target }
                if target == .loopback { self.lanURL = nil }
            } catch {
                self.networkExposure = previous
                self.alertMessage = "更新局域网访问设置失败：\(DshSettingsUIMessage.safe(error))"
            }
            self.isUpdatingNetworkExposure = false
        }
    }

    public func refreshLANURL() {
        guard browserAccessEnabled,
              networkExposure == .lan,
              !isLoadingLANURL else { return }
        isLoadingLANURL = true
        Task { [self] in
            do {
                self.lanURL = try await MainWindowController.shared.fetchLANURL()
            } catch {
                self.alertMessage = "获取局域网地址失败：\(DshSettingsUIMessage.safe(error))"
            }
            self.isLoadingLANURL = false
        }
    }

    public func copyLANURL() {
        guard !isLoadingLANURL else { return }
        isLoadingLANURL = true
        Task { [self] in
            do {
                let url = try await MainWindowController.shared.fetchLANURL()
                self.lanURL = url
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(url.absoluteString, forType: .string)
                self.showPluginStatus("局域网访问地址已复制（10 分钟内有效）")
            } catch {
                self.alertMessage = "获取局域网地址失败：\(DshSettingsUIMessage.safe(error))"
            }
            self.isLoadingLANURL = false
        }
    }

    public func openBrowser() {
        guard browserAccessEnabled, !isOpeningBrowser else { return }
        isOpeningBrowser = true
        Task { [self] in
            do {
                let url = try await MainWindowController.shared.fetchAuthenticatedBrowserURL()
                guard NSWorkspace.shared.open(url) else {
                    throw MainWindowController.BrowserURLError.openFailed
                }
            } catch {
                self.alertMessage = "打开浏览器失败：\(DshSettingsUIMessage.safe(error))"
            }
            self.isOpeningBrowser = false
        }
    }

    public func restartDshService() {
        MainWindowController.shared.startAndLoadDsh()
    }

    private func restartDshServiceAndWait() async throws {
        _ = try await MainWindowController.shared.restartDshService()
    }

    private func restartDshServiceDuringOperationAndWait() async throws {
        _ = try await MainWindowController.shared.restartDshServiceDuringOperation()
    }

    private func clearPluginStatus() {
        pluginStatusGeneration &+= 1
        pluginStatusDismissTask?.cancel()
        pluginStatusDismissTask = nil
        pluginStatusMessage = nil
    }

    private func showPluginStatus(_ message: String) {
        pluginStatusGeneration &+= 1
        let generation = pluginStatusGeneration
        pluginStatusDismissTask?.cancel()
        pluginStatusMessage = message
        pluginStatusDismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled,
                  let self,
                  self.pluginStatusGeneration == generation else { return }
            self.pluginStatusMessage = nil
            self.pluginStatusDismissTask = nil
        }
    }

    private func holdRefreshAnimation(since startedAt: Date) async {
        let minimumDuration = 0.9
        let remaining = minimumDuration - Date().timeIntervalSince(startedAt)
        guard remaining > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
    }
}
