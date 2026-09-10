import Foundation
import CryptoKit

public enum DshNetworkExposure: String, Codable, Sendable {
    case loopback
    case lan
}

public enum DshRuntimeUpdatePolicy: String, Codable, Sendable {
    case notify
    case automaticStable
}

public enum DshRuntimeChannel: String, Codable, Sendable {
    case latest
    case next
    case alpha

    /// Resolve the release channel represented by an installed Runtime
    /// version. This is deliberately independent from the user's pending
    /// update-channel setting: changing that setting must not rewrite the
    /// channel shown for the Runtime that is already running.
    public static func inferred(from version: String) -> DshRuntimeChannel {
        guard let prerelease = version
            .split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            .dropFirst()
            .first,
            let identifier = prerelease.split(separator: ".").first else {
            return .latest
        }

        switch identifier {
        case "alpha":
            return .alpha
        case "rc":
            return .next
        default:
            return .latest
        }
    }
}

/// The DSH profile used by the desktop app. The isolated desktop profile is
/// the default so terminal `dsh web` keeps its own dependency tree.
public enum DshAppProfile: String, Codable, CaseIterable, Hashable, Sendable {
    case desktop
    case web

    /// The logical `.desktop` selection predates upstream's reservation of
    /// the literal `desktop` profile for its Electron application. Keep the
    /// persisted enum value stable, but use an App-specific name whenever a
    /// path or Runtime launch target is constructed.
    public var runtimeProfileName: String {
        switch self {
        case .desktop: return "swift-desktop"
        case .web: return rawValue
        }
    }

    public var displayName: String {
        switch self {
        case .desktop: return "swift-desktop（推荐）"
        case .web: return "web（与终端共享）"
        }
    }

    public var terminalImpactDescription: String {
        switch self {
        case .desktop:
            return "App 使用独立的 profiles/swift-desktop；终端 dsh web 继续使用 profiles/web，插件和依赖互不影响。"
        case .web:
            return "App 与终端 dsh web 共用 profiles/web；插件变更可能影响终端启动，切回 swift-desktop 时会清理 App 注入的桥接依赖。"
        }
    }
}

/// A Profile switch is persisted before the target Profile is started. The
/// app may be terminated while pnpm or Node is materializing the target tree;
/// on the next launch this record tells startup which Profile was known to be
/// healthy and must be restored.
public struct DshProfileSwitchTransaction: Codable, Equatable, Sendable {
    public var from: DshAppProfile
    public var to: DshAppProfile
    public var phase: DshProfileSwitchPhase
    public var startedAt: Date
    /// Stable identity for one persisted Profile switch. Older state files
    /// did not carry this field; decoding derives a deterministic legacy
    /// identity so that recovery can still finish safely without accepting a
    /// nil-to-nil transaction match.
    public var transactionID: String

    public init(
        from: DshAppProfile,
        to: DshAppProfile,
        phase: DshProfileSwitchPhase = .switching,
        startedAt: Date = Date(),
        transactionID: String = UUID().uuidString
    ) {
        precondition(!transactionID.isEmpty, "Profile switch transaction ID must not be empty")
        self.from = from
        self.to = to
        self.phase = phase
        self.startedAt = startedAt
        self.transactionID = transactionID
    }

    private enum CodingKeys: String, CodingKey {
        case from
        case to
        case phase
        case startedAt
        case transactionID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let source = try container.decode(DshAppProfile.self, forKey: .from)
        let target = try container.decode(DshAppProfile.self, forKey: .to)
        let phase = try container.decodeIfPresent(DshProfileSwitchPhase.self, forKey: .phase) ?? .switching
        let startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt) ?? Date(timeIntervalSince1970: 0)
        self.from = source
        self.to = target
        self.phase = phase
        self.startedAt = startedAt
        let persistedID = try container.decodeIfPresent(String.self, forKey: .transactionID)
        self.transactionID = persistedID?.isEmpty == false
            ? persistedID!
            : Self.legacyTransactionID(
                from: source,
                to: target,
                phase: phase,
                startedAt: startedAt
            )
    }

    private struct LegacyIdentity: Encodable {
        let from: String
        let to: String
        let phase: String
        let startedAt: String
    }

    private static func legacyTransactionID(
        from: DshAppProfile,
        to: DshAppProfile,
        phase: DshProfileSwitchPhase,
        startedAt: Date
    ) -> String {
        let identity = LegacyIdentity(
            from: from.rawValue,
            to: to.rawValue,
            phase: phase.rawValue,
            startedAt: String(format: "%.17g", startedAt.timeIntervalSinceReferenceDate)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(identity)) ?? Data()
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return "legacy-profile-" + digest
    }
}

/// The target service is not considered committed until its startup and
/// health gate pass. The finalizing phase is used only when switching away
/// from the shared web Profile: desktop is already healthy, while web bridge
/// cleanup remains retryable.
public enum DshProfileSwitchPhase: String, Codable, Sendable {
    case switching
    case finalizing
}

public enum DshRuntimeTransactionPhase: String, Codable, Sendable {
    case idle
    case staging
    case switching
    case verifying
    case confirmed
    case rollingBack
}

public struct NpmRuntimeDescriptor: Codable, Equatable, Sendable {
    public let version: String
    public let registry: String
    public let integrity: String?
    public let installedAt: Date

    public init(version: String, registry: String, integrity: String? = nil, installedAt: Date = Date()) {
        self.version = version
        self.registry = registry
        self.integrity = integrity
        self.installedAt = installedAt
    }
}

public struct DshRuntimeState: Codable, Equatable, Sendable {
    public var active: NpmRuntimeDescriptor?
    public var previous: NpmRuntimeDescriptor?
    public var pending: NpmRuntimeDescriptor?
    /// Profile that owns an in-flight Runtime transaction. This is persisted
    /// so a failed rollback can never restore a desktop snapshot into the
    /// shared web profile after a later app-profile change.
    public var profile: DshAppProfile
    public var phase: DshRuntimeTransactionPhase
    public var updatePolicy: DshRuntimeUpdatePolicy
    public var channel: DshRuntimeChannel
    public var dismissedVersion: String?
    public var dismissedAppVersion: String?
    public var webProfileSnapshotID: String?
    public var healthyStartCount: Int
    public var lastDiagnostic: String?
    /// Identity of the Runtime transaction that owns pending/confirmed
    /// cleanup state. It is retained through the confirmed health-count
    /// window and cleared when the transaction settles idle.
    public var transactionID: String?

    public init(
        active: NpmRuntimeDescriptor? = nil,
        previous: NpmRuntimeDescriptor? = nil,
        pending: NpmRuntimeDescriptor? = nil,
        profile: DshAppProfile = .desktop,
        phase: DshRuntimeTransactionPhase = .idle,
        updatePolicy: DshRuntimeUpdatePolicy = .notify,
        channel: DshRuntimeChannel = .latest,
        dismissedVersion: String? = nil,
        dismissedAppVersion: String? = nil,
        webProfileSnapshotID: String? = nil,
        healthyStartCount: Int = 0,
        lastDiagnostic: String? = nil,
        transactionID: String? = nil
    ) {
        self.active = active
        self.previous = previous
        self.pending = pending
        self.profile = profile
        self.phase = phase
        self.updatePolicy = channel == .latest ? updatePolicy : .notify
        self.channel = channel
        self.dismissedVersion = dismissedVersion
        self.dismissedAppVersion = dismissedAppVersion
        self.webProfileSnapshotID = webProfileSnapshotID
        self.healthyStartCount = healthyStartCount
        self.lastDiagnostic = lastDiagnostic
        self.transactionID = transactionID
    }

    private enum CodingKeys: String, CodingKey {
        case active
        case previous
        case pending
        case profile
        case phase
        case updatePolicy
        case channel
        case dismissedVersion
        case dismissedAppVersion
        case webProfileSnapshotID
        case healthyStartCount
        case lastDiagnostic
        case transactionID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.active = try container.decodeIfPresent(NpmRuntimeDescriptor.self, forKey: .active)
        self.previous = try container.decodeIfPresent(NpmRuntimeDescriptor.self, forKey: .previous)
        self.pending = try container.decodeIfPresent(NpmRuntimeDescriptor.self, forKey: .pending)
        // Runtime updates have always been restricted to desktop. Missing
        // metadata therefore safely migrates legacy transactions to desktop.
        self.profile = try container.decodeIfPresent(DshAppProfile.self, forKey: .profile) ?? .desktop
        self.phase = try container.decodeIfPresent(DshRuntimeTransactionPhase.self, forKey: .phase) ?? .idle
        self.updatePolicy = try container.decodeIfPresent(DshRuntimeUpdatePolicy.self, forKey: .updatePolicy) ?? .notify
        self.channel = try container.decodeIfPresent(DshRuntimeChannel.self, forKey: .channel) ?? .latest
        if self.channel != .latest {
            self.updatePolicy = .notify
        }
        self.dismissedVersion = try container.decodeIfPresent(String.self, forKey: .dismissedVersion)
        self.dismissedAppVersion = try container.decodeIfPresent(String.self, forKey: .dismissedAppVersion)
        self.webProfileSnapshotID = try container.decodeIfPresent(String.self, forKey: .webProfileSnapshotID)
        self.healthyStartCount = try container.decodeIfPresent(Int.self, forKey: .healthyStartCount) ?? 0
        self.lastDiagnostic = try container.decodeIfPresent(String.self, forKey: .lastDiagnostic)
        let persistedID = try container.decodeIfPresent(String.self, forKey: .transactionID)
        if phase == .idle {
            // Idle state has no transaction owner. Decoding must not preserve
            // a non-empty value here: the mutation gates require
            // transactionID == nil while idle, so an old or foreign writer
            // that kept one would otherwise lock every plugin/update
            // operation forever without any recovery path.
            self.transactionID = nil
        } else if persistedID?.isEmpty == false {
            self.transactionID = persistedID!
        } else {
            // Legacy transactions had no owner ID. Derive one from every
            // persisted identity field, including full-precision descriptor
            // timestamps, so recovery can proceed without accepting a nil ID
            // and adjacent millisecond transactions cannot collide.
            self.transactionID = Self.legacyTransactionID(
                active: active,
                previous: previous,
                pending: pending,
                profile: self.profile,
                phase: self.phase,
                updatePolicy: self.updatePolicy,
                channel: self.channel,
                webProfileSnapshotID: self.webProfileSnapshotID
            )
        }
    }

    private struct LegacyDescriptor: Encodable {
        let version: String
        let registry: String
        let integrity: String?
        let installedAt: String
    }

    private struct LegacyIdentity: Encodable {
        let active: LegacyDescriptor?
        let previous: LegacyDescriptor?
        let pending: LegacyDescriptor?
        let profile: String
        let phase: String
        let updatePolicy: String
        let channel: String
        let webProfileSnapshotID: String?
    }

    private static func legacyTransactionID(
        active: NpmRuntimeDescriptor?,
        previous: NpmRuntimeDescriptor?,
        pending: NpmRuntimeDescriptor?,
        profile: DshAppProfile,
        phase: DshRuntimeTransactionPhase,
        updatePolicy: DshRuntimeUpdatePolicy,
        channel: DshRuntimeChannel,
        webProfileSnapshotID: String?
    ) -> String {
        func descriptor(_ value: NpmRuntimeDescriptor?) -> LegacyDescriptor? {
            value.map {
                LegacyDescriptor(
                    version: $0.version,
                    registry: $0.registry,
                    integrity: $0.integrity,
                    installedAt: String(format: "%.17g", $0.installedAt.timeIntervalSinceReferenceDate)
                )
            }
        }
        let identity = LegacyIdentity(
            active: descriptor(active),
            previous: descriptor(previous),
            pending: descriptor(pending),
            profile: profile.rawValue,
            phase: phase.rawValue,
            updatePolicy: updatePolicy.rawValue,
            channel: channel.rawValue,
            webProfileSnapshotID: webProfileSnapshotID
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(identity)) ?? Data()
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return "legacy-runtime-" + digest
    }

    public static let `default` = DshRuntimeState()
}

public enum DshRuntimeRecoveryAction: Equatable, Sendable {
    case finalizeConfirmed(active: NpmRuntimeDescriptor)
    case rollback(active: NpmRuntimeDescriptor, candidate: NpmRuntimeDescriptor)
    case reset(candidate: NpmRuntimeDescriptor)
}

/// Pure recovery decision logic shared by startup and integration tests.
/// Filesystem deletion and service restart stay outside this planner.
public enum DshRuntimeRecoveryPlanner {
    public static func plan(
        state: DshStateConfig,
        installedVersions: Set<String>
    ) -> DshRuntimeRecoveryAction? {
        guard let pending = state.runtimeState.pending else { return nil }

        if state.runtimeState.phase == .confirmed,
           state.selectedVersion == pending.version,
           installedVersions.contains(pending.version) {
            return .finalizeConfirmed(active: pending)
        }

        if let previous = state.runtimeState.previous,
           installedVersions.contains(previous.version) {
            return .rollback(active: previous, candidate: pending)
        }

        return .reset(candidate: pending)
    }
}

/// Runtime transaction gates used by the settings surface. A successfully
/// updated Runtime remains in `confirmed` until a second healthy start proves
/// that the old Runtime can be removed.
///
/// Two different scopes share this type on purpose:
/// - `allowsPluginMutation` is the **general settings** gate (port, theme,
///   Registry, channel, browser access, and read-only plugin work). It stays
///   open during `confirmed` so an update does not freeze unrelated settings.
/// - `allowsProfileTreeMutation` is the **Profile/package-tree** gate (plugin
///   install/update/remove and Profile switching). It requires a settled
///   `idle` Runtime, because a confirmed transaction keeps a full rollback
///   snapshot of exactly that tree: a plugin change made in the window would be
///   silently reverted by "roll back to the previous Runtime" (T1), and a
///   Profile switch would make the second healthy start unreachable and strand
///   the cleanup (T4). The user-visible rule is "restart once after an update,
///   then change plugins or switch Profiles".
public enum DshRuntimeMutationGate {
    public static func allowsPluginMutation(_ state: DshStateConfig) -> Bool {
        guard state.pendingProfileSwitch == nil,
              state.runtimeState.pending == nil else { return false }

        switch state.runtimeState.phase {
        case .idle:
            return state.runtimeState.previous == nil
                && state.runtimeState.webProfileSnapshotID == nil
                && state.runtimeState.transactionID == nil
        case .confirmed:
            // The candidate passed its in-process startup/health gate, so
            // ordinary settings may proceed while the cleanup window is open.
            return state.runtimeState.previous != nil
                && state.runtimeState.transactionID != nil
        case .staging, .switching, .verifying, .rollingBack:
            return false
        }
    }

    /// Gate for mutations that change the Profile/package tree that a
    /// confirmed Runtime transaction still holds a rollback snapshot for.
    public static func allowsProfileTreeMutation(_ state: DshStateConfig) -> Bool {
        allowsPluginMutation(state) && state.runtimeState.phase == .idle
    }

    public static func allowsRuntimeUpdate(_ state: DshStateConfig) -> Bool {
        guard allowsPluginMutation(state) else { return false }
        return state.runtimeState.phase == .idle
    }
}

/// Pure transaction transitions. Side effects such as npm installation,
/// service restart and filesystem cleanup remain in their callers, while the
/// persisted state shape is exercised by executable integration tests.
public enum DshRuntimeTransaction {
    public static func begin(
        active: NpmRuntimeDescriptor,
        candidate: NpmRuntimeDescriptor,
        updatePolicy: DshRuntimeUpdatePolicy,
        channel: DshRuntimeChannel,
        profile: DshAppProfile = .desktop,
        transactionID: String = UUID().uuidString
    ) -> DshRuntimeState {
        precondition(!transactionID.isEmpty, "Runtime transaction ID must not be empty")
        return DshRuntimeState(
            active: active,
            previous: active,
            pending: candidate,
            profile: profile,
            phase: .staging,
            updatePolicy: updatePolicy,
            channel: channel,
            healthyStartCount: 0,
            lastDiagnostic: nil,
            transactionID: transactionID
        )
    }

    public static func attachWebProfileSnapshot(
        _ state: DshRuntimeState,
        id: String,
        profile: DshAppProfile? = nil
    ) -> DshRuntimeState {
        var next = state
        next.webProfileSnapshotID = id
        if let profile {
            next.profile = profile
        }
        return next
    }

    public static func activateCandidate(_ state: DshRuntimeState) -> DshRuntimeState {
        guard let candidate = state.pending else { return state }
        var next = state
        next.active = candidate
        next.phase = .switching
        return next
    }

    public static func beginVerification(_ state: DshRuntimeState) -> DshRuntimeState {
        var next = state
        next.phase = .verifying
        return next
    }

    public static func confirm(_ state: DshRuntimeState) -> DshRuntimeState {
        var next = state
        next.pending = nil
        next.phase = .confirmed
        next.dismissedVersion = nil
        next.dismissedAppVersion = nil
        next.healthyStartCount = 1
        next.lastDiagnostic = nil
        return next
    }

    public static func beginRollback(_ state: DshRuntimeState) -> DshRuntimeState {
        var next = state
        next.phase = .rollingBack
        return next
    }

    public static func recordRollbackFailure(
        _ state: DshRuntimeState,
        diagnostic: String
    ) -> DshRuntimeState {
        var next = state
        next.phase = .rollingBack
        next.lastDiagnostic = diagnostic
        return next
    }

    public static func finishRollback(
        _ state: DshRuntimeState,
        active: NpmRuntimeDescriptor,
        retainedWebProfileSnapshotID: String? = nil
    ) -> DshRuntimeState {
        var next = state
        next.active = active
        next.previous = nil
        next.pending = nil
        next.phase = .idle
        next.webProfileSnapshotID = retainedWebProfileSnapshotID
        next.healthyStartCount = 0
        next.transactionID = nil
        return next
    }

    /// Repair an "idle residue": a state that already settled to `idle` but
    /// still carries transaction bookkeeping (`previous`/`transactionID`).
    ///
    /// The mutation gates require both to be empty while idle
    /// (`DshRuntimeMutationGate`), and no transaction transition clears them
    /// once the phase is idle, so such a residue locks every plugin and
    /// Runtime-update operation forever. It could be produced when a state
    /// writer mistook an open transaction for a settled one (for example an
    /// interrupted user-initiated rollback, whose `pending` is already nil).
    ///
    /// Only the transaction bookkeeping is cleared. A retained
    /// `webProfileSnapshotID` is deliberately preserved: it still references a
    /// real snapshot that `retryRetainedWebProfileSnapshotCleanup` must delete
    /// on this or the next launch, and dropping the reference would turn that
    /// snapshot into an untracked multi-GB leak.
    ///
    /// Returns nil when the state is not a settled idle residue, so callers can
    /// treat "no repair" and "repaired" distinctly.
    public static func repairIdleTransactionResidue(_ state: DshRuntimeState) -> DshRuntimeState? {
        guard state.phase == .idle, state.pending == nil else { return nil }
        guard state.previous != nil || state.transactionID != nil else { return nil }
        var next = state
        next.previous = nil
        next.transactionID = nil
        next.healthyStartCount = 0
        let detail = "检测到已结算的 DSH Runtime 事务残留，已自动清理事务引用。"
        if let existing = next.lastDiagnostic, !existing.isEmpty {
            next.lastDiagnostic = existing + " " + detail
        } else {
            next.lastDiagnostic = detail
        }
        return next
    }

    /// Final shape of an abandoned Runtime transaction the recovery planner
    /// cannot roll back or finalize (no usable previous Runtime, no usable
    /// candidate). Every transaction field must be cleared, including
    /// `transactionID`: `DshRuntimeMutationGate` requires all of
    /// previous/transactionID/webProfileSnapshotID to be empty while idle, and
    /// a reset that leaves the owner behind keeps plugin and Runtime-update
    /// mutations locked until the next decode or launch.
    ///
    /// The caller owns the Profile snapshot: this transition clears the
    /// reference only after the reset path has restored or deleted it.
    public static func settleAbandoned(
        _ state: DshRuntimeState,
        diagnostic: String
    ) -> DshRuntimeState {
        var next = state
        next.active = nil
        next.previous = nil
        next.pending = nil
        next.phase = .idle
        next.webProfileSnapshotID = nil
        next.healthyStartCount = 0
        next.transactionID = nil
        next.lastDiagnostic = diagnostic
        return next
    }
}

/// Persistent configuration and state model for DSH Desktop.
public struct DshStateConfig: Codable, Equatable {
    public var selectedVersion: String?
    public var appProfile: DshAppProfile
    /// Non-nil while a Profile switch has not yet completed its startup and
    /// cleanup gates. This is intentionally separate from Runtime update
    /// state: switching to the shared web Profile must be recoverable without
    /// taking or restoring a Runtime snapshot.
    public var pendingProfileSwitch: DshProfileSwitchTransaction?
    public var dismissedLatest: String?
    public var autoFollowLatest: Bool
    public var npmRegistry: String?
    public var runtimeState: DshRuntimeState
    public var dshPort: Int?
    public var browserAccessEnabled: Bool
    public var networkExposure: DshNetworkExposure
    public var uiTheme: String
    public var cachedUserPath: String?

    public init(
        selectedVersion: String? = nil,
        appProfile: DshAppProfile = .desktop,
        pendingProfileSwitch: DshProfileSwitchTransaction? = nil,
        dismissedLatest: String? = nil,
        autoFollowLatest: Bool = false,
        npmRegistry: String? = nil,
        runtimeState: DshRuntimeState = .default,
        dshPort: Int? = 3080,
        browserAccessEnabled: Bool = false,
        networkExposure: DshNetworkExposure = .loopback,
        uiTheme: String = "default",
        cachedUserPath: String? = nil
    ) {
        self.selectedVersion = selectedVersion
        self.appProfile = appProfile
        self.pendingProfileSwitch = pendingProfileSwitch
        self.dismissedLatest = dismissedLatest
        self.autoFollowLatest = autoFollowLatest
        self.npmRegistry = npmRegistry
        self.runtimeState = runtimeState
        self.dshPort = dshPort ?? 3080
        self.browserAccessEnabled = browserAccessEnabled
        self.networkExposure = browserAccessEnabled ? networkExposure : .loopback
        self.uiTheme = uiTheme
        self.cachedUserPath = cachedUserPath
    }

    private enum CodingKeys: String, CodingKey {
        case selectedVersion
        case appProfile
        case pendingProfileSwitch
        case dismissedLatest
        case autoFollowLatest
        case npmRegistry
        case runtimeState
        case dshPort
        case browserAccessEnabled
        case networkExposure
        case uiTheme
        case cachedUserPath
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.selectedVersion = try container.decodeIfPresent(String.self, forKey: .selectedVersion)
        // Legacy state files used the shared web profile. New app launches
        // intentionally migrate to an isolated desktop profile; the old web
        // directory is left untouched for terminal DSH usage.
        self.appProfile = try container.decodeIfPresent(DshAppProfile.self, forKey: .appProfile) ?? .desktop
        self.pendingProfileSwitch = try container.decodeIfPresent(DshProfileSwitchTransaction.self, forKey: .pendingProfileSwitch)
        self.dismissedLatest = try container.decodeIfPresent(String.self, forKey: .dismissedLatest)
        // New profiles default to notification-only updates. If an older
        // profile explicitly persisted autoFollowLatest, preserve that user
        // choice during migration.
        self.autoFollowLatest = try container.decodeIfPresent(Bool.self, forKey: .autoFollowLatest) ?? false
        self.npmRegistry = try container.decodeIfPresent(String.self, forKey: .npmRegistry)
        if let runtimeState = try container.decodeIfPresent(DshRuntimeState.self, forKey: .runtimeState) {
            self.runtimeState = runtimeState
            // Keep the legacy field coherent for older app builds that may
            // still decode the same state file.
            self.autoFollowLatest = runtimeState.updatePolicy == .automaticStable
        } else {
            self.runtimeState = DshRuntimeState(
                updatePolicy: self.autoFollowLatest ? .automaticStable : .notify,
                dismissedVersion: self.dismissedLatest
            )
        }
        self.dshPort = try container.decodeIfPresent(Int.self, forKey: .dshPort) ?? 3080
        // Missing in pre-2A state files means browser access remains closed.
        self.browserAccessEnabled = try container.decodeIfPresent(Bool.self, forKey: .browserAccessEnabled) ?? false
        let decodedExposure = try container.decodeIfPresent(DshNetworkExposure.self, forKey: .networkExposure) ?? .loopback
        self.networkExposure = self.browserAccessEnabled ? decodedExposure : .loopback
        self.uiTheme = try container.decodeIfPresent(String.self, forKey: .uiTheme) ?? "default"
        self.cachedUserPath = try container.decodeIfPresent(String.self, forKey: .cachedUserPath)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(selectedVersion, forKey: .selectedVersion)
        try container.encode(appProfile, forKey: .appProfile)
        try container.encodeIfPresent(pendingProfileSwitch, forKey: .pendingProfileSwitch)
        try container.encodeIfPresent(dismissedLatest, forKey: .dismissedLatest)
        try container.encode(autoFollowLatest, forKey: .autoFollowLatest)
        try container.encodeIfPresent(npmRegistry, forKey: .npmRegistry)
        try container.encode(runtimeState, forKey: .runtimeState)
        try container.encode(dshPort, forKey: .dshPort)
        try container.encode(browserAccessEnabled, forKey: .browserAccessEnabled)
        try container.encode(networkExposure, forKey: .networkExposure)
        try container.encode(uiTheme, forKey: .uiTheme)
        try container.encodeIfPresent(cachedUserPath, forKey: .cachedUserPath)
    }

    public static let `default` = DshStateConfig()
}

/// The primary state file has a different contract from optional caches:
/// absence is a normal first-install condition, while an existing file that
/// cannot be read or decoded is an unresolved persistence failure. Keeping
/// those cases distinct prevents startup from silently replacing user state
/// with defaults.
public enum DshStateLoadResult: Equatable, Sendable {
    case absent
    case loaded
    case unreadable(String)
    case corrupted(String)

    public var isUsable: Bool {
        switch self {
        case .absent, .loaded:
            return true
        case .unreadable, .corrupted:
            return false
        }
    }

    public var failureDescription: String? {
        switch self {
        case .absent, .loaded:
            return nil
        case .unreadable(let detail), .corrupted(let detail):
            return detail
        }
    }
}

/// The first startup decision must be made from the primary state-file load
/// result, not from the in-memory fallback config. An absent file is a normal
/// first launch; an existing file that cannot be read or decoded is a hard
/// stop until the user can inspect or repair it without DSH touching a
/// Profile.
public enum DshStateStartupDecision: Equatable, Sendable {
    case proceed
    case block(String)

    public static func decide(for result: DshStateLoadResult) -> Self {
        switch result {
        case .absent, .loaded:
            return .proceed
        case .unreadable(let detail), .corrupted(let detail):
            return .block(detail)
        }
    }
}

public enum DshStatePersistenceError: Error, LocalizedError, Equatable, Sendable {
    case stateUnavailable(String)
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .stateUnavailable(let detail):
            return "DSH 状态不可用：\(detail)"
        case .writeFailed(let detail):
            return "DSH 状态写入失败：\(detail)"
        }
    }
}

public final class DshStateManager {
    public static let shared = DshStateManager()

    private let lock = NSLock()
    private var config: DshStateConfig
    private let fileURL: URL
    private var loadResultValue: DshStateLoadResult
    private var persistenceErrorValue: DshStatePersistenceError?

    public static var appSupportDirectory: URL {
#if DSH_TESTING
        // Test-only seam: production builds retain the normal per-user
        // Application Support location. Test binaries must opt in to an
        // explicit temporary root so fixture runs cannot touch user state.
        guard let override = ProcessInfo.processInfo.environment["DSH_TEST_APP_SUPPORT"],
              !override.isEmpty else {
            fatalError("DSH_TESTING requires DSH_TEST_APP_SUPPORT")
        }
        let appSupport = URL(fileURLWithPath: override, isDirectory: true)
#else
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
#endif
        let dshDir = appSupport.appendingPathComponent("DSH", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dshDir.path) {
            try? FileManager.default.createDirectory(at: dshDir, withIntermediateDirectories: true)
        }
        return dshDir
    }

    public static var versionsDirectory: URL {
        let dir = appSupportDirectory.appendingPathComponent("dsh-versions", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private init() {
        self.fileURL = Self.appSupportDirectory.appendingPathComponent("dsh-state.json")
        self.persistenceErrorValue = nil
        switch Self.readStateResult(from: fileURL) {
        case .absent:
            self.config = .default
            self.loadResultValue = .absent
        case .loaded(let decoded):
            self.config = decoded
            self.loadResultValue = .loaded
        case .unreadable(let detail):
            self.config = .default
            self.loadResultValue = .unreadable(detail)
        case .corrupted(let detail):
            self.config = .default
            self.loadResultValue = .corrupted(detail)
        }
    }

    /// Read a state file without collapsing an existing but invalid file into
    /// the first-launch default. This is public for isolated startup tests and
    /// for callers that need to gate recovery before touching user state.
    public static func readState(from url: URL) -> Result<DshStateConfig, DshStatePersistenceError> {
        switch readStateResult(from: url) {
        case .absent:
            return .success(.default)
        case .loaded(let decoded):
            return .success(decoded)
        case .unreadable(let detail), .corrupted(let detail):
            return .failure(.stateUnavailable(detail))
        }
    }

    private static func readStateResult(from url: URL) -> StateFileReadResult {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .absent
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return .unreadable(safePersistenceDetail(error))
        }
        do {
            return .loaded(try JSONDecoder().decode(DshStateConfig.self, from: data))
        } catch {
            return .corrupted(safePersistenceDetail(error))
        }
    }

    private enum StateFileReadResult {
        case absent
        case loaded(DshStateConfig)
        case unreadable(String)
        case corrupted(String)
    }

    private static func safePersistenceDetail(_ error: Error) -> String {
        let description = error.localizedDescription
        return description.isEmpty ? String(describing: error) : description
    }

    public var current: DshStateConfig {
        lock.lock()
        defer { lock.unlock() }
        return config
    }

    /// Distinguish first launch, a valid state, and an invalid existing state.
    /// A caller must not infer first launch merely from `current == .default`.
    public var loadResult: DshStateLoadResult {
        lock.lock()
        defer { lock.unlock() }
        return loadResultValue
    }

    public var lastPersistenceError: DshStatePersistenceError? {
        lock.lock()
        defer { lock.unlock() }
        return persistenceErrorValue
    }

    /// Persist an update atomically. The return value is intentionally
    /// discardable for source compatibility with existing UI call sites, but
    /// callers that report success must inspect it (or use `updateOrThrow`).
    @discardableResult
    public func update(_ mutate: (inout DshStateConfig) -> Void) -> Result<Void, DshStatePersistenceError> {
        lock.lock()
        defer { lock.unlock() }

        guard loadResultValue.isUsable else {
            let detail = loadResultValue.failureDescription ?? "状态文件不可用"
            let error = DshStatePersistenceError.stateUnavailable(detail)
            persistenceErrorValue = error
            return .failure(error)
        }

        var candidate = config
        mutate(&candidate)
        do {
            try Self.writeState(candidate, to: fileURL)
            config = candidate
            persistenceErrorValue = nil
            if case .absent = loadResultValue {
                loadResultValue = .loaded
            }
            return .success(())
        } catch let error as DshStatePersistenceError {
            persistenceErrorValue = error
            return .failure(error)
        } catch {
            let wrapped = DshStatePersistenceError.writeFailed(Self.safePersistenceDetail(error))
            persistenceErrorValue = wrapped
            return .failure(wrapped)
        }
    }

    /// Throwing form for transaction boundaries that cannot continue after a
    /// failed state commit.
    public func updateOrThrow(_ mutate: (inout DshStateConfig) -> Void) throws {
        switch update(mutate) {
        case .success:
            return
        case .failure(let error):
            throw error
        }
    }

    private static func writeState(_ state: DshStateConfig, to url: URL) throws {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(state)
            try data.write(to: url, options: .atomic)
        } catch let error as DshStatePersistenceError {
            throw error
        } catch {
            throw DshStatePersistenceError.writeFailed(safePersistenceDetail(error))
        }
    }
}
