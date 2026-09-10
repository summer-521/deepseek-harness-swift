import Foundation
import CryptoKit
import Darwin

/// A resolved install target: the registry name plus the concrete version
/// the specifier would install. Produced without mutating anything so the
/// UI can gate downgrades before stopping services or taking snapshots.
public struct DshInstallCandidate: Equatable, Sendable {
    public let name: String
    public let version: String

    public init(name: String, version: String) {
        self.name = name
        self.version = version
    }
}

public struct DshPluginItem: Identifiable, Equatable {
    public var id: String { name }
    public let name: String
    public let version: String?
    public let latestVersion: String?
    public let description: String?
    public let isManaged: Bool
    public let isLocal: Bool

    public var hasUpdate: Bool {
        guard let latest = latestVersion, let current = version else { return false }
        let cleanCurrent = current.replacingOccurrences(of: "^", with: "").replacingOccurrences(of: "~", with: "")
        return latest != cleanCurrent && !isLocal && !isManaged
    }

    public init(name: String, version: String? = nil, latestVersion: String? = nil, description: String? = nil, isManaged: Bool = false, isLocal: Bool = false) {
        self.name = name
        self.version = version
        self.latestVersion = latestVersion
        self.description = description
        self.isManaged = isManaged
        self.isLocal = isLocal
    }
}

public enum DshPendingPluginUpdate: Equatable, Sendable {
    case plugin(String)
    case all
}

/// A pending user confirmation for an install that would downgrade an
/// already-installed plugin (the requested tag currently resolves below the
/// installed version). Confirming proceeds with the same release-age policy;
/// only the downgrade itself is acknowledged.
public struct DshPendingPluginDowngrade: Equatable, Sendable {
    public let spec: String
    public let name: String
    public let installedVersion: String
    public let candidateVersion: String

    public init(spec: String, name: String, installedVersion: String, candidateVersion: String) {
        self.spec = spec
        self.name = name
        self.installedVersion = installedVersion
        self.candidateVersion = candidateVersion
    }
}

/// Result of the read-only update resolver.  A preflight is deliberately
/// advisory: registry/network failures are reported as `inconclusive` so the
/// normal P01 transaction remains the source of truth.  Only a confirmed
/// minimum-release-age rejection is safe to surface before stopping the
/// service or creating a rollback snapshot.
public enum DshPluginUpdatePreflightResult: Equatable, Sendable {
    case clear
    case minimumReleaseAgeViolation
    case inconclusive
}

/// Read-only classification used by launch integration before any Profile
/// bootstrap write. A missing manifest is safe to bootstrap only when the
/// selected directory is genuinely empty; an existing but incomplete tree is
/// preserved for inspection/recovery.
public enum DshProfileBootstrapReadiness: String, Sendable {
    case freshEmpty
    case initialized
    case existingUninitialized
    case invalid
}

public enum DshPluginStartupGateDecision: String, Sendable {
    case allowFreshProfileBootstrap
    case allowProfileMutation
    case blockProfileMutation
}

public enum DshPluginManagerStartupGate {
    /// The Inspector deliberately stays independent from this manager. The
    /// integration layer passes its boolean evidence here so this policy can
    /// be used without importing or executing Profile-side code.
    public static func decision(
        profileReadiness: DshProfileBootstrapReadiness,
        inspectionIsComplete: Bool,
        inspectionHasErrors: Bool,
        inspectionHasUnknowns: Bool = false
    ) -> DshPluginStartupGateDecision {
        if profileReadiness == .freshEmpty,
           !inspectionHasErrors,
           !inspectionHasUnknowns {
            return .allowFreshProfileBootstrap
        }
        guard inspectionIsComplete, !inspectionHasErrors, !inspectionHasUnknowns else {
            return .blockProfileMutation
        }
        return .allowProfileMutation
    }
}

public struct DshProfileSnapshotProgress: Sendable {
    public let phase: String
    public let fraction: Double?
    public let detail: String?

    public init(phase: String, fraction: Double? = nil, detail: String? = nil) {
        self.phase = phase
        self.fraction = fraction
        self.detail = detail
    }
}

private struct DshProcessExecutionResult: Sendable {
    let status: Int32
    let stdout: Data
    let stderr: Data
}

/// Drain pnpm's pipes while it is running. Waiting for the process before
/// reading its output can deadlock once pnpm fills the OS pipe buffer during
/// supply-chain verification.
private final class DshProcessOutputCollector: @unchecked Sendable {
    private static let perStreamByteLimit = 64 * 1024

    private let stdoutPipe: Pipe?
    private let stderrPipe: Pipe?
    private let group = DispatchGroup()
    private let lock = NSLock()
    private var stdoutData = Data()
    private var stderrData = Data()
    private var nextStreamID = 0
    private var pendingStreams: [Int: FileHandle] = [:]
    private var stopped = false
    private var stdoutTruncated = false
    private var stderrTruncated = false
    /// Live progress lines (pnpm `Progress: …` summaries). Set before
    /// start(); invoked outside the lock, never for buffered history.
    var progressHandler: (@Sendable (String) -> Void)?
    private static let progressResidualLimit = 4096
    private var stdoutResidual = ""
    private var stderrResidual = ""

    init(stdout: Pipe?, stderr: Pipe?) {
        self.stdoutPipe = stdout
        self.stderrPipe = stderr
    }

    func start() {
        startReading(stdoutPipe, isStdout: true)
        startReading(stderrPipe, isStdout: false)
    }

    /// Wait briefly for EOF after the process exits, then close the read ends.
    /// A descendant can inherit a pipe and keep it open after pnpm has exited;
    /// waiting without a deadline would leave the caller blocked forever.
    func finishAfterProcessExit(drainTimeout: TimeInterval = 0.5) {
        guard group.wait(timeout: .now() + drainTimeout) == .timedOut else { return }
        stop()
    }

    func result() -> (stdout: Data, stderr: Data) {
        lock.lock()
        defer { lock.unlock() }
        return (stdoutData, stderrData)
    }

    private func startReading(_ pipe: Pipe?, isStdout: Bool) {
        guard let pipe else { return }
        let handle = pipe.fileHandleForReading
        lock.lock()
        let streamID = nextStreamID
        nextStreamID += 1
        let canStart = !stopped
        if canStart {
            pendingStreams[streamID] = handle
            group.enter()
        }
        lock.unlock()
        guard canStart else { return }

        handle.readabilityHandler = { [weak self] readable in
            guard let self else { return }
            let data = readable.availableData
            self.lock.lock()
            let shouldStop = self.stopped
            var progressLines: [String] = []
            let progressHandler = self.progressHandler
            if !data.isEmpty && !shouldStop {
                let destination: Data
                let truncated: Bool
                if isStdout {
                    destination = self.stdoutData
                    truncated = self.stdoutTruncated
                } else {
                    destination = self.stderrData
                    truncated = self.stderrTruncated
                }
                let remaining = max(0, Self.perStreamByteLimit - destination.count)
                if remaining > 0 {
                    let prefix = data.prefix(remaining)
                    if isStdout {
                        self.stdoutData.append(prefix)
                    } else {
                        self.stderrData.append(prefix)
                    }
                }
                if data.count > remaining && !truncated {
                    if isStdout {
                        self.stdoutTruncated = true
                    } else {
                        self.stderrTruncated = true
                    }
                }
                if progressHandler != nil,
                   let chunk = String(data: data, encoding: .utf8) {
                    // Split on both newline styles; keep only the trailing
                    // partial line (capped) for the next chunk.
                    let normalized = chunk.replacingOccurrences(of: "\r", with: "\n")
                    var pending: String
                    if isStdout {
                        pending = self.stdoutResidual + normalized
                    } else {
                        pending = self.stderrResidual + normalized
                    }
                    var lines = pending.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                    var tail = lines.popLast() ?? ""
                    if tail.count > Self.progressResidualLimit {
                        tail = String(tail.suffix(Self.progressResidualLimit))
                    }
                    if isStdout {
                        self.stdoutResidual = tail
                    } else {
                        self.stderrResidual = tail
                    }
                    for line in lines {
                        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty, trimmed.contains("Progress") {
                            progressLines.append(trimmed)
                        }
                    }
                }
            }
            self.lock.unlock()
            if progressHandler != nil {
                for line in progressLines {
                    progressHandler?(line)
                }
            }
            if data.isEmpty || shouldStop {
                self.finish(streamID: streamID, handle: readable)
            }
        }
    }

    private func finish(streamID: Int, handle: FileHandle) {
        lock.lock()
        let wasPending = pendingStreams.removeValue(forKey: streamID) != nil
        lock.unlock()
        guard wasPending else { return }
        handle.readabilityHandler = nil
        group.leave()
    }

    /// Stop all outstanding handlers and close the read ends. Each stream is
    /// removed from `pendingStreams` before its group leave, so a readability
    /// callback racing with shutdown cannot over-release the group.
    private func stop() {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        stopped = true
        let streams = pendingStreams
        pendingStreams.removeAll()
        lock.unlock()

        for handle in streams.values {
            handle.readabilityHandler = nil
            try? handle.close()
            group.leave()
        }
    }
}

private enum DshPluginOperationCoding {
    static func encode(_ reference: DshPluginOperationSnapshotReference) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(reference)
    }

    static func decode(_ data: Data) throws -> DshPluginOperationSnapshotReference {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(DshPluginOperationSnapshotReference.self, from: data)
    }
}

public final class DshPluginManager {
    public static let shared = DshPluginManager()

    public static let desktopHostPluginName = "dsh-desktop-host"
    /// Packages required by the managed desktop bridge but not user-managed
    /// plugins. They stay in the selected profile so the bridge's peer
    /// dependency and Cordis patch target remain resolvable.
    private static let internalPluginDependencyNames: Set<String> = [
        "@deepseek-ai/dsh-host-webserver",
    ]
    private static let desktopHostRequiredFiles = [
        "package.json",
        "index.js",
        "client.js",
        "webserver.js",
        "browser-url-route.js",
        "lan-url-route.js",
        "lan-http-ingress.js",
        "upstream-session-broker.js",
        "control.js",
        "access-state.js",
        "cordis.patch.yml",
    ]
    private static let standardProfileBundles = [
        "@deepseek-ai/dsh-base",
        "@deepseek-ai/dsh-web-app"
    ]
    private static let profileWorkspaceFileName = "pnpm-workspace.yaml"
    private static let webProfileSnapshotDirectoryName = "dsh-runtime-profile-snapshots"
    /// P01 snapshots live in their own namespace.  Runtime snapshots and
    /// plugin-operation snapshots must never be selected by one another's
    /// cleanup code.
    private static let pluginOperationSnapshotDirectoryName = "dsh-plugin-operation-snapshots"
    private static let pluginOperationSnapshotMetadataName = "snapshot.json"
    private static let missingProfileMarkerName = ".profile-was-missing"
    /// A cleanup marker is written only after the managed bridge and its
    /// internal peer have been installed and fingerprinted successfully.
    /// Package names alone are not ownership evidence: a terminal user may
    /// legitimately depend on a package with the same name.
    private static let desktopHostOwnershipMarkerName = ".dsh-desktop-host-ownership.json"

    public static func profileDirectory(for profile: DshAppProfile) -> URL {
        DshLaunchContext.profileDirectory(for: profile)
    }

    /// Thin-link tolerant fetch policy shared by every mutating pnpm
    /// command. `--network-concurrency=4` caps parallel connections; the
    /// explicit fetch budget replaces pnpm's 60s default timeout that turns
    /// slow-but-progressing downloads into endless timeout/retry storms.
    static let thinLinkFetchArguments = [
        "--network-concurrency=4",
        "--fetch-timeout=300000",
        "--fetch-retries=2",
    ]

    /// P01 is deliberately confined to the app's canonical desktop Profile.
    /// Callers may pass an explicit path for ordinary web-profile utilities,
    /// but a transaction snapshot must never turn that escape hatch into an
    /// arbitrary absolute write target.
    public static var canonicalDesktopProfileDirectory: URL {
        profileDirectory(for: .desktop).standardizedFileURL
    }

    public static var legacyDesktopProfileDirectory: URL {
        DshLaunchContext.profileDirectory(forName: "desktop").standardizedFileURL
    }

    /// Copy the Swift shell's pre-0.1.5 isolated profile to its new name.
    /// Upstream now owns the literal `desktop` profile, so the old tree is
    /// never launched or modified here and is deliberately retained. A staged
    /// copy prevents a force-quit from exposing a partial destination.
    @discardableResult
    public func migrateLegacyDesktopProfileIfNeeded(to destination: URL) throws -> Bool {
        let fileManager = FileManager.default
        let source = Self.legacyDesktopProfileDirectory
        let target = destination.standardizedFileURL
        guard target.path == Self.canonicalDesktopProfileDirectory.path,
              source.path != target.path,
              !fileManager.fileExists(atPath: target.path),
              fileManager.fileExists(atPath: source.path) else { return false }

        let sourceValues = try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard sourceValues.isDirectory == true, sourceValues.isSymbolicLink != true else {
            throw NSError(
                domain: "DshPluginManager",
                code: -40,
                userInfo: [NSLocalizedDescriptionKey: "旧 desktop Profile 不是可安全迁移的普通目录"]
            )
        }

        let packageURL = source.appendingPathComponent("package.json")
        let packageRoot = (try? Data(contentsOf: packageURL))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        guard let sourceBundle = NodeRuntime.shared.resolveDesktopHostBundlePath() else {
            throw NSError(
                domain: "DshPluginManager",
                code: -60,
                userInfo: [NSLocalizedDescriptionKey: "找不到内置桌面桥接，无法验证旧 desktop Profile 的归属"]
            )
        }
        let ownershipIsProven = hasUntamperedInstalledBridgeProof(
            profileDir: source,
            packageRoot: packageRoot
        ) || staleAppBridgeRejectionReason(
            profileDir: source,
            packageRoot: packageRoot,
            sourceBundle: sourceBundle
        ) == nil
        guard ownershipIsProven else {
            throw NSError(
                domain: "DshPluginManager",
                code: -41,
                userInfo: [NSLocalizedDescriptionKey: "旧 desktop Profile 无法证明由 Swift App 管理，未复制到 swift-desktop"]
            )
        }

        let parent = target.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(
            ".swift-desktop-migration-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: staging) }
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        let excluded = Set([
            "node_modules",
            ".dsh-module-fallback",
            Self.desktopHostOwnershipMarkerName,
        ])
        for entry in try fileManager.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: []
        ) where !excluded.contains(entry.lastPathComponent) {
            let values = try entry.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw NSError(
                    domain: "DshPluginManager",
                    code: -42,
                    userInfo: [NSLocalizedDescriptionKey: "旧 desktop Profile 含无法安全迁移的顶层符号链接"]
                )
            }
            try fileManager.copyItem(
                at: entry,
                to: staging.appendingPathComponent(entry.lastPathComponent)
            )
        }

        let stagedPackageURL = staging.appendingPathComponent("package.json")
        if var stagedRoot = packageRoot {
            stagedRoot["name"] = "dsh-profile-swift-desktop"
            if var dependencies = stagedRoot["dependencies"] as? [String: Any] {
                dependencies.removeValue(forKey: Self.desktopHostPluginName)
                dependencies.removeValue(forKey: "@deepseek-ai/dsh-host-webserver")
                stagedRoot["dependencies"] = dependencies
            }
            if var dsh = stagedRoot["dsh"] as? [String: Any],
               var profile = dsh["profile"] as? [String: Any],
               let bundles = profile["bundles"] as? [String] {
                profile["bundles"] = bundles.filter { $0 != Self.desktopHostPluginName }
                dsh["profile"] = profile
                stagedRoot["dsh"] = dsh
            }
            let data = try JSONSerialization.data(
                withJSONObject: stagedRoot,
                options: [.prettyPrinted, .sortedKeys]
            )
            try data.write(to: stagedPackageURL, options: .atomic)
        }
        do {
            try fileManager.moveItem(at: staging, to: target)
        } catch {
            if fileManager.fileExists(atPath: target.path) { return false }
            throw error
        }
        return true
    }


/// Resolve both external binaries, naming the missing one on failure. The
/// domain and `-1` code stay unchanged so existing error mapping (including
/// the MainWindow recovery classifier) keeps working; only the detail gains
/// the resolution outcome for diagnostics.
func dshRequireNodeAndPnpm(context: String = "") throws -> (node: String, pnpm: String) {
    let pnpm = NodeRuntime.shared.resolvePnpmBinary()
    let node = NodeRuntime.shared.resolveNodeBinary()
    guard let pnpm, let node else {
        var detail = "缺少 Node 或 pnpm（node=\(node ?? "nil")，pnpm=\(pnpm ?? "nil")）"
        if !context.isEmpty { detail += "，\(context)" }
        throw NSError(domain: "DshPluginManager", code: -1, userInfo: [NSLocalizedDescriptionKey: detail])
    }
    return (node, pnpm)
}

/// Kept for snapshot harnesses and migration tooling that explicitly
    /// targets the terminal-owned web profile.
    public static var webProfileDirectory: URL {
        profileDirectory(for: .web)
    }

    public static var activeProfileDirectory: URL {
        profileDirectory(for: DshStateManager.shared.current.appProfile)
    }

    private init() {}

    private static var webProfileSnapshotDirectory: URL {
        DshStateManager.appSupportDirectory
            .appendingPathComponent(Self.webProfileSnapshotDirectoryName, isDirectory: true)
    }

    private static var pluginOperationSnapshotDirectory: URL {
        DshStateManager.appSupportDirectory
            .appendingPathComponent(Self.pluginOperationSnapshotDirectoryName, isDirectory: true)
    }

    private static func webProfileSnapshotURL(for id: String) throws -> URL {
        guard UUID(uuidString: id) != nil, !id.contains("/") else {
            throw NSError(
                domain: "DshPluginManager",
                code: -30,
                userInfo: [NSLocalizedDescriptionKey: "web Profile 快照标识无效"]
            )
        }
        return webProfileSnapshotDirectory.appendingPathComponent(id, isDirectory: true)
    }

    private static func pluginOperationSnapshotURL(
        operationID: String,
        snapshotID: String
    ) throws -> URL {
        guard UUID(uuidString: operationID) != nil,
              UUID(uuidString: snapshotID) != nil,
              !operationID.contains("/"),
              !snapshotID.contains("/") else {
            throw NSError(
                domain: "DshPluginManager",
                code: -40,
                userInfo: [NSLocalizedDescriptionKey: "插件事务快照标识无效"]
            )
        }
        return pluginOperationSnapshotDirectory
            .appendingPathComponent(operationID, isDirectory: true)
            .appendingPathComponent(snapshotID, isDirectory: true)
    }

    /// Extra headroom for metadata, temporary clone/copy state, and the
    /// atomic destination replacement.  Exposed as a constant so the
    /// capacity contract can be tested with measured values rather than
    /// manufacturing a nearly-full volume.
    public static let pluginSnapshotSafetyBytes: Int64 = 256 * 1024 * 1024

    private static func volumeIdentifier(for url: URL) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.volumeIdentifierKey]) else { return nil }
        return values.volumeIdentifier.map { String(describing: $0) }
    }

    private static func allocatedSize(of directory: URL) -> UInt64 {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .fileAllocatedSizeKey,
            .totalFileAllocatedSizeKey,
            .fileSizeKey
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: []
        ) else { return 0 }

        var total: UInt64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { continue }
            let size = values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0
            if size > 0 {
                total += UInt64(size)
            }
        }
        return total
    }

    /// Validate the capacity contract independently from the filesystem.
    /// Snapshot callers provide the payload size and the destination volume's
    /// available bytes; the method adds the fixed safety margin and fails
    /// closed with a typed error.  This seam is intentionally side-effect
    /// free so tests never need to fill a real disk.
    public static func validatePluginSnapshotCapacity(
        requiredBytes: Int64,
        availableBytes: Int64
    ) throws {
        let boundedRequired = max(requiredBytes, 0)
        let requiredWithSafety: Int64
        if boundedRequired > Int64.max - pluginSnapshotSafetyBytes {
            requiredWithSafety = Int64.max
        } else {
            requiredWithSafety = boundedRequired + pluginSnapshotSafetyBytes
        }
        guard availableBytes >= requiredWithSafety else {
            throw DshPluginOperationError.snapshotCapacityInsufficient(
                requiredBytes: requiredWithSafety,
                availableBytes: availableBytes
            )
        }
    }

    private static func ensureCapacity(for source: URL, at destinationParent: URL) throws {
        let required = allocatedSize(of: source)
        let availableValues = try destinationParent.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey
        ])
        let available: Int64
        if let important = availableValues.volumeAvailableCapacityForImportantUsage {
            available = important
        } else {
            available = Int64(availableValues.volumeAvailableCapacity ?? 0)
        }
        let boundedRequired = Int64(min(required, UInt64(Int64.max)))
        try validatePluginSnapshotCapacity(
            requiredBytes: boundedRequired,
            availableBytes: available
        )
    }

    /// APFS clone is effectively metadata-only for a large Profile. If the
    /// source is on another volume, or clone is unavailable, fall back to a
    /// regular copy only after checking the destination volume capacity.
    private static func copyDirectoryPreferClone(from source: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        let destinationParent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: destinationParent, withIntermediateDirectories: true)

        let sourceVolume = volumeIdentifier(for: source)
        let destinationVolume = volumeIdentifier(for: destinationParent)
        var attemptedClone = false
        if sourceVolume != nil,
           sourceVolume == destinationVolume {
            attemptedClone = true
            if cloneDirectoryIfPossible(from: source, to: destination) {
                return
            }
        }

        // cp -cR can leave a partial destination after an I/O or filesystem
        // error. This destination is a transaction-local UUID path, so it is
        // safe and necessary to remove it before the ordinary-copy fallback.
        if attemptedClone, fileManager.fileExists(atPath: destination.path) {
            do {
                try fileManager.removeItem(at: destination)
            } catch {
                throw NSError(
                    domain: "DshPluginManager",
                    code: -36,
                    userInfo: [NSLocalizedDescriptionKey: "APFS clone 失败且无法清理临时目标：\(error.localizedDescription)"]
                )
            }
        }

        try ensureCapacity(for: source, at: destinationParent)
        try fileManager.copyItem(at: source, to: destination)
    }

    private static func cloneDirectoryIfPossible(from source: URL, to destination: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/cp")
        // `-c` asks APFS for a clone; there is no shell interpolation here.
        process.arguments = ["-cR", source.path, destination.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// Return a deterministic digest of a Profile tree.  This is used as a
    /// compare-before-write/compare-before-restore guard, not as a security
    /// signature.  Symlink targets are included as links rather than followed
    /// so a Profile cannot make the snapshot digest walk outside its tree.
    private static func pluginProfileDigestSynchronously(at profileURL: URL) throws -> String {
        let fileManager = FileManager.default
        var hasher = SHA256()
        let root = profileURL.standardizedFileURL
        guard fileManager.fileExists(atPath: root.path) else {
            hasher.update(data: Data("missing\0".utf8))
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }

        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ) else {
            throw NSError(
                domain: "DshPluginManager",
                code: -41,
                userInfo: [NSLocalizedDescriptionKey: "无法读取插件 Profile 内容"]
            )
        }

        var entries: [URL] = []
        while let entry = enumerator.nextObject() as? URL {
            entries.append(entry)
        }
        for entry in entries.sorted(by: { $0.path < $1.path }) {
            let relative = String(entry.standardizedFileURL.path.dropFirst(root.path.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            hasher.update(data: Data(relative.utf8))
            hasher.update(data: Data([0]))
            if let symlinkTarget = try? fileManager.destinationOfSymbolicLink(atPath: entry.path) {
                hasher.update(data: Data("link\0".utf8))
                hasher.update(data: Data(symlinkTarget.utf8))
            } else if values.isDirectory == true {
                hasher.update(data: Data("directory\0".utf8))
            } else {
                hasher.update(data: Data("file\0".utf8))
                hasher.update(data: try Data(contentsOf: entry))
            }
            hasher.update(data: Data([0]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Public read-only digest seam for the P01 coordinator and isolated
    /// integration harnesses.
    public func pluginProfileDigest(at profileDirectory: URL) async throws -> String {
        try await Task.detached(priority: .utility) {
            try Self.pluginProfileDigestSynchronously(at: profileDirectory)
        }.value
    }

    private static func writePluginSnapshotMetadata(
        _ reference: DshPluginOperationSnapshotReference,
        at snapshotURL: URL
    ) throws {
        let data = try DshPluginOperationCoding.encode(reference)
        try data.write(
            to: snapshotURL.appendingPathComponent(Self.pluginOperationSnapshotMetadataName),
            options: .atomic
        )
    }

    private static func readPluginSnapshotMetadata(
        at snapshotURL: URL
    ) throws -> DshPluginOperationSnapshotReference {
        let metadataURL = snapshotURL.appendingPathComponent(Self.pluginOperationSnapshotMetadataName)
        let data: Data
        do {
            data = try Data(contentsOf: metadataURL)
        } catch {
            throw NSError(
                domain: "DshPluginManager",
                code: -42,
                userInfo: [NSLocalizedDescriptionKey: "插件事务快照所有权记录缺失"]
            )
        }
        do {
            return try DshPluginOperationCoding.decode(data)
        } catch {
            throw NSError(
                domain: "DshPluginManager",
                code: -43,
                userInfo: [NSLocalizedDescriptionKey: "插件事务快照所有权记录损坏"]
            )
        }
    }

    private static func requireOwnedPluginSnapshot(
        _ requested: DshPluginOperationSnapshotReference,
        at snapshotURL: URL
    ) throws {
        let persisted = try readPluginSnapshotMetadata(at: snapshotURL)
        guard persisted.snapshotID == requested.snapshotID,
              persisted.operationID == requested.operationID,
              persisted.profile == requested.profile,
              persisted.profileDirectory == requested.profileDirectory,
              persisted.baselineDigest == requested.baselineDigest,
              persisted.ownerID == DshPluginOperationSnapshotReference.owner else {
            throw NSError(
                domain: "DshPluginManager",
                code: -44,
                userInfo: [NSLocalizedDescriptionKey: "插件事务快照不属于当前操作，已拒绝使用"]
            )
        }
    }

    private static func createPluginOperationSnapshotSynchronously(
        operationID: String,
        profile: DshAppProfile,
        profileDirectory: URL
    ) throws -> DshPluginOperationSnapshotReference {
        guard profile == .desktop else {
            throw DshPluginOperationError.desktopProfileRequired
        }
        guard UUID(uuidString: operationID) != nil else {
            throw NSError(
                domain: "DshPluginManager",
                code: -45,
                userInfo: [NSLocalizedDescriptionKey: "插件事务 ID 无效"]
            )
        }

        let fileManager = FileManager.default
        let profileURL = profileDirectory.standardizedFileURL
        guard profileURL.path == Self.canonicalDesktopProfileDirectory.path else {
            throw DshPluginOperationError.unsafeProfileDirectory
        }
        if fileManager.fileExists(atPath: profileURL.path),
           profileURL.resolvingSymlinksInPath().path != profileURL.path {
            throw DshPluginOperationError.unsafeProfileDirectory
        }
        let snapshotID = UUID().uuidString
        let snapshotURL = try pluginOperationSnapshotURL(
            operationID: operationID,
            snapshotID: snapshotID
        )
        let profileExists = fileManager.fileExists(atPath: profileURL.path)
        let baselineDigest = try pluginProfileDigestSynchronously(at: profileURL)
        try fileManager.createDirectory(at: snapshotURL, withIntermediateDirectories: true)
        do {
            if profileExists {
                try copyDirectoryPreferClone(
                    from: profileURL,
                    to: snapshotURL.appendingPathComponent("profile", isDirectory: true)
                )
            } else {
                try Data().write(
                    to: snapshotURL.appendingPathComponent(missingProfileMarkerName),
                    options: .atomic
                )
            }

            // A concurrently modified Profile must never be captured as a
            // purportedly coherent rollback point.
            guard try pluginProfileDigestSynchronously(at: profileURL) == baselineDigest else {
                throw DshPluginOperationError.staleProfileChanged
            }
            let reference = DshPluginOperationSnapshotReference(
                snapshotID: snapshotID,
                operationID: operationID,
                profile: profile,
                profileDirectory: profileURL,
                baselineDigest: baselineDigest,
                profileWasMissing: !profileExists
            )
            try writePluginSnapshotMetadata(reference, at: snapshotURL)
            return reference
        } catch {
            try? fileManager.removeItem(at: snapshotURL)
            throw error
        }
    }

    /// Create an app-owned snapshot for one P01 operation.  The operation ID,
    /// Profile and absolute path are persisted beside the copy and verified on
    /// every later restore/delete request.
    public func createPluginOperationSnapshot(
        operationID: String,
        profile: DshAppProfile = .desktop,
        profileDirectory: URL
    ) async throws -> DshPluginOperationSnapshotReference {
        try await Task.detached(priority: .utility) {
            try Self.createPluginOperationSnapshotSynchronously(
                operationID: operationID,
                profile: profile,
                profileDirectory: profileDirectory
            )
        }.value
    }

    private static func restorePluginOperationSnapshotSynchronously(
        _ reference: DshPluginOperationSnapshotReference,
        expectedCurrentDigest: String?
    ) throws {
        guard reference.ownerID == DshPluginOperationSnapshotReference.owner,
              reference.profile == .desktop,
              reference.profileDirectory == Self.canonicalDesktopProfileDirectory.path else {
            throw DshPluginOperationError.desktopProfileRequired
        }
        let snapshotURL = try pluginOperationSnapshotURL(
            operationID: reference.operationID,
            snapshotID: reference.snapshotID
        )
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: snapshotURL.path) else {
            throw NSError(
                domain: "DshPluginManager",
                code: -46,
                userInfo: [NSLocalizedDescriptionKey: "找不到插件事务快照"]
            )
        }
        try requireOwnedPluginSnapshot(reference, at: snapshotURL)

        let profileURL = URL(fileURLWithPath: reference.profileDirectory, isDirectory: true)
            .standardizedFileURL
        let profileExists = fileManager.fileExists(atPath: profileURL.path)
        if profileExists,
           profileURL.resolvingSymlinksInPath().path != profileURL.path {
            throw DshPluginOperationError.unsafeProfileDirectory
        }
        // A missing Profile is the signature of an interrupted restore: the
        // live tree was moved aside and the process died before the snapshot
        // copy completed. Nothing can be compared in that state, so the
        // expected-digest gate is skipped and the copy below resumes the
        // interrupted swap. The restored tree is still verified against the
        // baseline before the call returns.
        let currentDigest = profileExists
            ? try pluginProfileDigestSynchronously(at: profileURL)
            : nil
        if let expectedCurrentDigest, let currentDigest, currentDigest != expectedCurrentDigest {
            throw DshPluginOperationError.externalModification
        }

        let savedProfileURL = snapshotURL.appendingPathComponent("profile", isDirectory: true)
        let missingMarkerURL = snapshotURL.appendingPathComponent(missingProfileMarkerName)
        // Deterministic per-operation name so recovery can either resume an
        // interrupted swap or clean the leftover it left behind; a random
        // name would strand the live tree in an untracked directory.
        let displacedURL = profileURL.deletingLastPathComponent()
            .appendingPathComponent(".dsh-plugin-restore-\(reference.operationID)", isDirectory: true)
        var displacedCurrent = false
        do {
            if fileManager.fileExists(atPath: profileURL.path) {
                // A leftover from an earlier interrupted attempt must not
                // block the move. It is operation-scoped and its content is
                // superseded by the snapshot this restore is applying, so it
                // is safe to clear before the current tree is displaced.
                if fileManager.fileExists(atPath: displacedURL.path) {
                    try? fileManager.removeItem(at: displacedURL)
                }
                try fileManager.moveItem(at: profileURL, to: displacedURL)
                displacedCurrent = true
            }
            if !fileManager.fileExists(atPath: missingMarkerURL.path) {
                guard fileManager.fileExists(atPath: savedProfileURL.path) else {
                    throw NSError(
                        domain: "DshPluginManager",
                        code: -47,
                        userInfo: [NSLocalizedDescriptionKey: "插件事务快照内容不完整"]
                    )
                }
                try fileManager.createDirectory(
                    at: profileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try copyDirectoryPreferClone(from: savedProfileURL, to: profileURL)
            }
            guard try pluginProfileDigestSynchronously(at: profileURL) == reference.baselineDigest else {
                throw NSError(
                    domain: "DshPluginManager",
                    code: -48,
                    userInfo: [NSLocalizedDescriptionKey: "插件事务快照恢复后校验失败"]
                )
            }
            if displacedCurrent {
                try fileManager.removeItem(at: displacedURL)
            } else if fileManager.fileExists(atPath: displacedURL.path) {
                // Resumed restore: an earlier interrupted attempt left its
                // displaced tree here. The baseline is verified in place now,
                // so the operation-scoped leftover can be removed.
                try? fileManager.removeItem(at: displacedURL)
            }
        } catch {
            // Only touch the paths this attempt created. When the Profile was
            // displaced (displacedCurrent), profileURL holds the partial copy
            // and the original lives at displacedURL — put it back. When the
            // Profile was missing and the copy started (resume), profileURL
            // is also only a partial copy and can be removed. A Profile that
            // was never touched must stay untouched: deleting it would
            // destroy the live tree over a failed move.
            if displacedCurrent {
                try? fileManager.removeItem(at: profileURL)
                try? fileManager.moveItem(at: displacedURL, to: profileURL)
            } else if !profileExists {
                try? fileManager.removeItem(at: profileURL)
            }
            throw error
        }
    }

    /// Restore only when the current tree still matches the last digest
    /// observed by this operation.  A changed tree is an external conflict,
    /// not permission to overwrite newer user changes.
    public func restorePluginOperationSnapshot(
        _ reference: DshPluginOperationSnapshotReference,
        expectedCurrentDigest: String? = nil
    ) async throws {
        try await Task.detached(priority: .utility) {
            try Self.restorePluginOperationSnapshotSynchronously(
                reference,
                expectedCurrentDigest: expectedCurrentDigest
            )
        }.value
    }

    /// Delete exactly one owned snapshot.  Callers must clear the persisted
    /// operation record only after this succeeds (or intentionally retain it
    /// for a retry).
    public func deletePluginOperationSnapshot(
        _ reference: DshPluginOperationSnapshotReference
    ) async throws {
        try await Task.detached(priority: .utility) {
            // Validate the caller-provided owner before resolving any path.
            // Metadata validation below is still required: a path can be
            // replaced between operations, and deletion must remain
            // fail-closed when the on-disk owner proof does not match.
            guard reference.ownerID == DshPluginOperationSnapshotReference.owner,
                  reference.profile == .desktop,
                  reference.profileDirectory == Self.canonicalDesktopProfileDirectory.path else {
                throw DshPluginOperationError.desktopProfileRequired
            }
            let snapshotURL = try Self.pluginOperationSnapshotURL(
                operationID: reference.operationID,
                snapshotID: reference.snapshotID
            )
            guard FileManager.default.fileExists(atPath: snapshotURL.path) else { return }
            try Self.requireOwnedPluginSnapshot(reference, at: snapshotURL)
            try FileManager.default.removeItem(at: snapshotURL)
            let operationURL = snapshotURL.deletingLastPathComponent()
            if (try? FileManager.default.contentsOfDirectory(atPath: operationURL.path))?.isEmpty == true {
                try? FileManager.default.removeItem(at: operationURL)
            }
        }.value
    }

    /// Probe one exact operation snapshot. A present directory is considered
    /// usable only after its on-disk ownership metadata matches the supplied
    /// operation reference; a missing directory is an idempotent-cleanup
    /// result, not an implicit authorization to inspect or delete anything
    /// else.
    public func hasOwnedPluginOperationSnapshot(
        _ reference: DshPluginOperationSnapshotReference
    ) async throws -> Bool {
        try await Task.detached(priority: .utility) {
            guard reference.ownerID == DshPluginOperationSnapshotReference.owner,
                  reference.profile == .desktop,
                  reference.profileDirectory == Self.canonicalDesktopProfileDirectory.path else {
                throw DshPluginOperationError.desktopProfileRequired
            }
            let snapshotURL = try Self.pluginOperationSnapshotURL(
                operationID: reference.operationID,
                snapshotID: reference.snapshotID
            )
            guard FileManager.default.fileExists(atPath: snapshotURL.path) else {
                return false
            }
            try Self.requireOwnedPluginSnapshot(reference, at: snapshotURL)
            return true
        }.value
    }

    private static func createWebProfileSnapshotSynchronously(
        profile: DshAppProfile,
        profileDirectory: URL? = nil,
        onProgress: @escaping @Sendable (DshProfileSnapshotProgress) -> Void
    ) throws -> String {
        let id = UUID().uuidString
        let snapshotURL = try webProfileSnapshotURL(for: id)
        let profileURL = profileDirectory ?? Self.profileDirectory(for: profile)
        let snapshotDirectory = webProfileSnapshotDirectory
        let fileManager = FileManager.default

        onProgress(DshProfileSnapshotProgress(
            phase: "正在保护 web Profile...",
            fraction: 0,
            detail: "优先使用 APFS clone；跨卷时将检查可用空间"
        ))
        try fileManager.createDirectory(at: snapshotDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: snapshotURL, withIntermediateDirectories: true)

        do {
            if fileManager.fileExists(atPath: profileURL.path) {
                try copyDirectoryPreferClone(
                    from: profileURL,
                    to: snapshotURL.appendingPathComponent("profile", isDirectory: true)
                )
            } else {
                let marker = snapshotURL.appendingPathComponent(missingProfileMarkerName)
                try Data().write(to: marker, options: .atomic)
            }
        } catch {
            try? fileManager.removeItem(at: snapshotURL)
            throw NSError(
                domain: "DshPluginManager",
                code: -31,
                userInfo: [NSLocalizedDescriptionKey: "无法创建 web Profile 更新快照：\(error.localizedDescription)"]
            )
        }
        onProgress(DshProfileSnapshotProgress(
            phase: "web Profile 快照已创建",
            fraction: 1,
            detail: "快照 \(id)"
        ))
        return id
    }

    private static func restoreWebProfileSnapshotSynchronously(
        _ id: String,
        profile: DshAppProfile,
        profileDirectory: URL? = nil,
        onProgress: @escaping @Sendable (DshProfileSnapshotProgress) -> Void
    ) throws {
        let snapshotURL = try webProfileSnapshotURL(for: id)
        let profileURL = profileDirectory ?? Self.profileDirectory(for: profile)
        let savedProfileURL = snapshotURL.appendingPathComponent("profile", isDirectory: true)
        let missingMarkerURL = snapshotURL.appendingPathComponent(missingProfileMarkerName)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: snapshotURL.path) else {
            throw NSError(
                domain: "DshPluginManager",
                code: -32,
                userInfo: [NSLocalizedDescriptionKey: "找不到 web Profile 更新快照 \(id)"]
            )
        }

        onProgress(DshProfileSnapshotProgress(
            phase: "正在恢复 web Profile...",
            fraction: 0,
            detail: "正在停止对旧 Profile 的写入并还原快照"
        ))

        // Keep the displaced copy beside the live Profile. This is important
        // when Application Support and DSH_HOME are on different volumes:
        // moving the current Profile must remain same-volume and atomic. The
        // name is deterministic per snapshot so a resumed restore (the live
        // Profile was already moved aside) can clean the leftover.
        let displacedURL = profileURL.deletingLastPathComponent()
            .appendingPathComponent(".dsh-profile-restore-\(id)", isDirectory: true)
        let profileExists = fileManager.fileExists(atPath: profileURL.path)
        var displacedCurrent = false

        do {
            if profileExists {
                // A leftover from an earlier interrupted attempt must not
                // block the move; it is snapshot-scoped and superseded by the
                // snapshot being applied.
                if fileManager.fileExists(atPath: displacedURL.path) {
                    try? fileManager.removeItem(at: displacedURL)
                }
                try fileManager.moveItem(at: profileURL, to: displacedURL)
                displacedCurrent = true
            }

            if !fileManager.fileExists(atPath: missingMarkerURL.path) {
                guard fileManager.fileExists(atPath: savedProfileURL.path) else {
                    throw NSError(
                        domain: "DshPluginManager",
                        code: -33,
                        userInfo: [NSLocalizedDescriptionKey: "web Profile 快照内容不完整"]
                    )
                }
                try fileManager.createDirectory(
                    at: profileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try copyDirectoryPreferClone(from: savedProfileURL, to: profileURL)
            }

            if displacedCurrent {
                try? fileManager.removeItem(at: displacedURL)
            } else if fileManager.fileExists(atPath: displacedURL.path) {
                // Resumed restore: an earlier interrupted attempt left its
                // displaced tree here and the snapshot is now in place.
                try? fileManager.removeItem(at: displacedURL)
            }
        } catch {
            // Only touch the paths this attempt created (see the plugin
            // operation restore for the same reasoning); a Profile that was
            // never displaced or copied must stay untouched.
            if displacedCurrent {
                try? fileManager.removeItem(at: profileURL)
                try? fileManager.moveItem(at: displacedURL, to: profileURL)
            } else if !profileExists {
                try? fileManager.removeItem(at: profileURL)
            }
            throw NSError(
                domain: "DshPluginManager",
                code: -34,
                userInfo: [NSLocalizedDescriptionKey: "无法恢复 web Profile 更新快照：\(error.localizedDescription)"]
            )
        }
        onProgress(DshProfileSnapshotProgress(
            phase: "web Profile 已恢复",
            fraction: 1,
            detail: nil
        ))
    }

    /// Take a complete copy of the shared web Profile before a Runtime
    /// transaction lets pnpm change package.json, the lockfile, or
    /// node_modules. The snapshot is referenced by persisted transaction
    /// state and is kept until the new Runtime has survived two starts.
    public func createWebProfileSnapshot(
        profile: DshAppProfile = .web,
        profileDirectory: URL? = nil,
        onProgress: @escaping @Sendable (DshProfileSnapshotProgress) -> Void = { _ in }
    ) async throws -> String {
        try await Task.detached(priority: .utility) {
            try Self.createWebProfileSnapshotSynchronously(
                profile: profile,
                profileDirectory: profileDirectory,
                onProgress: onProgress
            )
        }.value
    }

    /// Restore a previously persisted Profile snapshot. Replacement is
    /// recoverable: the current Profile is moved aside until the snapshot
    /// copy succeeds, so a failed copy does not silently destroy both states.
    public func restoreWebProfileSnapshot(
        _ id: String,
        profile: DshAppProfile = .web,
        profileDirectory: URL? = nil,
        onProgress: @escaping @Sendable (DshProfileSnapshotProgress) -> Void = { _ in }
    ) async throws {
        try await Task.detached(priority: .utility) {
            try Self.restoreWebProfileSnapshotSynchronously(
                id,
                profile: profile,
                profileDirectory: profileDirectory,
                onProgress: onProgress
            )
        }.value
    }

    /// Remove one exact, no-longer-needed Profile snapshot.
    public func deleteWebProfileSnapshot(_ id: String) async throws {
        try await Task.detached(priority: .utility) {
            let snapshotURL = try Self.webProfileSnapshotURL(for: id)
            guard FileManager.default.fileExists(atPath: snapshotURL.path) else { return }
            try FileManager.default.removeItem(at: snapshotURL)
        }.value
    }

    /// Remove snapshots that are no longer referenced by persisted Runtime
    /// state. Snapshot directories are UUID-named, so unrelated Profile data
    /// cannot be selected by this cleanup.
    @discardableResult
    public func cleanupOrphanedWebProfileSnapshots(keeping retainedID: String?) async -> [String] {
        await Task.detached(priority: .utility) {
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: Self.webProfileSnapshotDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { return [] }

            var removed: [String] = []
            for entry in entries {
                let id = entry.lastPathComponent
                guard UUID(uuidString: id) != nil, id != retainedID else { continue }
                do {
                    try FileManager.default.removeItem(at: entry)
                    removed.append(id)
                } catch {
                    print("[DshPluginManager] Failed to remove orphaned Profile snapshot \(id):", error)
                }
            }
            return removed
        }.value
    }

    /// Remove P01 snapshot trees that are no longer referenced by a durable
    /// plugin-operation record. Deletion is deliberately conservative:
    /// - both path components must be UUIDs (operationID/snapshotID);
    /// - a directory must either prove ownership via snapshot.json (ownerID,
    ///   both IDs, profile and canonical path all matching the enclosing
    ///   names), or be a structurally app-created partial from the create
    ///   window (a `profile/` subtree or the missing-profile marker with no
    ///   metadata yet, which is unreferenced by definition);
    /// - the operation directory of `keepingOperationID` is never touched —
    ///   the coordinator owns its lifecycle;
    /// - anything unrecognized is left in place for the recovery surface.
    @discardableResult
    public func cleanupOrphanedPluginOperationSnapshots(
        keeping keepingOperationID: String?
    ) async -> [String] {
        await Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            guard let operationEntries = try? fileManager.contentsOfDirectory(
                at: Self.pluginOperationSnapshotDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { return [] }

            var removed: [String] = []
            for operationEntry in operationEntries {
                let operationID = operationEntry.lastPathComponent
                guard UUID(uuidString: operationID) != nil,
                      operationID != keepingOperationID else { continue }
                guard let snapshotEntries = try? fileManager.contentsOfDirectory(
                    at: operationEntry,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                ) else { continue }

                for snapshotEntry in snapshotEntries {
                    let snapshotID = snapshotEntry.lastPathComponent
                    guard UUID(uuidString: snapshotID) != nil else { continue }
                    if Self.canProveOrphanedPluginSnapshotOwnership(
                        operationID: operationID,
                        snapshotID: snapshotID,
                        at: snapshotEntry
                    ) {
                        do {
                            try fileManager.removeItem(at: snapshotEntry)
                            removed.append("\(operationID)/\(snapshotID)")
                        } catch {
                            print("[DshPluginManager] Failed to remove orphaned plugin snapshot \(operationID)/\(snapshotID):", error)
                        }
                    }
                }
                // Drop now-empty operation directories.
                if (try? fileManager.contentsOfDirectory(atPath: operationEntry.path))?.isEmpty == true {
                    try? fileManager.removeItem(at: operationEntry)
                }
            }
            return removed
        }.value
    }

    /// Ownership check used by orphan cleanup. Proven ownership means the
    /// persisted snapshot.json fully matches the enclosing UUID names, the
    /// app owner and the canonical desktop path. The create crash/kill window
    /// can also leave a structure without metadata; that partial is recognized
    /// only by its exact app-created shape (a `profile/` subtree or the
    /// missing-profile marker) and removed because it is unreferenced.
    private static func canProveOrphanedPluginSnapshotOwnership(
        operationID: String,
        snapshotID: String,
        at snapshotURL: URL
    ) -> Bool {
        let fileManager = FileManager.default
        if let reference = try? readPluginSnapshotMetadata(at: snapshotURL) {
            return reference.snapshotID == snapshotID
                && reference.operationID == operationID
                && reference.profile == .desktop
                && reference.profileDirectory == Self.canonicalDesktopProfileDirectory.path
                && reference.ownerID == DshPluginOperationSnapshotReference.owner
        }
        // No (readable) metadata: only the app's own create shapes count.
        return fileManager.fileExists(
            atPath: snapshotURL.appendingPathComponent("profile", isDirectory: true).path
        ) || fileManager.fileExists(
            atPath: snapshotURL.appendingPathComponent(Self.missingProfileMarkerName).path
        )
    }

    /// List all installed plugins in the selected DSH profile.
    public func listPlugins(outdatedMap: [String: String] = [:]) -> [DshPluginItem] {
        listPlugins(at: Self.activeProfileDirectory, outdatedMap: outdatedMap)
    }

    /// List plugins from an explicitly captured Profile directory. This is
    /// the path used by launch/recovery flows; it cannot move when settings
    /// change while an asynchronous refresh is in flight.
    public func listPlugins(at profileDir: URL, outdatedMap: [String: String] = [:]) -> [DshPluginItem] {
        let pkgUrl = profileDir.appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: pkgUrl),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let deps = json["dependencies"] as? [String: String] else {
            return []
        }

        var list: [DshPluginItem] = []
        for (name, spec) in deps {
            guard !Self.internalPluginDependencyNames.contains(name) else { continue }
            let isManaged = (name == Self.desktopHostPluginName)
            let isLocal = spec.hasPrefix("file:") || spec.hasPrefix("link:")
            let latest = outdatedMap[name]
            let description = readPluginDescription(name: name, profileDir: profileDir)
            list.append(DshPluginItem(
                name: name,
                version: spec,
                latestVersion: latest,
                description: description,
                isManaged: isManaged,
                isLocal: isLocal
            ))
        }

        // Pinned managed plugin at bottom, others alphabetical
        return list.sorted { a, b in
            if a.isManaged != b.isManaged { return !a.isManaged }
            return a.name.localizedCompare(b.name) == .orderedAscending
        }
    }

    /// Read display metadata from the installed plugin tree.
    ///
    /// Keep this aligned with Electron's `enrichPluginMetadata`: descriptions
    /// are optional metadata from the exact package currently installed in the
    /// profile, rather than data fetched from the registry. `node_modules`
    /// entries may be symlinks created by pnpm; Data(contentsOf:) follows them.
    private func readPluginDescription(name: String, profileDir: URL) -> String? {
        let manifestURL = profileDir
            .appendingPathComponent("node_modules", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
            .appendingPathComponent("package.json")

        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let description = manifest["description"] as? String,
              !description.isEmpty else {
            return nil
        }
        return description
    }

    /// Match Electron's external-theme detection for the native settings UI.
    ///
    /// Themes are declared either as direct profile dependencies or as profile
    /// bundles. DSH's own packages and the shell bridge are deliberately
    /// excluded because they are part of the built-in profile, not user themes.
    public func detectExternalTheme() -> String? {
        detectExternalTheme(at: Self.activeProfileDirectory)
    }

    public func detectExternalTheme(at profileDir: URL) -> String? {
        let packageURL = profileDir.appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: packageURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        var names: [String] = []
        if let dependencies = root["dependencies"] as? [String: Any] {
            names.append(contentsOf: dependencies.keys.sorted())
        }
        if let dsh = root["dsh"] as? [String: Any],
           let profile = dsh["profile"] as? [String: Any],
           let bundles = profile["bundles"] as? [String] {
            names.append(contentsOf: bundles)
        }

        var seen = Set<String>()
        for name in names where seen.insert(name).inserted {
            if name.hasPrefix("@deepseek-ai/") { continue }
            if name == Self.desktopHostPluginName || name == "dsh-desktop-claude" { continue }
            if name.range(of: "theme|skin", options: [.regularExpression, .caseInsensitive]) != nil {
                return name
            }
        }
        return nil
    }

    /// Check npm registry for outdated plugins using pnpm outdated --json.
    public func checkOutdatedPlugins() async throws -> [String: String] {
        let state = DshStateManager.shared.current
        return try await checkOutdatedPlugins(
            at: Self.profileDirectory(for: state.appProfile),
            profile: state.appProfile,
            registry: state.npmRegistry
        )
    }

    public func checkOutdatedPlugins(
        at profileDir: URL,
        profile: DshAppProfile? = nil,
        registry: String? = nil
    ) async throws -> [String: String] {
        try await checkOutdatedPlugins(
            at: profileDir,
            profile: profile,
            registry: registry,
            processEnvironment: nil
        )
    }

    private func checkOutdatedPlugins(
        at profileDir: URL,
        profile: DshAppProfile? = nil,
        registry: String? = nil,
        processEnvironment: [String: String]?
    ) async throws -> [String: String] {
        let stateSnapshot = DshStateManager.shared.current
        let capturedRegistry = DshVersionManager.normalizedRegistry(registry ?? stateSnapshot.npmRegistry)
        let (node, pnpm) = try dshRequireNodeAndPnpm()

        guard FileManager.default.fileExists(atPath: profileDir.appendingPathComponent("package.json").path) else {
            return [:]
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pnpm)
        proc.currentDirectoryURL = profileDir
        // pnpm 11's `outdated` command does not accept `--registry` as a
        // command-specific option. Keep the registry in the environment,
        // and disable the default 24-hour release-age gate for this read-only
        // metadata check so a newly published plugin can be reported at once.
        proc.arguments = [
            "outdated",
            "--format", "json",
            "--config.minimum-release-age=0"
        ]

        var env = processEnvironment ?? NodeRuntime.shared.buildEnvironment()
        env["DSH_NODE_BIN"] = node
        env["npm_config_registry"] = capturedRegistry
        proc.environment = env

        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardOutput = stdout
        proc.standardError = stderr

        let result = try await runProcess(proc, stdout: stdout, stderr: stderr)
        let data = result.stdout
        guard !data.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            guard result.status == 0 else {
                let detail = processOutput(result)
                throw NSError(
                    domain: "DshPluginManager",
                    code: -9,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "检测插件更新失败（退出码 \(result.status)）\(detail)"
                    ]
                )
            }
            return [:]
        }

        // pnpm outdated exits with status 1 when it finds at least one
        // outdated dependency. A valid JSON payload is the authoritative
        // result, so accept both the clean and the "updates found" statuses.
        guard result.status == 0 || result.status == 1 else {
            let detail = processOutput(result)
            throw NSError(
                domain: "DshPluginManager",
                code: -9,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "检测插件更新失败（退出码 \(result.status)）\(detail)"
                ]
            )
        }

        var outdated: [String: String] = [:]
        for (pkgName, info) in json {
            guard !Self.internalPluginDependencyNames.contains(pkgName) else { continue }
            if let infoDict = info as? [String: Any],
               let latestVer = infoDict["latest"] as? String {
                outdated[pkgName] = latestVer
            }
        }
        return outdated
    }

    /// `pnpm update --latest` can exit successfully while the configured
    /// minimum-release-age policy keeps a newly published dependency at its
    /// current version. Treat that as an incomplete update instead of
    /// reporting a committed success to the settings UI.
    private func verifyPluginsReachedLatest(
        _ packageNames: [String],
        profileDirectory: URL,
        profile: DshAppProfile,
        registry: String,
        ignoringMinimumReleaseAge: Bool
    ) async throws {
        let outdated = try await checkOutdatedPlugins(
            at: profileDirectory,
            profile: profile,
            registry: registry
        )
        let remaining = packageNames.filter { outdated[$0] != nil }.sorted()
        guard !remaining.isEmpty else { return }
        let packages = remaining.joined(separator: "、")
        let detail = ignoringMinimumReleaseAge
            ? "更新命令已完成，但以下插件仍未达到 Registry 最新版本：\(packages)"
            : "MINIMUM_RELEASE_AGE_VIOLATION：以下插件受发布时间策略限制，尚未更新到 Registry 最新版本：\(packages)"
        throw NSError(
            domain: "DshPluginManager",
            code: -11,
            userInfo: [NSLocalizedDescriptionKey: detail]
        )
    }

    /// Add a plugin by name or npm specifier.
    public func addPlugin(
        spec: String,
        ignoringMinimumReleaseAge: Bool = false,
        profileDirectory: URL? = nil,
        profile: DshAppProfile? = nil,
        registry: String? = nil,
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws {
        try validatePluginPackageSpecifier(spec)
        let stateSnapshot = DshStateManager.shared.current
        let targetProfile = profile ?? stateSnapshot.appProfile
        let profileDir = profileDirectory ?? Self.profileDirectory(for: targetProfile)
        let capturedRegistry = DshVersionManager.normalizedRegistry(registry ?? stateSnapshot.npmRegistry)
        if let packageName = packageName(from: spec),
           Self.internalPluginDependencyNames.contains(packageName) {
            throw NSError(
                domain: "DshPluginManager",
                code: -8,
                userInfo: [NSLocalizedDescriptionKey: "不能直接安装 DSH 内部依赖 \(packageName)"]
            )
        }
        try await validateRegistryPackageIfNeeded(spec: spec, registry: capturedRegistry)

        let (node, pnpm) = try dshRequireNodeAndPnpm()

        try bootstrapWebProfileManifestIfMissing(at: profileDir, profile: targetProfile)
        if let hostBundle = NodeRuntime.shared.resolveDesktopHostBundlePath() {
            _ = repairDesktopHostDependency(hostBundle, profileDirectory: profileDir)
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pnpm)
        proc.currentDirectoryURL = profileDir
        var arguments = ["add", spec] + Self.thinLinkFetchArguments + registryArguments(capturedRegistry)
        if ignoringMinimumReleaseAge {
            arguments.append("--config.minimum-release-age=0")
        }
        arguments.append("--reporter=append-only")
        proc.arguments = arguments

        var env = NodeRuntime.shared.buildEnvironment()
        env["DSH_NODE_BIN"] = node
        proc.environment = env

        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardOutput = stdout
        proc.standardError = stderr

        let result = try await runProcess(proc, stdout: stdout, stderr: stderr, onProgressLine: progress)

        guard result.status == 0 else {
            let detail = processOutput(result)
            throw NSError(domain: "DshPluginManager", code: -2, userInfo: [NSLocalizedDescriptionKey: "安装插件 \(spec) 失败（退出码 \(result.status)）\(detail)"])
        }
        if let packageName = packageName(from: spec) {
            try updateProfileBundle(packageName, removing: false, profileDir: profileDir)
        }
    }

    /// The UI uses this marker to offer a one-time opt-in retry. Keep the
    /// policy override scoped to the requested install instead of changing
    /// global pnpm configuration.
    public static func isMinimumReleaseAgeViolation(_ error: Error) -> Bool {
        let nsError = error as NSError
        let messages = [
            error.localizedDescription,
            nsError.userInfo[NSLocalizedDescriptionKey] as? String,
            nsError.userInfo[NSLocalizedFailureReasonErrorKey] as? String
        ].compactMap { $0 }
        return messages.contains { $0.contains("MINIMUM_RELEASE_AGE_VIOLATION") }
    }

    /// Resolve an update in a disposable Profile before the P01 mutation
    /// boundary is entered.  This intentionally does not use the real
    /// Profile's `node_modules`, lockfile or package manifest: pnpm receives
    /// only the small set of Profile inputs needed to resolve the graph and
    /// is forced into lockfile-only/no-scripts mode.  A registry or resolver
    /// failure is advisory (`.inconclusive`) and falls through to the normal
    /// transaction, while a release-age rejection can be confirmed by the UI
    /// immediately without stopping the service first.
    public func preflightPluginUpdate(
        name: String,
        profileDirectory: URL,
        profile: DshAppProfile,
        registry: String
    ) async throws -> DshPluginUpdatePreflightResult {
        try validatePluginPackageName(name)
        guard !Self.internalPluginDependencyNames.contains(name) else {
            return .inconclusive
        }
        return try await preflightPluginUpdates(
            [name],
            profileDirectory: profileDirectory,
            profile: profile,
            registry: registry
        )
    }

    /// Read-only resolver for a batch update.  The package list is derived
    /// from the isolated copy, not from mutable UI state, so direct callers
    /// and the settings UI use the same dependency set as the eventual P01
    /// mutation.
    public func preflightAllPluginUpdates(
        packageNames requestedPackageNames: [String]? = nil,
        profileDirectory: URL,
        profile: DshAppProfile,
        registry: String
    ) async throws -> DshPluginUpdatePreflightResult {
        let packageNames = try validatedUpdateAllPackageNames(
            requestedPackageNames,
            profileDirectory: profileDirectory
        )
        guard !packageNames.isEmpty else { return .clear }
        return try await preflightPluginUpdates(
            packageNames,
            profileDirectory: profileDirectory,
            profile: profile,
            registry: registry
        )
    }

    /// Read-only install resolver: `pnpm add --lockfile-only` inside a
    /// disposable copy of the Profile. Surfaces minimum-release-age
    /// rejections before any service stop, snapshot or mutation, mirroring
    /// the update preflight below.
    public func preflightInstallPluginUpdate(
        spec: String,
        profileDirectory: URL,
        profile: DshAppProfile,
        registry: String
    ) async throws -> DshPluginUpdatePreflightResult {
        try Task.checkCancellation()
        guard DshPluginOperationInputValidation.isValidPackageSpecifier(spec) else {
            return .inconclusive
        }
        var outdatedLookupNames: [String] = []
        if let name = packageName(from: spec) {
            outdatedLookupNames = [name]
        }
        return try await runPreflightResolver(
            pnpmArguments: ["add", spec, "--lockfile-only", "--ignore-scripts", "--network-concurrency=4"]
                + registryArguments(DshVersionManager.normalizedRegistry(registry))
                + ["--reporter=append-only"],
            outdatedLookupNames: outdatedLookupNames,
            profileDirectory: profileDirectory,
            profile: profile,
            registry: registry
        )
    }

    private func preflightPluginUpdates(
        _ packageNames: [String],
        profileDirectory: URL,
        profile: DshAppProfile,
        registry: String
    ) async throws -> DshPluginUpdatePreflightResult {
        try Task.checkCancellation()
        for packageName in packageNames {
            try validatePluginPackageName(packageName)
        }
        return try await runPreflightResolver(
            pnpmArguments: ["update"] + packageNames + [
                "--latest",
                "--lockfile-only",
                "--ignore-scripts",
                "--network-concurrency=4"
            ] + registryArguments(DshVersionManager.normalizedRegistry(registry)) + ["--reporter=append-only"],
            outdatedLookupNames: packageNames,
            profileDirectory: profileDirectory,
            profile: profile,
            registry: registry
        )
    }

    /// Shared disposable-tree resolver behind the update/install
    /// preflights. Copies only manifests into a temporary directory with an
    /// isolated store/config, runs the given lockfile-only pnpm command and
    /// interprets the result. Never touches the real Profile.
    private func runPreflightResolver(
        pnpmArguments: [String],
        outdatedLookupNames: [String],
        profileDirectory: URL,
        profile: DshAppProfile,
        registry: String
    ) async throws -> DshPluginUpdatePreflightResult {
        let capturedRegistry = DshVersionManager.normalizedRegistry(registry)
        guard let pnpm = NodeRuntime.shared.resolvePnpmBinary(),
              let node = NodeRuntime.shared.resolveNodeBinary() else {
            return .inconclusive
        }
        guard FileManager.default.fileExists(
            atPath: profileDirectory.appendingPathComponent("package.json").path
        ) else {
            return .inconclusive
        }

        let fileManager = FileManager.default
        let preflightDirectory = fileManager.temporaryDirectory
            .appendingPathComponent(
                "dsh-plugin-update-preflight-\(UUID().uuidString)",
                isDirectory: true
            )
        try fileManager.createDirectory(
            at: preflightDirectory,
            withIntermediateDirectories: true
        )
        defer { try? fileManager.removeItem(at: preflightDirectory) }

        // Keep this allow-list narrow. Copying node_modules, .npmrc files or
        // pnpmfile hooks would make the supposedly read-only check capable of
        // following user-controlled configuration/code. Private-registry
        // authentication that is not available to this isolated resolver is
        // handled as an inconclusive preflight and falls back to P01.
        let inputFiles = [
            "package.json",
            "pnpm-lock.yaml",
            Self.profileWorkspaceFileName
        ]
        for fileName in inputFiles {
            let source = profileDirectory.appendingPathComponent(fileName)
            let destination = preflightDirectory.appendingPathComponent(fileName)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            // Never copy a Profile symlink into the disposable tree: pnpm
            // could otherwise follow it and write a lockfile or manifest
            // outside the preflight directory.
            guard (try? fileManager.destinationOfSymbolicLink(atPath: source.path)) == nil else {
                return .inconclusive
            }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else { return .inconclusive }
            guard let data = try? Data(contentsOf: source) else {
                return .inconclusive
            }
            try data.write(to: destination, options: .atomic)
        }

        // These are the same DSH-owned invariants applied by the formal
        // update methods, but only to the disposable copy.
        try ensureManagedProfileWorkspaceConfiguration(
            at: preflightDirectory,
            profile: profile
        )
        if let hostBundle = NodeRuntime.shared.resolveDesktopHostBundlePath() {
            _ = repairDesktopHostDependency(
                hostBundle,
                profileDirectory: preflightDirectory
            )
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pnpm)
        proc.currentDirectoryURL = preflightDirectory
        proc.arguments = pnpmArguments

        var env = NodeRuntime.shared.buildEnvironment()
        env["DSH_NODE_BIN"] = node
        env["npm_config_registry"] = capturedRegistry
        // Never inherit a user/global config for the resolver. A private
        // registry without inline credentials will safely return an
        // inconclusive result and use the normal P01 path instead.
        let isolatedUserConfig = preflightDirectory.appendingPathComponent(
            ".dsh-preflight-user.npmrc"
        )
        let isolatedGlobalConfig = preflightDirectory.appendingPathComponent(
            ".dsh-preflight-global.npmrc"
        )
        try Data().write(to: isolatedUserConfig, options: .atomic)
        try Data().write(to: isolatedGlobalConfig, options: .atomic)
        env["npm_config_userconfig"] = isolatedUserConfig.path
        env["NPM_CONFIG_USERCONFIG"] = nil
        env["npm_config_globalconfig"] = isolatedGlobalConfig.path
        env["NPM_CONFIG_GLOBALCONFIG"] = nil
        env["npm_config_ignore_scripts"] = "true"
        let isolatedStore = preflightDirectory.appendingPathComponent("store", isDirectory: true)
        let isolatedCache = preflightDirectory.appendingPathComponent("cache", isDirectory: true)
        let isolatedState = preflightDirectory.appendingPathComponent("state", isDirectory: true)
        let isolatedHome = preflightDirectory.appendingPathComponent("pnpm-home", isDirectory: true)
        let isolatedXDGCache = preflightDirectory.appendingPathComponent("xdg-cache", isDirectory: true)
        let isolatedXDGData = preflightDirectory.appendingPathComponent("xdg-data", isDirectory: true)
        let isolatedXDGConfig = preflightDirectory.appendingPathComponent("xdg-config", isDirectory: true)
        env["pnpm_config_store_dir"] = isolatedStore.path
        env["npm_config_store_dir"] = isolatedStore.path
        env["pnpm_config_cache_dir"] = isolatedCache.path
        env["npm_config_cache"] = isolatedCache.path
        env["pnpm_config_state_dir"] = isolatedState.path
        env["PNPM_HOME"] = isolatedHome.path
        env["XDG_CACHE_HOME"] = isolatedXDGCache.path
        env["XDG_DATA_HOME"] = isolatedXDGData.path
        env["XDG_CONFIG_HOME"] = isolatedXDGConfig.path
        proc.environment = env

        // A successful lockfile-only update normally leaves a concrete
        // package.json/lockfile diff in the disposable tree. We use that
        // diff to distinguish a real resolver success from pnpm's valid
        // status-0 no-op when minimum-release-age suppresses the candidate.
        let baselinePackageData = try? Data(
            contentsOf: preflightDirectory.appendingPathComponent("package.json")
        )
        let baselineLockData = try? Data(
            contentsOf: preflightDirectory.appendingPathComponent("pnpm-lock.yaml")
        )

        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardOutput = stdout
        proc.standardError = stderr
        let result: DshProcessExecutionResult
        do {
            result = try await runProcess(proc, stdout: stdout, stderr: stderr)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .inconclusive
        }
        try Task.checkCancellation()

        let outputText = [
            String(decoding: result.stdout, as: UTF8.self),
            String(decoding: result.stderr, as: UTF8.self)
        ].joined(separator: "\n")
        if Self.preflightOutputIndicatesMinimumReleaseAge(outputText) {
            return .minimumReleaseAgeViolation
        }
        // A successful resolver run is enough to let the formal transaction
        // proceed. It may still discover a later health or version issue;
        // those checks remain owned by P01 and `verifyPluginsReachedLatest`.
        if result.status == 0 {
            let packageChanged = (try? Data(
                contentsOf: preflightDirectory.appendingPathComponent("package.json")
            )) != baselinePackageData
            let lockChanged = (try? Data(
                contentsOf: preflightDirectory.appendingPathComponent("pnpm-lock.yaml")
            )) != baselineLockData
            if packageChanged || lockChanged {
                // A batch resolver can make progress for one target while
                // silently leaving another target behind the configured
                // minimum-release-age gate.  The aggregate command still
                // exits successfully and produces a manifest/lockfile diff,
                // so the diff alone is not proof that every requested update
                // is clear to enter P01. Ask pnpm for the residual outdated
                // set in this same disposable tree; checking the unchanged
                // real Profile would report every target as outdated,
                // including the ones resolved by this preflight.
                if pnpmArguments.first == "update" {
                    do {
                        let outdated = try await checkOutdatedPlugins(
                            at: preflightDirectory,
                            profile: profile,
                            registry: capturedRegistry,
                            processEnvironment: env
                        )
                        if outdatedLookupNames.contains(where: { outdated[$0] != nil }) {
                            return .minimumReleaseAgeViolation
                        }
                    } catch {
                        return .inconclusive
                    }
                }
                return .clear
            }

            // No resolver artifact and no diagnostic is the pnpm status-0
            // silent-no-op shape. The same isolated-tree outdated check tells
            // us whether the requested update was expected; if the check
            // itself is unavailable, remain conservative and let the normal
            // transaction decide.
            do {
                let outdated = try await checkOutdatedPlugins(
                    at: preflightDirectory,
                    profile: profile,
                    registry: capturedRegistry,
                    processEnvironment: env
                )
                if outdatedLookupNames.contains(where: { outdated[$0] != nil }) {
                    return .minimumReleaseAgeViolation
                }
            } catch {
                return .inconclusive
            }
            return .clear
        }

        return .inconclusive
    }

    private static func preflightOutputIndicatesMinimumReleaseAge(_ output: String) -> Bool {
        let normalized = output.lowercased()
        return normalized.contains("minimum_release_age_violation")
            || normalized.contains("minimum-release-age")
            || normalized.contains("minimum release age")
    }

    /// Update a specific plugin to its latest version.
    ///
    /// The normal path keeps pnpm's supply-chain release-age policy. The UI
    /// retries with `ignoringMinimumReleaseAge` only after the user confirms
    /// the one-time override for a newly published dependency.
    public func updatePlugin(
        name: String,
        ignoringMinimumReleaseAge: Bool = false,
        profileDirectory: URL? = nil,
        profile: DshAppProfile? = nil,
        registry: String? = nil,
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws {
        try validatePluginPackageName(name)
        let stateSnapshot = DshStateManager.shared.current
        let targetProfile = profile ?? stateSnapshot.appProfile
        let profileDir = profileDirectory ?? Self.profileDirectory(for: targetProfile)
        let capturedRegistry = DshVersionManager.normalizedRegistry(registry ?? stateSnapshot.npmRegistry)
        guard !Self.internalPluginDependencyNames.contains(name) else {
            throw NSError(
                domain: "DshPluginManager",
                code: -8,
                userInfo: [NSLocalizedDescriptionKey: "不能直接更新 DSH 内部依赖 \(name)"]
            )
        }
        let (node, pnpm) = try dshRequireNodeAndPnpm()

        // pnpm validates every direct dependency before updating one plugin.
        // Heal a stale Electron-era file: dependency first, otherwise any
        // plugin update is rejected before pnpm reaches the requested name.
        if let hostBundle = NodeRuntime.shared.resolveDesktopHostBundlePath() {
            _ = repairDesktopHostDependency(hostBundle, profileDirectory: profileDir)
        }

        try ensureManagedProfileWorkspaceConfiguration(at: profileDir, profile: targetProfile)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pnpm)
        proc.currentDirectoryURL = profileDir
        var arguments = ["update", name, "--latest"] + Self.thinLinkFetchArguments
        if ignoringMinimumReleaseAge {
            arguments.append("--config.minimum-release-age=0")
        }
        proc.arguments = arguments + registryArguments(capturedRegistry) + ["--reporter=append-only"]

        var env = NodeRuntime.shared.buildEnvironment()
        env["DSH_NODE_BIN"] = node
        proc.environment = env

        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardOutput = stdout
        proc.standardError = stderr
        let result = try await runProcess(proc, stdout: stdout, stderr: stderr, onProgressLine: progress)

        guard result.status == 0 else {
            let detail = processOutput(result)
            throw NSError(domain: "DshPluginManager", code: -3, userInfo: [NSLocalizedDescriptionKey: "更新插件 \(name) 失败（退出码 \(result.status)）\(detail)"])
        }
        try await verifyPluginsReachedLatest(
            [name],
            profileDirectory: profileDir,
            profile: targetProfile,
            registry: capturedRegistry,
            ignoringMinimumReleaseAge: ignoringMinimumReleaseAge
        )
    }

    /// Update all installed plugins to their latest versions.
    public func updateAllPlugins(
        packageNames requestedPackageNames: [String]? = nil,
        ignoringMinimumReleaseAge: Bool = false,
        profileDirectory: URL? = nil,
        profile: DshAppProfile? = nil,
        registry: String? = nil,
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws {
        let stateSnapshot = DshStateManager.shared.current
        let targetProfile = profile ?? stateSnapshot.appProfile
        let profileDir = profileDirectory ?? Self.profileDirectory(for: targetProfile)
        let capturedRegistry = DshVersionManager.normalizedRegistry(registry ?? stateSnapshot.npmRegistry)
        let pluginNames = try validatedUpdateAllPackageNames(
            requestedPackageNames,
            profileDirectory: profileDir
        )
        guard !pluginNames.isEmpty else { return }
        let (node, pnpm) = try dshRequireNodeAndPnpm()

        if let hostBundle = NodeRuntime.shared.resolveDesktopHostBundlePath() {
            _ = repairDesktopHostDependency(hostBundle, profileDirectory: profileDir)
        }

        try ensureManagedProfileWorkspaceConfiguration(at: profileDir, profile: targetProfile)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pnpm)
        proc.currentDirectoryURL = profileDir
        var arguments = ["update"] + pluginNames + ["--latest"] + Self.thinLinkFetchArguments
        if ignoringMinimumReleaseAge {
            arguments.append("--config.minimum-release-age=0")
        }
        proc.arguments = arguments + registryArguments(capturedRegistry) + ["--reporter=append-only"]

        var env = NodeRuntime.shared.buildEnvironment()
        env["DSH_NODE_BIN"] = node
        proc.environment = env

        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardOutput = stdout
        proc.standardError = stderr
        let result = try await runProcess(proc, stdout: stdout, stderr: stderr, onProgressLine: progress)

        guard result.status == 0 else {
            let detail = processOutput(result)
            throw NSError(domain: "DshPluginManager", code: -4, userInfo: [NSLocalizedDescriptionKey: "批量更新插件失败（退出码 \(result.status)）\(detail)"])
        }
        try await verifyPluginsReachedLatest(
            pluginNames,
            profileDirectory: profileDir,
            profile: targetProfile,
            registry: capturedRegistry,
            ignoringMinimumReleaseAge: ignoringMinimumReleaseAge
        )
    }

    /// Remove a plugin by name.
    public func removePlugin(
        name: String,
        profileDirectory: URL? = nil,
        profile: DshAppProfile? = nil,
        registry: String? = nil
    ) async throws {
        try validatePluginPackageName(name)
        let stateSnapshot = DshStateManager.shared.current
        let targetProfile = profile ?? stateSnapshot.appProfile
        let profileDir = profileDirectory ?? Self.profileDirectory(for: targetProfile)
        let capturedRegistry = DshVersionManager.normalizedRegistry(registry ?? stateSnapshot.npmRegistry)
        guard !Self.internalPluginDependencyNames.contains(name) else {
            throw NSError(
                domain: "DshPluginManager",
                code: -8,
                userInfo: [NSLocalizedDescriptionKey: "不能直接卸载 DSH 内部依赖 \(name)"]
            )
        }
        guard name != Self.desktopHostPluginName else {
            throw NSError(domain: "DshPluginManager", code: -5, userInfo: [NSLocalizedDescriptionKey: "不能删除系统内置桥接插件"])
        }
        let (node, pnpm) = try dshRequireNodeAndPnpm()

        try bootstrapWebProfileManifestIfMissing(at: profileDir, profile: targetProfile)
        if let hostBundle = NodeRuntime.shared.resolveDesktopHostBundlePath() {
            _ = repairDesktopHostDependency(hostBundle, profileDirectory: profileDir)
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pnpm)
        proc.currentDirectoryURL = profileDir
        // pnpm 11's `remove` command does not accept `--registry`. Removal
        // only operates on the existing lockfile, so keep the registry in
        // the environment for any incidental resolution instead of passing
        // it as an unsupported command-specific option.
        proc.arguments = ["remove", name, "--config.minimum-release-age=0", "--reporter=append-only"]

        var env = NodeRuntime.shared.buildEnvironment()
        env["DSH_NODE_BIN"] = node
        env["npm_config_registry"] = capturedRegistry
        proc.environment = env

        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardOutput = stdout
        proc.standardError = stderr

        let result = try await runProcess(proc, stdout: stdout, stderr: stderr)

        guard result.status == 0 else {
            let detail = processOutput(result)
            throw NSError(
                domain: "DshPluginManager",
                code: -6,
                userInfo: [NSLocalizedDescriptionKey: "卸载插件 \(name) 失败（退出码 \(result.status)）\(detail)"]
            )
        }
        try updateProfileBundle(name, removing: true, profileDir: profileDir)
    }

    private func updateProfileBundle(
        _ name: String,
        removing: Bool,
        profileDir: URL? = nil
    ) throws {
        let profileDir = profileDir ?? Self.activeProfileDirectory
        let packageURL = profileDir.appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: packageURL),
              var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var dsh = root["dsh"] as? [String: Any],
              var profile = dsh["profile"] as? [String: Any],
              var bundles = profile["bundles"] as? [String] else {
            throw NSError(
                domain: "DshPluginManager",
                code: -10,
                userInfo: [NSLocalizedDescriptionKey: "web Profile manifest 缺少 dsh.profile.bundles"]
            )
        }

        if removing {
            bundles.removeAll { $0 == name }
        } else if !bundles.contains(name) {
            bundles.append(name)
        }

        profile["bundles"] = bundles
        dsh["profile"] = profile
        root["dsh"] = dsh
        let updated = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try updated.write(to: packageURL, options: .atomic)
    }

    /// Remove the desktop shell bridge from an explicitly selected profile.
    /// This is used only when leaving the shared web profile so terminal
    /// `dsh web` is returned to its normal upstream dependency tree.
    public func removeDesktopHostArtifacts(
        from profile: DshAppProfile,
        profileDirectory: URL? = nil,
        registry: String? = nil
    ) async throws {
        guard profile == .web else { return }
        let stateSnapshot = DshStateManager.shared.current
        let profileDir = profileDirectory ?? Self.profileDirectory(for: profile)
        let capturedRegistry = DshVersionManager.normalizedRegistry(registry ?? stateSnapshot.npmRegistry)
        let packageURL = profileDir.appendingPathComponent("package.json")
        let root: [String: Any]?
        if let data = try? Data(contentsOf: packageURL) {
            root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        } else {
            root = nil
        }

        let dependencies = root?["dependencies"] as? [String: String] ?? [:]
        let dependenciesToRemove = [
            Self.desktopHostPluginName,
            "@deepseek-ai/dsh-host-webserver"
        ].filter { dependencies[$0] != nil }

        let fileManager = FileManager.default
        let stalePaths = [
            profileDir.appendingPathComponent("node_modules/dsh-desktop-host", isDirectory: true),
            profileDir.appendingPathComponent("node_modules/@deepseek-ai/dsh-host-webserver", isDirectory: true)
        ]
        let hasStaleBridgePath = stalePaths.contains { fileManager.fileExists(atPath: $0.path) }
        let hasBridgeBundle: Bool
        if let dsh = root?["dsh"] as? [String: Any],
           let profile = dsh["profile"] as? [String: Any],
           let bundles = profile["bundles"] as? [String] {
            hasBridgeBundle = bundles.contains(Self.desktopHostPluginName)
        } else {
            hasBridgeBundle = false
        }

        // Removal is destructive even when pnpm has already removed the
        // direct dependencies. Require the durable proof whenever any bridge
        // artifact is present, including an orphaned node_modules path.
        guard !dependenciesToRemove.isEmpty || hasStaleBridgePath || hasBridgeBundle else {
            return
        }
        // A force-quit can land after pnpm has materialized the complete
        // bridge tree but before the post-install proof is atomically written.
        // Recover that one window by adopting only a tree whose bytes match
        // the current bundled bridge and whose manifest has the managed shape.
        // A same-name user dependency still fails closed because adoption
        // rejects non-file declarations or any byte/path mismatch.
        var verifiedRoot = root
        do {
            try verifyDesktopHostOwnershipProof(
                profileDir: profileDir,
                packageRoot: verifiedRoot
            )
        } catch let verificationError {
            if !hasUntamperedInstalledBridgeProof(
                profileDir: profileDir,
                packageRoot: verifiedRoot
            ) {
                // A same-name dependency installed by the terminal user is
                // deliberately never removed. Make the fail-closed refusal
                // actionable so web->desktop cleanup does not silently retry
                // forever without telling the user what to change.
                let actionableFailure = Self.unprovenBridgeOwnershipFailure(underlying: verificationError)
                do {
                    guard let sourceBundle = NodeRuntime.shared.resolveDesktopHostBundlePath(),
                          try adoptDesktopHostOwnershipProof(
                              profileDir: profileDir,
                              packageRoot: verifiedRoot,
                              sourceBundle: sourceBundle
                          ) else {
                        throw actionableFailure
                    }
                } catch {
                    // Preserve the actionable cleanup diagnostic for an
                    // unproven same-name dependency. Adoption is a recovery
                    // aid, never a reason to disclose or broaden ownership.
                    throw actionableFailure
                }
                verifiedRoot = (try? Data(contentsOf: packageURL))
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                try verifyDesktopHostOwnershipProof(
                    profileDir: profileDir,
                    packageRoot: verifiedRoot
                )
            }
        }

        if !dependenciesToRemove.isEmpty {
            let (node, pnpm) = try dshRequireNodeAndPnpm(context: "无法清理 web Profile 桥接依赖")

            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: pnpm)
            proc.currentDirectoryURL = profileDir
            proc.arguments = ["remove"] + dependenciesToRemove + [
                "--config.minimum-release-age=0",
                "--reporter=append-only"
            ]

            var env = NodeRuntime.shared.buildEnvironment()
            env["DSH_NODE_BIN"] = node
            env["npm_config_registry"] = capturedRegistry
            proc.environment = env

            let stdout = Pipe()
            let stderr = Pipe()
            proc.standardOutput = stdout
            proc.standardError = stderr

            let result = try await runProcess(
                proc,
                stdout: stdout,
                stderr: stderr,
                maximumRuntime: Self.profileBridgeProcessMaximumRuntime
            )
            guard result.status == 0 else {
                let detail = processOutput(result)
                throw NSError(
                    domain: "DshPluginManager",
                    code: -18,
                    userInfo: [NSLocalizedDescriptionKey: "清理 web Profile 桥接依赖失败（退出码 \(result.status)）\(detail)"]
                )
            }
        }

        // pnpm removes direct links and lockfile entries. Keep DSH's bundle
        // manifest synchronized as well; otherwise the next `dsh web` boot
        // would try to load the deleted bridge again.
        try updateProfileBundle(
            Self.desktopHostPluginName,
            removing: true,
            profileDir: profileDir
        )

        // Clean stale links left by interrupted pnpm operations. These are
        // exact children of the selected profile and never touch pnpm's store.
        for path in stalePaths where fileManager.fileExists(atPath: path.path) {
            try fileManager.removeItem(at: path)
        }

        let ownershipMarker = profileDir.appendingPathComponent(Self.desktopHostOwnershipMarkerName)
        if fileManager.fileExists(atPath: ownershipMarker.path) {
            try fileManager.removeItem(at: ownershipMarker)
        }
    }

    private func validatePluginPackageName(_ name: String) throws {
        guard DshPluginOperationInputValidation.isValidPackageName(name) else {
            throw NSError(
                domain: "DshPluginManager",
                code: -50,
                userInfo: [NSLocalizedDescriptionKey: "插件名称无效或包含 pnpm 选项：\(name)"]
            )
        }
    }

    private func validatePluginPackageSpecifier(_ spec: String) throws {
        guard DshPluginOperationInputValidation.isValidPackageSpecifier(spec) else {
            throw NSError(
                domain: "DshPluginManager",
                code: -51,
                userInfo: [NSLocalizedDescriptionKey: "插件 spec 无效或包含 pnpm 选项：\(spec)"]
            )
        }
    }

    /// Explicit update-all targets originate in UI/persisted operation state,
    /// so repeat the managed/local/internal filtering here instead of trusting
    /// the caller to have used `listPlugins` first. Unknown but syntactically
    /// valid names are retained: pnpm will report the normal dependency error
    /// rather than silently changing the requested operation.
    private func validatedUpdateAllPackageNames(
        _ requested: [String]?,
        profileDirectory: URL
    ) throws -> [String] {
        let installed = Dictionary(
            uniqueKeysWithValues: listPlugins(at: profileDirectory).map { ($0.name, $0) }
        )
        let candidates = requested ?? installed.values
            .filter { !$0.isManaged && !$0.isLocal }
            .map(\.name)

        var seen = Set<String>()
        var result: [String] = []
        for name in candidates {
            try validatePluginPackageName(name)
            guard seen.insert(name).inserted else { continue }
            guard !Self.internalPluginDependencyNames.contains(name),
                  installed[name]?.isManaged != true,
                  installed[name]?.isLocal != true else {
                continue
            }
            result.append(name)
        }
        return result
    }

    private func packageName(from spec: String) -> String? {
        let value = spec.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              !value.hasPrefix("github:"),
              !value.hasPrefix("file:"),
              !value.hasPrefix("link:"),
              !value.hasPrefix("./"),
              !value.hasPrefix("../") else {
            return nil
        }

        if value.hasPrefix("@"), let slash = value.firstIndex(of: "/") {
            let suffix = value.index(after: slash)
            let end = value[suffix...].firstIndex(of: "@") ?? value.endIndex
            return String(value[..<end])
        }

        let end = value.firstIndex(of: "@") ?? value.endIndex
        return String(value[..<end])
    }

    /// Match Electron's preflight check for npm registry plugins. A clear
    /// 404 is actionable; network and other registry failures are left to
    /// pnpm so its native error remains the source of truth.
    private func validateRegistryPackageIfNeeded(spec: String, registry: String) async throws {
        let value = spec.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.hasPrefix("workspace:"),
              !value.hasPrefix("http://"),
              !value.hasPrefix("https://"),
              !value.hasPrefix("git:"),
              !value.hasPrefix("git+"),
              let name = packageName(from: spec) else { return }
        let base = registry.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard URL(string: "\(base)/\(name)") != nil else { return }

        let (_, status) = await fetchPackument(name: name, registry: registry)
        guard status != 404 else {
            throw NSError(
                domain: "DshPluginManager",
                code: -7,
                userInfo: [NSLocalizedDescriptionKey: "未找到 npm 包 \(name)（HTTP 404），请检查拼写或确认该包已发布到当前镜像"]
            )
        }
    }

    /// Fetch a registry packument without failing the caller on transport
    /// problems: offline and private-registry failures stay fail-open and
    /// surface later through the normal pnpm/verify path.
    private func fetchPackument(name: String, registry: String) async -> (document: [String: Any]?, status: Int?) {
        guard let encodedName = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else {
            return (nil, nil)
        }
        let base = registry.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/\(encodedName)") else { return (nil, nil) }

        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("application/vnd.npm.install-v1+json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return (nil, status)
            }
            return (object, status)
        } catch {
            return (nil, nil)
        }
    }

    /// Resolve what `spec` would install to a concrete version without
    /// mutating anything. Exact pins need no network; tags resolve through
    /// the packument's dist-tags. Returns nil for ranges, local/github
    /// specs and every transport failure so callers fail open.
    public func resolveInstallCandidateVersion(spec: String, registry: String) async -> DshInstallCandidate? {
        guard let split = DshPluginOperationInputValidation.splitInstallSpecifier(spec) else {
            return nil
        }
        if let pinned = split.pinned, DshSemanticVersion(pinned) != nil {
            return DshInstallCandidate(name: split.name, version: pinned)
        }
        let tag = split.pinned ?? "latest"
        let (document, _) = await fetchPackument(name: split.name, registry: registry)
        guard let tags = document?["dist-tags"] as? [String: String],
              let version = tags[tag] else {
            return nil
        }
        return DshInstallCandidate(name: split.name, version: version)
    }

    /// Keep the local bridge dependency and pnpm lockfile aligned with the
    /// currently running shell. Older Electron builds stored the bridge under
    /// app.asar.unpacked; Swift packages store it directly under Resources.
    @discardableResult
    private func repairDesktopHostDependency(_ hostBundle: String, profileDirectory: URL? = nil) -> Bool {
        let profileDir = profileDirectory ?? Self.activeProfileDirectory
        let packageURL = profileDir.appendingPathComponent("package.json")
        let lockURL = profileDir.appendingPathComponent("pnpm-lock.yaml")
        let hostSpec = "file:\(hostBundle)"
        let relativeHostPath = relativePath(from: profileDir, to: URL(fileURLWithPath: hostBundle))
        var changed = false

        if let data = try? Data(contentsOf: packageURL),
           var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           var dependencies = root["dependencies"] as? [String: String],
           dependencies[Self.desktopHostPluginName] != hostSpec {
            dependencies[Self.desktopHostPluginName] = hostSpec
            root["dependencies"] = dependencies
            if let updated = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) {
                try? updated.write(to: packageURL, options: .atomic)
                changed = true
            }
        }

        // Keep the lockfile in sync as well. It stores the absolute importer
        // specifier but relative package/snapshot references, and an old
        // Electron lockfile can otherwise keep pnpm resolving the dead path.
        if let lockData = try? Data(contentsOf: lockURL),
           var lock = String(data: lockData, encoding: .utf8) {
            var lines = lock.components(separatedBy: "\n")
            for index in lines.indices where lines[index].contains("dsh-desktop-host") {
                let line = lines[index]
                if let marker = line.range(of: "specifier:") {
                    let updatedLine = String(line[..<marker.upperBound]) + " " + hostSpec
                    if updatedLine != line {
                        lines[index] = updatedLine
                        changed = true
                    }
                } else if let marker = line.range(of: "version: file:") ?? line.range(of: "version: link:") {
                    let updatedLine = String(line[..<marker.upperBound]) + relativeHostPath
                    if updatedLine != line {
                        lines[index] = updatedLine
                        changed = true
                    }
                } else if let marker = line.range(of: "resolution: {directory: "),
                          let end = line.range(of: ", type: directory}", range: marker.upperBound..<line.endIndex) {
                    let updatedLine = String(line[..<marker.upperBound]) + relativeHostPath + String(line[end.lowerBound...])
                    if updatedLine != line {
                        lines[index] = updatedLine
                        changed = true
                    }
                } else if let marker = line.range(of: "@file:"),
                          let end = line.lastIndex(of: ":"), end > marker.upperBound {
                    let updatedLine = String(line[..<marker.upperBound]) + relativeHostPath + String(line[end...])
                    if updatedLine != line {
                        lines[index] = updatedLine
                        changed = true
                    }
                }
            }
            lock = lines.joined(separator: "\n")
            if let updated = lock.data(using: .utf8) {
                try? updated.write(to: lockURL, options: .atomic)
            }
        }

        return changed
    }

    private func relativePath(from base: URL, to target: URL) -> String {
        let baseComponents = base.standardizedFileURL.pathComponents
        let targetComponents = target.standardizedFileURL.pathComponents
        var common = 0
        while common < baseComponents.count,
              common < targetComponents.count,
              baseComponents[common] == targetComponents[common] {
            common += 1
        }

        let parentSteps = Array(repeating: "..", count: max(0, baseComponents.count - common))
        let targetSteps = Array(targetComponents.dropFirst(common))
        return (parentSteps + targetSteps).joined(separator: "/")
    }

    private func runProcess(
        _ proc: Process,
        stdout: Pipe? = nil,
        stderr: Pipe? = nil,
        onProgressLine: (@Sendable (String) -> Void)? = nil,
        maximumRuntime: TimeInterval? = nil
    ) async throws -> DshProcessExecutionResult {
        let collector = DshProcessOutputCollector(stdout: stdout, stderr: stderr)
        collector.progressHandler = onProgressLine
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    proc.standardInput = FileHandle.nullDevice
                    try proc.run()
                    let pid = proc.processIdentifier
                    let processGroupID = Self.ownedProcessGroupID(for: pid)
                    collector.start()
                    var timedOut = false
                    let deadline = Date().addingTimeInterval(
                        maximumRuntime ?? Self.processMaximumRuntime
                    )
                    while proc.isRunning {
                        let remaining = deadline.timeIntervalSinceNow
                        if remaining <= 0 {
                            timedOut = true
                            Self.signalProcess(proc, groupID: processGroupID, signal: SIGTERM)
                            let graceDeadline = Date().addingTimeInterval(3)
                            while proc.isRunning && Date() < graceDeadline {
                                Thread.sleep(forTimeInterval: 0.05)
                            }
                            if proc.isRunning {
                                Self.signalProcess(proc, groupID: processGroupID, signal: SIGKILL)
                            }
                            break
                        }
                        Thread.sleep(forTimeInterval: min(0.25, remaining))
                    }
                    proc.waitUntilExit()
                    collector.finishAfterProcessExit()
                    let output = collector.result()
                    if timedOut {
                        throw NSError(
                            domain: "DshPluginManager",
                            code: -37,
                            userInfo: [NSLocalizedDescriptionKey: "插件命令超过最长运行时间，已停止并准备恢复原插件状态"]
                        )
                    }
                    continuation.resume(returning: DshProcessExecutionResult(
                        status: proc.terminationStatus,
                        stdout: output.stdout,
                        stderr: output.stderr
                    ))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// A process group is usable only after this process has successfully
    /// made the spawned child its group leader. Never send a negative PID to
    /// `kill` for an inherited group: that could terminate unrelated app or
    /// shell processes. If the child exits before this handshake completes,
    /// no group is considered owned.
    private static func ownedProcessGroupID(for pid: pid_t) -> pid_t? {
        guard pid > 1, pid != getpid() else { return nil }
        if setpgid(pid, pid) != 0, errno != EACCES, errno != EPERM {
            return nil
        }
        guard getpgid(pid) == pid else { return nil }
        return pid
    }

    /// Signal an owned process group when it is still led by the spawned
    /// process; otherwise signal only that exact child PID. The latter guard
    /// is important after the parent exits: its PID may no longer identify a
    /// process group even though an inherited pipe remains open.
    private static func signalProcess(
        _ proc: Process,
        groupID: pid_t?,
        signal: Int32
    ) {
        let pid = proc.processIdentifier
        guard pid > 1, pid != getpid(), proc.isRunning else { return }
        if let groupID,
           groupID > 1,
           groupID != getpgrp(),
           getpgid(pid) == groupID {
            _ = kill(-groupID, signal)
        } else {
            _ = kill(pid, signal)
        }
    }

    /// A silent download is not proof of an idle network connection. Keep a
    /// generous wall-clock safety bound for ordinary plugin operations, but
    /// never derive liveness from stdout/stderr activity. Profile bridge
    /// materialization uses the shorter dedicated bound below so switching
    /// Profiles cannot leave the UI waiting indefinitely on pnpm.
    private static let processMaximumRuntime: TimeInterval = 30 * 60
    private static var profileBridgeProcessMaximumRuntime: TimeInterval {
#if DSH_TESTING
        if let raw = ProcessInfo.processInfo.environment["DSH_TEST_PROFILE_BRIDGE_TIMEOUT"],
           let value = TimeInterval(raw), value > 0 {
            return value
        }
#endif
        return 5 * 60
    }

    private static let processOutputByteLimit = 32 * 1024
    private static let processOutputCharacterLimit = 8 * 1024
    private static let processOutputTruncationMarker = "\n[output truncated]"

    private func redactedProcessOutput(_ data: Data) -> String {
        let bounded = data.count > Self.processOutputByteLimit
            ? data.prefix(Self.processOutputByteLimit)
            : data[...]
        let text = String(decoding: bounded, as: UTF8.self)
        return DshSecretRedactor().redact(text)
    }

    private func capProcessOutputCharacters(_ text: String) -> String {
        guard text.count > Self.processOutputCharacterLimit else { return text }
        let marker = Self.processOutputTruncationMarker
        let keepCount = max(0, Self.processOutputCharacterLimit - marker.count)
        return String(text.prefix(keepCount)) + marker
    }

    private func capProcessOutputBytes(_ text: String) -> String {
        let data = Data(text.utf8)
        guard data.count > Self.processOutputByteLimit else { return text }
        let marker = Data(Self.processOutputTruncationMarker.utf8)
        let keepCount = max(0, Self.processOutputByteLimit - marker.count)
        return String(decoding: data.prefix(keepCount), as: UTF8.self) + Self.processOutputTruncationMarker
    }

    private func processOutput(_ result: DshProcessExecutionResult) -> String {
        let out = redactedProcessOutput(result.stdout)
        let err = redactedProcessOutput(result.stderr)
        var detail = [out, err]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        detail = capProcessOutputCharacters(detail)
        detail = capProcessOutputBytes(detail)
        return detail.isEmpty ? "" : "：\n\(detail)"
    }

    private func currentDshVersion() -> String? {
        guard let entry = DshVersionManager.shared.resolveCurrentEntry() else { return nil }
        let packageURL = URL(fileURLWithPath: entry)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: packageURL),
              let package = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              package["name"] as? String == "@deepseek-ai/dsh",
              let version = package["version"] as? String,
              DshVersionManager.isValidVersion(version) else {
            return nil
        }
        return version
    }

    /// Keep the application-owned desktop Profile compatible with pnpm's
    /// DSH workspace defaults. The Web profile is shared with the terminal
    /// CLI, so it is intentionally left untouched here.
    private func ensureManagedProfileWorkspaceConfiguration(
        at profileDir: URL,
        profile: DshAppProfile? = nil
    ) throws {
        guard (profile ?? DshStateManager.shared.current.appProfile) == .desktop else { return }
        try FileManager.default.createDirectory(at: profileDir, withIntermediateDirectories: true)

        let workspaceURL = profileDir.appendingPathComponent(Self.profileWorkspaceFileName)
        let canonical = """
        packages:
          - .

        nodeLinker: hoisted
        autoInstallPeers: false
        """

        guard FileManager.default.fileExists(atPath: workspaceURL.path) else {
            try canonical.write(to: workspaceURL, atomically: true, encoding: .utf8)
            return
        }

        guard let data = try? Data(contentsOf: workspaceURL),
              let source = String(data: data, encoding: .utf8) else {
            throw NSError(
                domain: "DshPluginManager",
                code: -23,
                userInfo: [NSLocalizedDescriptionKey: "无法读取 Desktop Profile 的 pnpm workspace 配置"]
            )
        }

        // Preserve custom settings such as allowBuilds and
        // minimumReleaseAgeExclude. Only repair the DSH workspace invariants
        // that affect peer resolution and the profile package layout.
        var updated = source
        if !Self.hasTopLevelWorkspaceKey("packages", in: updated) {
            updated = Self.appendWorkspaceText("packages:\n  - .", to: updated)
        }
        updated = Self.setTopLevelWorkspaceValue("nodeLinker", value: "hoisted", in: updated)
        updated = Self.setTopLevelWorkspaceValue("autoInstallPeers", value: "false", in: updated)

        guard updated != source else { return }
        try updated.write(to: workspaceURL, atomically: true, encoding: .utf8)
    }

    private static func hasTopLevelWorkspaceKey(_ key: String, in source: String) -> Bool {
        source.components(separatedBy: "\n").contains { line in
            !line.hasPrefix(" ") &&
            !line.hasPrefix("\t") &&
            line.hasPrefix("\(key):")
        }
    }

    private static func setTopLevelWorkspaceValue(
        _ key: String,
        value: String,
        in source: String
    ) -> String {
        var lines = source.components(separatedBy: "\n")
        if let index = lines.firstIndex(where: { line in
            !line.hasPrefix(" ") &&
            !line.hasPrefix("\t") &&
            line.hasPrefix("\(key):")
        }) {
            lines[index] = "\(key): \(value)"
            return lines.joined(separator: "\n")
        }
        return appendWorkspaceText("\(key): \(value)", to: source)
    }

    private static func appendWorkspaceText(_ text: String, to source: String) -> String {
        var result = source
        if !result.isEmpty && !result.hasSuffix("\n") {
            result += "\n"
        }
        if !result.isEmpty && !result.hasSuffix("\n\n") {
            result += "\n"
        }
        result += text
        if !result.hasSuffix("\n") {
            result += "\n"
        }
        return result
    }

    /// Create the canonical selected-profile manifest before pnpm is invoked.
    ///
    /// DSH normally creates this file during its first boot. That ordering is
    /// unsafe for the desktop shell because the first boot would use the
    /// upstream, unprotected WebServer before the managed host can be added.
    /// The shape mirrors DSH's standard profile initializer and preserves
    /// any existing user dependencies and bundle order.
    public func bootstrapWebProfileManifestIfMissing() throws {
        let selectedProfile = DshStateManager.shared.current.appProfile
        try bootstrapWebProfileManifestIfMissing(
            at: Self.activeProfileDirectory,
            profile: selectedProfile
        )
    }

    /// Bootstrap an explicitly selected Profile directory. `profile` is only
    /// the logical owner used for workspace rules; the supplied URL remains
    /// the sole filesystem target.
    public func bootstrapWebProfileManifestIfMissing(
        at profileDir: URL,
        profile selectedProfile: DshAppProfile
    ) throws {
        let readiness = bootstrapReadiness(at: profileDir)
        switch readiness {
        case .initialized:
            return
        case .existingUninitialized:
            throw NSError(
                domain: "DshPluginManager",
                code: -25,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "拒绝自动创建 \(selectedProfile.runtimeProfileName) Profile manifest：现有 Profile 未完成初始化，请先完成只读依赖检查或恢复"
                ]
            )
        case .invalid:
            throw NSError(
                domain: "DshPluginManager",
                code: -11,
                userInfo: [NSLocalizedDescriptionKey: "无法读取 \(selectedProfile.runtimeProfileName) Profile manifest"]
            )
        case .freshEmpty:
            break
        }

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: profileDir, withIntermediateDirectories: true)
        try ensureManagedProfileWorkspaceConfiguration(at: profileDir, profile: selectedProfile)
        let root: [String: Any] = [
            "name": "dsh-profile-\(selectedProfile.runtimeProfileName)",
            "private": true,
            "dependencies": [String: String](),
            "dsh": [
                "profile": ["bundles": Self.standardProfileBundles]
            ]
        ]
        let packageURL = profileDir.appendingPathComponent("package.json")
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: packageURL, options: .atomic)
    }

    /// Repair the profile manifest created by an older Swift shell.
    ///
    /// Existing Profiles are deliberately left untouched. F03 startup must
    /// inspect or recover a non-empty incomplete tree before any write; only a
    /// genuinely empty Profile may receive the canonical bootstrap manifest.
    public func repairWebProfileManifestIfNeeded() {
        let profileDir = Self.activeProfileDirectory
        guard bootstrapReadiness(at: profileDir) == .freshEmpty else { return }
        try? bootstrapWebProfileManifestIfMissing(
            at: profileDir,
            profile: DshStateManager.shared.current.appProfile
        )
    }

    /// Whether the web profile has already been initialized enough for pnpm
    /// to add a local bridge bundle without recreating a partial manifest.
    /// A completely new profile is intentionally left for the first DSH boot
    /// so DSH can write its canonical package metadata first.
    public func hasInitializedWebProfileManifest() -> Bool {
        hasInitializedWebProfileManifest(at: Self.activeProfileDirectory)
    }

    public func hasInitializedWebProfileManifest(at profileDir: URL) -> Bool {
        bootstrapReadiness(at: profileDir) == .initialized
    }

    /// Classify a captured Profile path without creating directories or
    /// repairing its manifest. Launchers must use this result together with
    /// the Inspector evidence before calling a bootstrap mutator.
    public func bootstrapReadiness(at profileDir: URL) -> DshProfileBootstrapReadiness {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: profileDir.path) else { return .freshEmpty }
        guard let values = try? profileDir.resourceValues(forKeys: [.isDirectoryKey]),
              values.isDirectory == true else {
            return .invalid
        }

        guard let entries = try? fileManager.contentsOfDirectory(
            at: profileDir,
            includingPropertiesForKeys: nil,
            options: []
        ) else {
            return .invalid
        }
        guard !entries.isEmpty else { return .freshEmpty }

        let packageURL = profileDir.appendingPathComponent("package.json")
        guard fileManager.fileExists(atPath: packageURL.path) else {
            return .existingUninitialized
        }
        guard let data = try? Data(contentsOf: packageURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .invalid
        }
        guard let dsh = root["dsh"] as? [String: Any],
              let profile = dsh["profile"] as? [String: Any],
              let bundles = profile["bundles"] as? [String],
              !bundles.isEmpty else {
            return .existingUninitialized
        }
        return .initialized
    }

    /// Ensure the built-in desktop host bridge plugin is installed and valid
    /// in the selected profile. Failure is thrown so callers cannot start a bare
    /// WebServer as a fallback.
    public func ensureDesktopHostPlugin(
        registry: String? = nil,
        profileDirectory: URL? = nil,
        profile: DshAppProfile? = nil,
        runtimeVersion: String? = nil
    ) async throws -> Bool {
        let stateSnapshot = DshStateManager.shared.current
        let targetProfile = profile ?? stateSnapshot.appProfile
        let capturedRegistry = DshVersionManager.normalizedRegistry(registry ?? stateSnapshot.npmRegistry)
        guard let hostBundle = NodeRuntime.shared.resolveDesktopHostBundlePath() else {
            throw NSError(domain: "DshPluginManager", code: -12, userInfo: [NSLocalizedDescriptionKey: "找不到内置 dsh-desktop-host Bundle"])
        }
        guard let dshVersion = runtimeVersion ?? currentDshVersion() else {
            throw NSError(domain: "DshPluginManager", code: -18, userInfo: [NSLocalizedDescriptionKey: "无法确定当前 DSH 版本，拒绝启动未验证的桌面 Host"])
        }
        try validateDesktopHostBundle(hostBundle)
        let profileDir = profileDirectory ?? Self.profileDirectory(for: targetProfile)

        let hostSpec = "file:\(hostBundle)"
        let installedHostIsCurrent = isInstalledDesktopHostBundle(
            profileDir: profileDir,
            sourceBundle: hostBundle
        )

        // A package with the bridge's name may belong to the terminal user.
        // Before repairing or replacing any existing node_modules entry,
        // require the durable proof established by a prior managed install.
        let installedHostURL = profileDir
            .appendingPathComponent("node_modules", isDirectory: true)
            .appendingPathComponent(Self.desktopHostPluginName, isDirectory: true)
        let packageURL = profileDir.appendingPathComponent("package.json")
        let packageRoot = (try? Data(contentsOf: packageURL))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let hasBridgeDeclaration: Bool
        if let packageRoot,
           let dependencies = packageRoot["dependencies"] as? [String: Any] {
            let hasDependency = dependencies[Self.desktopHostPluginName] != nil
                || dependencies["@deepseek-ai/dsh-host-webserver"] != nil
            let hasBundle = (packageRoot["dsh"] as? [String: Any])
                .flatMap { $0["profile"] as? [String: Any] }
                .flatMap { $0["bundles"] as? [String] }?
                .contains(Self.desktopHostPluginName) == true
            hasBridgeDeclaration = hasDependency || hasBundle
        } else {
            hasBridgeDeclaration = false
        }
        var hasVerifiedHostOwnership = false
        var hasStaleOwnedHost = false
        if FileManager.default.fileExists(atPath: installedHostURL.path) || hasBridgeDeclaration {
            do {
                try verifyDesktopHostOwnershipProof(
                    profileDir: profileDir, packageRoot: packageRoot,
                    operation: "安装桌面桥接依赖")
                hasVerifiedHostOwnership = true
            } catch {
                // Pre-marker installs predate the proof file. Adopt ownership
                // only when the installed bits provably came from this App;
                // partial installs fall through to pnpm add, which records
                // the proof once the tree is complete.
                let proofWritten = try adoptDesktopHostOwnershipProof(
                    profileDir: profileDir, packageRoot: packageRoot,
                    sourceBundle: hostBundle)
                if proofWritten {
                    let refreshedRoot = (try? Data(contentsOf: packageURL))
                        .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                    try verifyDesktopHostOwnershipProof(
                        profileDir: profileDir, packageRoot: refreshedRoot,
                        operation: "安装桌面桥接依赖")
                    hasVerifiedHostOwnership = true
                } else if installedHostIsCurrent {
                    // The host bytes and declarations were proven by adopt,
                    // but the WebServer may still be missing. Keep the host
                    // local and ask pnpm only for that missing dependency.
                    hasVerifiedHostOwnership = true
                } else if staleAppBridgeRejectionReason(
                    profileDir: profileDir,
                    packageRoot: packageRoot,
                    sourceBundle: hostBundle
                ) == nil {
                    // A valid old App source plus matching installed
                    // fingerprint proves this is an App-owned stale bridge.
                    // It is refreshed locally below, without a graph-wide
                    // pnpm reinstall.
                    hasVerifiedHostOwnership = true
                    hasStaleOwnedHost = true
                }
            }
        }

        try bootstrapWebProfileManifestIfMissing(at: profileDir, profile: targetProfile)

        if hasVerifiedHostOwnership && (hasStaleOwnedHost || !FileManager.default.fileExists(atPath: installedHostURL.path)) {
            try refreshAppOwnedDesktopHostBundle(
                profileDir: profileDir,
                sourceBundle: hostBundle
            )
        }
        // This is metadata-only reconciliation. It is safe after ownership
        // has been established, and never implies a graph-wide reinstall.
        _ = repairDesktopHostDependency(hostBundle, profileDirectory: profileDir)

        let plugins = listPlugins(at: profileDir)
        if let existing = plugins.first(where: { $0.name == Self.desktopHostPluginName }) {
            if existing.version == hostSpec {
                if profileContainsBundle(Self.desktopHostPluginName, profileDir: profileDir),
                   isInstalledDesktopHostBundle(profileDir: profileDir, sourceBundle: hostBundle),
                   isInstalledWebServerPackage(profileDir: profileDir, version: dshVersion) {
                    try writeDesktopHostOwnershipProof(profileDir: profileDir, sourceBundle: hostBundle)
                    return false // Already installed and mounted.
                }
                try updateProfileBundle(Self.desktopHostPluginName, removing: false, profileDir: profileDir)
                // The local bridge may be mounted already while the matching
                // upstream WebServer dependency is missing from an older
                // profile. The pnpm call below adds only that missing piece.
            }
        }

        let hostIsInstalled = isInstalledDesktopHostBundle(
            profileDir: profileDir,
            sourceBundle: hostBundle
        )
        let webServerIsInstalled = isInstalledWebServerPackage(
            profileDir: profileDir,
            version: dshVersion
        )
        guard !hostIsInstalled || !webServerIsInstalled else {
            throw NSError(
                domain: "DshPluginManager",
                code: -15,
                userInfo: [NSLocalizedDescriptionKey: "内置桥接插件已物化，但 Profile manifest 未正确挂载"]
            )
        }

        let (node, pnpm) = try dshRequireNodeAndPnpm()

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pnpm)
        proc.currentDirectoryURL = profileDir
        proc.arguments = hostIsInstalled
            ? [
                "add",
                "@deepseek-ai/dsh-host-webserver@\(dshVersion)",
                "--config.minimum-release-age=0",
                "--registry", capturedRegistry,
                "--reporter=append-only"
            ]
            : [
                "add",
                "file:\(hostBundle)",
                "@deepseek-ai/dsh-host-webserver@\(dshVersion)",
                "--config.minimum-release-age=0",
                "--registry", capturedRegistry,
                "--reporter=append-only"
            ]

        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardOutput = stdout
        proc.standardError = stderr

        var env = NodeRuntime.shared.buildEnvironment()
        env["DSH_NODE_BIN"] = node
        proc.environment = env

        let result: DshProcessExecutionResult
        do {
            result = try await runProcess(
                proc,
                stdout: stdout,
                stderr: stderr,
                maximumRuntime: Self.profileBridgeProcessMaximumRuntime
            )
        } catch {
            throw NSError(
                domain: "DshPluginManager",
                code: -13,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "无法启动 pnpm 安装内置桥接插件：\(error.localizedDescription)"
                ]
            )
        }
        guard result.status == 0 else {
            throw NSError(
                domain: "DshPluginManager",
                code: -14,
                userInfo: [NSLocalizedDescriptionKey: "安装内置桥接插件失败（退出码 \(result.status)）\(processOutput(result))"]
            )
        }

        try updateProfileBundle(Self.desktopHostPluginName, removing: false, profileDir: profileDir)
        guard profileContainsBundle(Self.desktopHostPluginName, profileDir: profileDir),
              isInstalledDesktopHostBundle(profileDir: profileDir, sourceBundle: hostBundle),
              isInstalledWebServerPackage(profileDir: profileDir, version: dshVersion) else {
            throw NSError(domain: "DshPluginManager", code: -15, userInfo: [NSLocalizedDescriptionKey: "内置桥接插件安装后未正确挂载"])
        }
        try writeDesktopHostOwnershipProof(profileDir: profileDir, sourceBundle: hostBundle)
        return true
    }

    /// Repair an incomplete application-owned Profile install before DSH is
    /// launched. `dsh plugin` deliberately forwards pnpm arguments verbatim,
    /// so a Profile created during a fresh DSH family release can be left with
    /// a lockfile but without a complete `node_modules` tree when pnpm's
    /// minimum-release-age policy rejects the just-published packages.
    ///
    /// This is intentionally lazy and scoped to the Profile used by the app:
    /// healthy profiles are not reinstalled, and the global pnpm configuration is never changed.
    /// The install is allowed to use zero
    /// release age only because the app is materializing its own pinned Profile
    /// lockfile; --frozen-lockfile prevents this repair from resolving new
    /// user dependencies, while pnpm still verifies the lockfile integrity and
    /// registry data.
    @discardableResult
    public func repairProfileDependenciesIfNeeded(
        registry: String? = nil,
        profileDirectory: URL? = nil,
        profile: DshAppProfile? = nil
    ) async throws -> Bool {
        let stateSnapshot = DshStateManager.shared.current
        let targetProfile = profile ?? stateSnapshot.appProfile
        let capturedRegistry = DshVersionManager.normalizedRegistry(registry ?? stateSnapshot.npmRegistry)
        guard targetProfile == .desktop else {
            // The web Profile is intentionally shared with the terminal CLI.
            // Never repair or reinstall that user-owned dependency tree during
            // an app launch.
            return false
        }
        let profileDir = profileDirectory ?? Self.profileDirectory(for: targetProfile)
        try ensureManagedProfileWorkspaceConfiguration(at: profileDir, profile: targetProfile)
        let packageURL = profileDir.appendingPathComponent("package.json")
        let lockfileURL = profileDir.appendingPathComponent("pnpm-lock.yaml")
        guard FileManager.default.fileExists(atPath: lockfileURL.path) else {
            // A new profile has no lockfile yet. The managed Host reconciliation
            // below the caller owns that first-install path.
            return false
        }
        guard let data = try? Data(contentsOf: packageURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dependencies = root["dependencies"] as? [String: Any],
              !dependencies.isEmpty else {
            return false
        }

        guard profileDependenciesNeedInstall(dependencies, profileDir: profileDir) else {
            return false
        }
        guard let pnpm = NodeRuntime.shared.resolvePnpmBinary(),
              let node = NodeRuntime.shared.resolveNodeBinary() else {
            throw NSError(
                domain: "DshPluginManager",
                code: -19,
                userInfo: [NSLocalizedDescriptionKey: "Desktop Profile 依赖不完整，但找不到 Node 或 pnpm，无法自动修复"]
            )
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pnpm)
        proc.currentDirectoryURL = profileDir
        proc.arguments = [
            "install",
            "--frozen-lockfile",
            "--config.minimum-release-age=0",
                "--registry", capturedRegistry,
            "--prefer-offline",
            "--reporter=append-only"
        ]

        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardOutput = stdout
        proc.standardError = stderr

        var env = NodeRuntime.shared.buildEnvironment()
        env["DSH_NODE_BIN"] = node
        proc.environment = env

        let result: DshProcessExecutionResult
        do {
            result = try await runProcess(proc, stdout: stdout, stderr: stderr)
        } catch {
            throw NSError(
                domain: "DshPluginManager",
                code: -20,
                userInfo: [NSLocalizedDescriptionKey: "无法启动 Desktop Profile 依赖修复"]
            )
        }
        guard result.status == 0 else {
            let detail = processOutput(result)
            throw NSError(
                domain: "DshPluginManager",
                code: -21,
                userInfo: [NSLocalizedDescriptionKey: "Swift Desktop Profile 依赖修复失败（退出码 \(result.status)）。如果需要手动修复，请执行：dsh plugin --profile \(targetProfile.runtimeProfileName) install --config.minimum-release-age=0\(detail)"]
            )
        }

        guard !profileDependenciesNeedInstall(dependencies, profileDir: profileDir) else {
            throw NSError(
                domain: "DshPluginManager",
                code: -22,
                userInfo: [NSLocalizedDescriptionKey: "Desktop Profile 依赖修复完成，但仍有依赖未物化；请打开设置查看详细错误"]
            )
        }
        return true
    }

    private func profileDependenciesNeedInstall(
        _ dependencies: [String: Any],
        profileDir: URL
    ) -> Bool {
        let modulesManifest = profileDir
            .appendingPathComponent("node_modules", isDirectory: true)
            .appendingPathComponent(".modules.yaml")
        guard FileManager.default.fileExists(atPath: modulesManifest.path) else {
            return true
        }

        return dependencies.keys.contains { name in
            guard let packageManifest = packageManifestURL(name: name, profileDir: profileDir) else {
                return true
            }
            return !FileManager.default.fileExists(atPath: packageManifest.path)
        }
    }

    private func packageManifestURL(name: String, profileDir: URL) -> URL? {
        let parts = name.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 1 || (parts.count == 2 && parts[0].hasPrefix("@")),
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            return nil
        }

        let nodeModules = profileDir.appendingPathComponent("node_modules", isDirectory: true)
        let packageURL = parts.reduce(nodeModules) { $0.appendingPathComponent($1, isDirectory: true) }
            .appendingPathComponent("package.json")
        let root = nodeModules.standardizedFileURL.path
        let candidate = packageURL.standardizedFileURL.path
        guard candidate.hasPrefix(root + "/") else { return nil }
        return packageURL
    }

    private func validateDesktopHostBundle(_ path: String) throws {
        let bundleURL = URL(fileURLWithPath: path, isDirectory: true)
        guard Self.desktopHostRequiredFiles.allSatisfy({ FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent($0).path) }),
              let data = try? Data(contentsOf: bundleURL.appendingPathComponent("package.json")),
              let package = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              package["name"] as? String == Self.desktopHostPluginName,
              let exports = package["exports"] as? [String: String],
              exports["./webserver"] == "./webserver.js" else {
            throw NSError(domain: "DshPluginManager", code: -16, userInfo: [NSLocalizedDescriptionKey: "内置 dsh-desktop-host Bundle 不完整"])
        }
    }

    private func isInstalledDesktopHostBundle(profileDir: URL, sourceBundle: String) -> Bool {
        let manifestURL = profileDir
            .appendingPathComponent("node_modules", isDirectory: true)
            .appendingPathComponent(Self.desktopHostPluginName, isDirectory: true)
            .appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let package = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        guard package["name"] as? String == Self.desktopHostPluginName else { return false }
        return desktopHostBundleFingerprint(at: manifestURL.deletingLastPathComponent())
            == desktopHostBundleFingerprint(at: URL(fileURLWithPath: sourceBundle, isDirectory: true))
    }

    private func removeInstalledDesktopHostBundle(profileDir: URL, sourceBundle: String) throws {
        let installedURL = profileDir
            .appendingPathComponent("node_modules", isDirectory: true)
            .appendingPathComponent(Self.desktopHostPluginName, isDirectory: true)
        let sourceURL = URL(fileURLWithPath: sourceBundle, isDirectory: true)
        guard installedURL.standardizedFileURL.path != sourceURL.standardizedFileURL.path,
              FileManager.default.fileExists(atPath: installedURL.path) else { return }
        try FileManager.default.removeItem(at: installedURL)
    }

    private func desktopHostBundleFingerprint(at bundleURL: URL) -> String? {
        var hasher = SHA256()
        for name in Self.desktopHostRequiredFiles {
            let fileURL = bundleURL.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: fileURL) else { return nil }
            hasher.update(data: Data(name.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: data)
            hasher.update(data: Data([0]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func isInstalledWebServerPackage(profileDir: URL, version: String) -> Bool {
        let manifestURL = profileDir
            .appendingPathComponent("node_modules", isDirectory: true)
            .appendingPathComponent("@deepseek-ai", isDirectory: true)
            .appendingPathComponent("dsh-host-webserver", isDirectory: true)
            .appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let package = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return package["name"] as? String == "@deepseek-ai/dsh-host-webserver"
            && package["version"] as? String == version
    }

    /// Turn an unproven bridge-ownership failure into an actionable message:
    /// a same-name dependency installed by the terminal user is retained by
    /// design, and the user must see why web->desktop cleanup keeps failing.
    private static func unprovenBridgeOwnershipFailure(underlying: Error) -> Error {
        NSError(
            domain: "DshPluginManager",
            code: -60,
            userInfo: [NSLocalizedDescriptionKey: "\(underlying.localizedDescription) 若 \(desktopHostPluginName) 或 @deepseek-ai/dsh-host-webserver 是您手动安装到 web Profile 的同名包，请先在终端 dsh web 中移除或重命名该包，再重试切换到 swift-desktop Profile。"]
        )
    }

    private func desktopHostOwnershipError(_ detail: String, operation: String = "清理 web Profile 桥接依赖") -> NSError {
        NSError(
            domain: "DshPluginManager",
            code: -24,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "拒绝自动\(operation)：\(detail)。为保护用户同名依赖，请手动处理"
            ]
        )
    }

    private func normalizedFileDependencyPath(_ spec: String) -> String? {
        guard spec.hasPrefix("file:") else { return nil }
        let path = String(spec.dropFirst("file:".count))
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private func isPath(_ candidate: URL, inside directory: URL) -> Bool {
        let root = directory.resolvingSymlinksInPath().standardizedFileURL.path
        let path = candidate.resolvingSymlinksInPath().standardizedFileURL.path
        return path == root || path.hasPrefix(root + "/")
    }

    private func manifestFingerprint(at manifestURL: URL) -> String? {
        guard let data = try? Data(contentsOf: manifestURL) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Adopt a pre-marker bridge install established by an older shell.
    /// Returns true when the ownership proof was recorded immediately.
    /// Adoption requires the installed bits to be byte-identical to the
    /// current bundled bridge plus manifest declarations that already point
    /// at a file: bridge and the runtime webserver; anything else stays
    /// fail-closed so user-owned same-name entries are never touched.
    /// A partial install (host present, webserver missing) returns false so
    /// the pnpm add below completes it and records the proof post-install.
    private func adoptDesktopHostOwnershipProof(
        profileDir: URL,
        packageRoot: [String: Any]?,
        sourceBundle: String
    ) throws -> Bool {
        let operation = "安装桌面桥接依赖"
        let installedHostURL = profileDir
            .appendingPathComponent("node_modules", isDirectory: true)
            .appendingPathComponent(Self.desktopHostPluginName, isDirectory: true)
        guard FileManager.default.fileExists(atPath: installedHostURL.path),
              isPath(installedHostURL, inside: profileDir),
              isInstalledDesktopHostBundle(profileDir: profileDir, sourceBundle: sourceBundle) else {
            if let reason = staleAppBridgeRejectionReason(
                profileDir: profileDir, packageRoot: packageRoot, sourceBundle: sourceBundle) {
                throw desktopHostOwnershipError(reason, operation: operation)
            }
            // Stale but provably App-placed: leave the manifest and installed
            // tree untouched until ensureDesktopHostPlugin has staged and
            // atomically replaced the bridge. The proof is recorded only
            // after the replacement and all postconditions pass.
            return false
        }
        let packageURL = profileDir.appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: packageURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dependencies = root["dependencies"] as? [String: Any],
              let hostSpec = dependencies[Self.desktopHostPluginName] as? String,
              normalizedFileDependencyPath(hostSpec) != nil,
              let webServerSpec = dependencies["@deepseek-ai/dsh-host-webserver"] as? String,
              !webServerSpec.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let dsh = root["dsh"] as? [String: Any],
              let profile = dsh["profile"] as? [String: Any],
              let bundles = profile["bundles"] as? [String],
              bundles.contains(Self.desktopHostPluginName) else {
            throw desktopHostOwnershipError("缺少、损坏或不匹配的持久所有权证明", operation: operation)
        }
        // App upgrades move the file: target; align the declaration (and the
        // lockfile importer) before recording the proof. Bit-equality above
        // already proved the installed directory is ours.
        _ = repairDesktopHostDependency(sourceBundle, profileDirectory: profileDir)
        if (try? writeDesktopHostOwnershipProof(profileDir: profileDir, sourceBundle: sourceBundle)) != nil {
            return true
        }
        return false
    }

    /// Refresh only the App-owned bridge bundle. The copy is staged inside
    /// the selected Profile (therefore on the same volume), validated before
    /// publication, and installed with FileManager's replacement primitive.
    /// If the filesystem cannot atomically replace a populated directory, the
    /// refresh fails without falling back to a two-move sequence that could
    /// leave the bridge missing after a force-quit. User dependencies elsewhere
    /// in node_modules are never touched.
    private func refreshAppOwnedDesktopHostBundle(
        profileDir: URL,
        sourceBundle: String
    ) throws {
        let fileManager = FileManager.default
        let sourceURL = URL(fileURLWithPath: sourceBundle, isDirectory: true)
        let installedURL = profileDir
            .appendingPathComponent("node_modules", isDirectory: true)
            .appendingPathComponent(Self.desktopHostPluginName, isDirectory: true)
        guard isPath(installedURL, inside: profileDir) else {
            throw desktopHostOwnershipError(
                "已安装桥接路径缺失或越界",
                operation: "刷新桌面桥接依赖"
            )
        }
        guard let sourceFingerprint = desktopHostBundleFingerprint(at: sourceURL) else {
            throw desktopHostOwnershipError(
                "当前内置桥接指纹不可读",
                operation: "刷新桌面桥接依赖"
            )
        }

        let stagingRoot = profileDir.appendingPathComponent(
            ".dsh-desktop-host-staging-\(UUID().uuidString)",
            isDirectory: true
        )
        let stagedURL = stagingRoot.appendingPathComponent(
            Self.desktopHostPluginName,
            isDirectory: true
        )
        let backupURL = installedURL.deletingLastPathComponent().appendingPathComponent(
            ".dsh-desktop-host-previous-\(UUID().uuidString)",
            isDirectory: true
        )
        var backupExists = false
        defer {
            try? fileManager.removeItem(at: stagingRoot)
            if backupExists {
                try? fileManager.removeItem(at: backupURL)
            }
        }

        try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        try fileManager.copyItem(at: sourceURL, to: stagedURL)
        try validateDesktopHostBundle(stagedURL.path)
        guard desktopHostBundleFingerprint(at: stagedURL) == sourceFingerprint else {
            throw desktopHostOwnershipError(
                "暂存桥接指纹不匹配",
                operation: "刷新桌面桥接依赖"
            )
        }
        try fileManager.createDirectory(
            at: installedURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if fileManager.fileExists(atPath: installedURL.path) {
            do {
                // This keeps the destination replacement atomic when the
                // filesystem supports directory replacement.
                _ = try fileManager.replaceItemAt(
                    installedURL,
                    withItemAt: stagedURL,
                    backupItemName: backupURL.lastPathComponent,
                    options: []
                )
                backupExists = fileManager.fileExists(atPath: backupURL.path)
            } catch {
                throw desktopHostOwnershipError(
                    "文件系统不支持原子替换，旧桥接已保留（\(error.localizedDescription)）",
                    operation: "刷新桌面桥接依赖"
                )
            }
        } else {
            try fileManager.moveItem(at: stagedURL, to: installedURL)
        }

        guard desktopHostBundleFingerprint(at: installedURL) == sourceFingerprint else {
            try? fileManager.removeItem(at: installedURL)
            if backupExists {
                try? fileManager.moveItem(at: backupURL, to: installedURL)
                backupExists = false
            }
            throw desktopHostOwnershipError(
                "刷新后桥接指纹不匹配",
                operation: "刷新桌面桥接依赖"
            )
        }
    }

    /// A bridge installed by a previous App whose bundled bits have since
    /// changed. Returns nil when the installed directory is still provably
    /// App-placed (byte-identical to the bundle the manifest spec points at,
    /// that spec lives inside an App bundle's Resources tree, and the
    /// referenced bundle validates); otherwise returns a specific reason so
    /// the failure stays actionable instead of collapsing into the generic
    /// missing-proof message.
    private func hasStaleBridgeOwnershipProof(
        profileDir: URL,
        packageRoot: [String: Any]?,
        sourceBundle: String,
        currentSourceFingerprint: String
    ) -> Bool {
        let markerURL = profileDir.appendingPathComponent(Self.desktopHostOwnershipMarkerName)
        guard let markerData = try? Data(contentsOf: markerURL),
              let marker = try? JSONSerialization.jsonObject(with: markerData) as? [String: Any],
              marker["schema"] as? Int == 1,
              marker["profileDirectory"] as? String == profileDir.standardizedFileURL.path,
              marker["sourceBundle"] as? String
                == URL(fileURLWithPath: sourceBundle, isDirectory: true).standardizedFileURL.path,
              let recordedSourceFingerprint = marker["sourceFingerprint"] as? String,
              let recordedInstalledFingerprint = marker["installedFingerprint"] as? String,
              recordedSourceFingerprint != currentSourceFingerprint,
              recordedInstalledFingerprint == desktopHostBundleFingerprint(
                at: profileDir
                    .appendingPathComponent("node_modules", isDirectory: true)
                    .appendingPathComponent(Self.desktopHostPluginName, isDirectory: true)
              ),
              let recordedDependencies = marker["dependencies"] as? [String: String],
              recordedDependencies.count == 2,
              let recordedHostSpec = recordedDependencies[Self.desktopHostPluginName],
              let recordedWebServerSpec = recordedDependencies["@deepseek-ai/dsh-host-webserver"],
              let root = packageRoot,
              let dependencies = root["dependencies"] as? [String: Any],
              dependencies[Self.desktopHostPluginName] as? String
                == recordedHostSpec,
              dependencies["@deepseek-ai/dsh-host-webserver"] as? String
                == recordedWebServerSpec,
              let dsh = root["dsh"] as? [String: Any],
              let profile = dsh["profile"] as? [String: Any],
              let bundles = profile["bundles"] as? [String],
              bundles.contains(Self.desktopHostPluginName) else {
            return false
        }
        return true
    }

    /// True when a durable ownership proof exists and the on-disk bridge tree
    /// is exactly the tree the recorded managed install produced, with the
    /// manifest still declaring the recorded dependency specs. The source app
    /// may have been deleted, moved, or rebuilt since then (routine for
    /// development builds outside /Applications); the recorded installed
    /// fingerprint still anchors ownership of the tree itself.
    private func hasUntamperedInstalledBridgeProof(
        profileDir: URL,
        packageRoot: [String: Any]?
    ) -> Bool {
        let markerURL = profileDir.appendingPathComponent(Self.desktopHostOwnershipMarkerName)
        guard let markerData = try? Data(contentsOf: markerURL),
              let marker = try? JSONSerialization.jsonObject(with: markerData) as? [String: Any],
              marker["schema"] as? Int == 1,
              marker["profileDirectory"] as? String == profileDir.standardizedFileURL.path,
              let installedFingerprint = marker["installedFingerprint"] as? String,
              !installedFingerprint.isEmpty,
              let recordedDependencies = marker["dependencies"] as? [String: String],
              recordedDependencies.count == 2,
              let recordedHostSpec = recordedDependencies[Self.desktopHostPluginName],
              let recordedWebServerSpec = recordedDependencies["@deepseek-ai/dsh-host-webserver"],
              let root = packageRoot,
              ((root["dsh"] as? [String: Any])
                .flatMap { $0["profile"] as? [String: Any] }
                .flatMap { $0["bundles"] as? [String] }?
                .contains(Self.desktopHostPluginName)) == true,
              let onDiskFingerprint = desktopHostBundleFingerprint(
                at: profileDir
                    .appendingPathComponent("node_modules", isDirectory: true)
                    .appendingPathComponent(Self.desktopHostPluginName, isDirectory: true)
              ),
              onDiskFingerprint == installedFingerprint else {
            return false
        }
        // A process can be terminated after pnpm removes the direct entries
        // but before the bundle list and marker are finalized. Missing bridge
        // entries are therefore accepted only as the absence of a conflict;
        // any surviving same-name declaration must still match the proof.
        guard let dependencies = root["dependencies"] as? [String: Any] else {
            return false
        }
        if let hostSpec = dependencies[Self.desktopHostPluginName] as? String,
           hostSpec != recordedHostSpec {
            return false
        }
        if let webServerSpec = dependencies["@deepseek-ai/dsh-host-webserver"] as? String,
           webServerSpec != recordedWebServerSpec {
            return false
        }
        // If the internal peer is still materialized, bind it to the
        // fingerprint recorded by the same managed install as well. A user
        // replacement that keeps only the bridge package name must never be
        // accepted as proof merely because the host bytes happen to match.
        let webServerManifestURL = profileDir
            .appendingPathComponent("node_modules", isDirectory: true)
            .appendingPathComponent("@deepseek-ai", isDirectory: true)
            .appendingPathComponent("dsh-host-webserver", isDirectory: true)
            .appendingPathComponent("package.json")
        if FileManager.default.fileExists(atPath: webServerManifestURL.path) {
            guard let recordedWebServerFingerprint = marker["webServerManifestFingerprint"] as? String,
                  manifestFingerprint(at: webServerManifestURL) == recordedWebServerFingerprint else {
                return false
            }
        }
        return true
    }

    private func staleAppBridgeRejectionReason(
        profileDir: URL,
        packageRoot: [String: Any]?,
        sourceBundle: String
    ) -> String? {
        let sourcePath = URL(fileURLWithPath: sourceBundle, isDirectory: true).standardizedFileURL.path
        guard let root = packageRoot else {
            return "Profile manifest 不可读"
        }
        guard let dependencies = root["dependencies"] as? [String: Any],
              let hostSpec = dependencies[Self.desktopHostPluginName] as? String,
              let oldPath = normalizedFileDependencyPath(hostSpec) else {
            return "桥接声明不是 App 安装的 file: 依赖"
        }
        // The recorded source app may have been deleted or replaced since the
        // managed install (normal for development builds). The proof's
        // installed fingerprint still proves the tree is App-managed, so the
        // caller refreshes it from the current bundle and re-records the proof.
        if hasUntamperedInstalledBridgeProof(profileDir: profileDir, packageRoot: root) {
            return nil
        }
        guard let dsh = root["dsh"] as? [String: Any],
              let profile = dsh["profile"] as? [String: Any],
              let bundles = profile["bundles"] as? [String],
              bundles.contains(Self.desktopHostPluginName) else {
            return "Profile manifest 缺少内置桥接 Bundle 记录"
        }
        guard let webServerSpec = dependencies["@deepseek-ai/dsh-host-webserver"] as? String,
              !webServerSpec.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Profile manifest 缺少 WebServer 依赖声明"
        }
        let oldURL = URL(fileURLWithPath: oldPath, isDirectory: true)
        let installedHostURL = profileDir
            .appendingPathComponent("node_modules", isDirectory: true)
            .appendingPathComponent(Self.desktopHostPluginName, isDirectory: true)
        guard FileManager.default.fileExists(atPath: installedHostURL.path),
              isPath(installedHostURL, inside: profileDir) else {
            return "已安装桥接路径缺失或越界"
        }
        guard let installedFingerprint = desktopHostBundleFingerprint(at: installedHostURL) else {
            return "已安装桥接 Bundle 指纹不可读"
        }
        if oldPath == sourcePath {
            if let currentFingerprint = desktopHostBundleFingerprint(
                at: URL(fileURLWithPath: sourceBundle, isDirectory: true)
            ), hasStaleBridgeOwnershipProof(
                profileDir: profileDir,
                packageRoot: packageRoot,
                sourceBundle: sourceBundle,
                currentSourceFingerprint: currentFingerprint
            ) {
                return nil
            }
            return "已安装桥接与当前内置桥接指纹不同（可能已损坏或被手动修改）"
        }
        // The manifest must pin the previous source inside an App bundle's
        // Resources tree; user directories never qualify, so this declaration
        // is itself evidence the tree was App-placed.
        guard isAppBundledBridgeSource(oldPath) else {
            return "旧桥接来源不在 App 包内"
        }
        if let oldFingerprint = desktopHostBundleFingerprint(at: oldURL) {
            // The previous source app is still readable, so the on-disk tree
            // must be exactly what that managed install produced.
            guard installedFingerprint == oldFingerprint else {
                return "已安装文件与旧桥接来源不一致（可能被手动修改过）"
            }
        }
        // The previous source app is gone or broken (deleted development
        // builds are routine). The App-bundle declaration plus the intact
        // manifest shape above pin App provenance; the caller replaces the
        // tree with the current bundle's bits and re-records the proof.
        return nil
    }

    /// The manifest file: spec must resolve inside an App bundle's Resources
    /// tree (e.g. `.../DSH.app/Contents/Resources/...`). User directories
    /// never qualify, so a matching stale install cannot be user-owned code.
    private func isAppBundledBridgeSource(_ path: String) -> Bool {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        guard let range = standardized.range(of: ".app/Contents/", options: .caseInsensitive) else {
            return false
        }
        return standardized[range.upperBound...].hasPrefix("Resources/")
    }

    /// Validate the persistent bridge ownership proof before any destructive
    /// operation. The proof binds the selected Profile, the exact bundled
    /// source, both direct dependency specifiers, and installed fingerprints.
    /// Missing or stale proof always fails closed; package names are never
    /// treated as ownership evidence.
    private func verifyDesktopHostOwnershipProof(
        profileDir: URL,
        packageRoot: [String: Any]?,
        operation: String = "清理 web Profile 桥接依赖"
    ) throws {
        let fileManager = FileManager.default
        let markerURL = profileDir.appendingPathComponent(Self.desktopHostOwnershipMarkerName)
        guard let markerData = try? Data(contentsOf: markerURL),
              let marker = try? JSONSerialization.jsonObject(with: markerData) as? [String: Any],
              marker["schema"] as? Int == 1,
              let recordedProfile = marker["profileDirectory"] as? String,
              recordedProfile == profileDir.standardizedFileURL.path,
              let sourcePath = marker["sourceBundle"] as? String,
              let sourceFingerprint = marker["sourceFingerprint"] as? String,
              let installedFingerprint = marker["installedFingerprint"] as? String,
              let recordedDependencies = marker["dependencies"] as? [String: String],
              recordedDependencies.count == 2,
              let recordedHostSpec = recordedDependencies[Self.desktopHostPluginName],
              let recordedWebServerSpec = recordedDependencies["@deepseek-ai/dsh-host-webserver"] else {
            throw desktopHostOwnershipError("缺少、损坏或不匹配的持久所有权证明", operation: operation)
        }

        guard let currentSourcePath = NodeRuntime.shared.resolveDesktopHostBundlePath(),
              URL(fileURLWithPath: sourcePath).standardizedFileURL.path
                == URL(fileURLWithPath: currentSourcePath).standardizedFileURL.path else {
            throw desktopHostOwnershipError("内置桥接来源已变化", operation: operation)
        }
        let sourceURL = URL(fileURLWithPath: sourcePath, isDirectory: true)
        guard desktopHostBundleFingerprint(at: sourceURL) == sourceFingerprint else {
            throw desktopHostOwnershipError("内置桥接来源指纹不匹配", operation: operation)
        }

        guard let root = packageRoot,
              let dependencies = root["dependencies"] as? [String: Any],
              let currentHostSpec = dependencies[Self.desktopHostPluginName] as? String,
              let currentWebServerSpec = dependencies["@deepseek-ai/dsh-host-webserver"] as? String else {
            throw desktopHostOwnershipError("Profile manifest 缺少可验证的桥接依赖", operation: operation)
        }
        guard currentHostSpec == recordedHostSpec,
              currentWebServerSpec == recordedWebServerSpec,
              normalizedFileDependencyPath(recordedHostSpec)
                == sourceURL.standardizedFileURL.path else {
            throw desktopHostOwnershipError("Profile manifest 中的桥接依赖归属不匹配", operation: operation)
        }

        guard let dsh = root["dsh"] as? [String: Any],
              let profile = dsh["profile"] as? [String: Any],
              let bundles = profile["bundles"] as? [String],
              bundles.contains(Self.desktopHostPluginName) else {
            throw desktopHostOwnershipError("Profile manifest 缺少内置桥接 Bundle 记录", operation: operation)
        }

        let installedHostURL = profileDir
            .appendingPathComponent("node_modules", isDirectory: true)
            .appendingPathComponent(Self.desktopHostPluginName, isDirectory: true)
        if fileManager.fileExists(atPath: installedHostURL.path) {
            guard isPath(installedHostURL, inside: profileDir),
                  let manifestURL = packageManifestURL(name: Self.desktopHostPluginName, profileDir: profileDir),
                  let data = try? Data(contentsOf: manifestURL),
                  let package = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  package["name"] as? String == Self.desktopHostPluginName,
                  desktopHostBundleFingerprint(at: installedHostURL) == installedFingerprint else {
                throw desktopHostOwnershipError("已安装桥接 Bundle 指纹或路径不匹配", operation: operation)
            }
        }

        let webServerName = "@deepseek-ai/dsh-host-webserver"
        let webServerURL = profileDir
            .appendingPathComponent("node_modules", isDirectory: true)
            .appendingPathComponent("@deepseek-ai", isDirectory: true)
            .appendingPathComponent("dsh-host-webserver", isDirectory: true)
        if fileManager.fileExists(atPath: webServerURL.path) {
            guard isPath(webServerURL, inside: profileDir),
                  let manifestURL = packageManifestURL(name: webServerName, profileDir: profileDir),
                  let data = try? Data(contentsOf: manifestURL),
                  let package = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  package["name"] as? String == webServerName,
                  manifestFingerprint(at: manifestURL)
                    == marker["webServerManifestFingerprint"] as? String else {
                throw desktopHostOwnershipError("已安装 WebServer 依赖指纹或路径不匹配", operation: operation)
            }
        }
    }

    /// Record ownership only after all bridge postconditions have passed.
    /// This marker is deliberately local to the selected Profile and is
    /// removed only after a verified cleanup succeeds.
    private func writeDesktopHostOwnershipProof(profileDir: URL, sourceBundle: String) throws {
        let packageURL = profileDir.appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: packageURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dependencies = root["dependencies"] as? [String: Any],
              let hostSpec = dependencies[Self.desktopHostPluginName] as? String,
              let webServerSpec = dependencies["@deepseek-ai/dsh-host-webserver"] as? String,
              let dsh = root["dsh"] as? [String: Any],
              let profile = dsh["profile"] as? [String: Any],
              let bundles = profile["bundles"] as? [String],
              bundles.contains(Self.desktopHostPluginName) else {
            throw desktopHostOwnershipError("安装后无法验证 Profile 桥接依赖", operation: "安装桌面桥接依赖")
        }

        let sourceURL = URL(fileURLWithPath: sourceBundle, isDirectory: true)
        guard let sourceFingerprint = desktopHostBundleFingerprint(at: sourceURL),
              normalizedFileDependencyPath(hostSpec) == sourceURL.standardizedFileURL.path else {
            throw desktopHostOwnershipError("安装后桥接来源指纹或依赖路径不匹配", operation: "安装桌面桥接依赖")
        }

        let installedHostURL = profileDir
            .appendingPathComponent("node_modules", isDirectory: true)
            .appendingPathComponent(Self.desktopHostPluginName, isDirectory: true)
        let webServerManifestURL = profileDir
            .appendingPathComponent("node_modules", isDirectory: true)
            .appendingPathComponent("@deepseek-ai", isDirectory: true)
            .appendingPathComponent("dsh-host-webserver", isDirectory: true)
            .appendingPathComponent("package.json")
        guard isPath(installedHostURL, inside: profileDir),
              let installedFingerprint = desktopHostBundleFingerprint(at: installedHostURL),
              installedFingerprint == sourceFingerprint,
              let webServerManifestFingerprint = manifestFingerprint(at: webServerManifestURL) else {
            throw desktopHostOwnershipError("安装后无法验证桥接依赖物化路径", operation: "安装桌面桥接依赖")
        }

        let proof: [String: Any] = [
            "schema": 1,
            "profileDirectory": profileDir.standardizedFileURL.path,
            "sourceBundle": sourceURL.standardizedFileURL.path,
            "sourceFingerprint": sourceFingerprint,
            "installedFingerprint": installedFingerprint,
            "webServerManifestFingerprint": webServerManifestFingerprint,
            "dependencies": [
                Self.desktopHostPluginName: hostSpec,
                "@deepseek-ai/dsh-host-webserver": webServerSpec
            ]
        ]
        let markerURL = profileDir.appendingPathComponent(Self.desktopHostOwnershipMarkerName)
        let markerData = try JSONSerialization.data(withJSONObject: proof, options: [.prettyPrinted, .sortedKeys])
        try markerData.write(to: markerURL, options: .atomic)
    }

    private func profileContainsBundle(_ name: String, profileDir: URL? = nil) -> Bool {
        let packageURL = (profileDir ?? Self.activeProfileDirectory).appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: packageURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dsh = root["dsh"] as? [String: Any],
              let profile = dsh["profile"] as? [String: Any],
              let bundles = profile["bundles"] as? [String] else {
            return false
        }
        return bundles.contains(name)
    }

    private func registryArguments(_ registry: String) -> [String] {
        ["--registry", registry]
    }
}
