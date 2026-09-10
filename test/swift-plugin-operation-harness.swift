import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
    }
}

private let fileManager = FileManager.default

private func testHome() -> URL {
    guard let raw = ProcessInfo.processInfo.environment["DSH_HOME"], !raw.isEmpty else {
        fputs("FAIL: DSH_HOME is required\n", stderr)
        exit(2)
    }
    return URL(fileURLWithPath: raw, isDirectory: true).standardizedFileURL
}

private func profileURL() -> URL {
    DshPluginManager.profileDirectory(for: .desktop)
}

private func operationStoreURL() -> URL {
    DshStateManager.appSupportDirectory.appendingPathComponent(
        "dsh-plugin-operation.json"
    )
}

private func snapshotDirectoryURL(
    _ reference: DshPluginOperationSnapshotReference
) -> URL {
    DshStateManager.appSupportDirectory
        .appendingPathComponent("dsh-plugin-operation-snapshots", isDirectory: true)
        .appendingPathComponent(reference.operationID, isDirectory: true)
        .appendingPathComponent(reference.snapshotID, isDirectory: true)
}

private func resetFixture() throws {
    // The caller supplies a fresh temporary DSH_HOME and app-support root.
    // Only paths below those explicit roots are touched here.
    try? fileManager.removeItem(at: profileURL())
    try? fileManager.removeItem(at: operationStoreURL())
    try? fileManager.removeItem(
        at: DshStateManager.appSupportDirectory.appendingPathComponent(
            "dsh-plugin-operation-snapshots", isDirectory: true
        )
    )
    try fileManager.createDirectory(at: profileURL(), withIntermediateDirectories: true)
    try Data(#"{"dependencies":{"plugin":"1.0.0","plugin-a":"1.0.0","plugin-b":"1.0.0"}}"#.utf8)
        .write(to: profileURL().appendingPathComponent("package.json"), options: .atomic)
    try Data("baseline".utf8)
        .write(to: profileURL().appendingPathComponent("marker"), options: .atomic)
    try Data("batch-a-baseline".utf8)
        .write(to: profileURL().appendingPathComponent("batch-a"), options: .atomic)
    try Data("batch-b-baseline".utf8)
        .write(to: profileURL().appendingPathComponent("batch-b"), options: .atomic)
}

private func writeOperationState(_ state: DshPluginOperationState) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    try fileManager.createDirectory(
        at: operationStoreURL().deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try encoder.encode(state).write(to: operationStoreURL(), options: .atomic)
}

private func readOperationState() throws -> DshPluginOperationState {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(
        DshPluginOperationState.self,
        from: Data(contentsOf: operationStoreURL())
    )
}

private func persistFixtureOperation(
    phase: DshPluginOperationPhase,
    mutationDigest: String? = nil,
    action: DshPluginOperationAction = .update
) async throws -> DshPluginOperationState {
    let operationID = UUID().uuidString
    let snapshot = try await DshPluginManager.shared.createPluginOperationSnapshot(
        operationID: operationID,
        profile: .desktop,
        profileDirectory: profileURL()
    )
    let state = DshPluginOperationState(
        operationID: operationID,
        profile: .desktop,
        targetPackage: action == .updateAll ? nil : "plugin",
        targetPackages: action == .updateAll ? ["plugin-a", "plugin-b"] : [],
        action: action,
        snapshot: snapshot,
        phase: phase,
        mutationDigest: mutationDigest
    )
    try writeOperationState(state)
    return state
}

private func marker(_ value: String) throws {
    try Data(value.utf8)
        .write(to: profileURL().appendingPathComponent("marker"), options: .atomic)
}

/// Write the persisted app state before anything touches
/// `DshStateManager.shared`, so the process starts from this fixture.
private func writeAppState(_ json: String) throws {
    let url = DshStateManager.appSupportDirectory.appendingPathComponent("dsh-state.json")
    try Data(json.utf8).write(to: url, options: .atomic)
}

/// Install a minimal Runtime tree that `DshVersionManager` recognises as an
/// installed version (manifest plus the declared bin entry).
private func installFakeRuntime(version: String) throws {
    let packageRoot = DshStateManager.versionsDirectory
        .appendingPathComponent(version, isDirectory: true)
        .appendingPathComponent("node_modules", isDirectory: true)
        .appendingPathComponent("@deepseek-ai", isDirectory: true)
        .appendingPathComponent("dsh", isDirectory: true)
    try fileManager.createDirectory(at: packageRoot, withIntermediateDirectories: true)
    let manifest = #"{"name":"@deepseek-ai/dsh","version":"\#(version)","bin":{"dsh":"bin.js"}}"#
    try Data(manifest.utf8)
        .write(to: packageRoot.appendingPathComponent("package.json"), options: .atomic)
    try Data("#!/usr/bin/env node\n".utf8)
        .write(to: packageRoot.appendingPathComponent("bin.js"), options: .atomic)
}

private func requireContents(_ expected: String, at url: URL, _ message: String) throws {
    let actual = try String(contentsOf: url, encoding: .utf8)
    require(actual == expected, message)
}

private func expectOperationError(
    _ expected: DshPluginOperationError,
    _ body: () async throws -> Void
) async {
    do {
        try await body()
        require(false, "expected error \(expected), operation succeeded")
    } catch let error as DshPluginOperationError {
        require(error == expected, "expected \(expected), got \(error)")
    } catch {
        require(false, "expected \(expected), got \(error)")
    }
}

private func waitForHook(_ counter: Counter, _ message: String) async throws {
    for _ in 0..<100 {
        if counter.value > 0 { return }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    require(false, message)
}

private func expectCancelled(_ task: Task<DshPluginOperationResult, Error>) async {
    do {
        _ = try await task.value
        require(false, "cancelled plugin operation unexpectedly succeeded")
    } catch is CancellationError {
        return
    } catch {
        require(false, "cancelled plugin operation returned (error)")
    }
}

private func setupPrepared() async throws {
    try resetFixture()
    let state = try await persistFixtureOperation(phase: .prepared)
    require(state.phase == .prepared, "prepared setup must persist prepared")
}

private func recoverPrepared() async throws {
    let state = try readOperationState()
    let coordinator = DshPluginOperationCoordinator(operationStoreURL: operationStoreURL())
    let result = try await coordinator.recoverPendingOperation()
    require(result?.operationID == state.operationID, "prepared recovery must resume the same operation")
    require(result?.phase == .prepared && result?.wasRestored == true, "prepared recovery result")
    require(coordinator.pendingOperation == nil, "prepared recovery must clear the record")
    require(!fileManager.fileExists(atPath: snapshotDirectoryURL(state.snapshot).path), "prepared recovery must remove snapshot")
    try requireContents("baseline", at: profileURL().appendingPathComponent("marker"), "prepared recovery must preserve baseline")
}

private func setupMutatingWithoutDigest() async throws {
    try resetFixture()
    let state = try await persistFixtureOperation(phase: .mutating)
    try marker("mutating-before-interruption")
    require(state.mutationDigest == nil, "mutating interruption fixture must omit digest")
}

private func recoverMutatingWithoutDigest() async throws {
    let coordinator = DshPluginOperationCoordinator(operationStoreURL: operationStoreURL())
    await expectOperationError(.operationInterruptedDuringMutation) {
        _ = try await coordinator.recoverPendingOperation()
    }
    require(coordinator.pendingOperation?.phase == .recoveryRequired,
            "missing mutation digest must require recovery")
    try requireContents(
        "mutating-before-interruption",
        at: profileURL().appendingPathComponent("marker"),
        "missing digest must not overwrite the current tree"
    )
}

private func recoverMutatingWithoutDigestAfterConflictResolution() async throws {
    // This models an explicit operator resolution between launches. Once the
    // Profile is back at the snapshot baseline, the retained owner record can
    // be cleaned up without guessing that an unowned tree belonged to P01.
    try marker("baseline")
    let coordinator = DshPluginOperationCoordinator(operationStoreURL: operationStoreURL())
    let result = try await coordinator.recoverPendingOperation()
    require(result?.wasRestored == true,
            "missing digest recovery must continue after the conflict is resolved")
    require(coordinator.pendingOperation == nil,
            "resolved missing-digest recovery must clear the record")
    try requireContents(
        "baseline",
        at: profileURL().appendingPathComponent("marker"),
        "resolved missing-digest recovery must preserve the baseline"
    )
}

private func setupAdoptInterrupted() async throws {
    try resetFixture()
    let state = try await persistFixtureOperation(phase: .recoveryRequired)
    try marker("adopted-tree")
    require(state.mutationDigest == nil, "adopt fixture must omit digest")
    require(state.phase == .recoveryRequired, "adopt fixture must persist recoveryRequired")
}

private func recoverAdoptVerified() async throws {
    let operationID = try readOperationState().operationID
    let coordinator = DshPluginOperationCoordinator(operationStoreURL: operationStoreURL())
    let result = try await coordinator.adoptInterruptedTransaction(
        operationID: operationID,
        hooks: DshPluginOperationHooks(
            mutate: { _ in },
            verify: { _ in }
        )
    )
    require(result.phase == .committed, "healthy adopted tree must commit")
    require(coordinator.pendingOperation?.phase == .committed, "committed adopt must remain durable")
    try requireContents(
        "adopted-tree",
        at: profileURL().appendingPathComponent("marker"),
        "verified adopt must keep the current tree"
    )
}

private func recoverAdoptUnhealthy() async throws {
    let operationID = try readOperationState().operationID
    let coordinator = DshPluginOperationCoordinator(operationStoreURL: operationStoreURL())
    let result = try await coordinator.adoptInterruptedTransaction(
        operationID: operationID,
        hooks: DshPluginOperationHooks(
            mutate: { _ in },
            verify: { _ in
                throw NSError(domain: "fixture", code: 92, userInfo: [
                    NSLocalizedDescriptionKey: "adopted tree failed health verification"
                ])
            }
        )
    )
    require(result.phase == .restoring && result.wasRestored == true, "unhealthy adopted tree must restore")
    require(coordinator.pendingOperation == nil, "adopt restore must clear the record")
    try requireContents(
        "baseline",
        at: profileURL().appendingPathComponent("marker"),
        "adopt restore must bring back the snapshot baseline"
    )
}

private func recoverAdoptRejectsCommitted() async throws {
    try resetFixture()
    let state = try await persistFixtureOperation(phase: .committed)
    let coordinator = DshPluginOperationCoordinator(operationStoreURL: operationStoreURL())
    await expectOperationError(.invalidTransition(state.phase, .verifying)) {
        _ = try await coordinator.adoptInterruptedTransaction(
            operationID: state.operationID,
            hooks: DshPluginOperationHooks(mutate: { _ in })
        )
    }
    require(coordinator.pendingOperation?.phase == .committed, "rejected adopt must leave the record untouched")
}

private func runAdoptGatingMatrix() throws {
    var interrupted = try interruptedFixtureState()
    let adoptable = DshPluginOperationCoordinator.adoptableInterruptedTransaction(from: interrupted)
    require(
        adoptable?.operationID == interrupted.operationID,
        "recoveryRequired record without digest on desktop must be adoptable"
    )
    interrupted = DshPluginOperationState(
        operationID: interrupted.operationID,
        profile: interrupted.profile,
        targetPackage: interrupted.targetPackage,
        targetPackages: interrupted.targetPackages,
        action: interrupted.action,
        snapshot: interrupted.snapshot,
        phase: .committed,
        mutationDigest: interrupted.mutationDigest,
        lastError: interrupted.lastError
    )
    require(
        DshPluginOperationCoordinator.adoptableInterruptedTransaction(from: interrupted) == nil,
        "committed record must never be adoptable"
    )
    print("plugin operation scenario adopt-gating-matrix passed")
}

private func interruptedFixtureState() throws -> DshPluginOperationState {
    let operationID = UUID().uuidString
    let snapshot = DshPluginOperationSnapshotReference(
        snapshotID: UUID().uuidString,
        operationID: operationID,
        profile: .desktop,
        profileDirectory: profileURL(),
        baselineDigest: "baseline",
        ownerID: DshPluginOperationSnapshotReference.owner,
        profileWasMissing: false
    )
    return DshPluginOperationState(
        operationID: operationID,
        profile: .desktop,
        targetPackage: "plugin",
        targetPackages: [],
        action: .install,
        snapshot: snapshot,
        phase: .recoveryRequired,
        mutationDigest: nil,
        lastError: "interrupted"
    )
}

private func setupVerifying() async throws {
    try resetFixture()
    let manager = DshPluginManager.shared
    let operationID = UUID().uuidString
    let snapshot = try await manager.createPluginOperationSnapshot(
        operationID: operationID,
        profile: .desktop,
        profileDirectory: profileURL()
    )
    try marker("mutated")
    let digest = try await manager.pluginProfileDigest(at: profileURL())
    let state = DshPluginOperationState(
        operationID: operationID,
        profile: .desktop,
        targetPackage: "plugin",
        action: .update,
        snapshot: snapshot,
        phase: .verifying,
        mutationDigest: digest
    )
    try writeOperationState(state)
}

private func recoverVerifyingCommit() async throws {
    let coordinator = DshPluginOperationCoordinator(operationStoreURL: operationStoreURL())
    let result = try await coordinator.recoverPendingOperation(
        hooks: DshPluginOperationHooks(
            mutate: { _ in },
            verify: { _ in }
        )
    )
    require(result?.phase == .committed, "verifying restart should commit after successful verification")
    require(coordinator.pendingOperation?.phase == .committed, "committed record must remain durable")
    try requireContents("mutated", at: profileURL().appendingPathComponent("marker"), "successful verifying recovery must keep mutation")
}

private func recoverVerifyingRestore() async throws {
    let coordinator = DshPluginOperationCoordinator(operationStoreURL: operationStoreURL())
    let result = try await coordinator.recoverPendingOperation(
        hooks: DshPluginOperationHooks(
            mutate: { _ in },
            verify: { _ in
                throw NSError(domain: "fixture", code: 91, userInfo: [
                    NSLocalizedDescriptionKey: "verification failed"
                ])
            }
        )
    )
    require(result?.phase == .restoring && result?.wasRestored == true, "failed verifying restart must restore")
    require(coordinator.pendingOperation == nil, "successful restore must clear verifying record")
    try requireContents("baseline", at: profileURL().appendingPathComponent("marker"), "failed verifying restart must restore baseline")
}

private func setupRestoredHealthFailure() async throws {
    try await setupVerifying()
    let coordinator = DshPluginOperationCoordinator(operationStoreURL: operationStoreURL())
    await expectOperationError(.recoveryRequired("restored health rejected")) {
        _ = try await coordinator.recoverPendingOperation(
            hooks: DshPluginOperationHooks(
                mutate: { _ in },
                verify: { _ in
                    throw NSError(domain: "fixture", code: 92, userInfo: [
                        NSLocalizedDescriptionKey: "verification failed"
                    ])
                },
                verifyRestored: { _ in
                    throw NSError(domain: "fixture", code: 93, userInfo: [
                        NSLocalizedDescriptionKey: "restored health rejected"
                    ])
                }
            )
        )
    }
    require(coordinator.pendingOperation?.phase == .recoveryRequired,
            "failed restored health must retain recoveryRequired")
    try requireContents(
        "baseline",
        at: profileURL().appendingPathComponent("marker"),
        "failed restored health must leave the baseline restored"
    )
}

private func recoverRestoredHealthFailure() async throws {
    let coordinator = DshPluginOperationCoordinator(operationStoreURL: operationStoreURL())
    let restoredChecks = Counter()
    let result = try await coordinator.recoverPendingOperation(
        hooks: DshPluginOperationHooks(
            mutate: { _ in },
            verifyRestored: { _ in restoredChecks.increment() }
        )
    )
    require(result?.wasRestored == true,
            "a second launch must retry restored health instead of reporting external modification")
    require(restoredChecks.value == 1,
            "a second launch must run the restored health hook once")
    require(coordinator.pendingOperation == nil,
            "successful restored health retry must clear the record")
    try requireContents(
        "baseline",
        at: profileURL().appendingPathComponent("marker"),
        "successful restored health retry must preserve the baseline"
    )
}

private func setupRestoring() async throws {
    try resetFixture()
    let manager = DshPluginManager.shared
    let operationID = UUID().uuidString
    let snapshot = try await manager.createPluginOperationSnapshot(
        operationID: operationID,
        profile: .desktop,
        profileDirectory: profileURL()
    )
    try marker("mutated-before-restoring-interruption")
    let digest = try await manager.pluginProfileDigest(at: profileURL())
    let state = DshPluginOperationState(
        operationID: operationID,
        profile: .desktop,
        targetPackage: "plugin",
        action: .update,
        snapshot: snapshot,
        phase: .restoring,
        mutationDigest: digest
    )
    try writeOperationState(state)
}

private func recoverRestoringIdempotently() async throws {
    let coordinator = DshPluginOperationCoordinator(operationStoreURL: operationStoreURL())
    let first = try await coordinator.recoverPendingOperation()
    require(first?.wasRestored == true, "restoring restart must continue restoration")
    try requireContents("baseline", at: profileURL().appendingPathComponent("marker"), "restoring restart must restore baseline")
    require(coordinator.pendingOperation == nil, "restoring restart must clear after completion")
    let second = try await coordinator.recoverPendingOperation()
    require(second == nil, "restoring recovery must be idempotent")
}

/// Simulate a force-quit in the P01 restore window after the live Profile was
/// moved aside (to the deterministic displaced path) but before the snapshot
/// copy completed. Recovery must resume the interrupted swap from the
/// app-owned snapshot instead of misreading the absent Profile as an external
/// modification, and must reclaim the displaced leftover it created.
private func setupResumingInterruptedRestore() async throws {
    try resetFixture()
    let manager = DshPluginManager.shared
    let operationID = UUID().uuidString
    let snapshot = try await manager.createPluginOperationSnapshot(
        operationID: operationID,
        profile: .desktop,
        profileDirectory: profileURL()
    )
    try marker("mutated-before-interrupted-restore")
    let mutationDigest = try await manager.pluginProfileDigest(at: profileURL())
    let state = DshPluginOperationState(
        operationID: operationID,
        profile: .desktop,
        targetPackage: "plugin",
        action: .update,
        snapshot: snapshot,
        phase: .restoring,
        mutationDigest: mutationDigest
    )
    try writeOperationState(state)
    let displaced = profileURL().deletingLastPathComponent()
        .appendingPathComponent(".dsh-plugin-restore-\(operationID)", isDirectory: true)
    try fileManager.moveItem(at: profileURL(), to: displaced)
    require(!fileManager.fileExists(atPath: profileURL().path),
            "interrupted restore fixture must leave the canonical Profile absent")
    require(fileManager.fileExists(atPath: displaced.path),
            "interrupted restore fixture must retain the displaced tree")
}

private func recoverResumingInterruptedRestore() async throws {
    let coordinator = DshPluginOperationCoordinator(operationStoreURL: operationStoreURL())
    let result = try await coordinator.recoverPendingOperation()
    require(result?.wasRestored == true,
            "an interrupted restore must resume instead of reporting external modification")
    try requireContents("baseline", at: profileURL().appendingPathComponent("marker"),
                        "resumed restore must put the baseline back")
    require(coordinator.pendingOperation == nil,
            "resumed restore must clear the durable record")
    let leftovers = (try? fileManager.contentsOfDirectory(
        atPath: profileURL().deletingLastPathComponent().path
    ))?.filter { $0.hasPrefix(".dsh-plugin-restore-") } ?? []
    require(leftovers.isEmpty,
            "resumed restore must reclaim the displaced tree it left behind")
    let second = try await coordinator.recoverPendingOperation()
    require(second == nil, "resumed recovery must be idempotent")
}

/// R1 regression: an interrupted user-initiated rollback persists
/// `.rollingBack` with `pending == nil`. `ensureSelection()` (reached from
/// `SettingsViewModel.loadFromState()` during startup) must not rewrite that
/// shape to `idle`: doing so would skip the Profile restore, let the retained
/// snapshot be deleted without ever being applied, and lock every plugin /
/// Runtime-update mutation behind a `previous` that nothing clears while idle.
private func verifyInterruptedRollbackSurvivesSelectionSync() async throws {
    try resetFixture()
    try installFakeRuntime(version: "1.0.0")
    let stateJSON = """
    {"appProfile":"desktop","selectedVersion":"1.0.0","runtimeState":{\
    "phase":"rollingBack","profile":"desktop",\
    "active":{"version":"1.0.1","registry":"https://registry.npmjs.org","installedAt":0},\
    "previous":{"version":"1.0.0","registry":"https://registry.npmjs.org","installedAt":0},\
    "transactionID":"tx-m2-rollback","webProfileSnapshotID":"snapshot-m2"}}
    """
    try writeAppState(stateJSON)
    let manager = DshStateManager.shared
    require(manager.current.runtimeState.phase == .rollingBack,
            "fixture must start in the interrupted-rollback phase")

    let resolved = DshVersionManager.shared.ensureSelection()
    require(resolved == "1.0.0", "selection must keep the rollback target")

    let after = manager.current.runtimeState
    require(after.phase == .rollingBack,
            "an interrupted rollback must not be rewritten to idle")
    require(after.previous?.version == "1.0.0",
            "an interrupted rollback must keep its previous Runtime")
    require(after.transactionID == "tx-m2-rollback",
            "an interrupted rollback must keep its transaction owner")
    require(after.webProfileSnapshotID == "snapshot-m2",
            "an interrupted rollback must keep its retained snapshot reference")
    require(!DshRuntimeMutationGate.allowsPluginMutation(manager.current),
            "the open rollback must still deny plugin mutations")
}

/// R3 regression: a resumed restore must be staged. A stale staging directory
/// from an earlier interrupted attempt is disposable and must not block or
/// corrupt the resumed swap.
private func setupRestoreWithStaleStaging() async throws {
    try resetFixture()
    let manager = DshPluginManager.shared
    let operationID = UUID().uuidString
    let snapshot = try await manager.createPluginOperationSnapshot(
        operationID: operationID,
        profile: .desktop,
        profileDirectory: profileURL()
    )
    try marker("mutated-before-interrupted-restore")
    let mutationDigest = try await manager.pluginProfileDigest(at: profileURL())
    let state = DshPluginOperationState(
        operationID: operationID,
        profile: .desktop,
        targetPackage: "plugin",
        action: .update,
        snapshot: snapshot,
        phase: .restoring,
        mutationDigest: mutationDigest
    )
    try writeOperationState(state)
    let parent = profileURL().deletingLastPathComponent()
    try fileManager.moveItem(
        at: profileURL(),
        to: parent.appendingPathComponent(".dsh-plugin-restore-\(operationID)", isDirectory: true)
    )
    let staging = parent.appendingPathComponent(
        ".dsh-plugin-restore-staging-\(operationID)",
        isDirectory: true
    )
    try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
    try Data("half-written".utf8)
        .write(to: staging.appendingPathComponent("marker"), options: .atomic)
}

private func recoverRestoreWithStaleStaging() async throws {
    let coordinator = DshPluginOperationCoordinator(operationStoreURL: operationStoreURL())
    let result = try await coordinator.recoverPendingOperation()
    require(result?.wasRestored == true, "a stale staging directory must not block the resume")
    try requireContents("baseline", at: profileURL().appendingPathComponent("marker"),
                        "resumed restore must install the verified baseline")
    let leftovers = (try? fileManager.contentsOfDirectory(
        atPath: profileURL().deletingLastPathComponent().path
    ))?.filter { $0.hasPrefix(".dsh-plugin-restore-") } ?? []
    require(leftovers.isEmpty,
            "a completed resume must leave no displaced or staging directory behind")
}

/// Round-4 (resume ordering): an interrupted attempt leaves the complete
/// pre-restore tree at the displaced path and a partial copy at the canonical
/// path. A resumed restore must not delete that leftover before the staged
/// replacement has been verified — it is the only complete copy. This fixture
/// makes the snapshot content incomplete so the resumed restore fails, and
/// requires both the leftover and the (unverified) canonical tree to survive.
private func verifyInterruptedRestoreKeepsLeftover() async throws {
    try resetFixture()
    let manager = DshPluginManager.shared
    let operationID = UUID().uuidString
    let snapshot = try await manager.createPluginOperationSnapshot(
        operationID: operationID,
        profile: .desktop,
        profileDirectory: profileURL()
    )
    let parent = profileURL().deletingLastPathComponent()
    let displaced = parent.appendingPathComponent(".dsh-plugin-restore-\(operationID)", isDirectory: true)
    try fileManager.moveItem(at: profileURL(), to: displaced)
    try fileManager.createDirectory(at: profileURL(), withIntermediateDirectories: true)
    try marker("partial-copy")
    try fileManager.removeItem(
        at: snapshotDirectoryURL(snapshot).appendingPathComponent("profile", isDirectory: true)
    )
    var restoreError: Error?
    do {
        try await manager.restorePluginOperationSnapshot(snapshot, expectedCurrentDigest: nil)
    } catch {
        restoreError = error
    }
    require(restoreError != nil, "a plugin snapshot without content must fail the restore")
    try requireContents("baseline", at: displaced.appendingPathComponent("marker"),
                        "the complete leftover must survive a failed resumed restore")
    try requireContents("partial-copy", at: profileURL().appendingPathComponent("marker"),
                        "the canonical tree must not be replaced by a failed restore")
}

/// R3 regression: a restore that already failed once (recoveryRequired, but a
/// mutation digest exists) with the canonical Profile absent must resume
/// instead of dead-ending as `externalModification`. This is what a full disk
/// or a force-quit during the resumed copy leaves behind.
private func setupRecoveryRequiredMissingProfile() async throws {
    try resetFixture()
    let manager = DshPluginManager.shared
    let operationID = UUID().uuidString
    let snapshot = try await manager.createPluginOperationSnapshot(
        operationID: operationID,
        profile: .desktop,
        profileDirectory: profileURL()
    )
    try marker("mutated-before-interrupted-restore")
    let mutationDigest = try await manager.pluginProfileDigest(at: profileURL())
    let state = DshPluginOperationState(
        operationID: operationID,
        profile: .desktop,
        targetPackage: "plugin",
        action: .update,
        snapshot: snapshot,
        phase: .recoveryRequired,
        mutationDigest: mutationDigest
    )
    try writeOperationState(state)
    try fileManager.moveItem(
        at: profileURL(),
        to: profileURL().deletingLastPathComponent()
            .appendingPathComponent(".dsh-plugin-restore-\(operationID)", isDirectory: true)
    )
}

private func recoverRecoveryRequiredMissingProfile() async throws {
    let coordinator = DshPluginOperationCoordinator(operationStoreURL: operationStoreURL())
    let result = try await coordinator.recoverPendingOperation()
    require(result?.wasRestored == true,
            "an absent Profile with a mutation digest must resume, not report external modification")
    try requireContents("baseline", at: profileURL().appendingPathComponent("marker"),
                        "resumed restore must put the baseline back")
    require(coordinator.pendingOperation == nil, "resumed recovery must clear the record")
}

/// R2 regression: the startup sweep must actually see the dot-prefixed
/// leftovers it targets, and must never select a directory whose name is not
/// exactly app-generated (fixed prefix + UUID).
private func verifyStagingSweep() async throws {
    try resetFixture()
    let profilesRoot = DshLaunchContext.defaultDshHome
        .appendingPathComponent("profiles", isDirectory: true)
    let desktop = DshLaunchContext.profileDirectory(for: .desktop)
    let nodeModules = desktop.appendingPathComponent("node_modules", isDirectory: true)
    try fileManager.createDirectory(at: nodeModules, withIntermediateDirectories: true)

    let migration = UUID().uuidString
    let displaced = UUID().uuidString
    let staging = UUID().uuidString
    let bridgeStaging = UUID().uuidString
    let bridgePrevious = UUID().uuidString
    let leftovers = [
        profilesRoot.appendingPathComponent(".swift-desktop-migration-\(migration)", isDirectory: true),
        profilesRoot.appendingPathComponent(".dsh-plugin-restore-\(displaced)", isDirectory: true),
        profilesRoot.appendingPathComponent(".dsh-plugin-restore-staging-\(staging)", isDirectory: true),
        desktop.appendingPathComponent(".dsh-desktop-host-staging-\(bridgeStaging)", isDirectory: true),
        nodeModules.appendingPathComponent(".dsh-desktop-host-previous-\(bridgePrevious)", isDirectory: true),
    ]
    for url in leftovers {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }
    // Decoys: same prefixes but not app-generated names, plus live entries.
    let decoyPrefixes = [
        profilesRoot.appendingPathComponent(".swift-desktop-migration-notes", isDirectory: true),
        profilesRoot.appendingPathComponent(".dsh-plugin-restore-manual-backup", isDirectory: true),
        desktop.appendingPathComponent(".dsh-desktop-host-staging-user-copy", isDirectory: true),
    ]
    for url in decoyPrefixes {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }
    let livePackage = nodeModules.appendingPathComponent("real-plugin", isDirectory: true)
    try fileManager.createDirectory(at: livePackage, withIntermediateDirectories: true)

    let removed = await DshPluginManager.shared.cleanupOrphanedStagingDirectories()
    require(Set(removed) == Set([
        ".swift-desktop-migration-\(migration)",
        ".dsh-plugin-restore-\(displaced)",
        ".dsh-plugin-restore-staging-\(staging)",
        ".dsh-desktop-host-staging-\(bridgeStaging)",
        ".dsh-desktop-host-previous-\(bridgePrevious)",
    ]), "the sweep must remove every app-generated leftover, got \(removed.sorted())")
    for url in leftovers {
        require(!fileManager.fileExists(atPath: url.path),
                "leftover \(url.lastPathComponent) must be removed")
    }
    for url in decoyPrefixes {
        require(fileManager.fileExists(atPath: url.path),
                "a directory that is not app-generated must be kept: \(url.lastPathComponent)")
    }
    require(fileManager.fileExists(atPath: livePackage.path),
            "live profile content must never be touched")
}

/// T2 regression: `ensureSelection` runs from `SettingsViewModel.loadFromState`
/// during startup, before `recoverPendingRuntimeUpdate`. It must never settle a
/// Runtime transaction that still owns usable recovery evidence (a pending
/// candidate or an installed previous Runtime) — doing so would clear the
/// previous Runtime, the transaction owner and the retained Profile snapshot
/// before the recovery planner could roll back.
private func verifySelectionPreservesRecoverableTransaction() async throws {
    try resetFixture()
    try installFakeRuntime(version: "1.0.0")
    let stateJSON = """
    {"appProfile":"desktop","selectedVersion":"2.0.0","runtimeState":{\
    "phase":"verifying","profile":"desktop",\
    "active":{"version":"2.0.0","registry":"https://registry.npmjs.org","installedAt":0},\
    "previous":{"version":"1.0.0","registry":"https://registry.npmjs.org","installedAt":0},\
    "pending":{"version":"2.0.0","registry":"https://registry.npmjs.org","installedAt":0},\
    "transactionID":"tx-verifying","webProfileSnapshotID":"snapshot-verifying"}}
    """
    try writeAppState(stateJSON)
    let manager = DshStateManager.shared
    require(manager.current.runtimeState.phase == .verifying, "fixture must start verifying")

    let resolved = DshVersionManager.shared.ensureSelection()
    require(resolved == "2.0.0", "the durable candidate selection must be reported unchanged")

    let after = manager.current.runtimeState
    require(after.phase == .verifying, "an open transaction must not be reset to idle")
    require(after.pending?.version == "2.0.0", "the pending candidate must survive selection repair")
    require(after.previous?.version == "1.0.0", "the rollback target must survive selection repair")
    require(after.transactionID == "tx-verifying", "the transaction owner must survive selection repair")
    require(after.webProfileSnapshotID == "snapshot-verifying",
            "the retained Profile snapshot must survive selection repair")

    // The recovery planner must still be able to roll this transaction back.
    guard let previous = after.previous, let pending = after.pending else {
        require(false, "preserved transaction must keep previous and pending")
        return
    }
    let plan = DshRuntimeRecoveryPlanner.plan(
        state: manager.current,
        installedVersions: Set(DshVersionManager.shared.listInstalledVersions())
    )
    require(plan == .rollback(active: previous, candidate: pending),
            "the planner must still roll the preserved transaction back, got \(String(describing: plan))")
}

/// T2 positive control: a transaction whose recovery evidence is already gone
/// may still be settled, so the mutation gates cannot stay locked forever.
private func verifySelectionSettlesUnrecoverableTransaction() async throws {
    try resetFixture()
    let stateJSON = """
    {"appProfile":"desktop","selectedVersion":"9.9.9","runtimeState":{\
    "phase":"idle","profile":"desktop",\
    "previous":{"version":"8.8.8","registry":"https://registry.npmjs.org","installedAt":0},\
    "transactionID":"tx-abandoned"}}
    """
    try writeAppState(stateJSON)
    let manager = DshStateManager.shared

    _ = DshVersionManager.shared.ensureSelection()
    let after = manager.current.runtimeState
    require(after.phase == .idle, "an unrecoverable residue must settle to idle")
    require(after.previous == nil, "the unusable previous Runtime must be cleared")
    require(after.transactionID == nil, "the stale transaction owner must be cleared")
    require(DshRuntimeMutationGate.allowsPluginMutation(manager.current),
            "settling an unrecoverable residue must reopen plugin mutations")
}

/// T6 regression: the canonical Profile path must be rejected when it is a
/// dangling symlink — `fileExists` is false for it, so without an explicit
/// lstat check an operation is accepted as "Profile absent" and only fails
/// after a durable record exists.
private func verifyDanglingProfileSymlinkGuards() async throws {
    try resetFixture()
    let linkPath = profileURL().path
    try fileManager.removeItem(at: profileURL())
    try fileManager.createSymbolicLink(
        atPath: linkPath,
        withDestinationPath: "/tmp/dsh-missing-profile-target"
    )
    require(!fileManager.fileExists(atPath: linkPath), "fixture must be a dangling symlink")

    do {
        _ = try await DshPluginManager.shared.createPluginOperationSnapshot(
            operationID: UUID().uuidString,
            profile: .desktop,
            profileDirectory: profileURL()
        )
        require(false, "snapshot creation must reject a dangling symlink Profile")
    } catch DshPluginOperationError.unsafeProfileDirectory {
        // expected
    }

    let coordinator = DshPluginOperationCoordinator(operationStoreURL: operationStoreURL())
    do {
        _ = try await coordinator.perform(
            DshPluginOperationRequest(
                action: .update,
                profile: .desktop,
                profileDirectory: profileURL(),
                targetPackage: "plugin"
            ),
            hooks: DshPluginOperationHooks(
                prepareForMutation: {},
                mutate: { _ in },
                verify: { _ in }
            )
        )
        require(false, "a plugin request must reject a dangling symlink Profile")
    } catch DshPluginOperationError.unsafeProfileDirectory {
        // expected
    }
    require(coordinator.pendingOperation == nil,
            "a rejected request must not leave a durable operation record")
}

/// T6 regression for the user-consented adopt path.
private func setupDanglingProfileSymlinkAdopt() async throws {
    try await setupAdoptInterrupted()
    let linkPath = profileURL().path
    try fileManager.removeItem(at: profileURL())
    try fileManager.createSymbolicLink(
        atPath: linkPath,
        withDestinationPath: "/tmp/dsh-missing-profile-target"
    )
}

private func recoverDanglingProfileSymlinkAdopt() async throws {
    let operationID = try readOperationState().operationID
    let coordinator = DshPluginOperationCoordinator(operationStoreURL: operationStoreURL())
    do {
        _ = try await coordinator.adoptInterruptedTransaction(
            operationID: operationID,
            hooks: DshPluginOperationHooks(
                mutate: { _ in },
                verify: { _ in }
            )
        )
        require(false, "adopt must reject a dangling symlink Profile")
    } catch DshPluginOperationError.unsafeProfileDirectory {
        // expected
    }
}

/// Sweep characterization + hardening guard (round-3 T5): the orphan sweeps
/// enumerate with `FileManager.contentsOfDirectory(at:...)`, which refuses a
/// symlinked directory (only the `atPath:` variant follows links, and the
/// removals apply to link entries themselves), so a symlinked snapshot root
/// must never lead to a deletion outside the app-owned tree. The scenario also
/// pins the positive control: a genuine orphan is still removed.
private func verifySnapshotSweepSymlinkGuard() async throws {
    try resetFixture()
    let manager = DshPluginManager.shared
    let appSupport = DshStateManager.appSupportDirectory
    let webRoot = appSupport.appendingPathComponent("dsh-runtime-profile-snapshots", isDirectory: true)
    let pluginRoot = appSupport.appendingPathComponent(
        "dsh-plugin-operation-snapshots",
        isDirectory: true
    )
    let outside = appSupport.appendingPathComponent("outside-root", isDirectory: true)

    // Positive control: a genuine orphan is still removed.
    let orphan = try await manager.createPluginOperationSnapshot(
        operationID: UUID().uuidString,
        profile: .desktop,
        profileDirectory: profileURL()
    )
    let orphanURL = snapshotDirectoryURL(orphan)
    require(fileManager.fileExists(atPath: orphanURL.path), "orphan fixture must exist")
    let removedOrphan = await manager.cleanupOrphanedPluginOperationSnapshots(keeping: nil)
    require(removedOrphan.contains("\(orphan.operationID)/\(orphan.snapshotID)"),
            "the sweep must still remove a genuine orphan, got \(removedOrphan)")
    require(!fileManager.fileExists(atPath: orphanURL.path), "the orphan must be gone")

    // Guard: symlinked roots must be skipped entirely.
    let externalSnapshot = UUID().uuidString
    let externalDir = outside.appendingPathComponent(externalSnapshot, isDirectory: true)
    try fileManager.createDirectory(at: externalDir, withIntermediateDirectories: true)
    try? fileManager.removeItem(at: webRoot)
    try? fileManager.removeItem(at: pluginRoot)
    try fileManager.createSymbolicLink(at: webRoot, withDestinationURL: outside)
    try fileManager.createSymbolicLink(at: pluginRoot, withDestinationURL: outside)

    let removedWeb = await manager.cleanupOrphanedWebProfileSnapshots(keeping: nil)
    require(removedWeb.isEmpty, "a symlinked web snapshot root must not be swept, got \(removedWeb)")
    let removedPlugin = await manager.cleanupOrphanedPluginOperationSnapshots(keeping: nil)
    require(removedPlugin.isEmpty, "a symlinked P01 snapshot root must not be swept, got \(removedPlugin)")
    require(fileManager.fileExists(atPath: externalDir.path),
            "a directory outside the app-owned root must never be deleted")
}

/// Simulate the narrow force-quit window after restoration and snapshot
/// deletion but before the durable operation record is removed. Recovery must
/// use the baseline digest and the persisted owner reference to finish
/// cleanup, instead of attempting a second restore or getting stuck forever.
private func setupRestoringAfterSnapshotDeletion() async throws {
    try resetFixture()
    let manager = DshPluginManager.shared
    let operationID = UUID().uuidString
    let snapshot = try await manager.createPluginOperationSnapshot(
        operationID: operationID,
        profile: .desktop,
        profileDirectory: profileURL()
    )
    try marker("mutated-before-cleanup-interruption")
    let mutationDigest = try await manager.pluginProfileDigest(at: profileURL())
    let state = DshPluginOperationState(
        operationID: operationID,
        profile: .desktop,
        targetPackage: "plugin",
        action: .update,
        snapshot: snapshot,
        phase: .restoring,
        mutationDigest: mutationDigest
    )
    try writeOperationState(state)
    try await manager.restorePluginOperationSnapshot(
        snapshot,
        expectedCurrentDigest: mutationDigest
    )
    try await manager.deletePluginOperationSnapshot(snapshot)
    require(fileManager.fileExists(atPath: operationStoreURL().path),
            "cleanup interruption fixture must retain the operation record")
    require(!fileManager.fileExists(atPath: snapshotDirectoryURL(snapshot).path),
            "cleanup interruption fixture must remove the snapshot")
}

private func recoverRestoringAfterSnapshotDeletion() async throws {
    let coordinator = DshPluginOperationCoordinator(operationStoreURL: operationStoreURL())
    guard case .loaded(let state) = coordinator.persistedStatus else {
        require(false, "cleanup interruption must expose a loaded persisted status")
        return
    }
    let result = try await coordinator.recoverPendingOperation()
    require(result?.operationID == state.operationID,
            "cleanup recovery must resume the same operation")
    require(result?.wasRestored == true,
            "cleanup recovery must report the already-restored baseline")
    require(coordinator.persistedStatus == .absent,
            "cleanup recovery must clear the durable record")
    try requireContents("baseline", at: profileURL().appendingPathComponent("marker"),
                        "cleanup recovery must keep the restored baseline")
    let second = try await coordinator.recoverPendingOperation()
    require(second == nil, "cleanup recovery must remain idempotent")
}

private func runCommittedRetention() async throws {
    try resetFixture()
    let coordinator = DshPluginOperationCoordinator(operationStoreURL: operationStoreURL())
    let request = DshPluginOperationRequest(
        action: .update,
        profile: .desktop,
        profileDirectory: profileURL(),
        targetPackage: "plugin"
    )
    let result = try await coordinator.perform(
        request,
        hooks: DshPluginOperationHooks(
            mutate: { request in
                try Data("committed".utf8).write(
                    to: request.profileDirectory.appendingPathComponent("marker"),
                    options: .atomic
                )
            }
        )
    )
    require(result.phase == .committed, "successful operation must commit")
    guard let pending = coordinator.pendingOperation else {
        require(false, "committed record must remain until health confirmation")
        return
    }
    require(pending.phase == .committed, "committed record must remain until health confirmation")
    require(coordinator.persistedStatus == .loaded(pending),
            "committed operation must expose an explicit loaded status")
    require(fileManager.fileExists(atPath: operationStoreURL().path), "committed record must be durable")
    try await coordinator.finalizeCommittedOperation(operationID: result.operationID)
    require(coordinator.pendingOperation == nil, "finalize must clear committed record")
    require(coordinator.persistedStatus == .absent, "finalize must expose an absent status")
    require(!fileManager.fileExists(atPath: operationStoreURL().path), "finalize must remove durable record")
}

private func runCancelledBeforeRecord() async throws {
    try resetFixture()
    let coordinator = DshPluginOperationCoordinator(operationStoreURL: operationStoreURL())
    let entered = Counter()
    let request = DshPluginOperationRequest(
        action: .update,
        profile: .desktop,
        profileDirectory: profileURL(),
        targetPackage: "plugin"
    )
    let task = Task {
        try await coordinator.perform(
            request,
            hooks: DshPluginOperationHooks(
                prepareForMutation: {
                    entered.increment()
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                },
                mutate: { _ in }
            )
        )
    }
    try await waitForHook(entered, "prepare hook did not start")
    task.cancel()
    await expectCancelled(task)
    require(coordinator.pendingOperation == nil, "pre-record cancellation must not leave an operation")
    require(!coordinator.hasPersistedOperationRecord, "pre-record cancellation must not persist an owner record")
    let snapshotRoot = DshStateManager.appSupportDirectory
        .appendingPathComponent("dsh-plugin-operation-snapshots", isDirectory: true)
    let entries = try? fileManager.contentsOfDirectory(atPath: snapshotRoot.path)
    require(entries?.isEmpty ?? true, "pre-record cancellation must not leave snapshot directories")
}

private func runCancelledDuringMutation(restoreFails: Bool = false) async throws {
    try resetFixture()
    let coordinator = DshPluginOperationCoordinator(operationStoreURL: operationStoreURL())
    let entered = Counter()
    let restoredChecks = Counter()
    let request = DshPluginOperationRequest(
        action: .update,
        profile: .desktop,
        profileDirectory: profileURL(),
        targetPackage: "plugin"
    )
    let task = Task {
        try await coordinator.perform(
            request,
            hooks: DshPluginOperationHooks(
                mutate: { request in
                    entered.increment()
                    try Data("mutated-before-cancel".utf8).write(
                        to: request.profileDirectory.appendingPathComponent("marker"),
                        options: .atomic
                    )
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                },
                verifyRestored: { _ in
                    restoredChecks.increment()
                    if restoreFails {
                        throw NSError(domain: "fixture", code: 94, userInfo: [
                            NSLocalizedDescriptionKey: "restored health rejected"
                        ])
                    }
                }
            )
        )
    }
    try await waitForHook(entered, "mutation hook did not start")
    task.cancel()
    if restoreFails {
        do {
            _ = try await task.value
            require(false, "cancellation with failed restoration unexpectedly succeeded")
        } catch let error as DshPluginOperationError {
            guard case .recoveryRequired = error else {
                require(false, "failed restoration must report recoveryRequired, got (error)")
                return
            }
        } catch {
            require(false, "failed restoration returned unexpected error (error)")
        }
        require(coordinator.pendingOperation?.phase == .recoveryRequired,
                "failed cancellation recovery must retain recoveryRequired")
        require(restoredChecks.value == 1, "failed cancellation recovery must run restored health once")
        try requireContents("baseline", at: profileURL().appendingPathComponent("marker"),
                            "failed cancellation recovery must still restore the baseline")
    } else {
        await expectCancelled(task)
        require(coordinator.pendingOperation == nil,
                "mutation cancellation with successful recovery must clear the record")
        require(restoredChecks.value == 1,
                "mutation cancellation must re-check restored health")
        try requireContents("baseline", at: profileURL().appendingPathComponent("marker"),
                            "mutation cancellation must restore the baseline")
    }
}

private func runCancelledDuringVerify() async throws {
    try resetFixture()
    let coordinator = DshPluginOperationCoordinator(operationStoreURL: operationStoreURL())
    let entered = Counter()
    let restoredChecks = Counter()
    let request = DshPluginOperationRequest(
        action: .update,
        profile: .desktop,
        profileDirectory: profileURL(),
        targetPackage: "plugin"
    )
    let task = Task {
        try await coordinator.perform(
            request,
            hooks: DshPluginOperationHooks(
                mutate: { request in
                    try Data("mutated-before-verify-cancel".utf8).write(
                        to: request.profileDirectory.appendingPathComponent("marker"),
                        options: .atomic
                    )
                },
                verify: { _ in
                    entered.increment()
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                },
                verifyRestored: { _ in restoredChecks.increment() }
            )
        )
    }
    try await waitForHook(entered, "verify hook did not start")
    task.cancel()
    await expectCancelled(task)
    require(coordinator.pendingOperation == nil,
            "verify cancellation with successful recovery must clear the record")
    require(restoredChecks.value == 1, "verify cancellation must re-check restored health")
    try requireContents("baseline", at: profileURL().appendingPathComponent("marker"),
                        "verify cancellation must restore the baseline")
}

private func runSnapshotCapacityContract() throws {
    let required = Int64(4 * 1024 * 1024)
    let safety = DshPluginManager.pluginSnapshotSafetyBytes
    do {
        try DshPluginManager.validatePluginSnapshotCapacity(
            requiredBytes: required,
            availableBytes: safety + required - 1
        )
        require(false, "insufficient snapshot capacity unexpectedly passed")
    } catch let error as DshPluginOperationError {
        guard case .snapshotCapacityInsufficient(
            let requiredBytes,
            let availableBytes
        ) = error else {
            require(false, "insufficient snapshot capacity returned (error)")
            return
        }
        require(requiredBytes == safety + required, "capacity error must report required bytes including safety")
        require(availableBytes == safety + required - 1, "capacity error must report available bytes")
    }
    try DshPluginManager.validatePluginSnapshotCapacity(
        requiredBytes: required,
        availableBytes: safety + required
    )
}

private func runInstallDowngradeGate() throws {
    // Exact pins need no network: the gate must decide purely.
    let splitLatest = DshPluginOperationInputValidation.splitInstallSpecifier("@deepseek-ai/dsh-subagent-codex@latest")
    require(splitLatest?.name == "@deepseek-ai/dsh-subagent-codex", "scoped spec must split the name")
    require(splitLatest?.pinned == "latest", "scoped spec must split the tag")
    let splitExact = DshPluginOperationInputValidation.splitInstallSpecifier("dsh-codex-subscription@0.1.2")
    require(splitExact?.name == "dsh-codex-subscription", "bare spec must split the name")
    require(splitExact?.pinned == "0.1.2", "bare spec must split the version")
    let splitBare = DshPluginOperationInputValidation.splitInstallSpecifier("@deepseek-ai/dsh-subagent-codex")
    require(splitBare?.name == "@deepseek-ai/dsh-subagent-codex", "bare scoped spec keeps the name")
    require(splitBare?.pinned == nil, "bare spec has no pinned value")
    require(DshPluginOperationInputValidation.splitInstallSpecifier("file:/tmp/x") == nil, "local specs carry no version")
    require(DshPluginOperationInputValidation.splitInstallSpecifier("--global") == nil, "option-looking specs are rejected")
    require(DshPluginOperationInputValidation.splitInstallSpecifier("@scope/only@") == nil, "empty pinned value is rejected")

    // The user's case: latest (0.0.1-rc.1) over installed 0.1.2-alpha.2.
    require(DshPluginOperationInputValidation.isInstallDowngrade(installed: "0.1.2-alpha.2", candidate: "0.0.1-rc.1") == true,
            "older candidate over newer install is a downgrade")
    require(DshPluginOperationInputValidation.isInstallDowngrade(installed: "0.1.2-alpha.2", candidate: "0.1.2-alpha.2") == false,
            "same version is not a downgrade")
    require(DshPluginOperationInputValidation.isInstallDowngrade(installed: "0.1.2-alpha.2", candidate: "0.1.3") == false,
            "newer candidate is not a downgrade")
    require(DshPluginOperationInputValidation.isInstallDowngrade(installed: "1.0.0", candidate: "latest") == nil,
            "unparsable candidate fails open")
    require(DshPluginOperationInputValidation.isInstallDowngrade(installed: "^1.0.0", candidate: "1.0.1") == nil,
            "unparsable installed fails open")
    print("plugin operation scenario install-downgrade-gate passed")
}

private func runOwnedSnapshotDeleteGuard() async throws {
    try resetFixture()
    let manager = DshPluginManager.shared
    let operationID = UUID().uuidString
    let snapshot = try await manager.createPluginOperationSnapshot(
        operationID: operationID,
        profile: .desktop,
        profileDirectory: profileURL()
    )
    let foreign = DshPluginOperationSnapshotReference(
        snapshotID: snapshot.snapshotID,
        operationID: snapshot.operationID,
        profile: snapshot.profile,
        profileDirectory: profileURL(),
        baselineDigest: snapshot.baselineDigest,
        createdAt: snapshot.createdAt,
        ownerID: "foreign-owner",
        profileWasMissing: snapshot.profileWasMissing
    )
    await expectOperationError(.desktopProfileRequired) {
        try await manager.deletePluginOperationSnapshot(foreign)
    }
    require(fileManager.fileExists(atPath: snapshotDirectoryURL(snapshot).path),
            "foreign delete request must leave the owned snapshot intact")
    try await manager.deletePluginOperationSnapshot(snapshot)
    require(!fileManager.fileExists(atPath: snapshotDirectoryURL(snapshot).path),
            "matching owner delete request must remove exactly its snapshot")
}

private func runBatchFailure() async throws {
    try resetFixture()
    let coordinator = DshPluginOperationCoordinator(operationStoreURL: operationStoreURL())
    let restoredChecks = Counter()
    let request = DshPluginOperationRequest(
        action: .updateAll,
        profile: .desktop,
        profileDirectory: profileURL(),
        targetPackages: ["plugin-a", "plugin-b"]
    )
    var operationError: Error?
    do {
        _ = try await coordinator.perform(
            request,
            hooks: DshPluginOperationHooks(
                mutate: { request in
                    try Data("batch-a-mutated".utf8).write(
                        to: request.profileDirectory.appendingPathComponent("batch-a"),
                        options: .atomic
                    )
                    try Data("batch-b-mutated".utf8).write(
                        to: request.profileDirectory.appendingPathComponent("batch-b"),
                        options: .atomic
                    )
                    try Data("partial-package-update".utf8).write(
                        to: request.profileDirectory.appendingPathComponent("package.json"),
                        options: .atomic
                    )
                    throw NSError(domain: "fixture", code: 73, userInfo: [
                        NSLocalizedDescriptionKey: "batch command failed halfway"
                    ])
                },
                verifyRestored: { _ in restoredChecks.value += 1 }
            )
        )
    } catch {
        operationError = error
    }
    require(operationError != nil, "batch mutation failure must throw")
    require(restoredChecks.value == 1, "batch failure must re-check restored health")
    require(coordinator.pendingOperation == nil, "batch rollback must clear record")
    try requireContents("baseline", at: profileURL().appendingPathComponent("marker"), "batch rollback must preserve marker")
    try requireContents("batch-a-baseline", at: profileURL().appendingPathComponent("batch-a"), "batch rollback must restore first package")
    try requireContents("batch-b-baseline", at: profileURL().appendingPathComponent("batch-b"), "batch rollback must restore second package")
    let restoredManifest = try String(contentsOf: profileURL().appendingPathComponent("package.json"), encoding: .utf8)
    require(restoredManifest.contains("plugin-a"), "batch rollback must restore package manifest")
}

private func runCorruptRecord() async throws {
    try resetFixture()
    try Data("{ this is not a plugin operation record".utf8)
        .write(to: operationStoreURL(), options: .atomic)
    let coordinator = DshPluginOperationCoordinator(operationStoreURL: operationStoreURL())
    require(coordinator.persistedStatus.isCorrupt,
            "malformed operation record must expose corrupt persisted status")
    let preparationChecks = Counter()
    let request = DshPluginOperationRequest(
        action: .update,
        profile: .desktop,
        profileDirectory: profileURL(),
        targetPackage: "plugin"
    )
    await expectOperationError(.recoveryRequired("插件事务记录损坏")) {
        _ = try await coordinator.perform(
            request,
            hooks: DshPluginOperationHooks(
                prepareForMutation: { preparationChecks.value += 1 },
                mutate: { _ in }
            )
        )
    }
    require(preparationChecks.value == 0, "corrupt record must fail closed before preparation")
    await expectOperationError(.recoveryRequired("插件事务记录损坏")) {
        _ = try await coordinator.recoverPendingOperation()
    }
    require(fileManager.fileExists(atPath: operationStoreURL().path), "corrupt record must remain for explicit recovery")
}

private func runStructurallyInvalidRecord() async throws {
    try resetFixture()
    _ = try await persistFixtureOperation(phase: .restoring)
    var object = try JSONSerialization.jsonObject(
        with: Data(contentsOf: operationStoreURL())
    ) as! [String: Any]
    object["operationID"] = UUID().uuidString
    try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        .write(to: operationStoreURL(), options: .atomic)

    let coordinator = DshPluginOperationCoordinator(operationStoreURL: operationStoreURL())
    require(coordinator.persistedStatus == .corrupt("插件事务记录损坏"),
            "inconsistent operation IDs must be classified as corrupt")
    await expectOperationError(.recoveryRequired("插件事务记录损坏")) {
        _ = try await coordinator.recoverPendingOperation()
    }
    require(fileManager.fileExists(atPath: operationStoreURL().path),
            "structurally corrupt operation record must remain for explicit recovery")
}

private func setupRestorationGuard(_ kind: String) async throws {
    try resetFixture()
    let state = try await persistFixtureOperation(phase: .restoring)
    try marker("mutated-guard")
    let digest = try await DshPluginManager.shared.pluginProfileDigest(at: profileURL())
    let corrected = DshPluginOperationState(
        operationID: state.operationID,
        profile: state.profile,
        targetPackage: state.targetPackage,
        targetPackages: state.targetPackages,
        action: state.action,
        snapshot: state.snapshot,
        startedAt: state.startedAt,
        phase: .restoring,
        mutationDigest: digest
    )
    try writeOperationState(corrected)
    let snapshotURL = snapshotDirectoryURL(state.snapshot)
    if kind == "missing" {
        try fileManager.removeItem(at: snapshotURL)
    } else {
        let metadataURL = snapshotURL.appendingPathComponent("snapshot.json")
        var object = try JSONSerialization.jsonObject(with: Data(contentsOf: metadataURL)) as! [String: Any]
        object["ownerID"] = "not-dsh-desktop-owner"
        let metadata = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try metadata.write(to: metadataURL, options: .atomic)
    }
}

private func recoverRestorationGuard(_ kind: String) async throws {
    let coordinator = DshPluginOperationCoordinator(operationStoreURL: operationStoreURL())
    do {
        _ = try await coordinator.recoverPendingOperation()
        require(false, "\(kind) snapshot guard must fail")
    } catch {
        require(coordinator.pendingOperation != nil, "\(kind) snapshot guard must retain operation record")
        require(coordinator.pendingOperation?.phase == .recoveryRequired, "\(kind) snapshot guard must enter recoveryRequired")
    }
    try requireContents("mutated-guard", at: profileURL().appendingPathComponent("marker"), "\(kind) snapshot guard must not overwrite current tree")
}

private func setupExternalModification() async throws {
    try await setupVerifying()
    try marker("external-concurrent-change")
}

private func recoverExternalModification() async throws {
    let coordinator = DshPluginOperationCoordinator(operationStoreURL: operationStoreURL())
    await expectOperationError(.externalModification) {
        _ = try await coordinator.recoverPendingOperation()
    }
    require(coordinator.pendingOperation?.phase == .recoveryRequired, "external change must require recovery")
    try requireContents("external-concurrent-change", at: profileURL().appendingPathComponent("marker"), "external change must never be overwritten")
}

@main
struct PluginOperationHarness {
    static func main() async throws {
        _ = testHome()
        let scenario = CommandLine.arguments.dropFirst().first ?? "committed"
        switch scenario {
        case "prepared-setup": try await setupPrepared()
        case "prepared-recover": try await recoverPrepared()
        case "mutating-no-digest-setup": try await setupMutatingWithoutDigest()
        case "mutating-no-digest-recover": try await recoverMutatingWithoutDigest()
        case "mutating-no-digest-recover-again": try await recoverMutatingWithoutDigestAfterConflictResolution()
        case "adopt-setup": try await setupAdoptInterrupted()
        case "adopt-verified": try await recoverAdoptVerified()
        case "adopt-unhealthy": try await recoverAdoptUnhealthy()
        case "adopt-rejects-committed": try await recoverAdoptRejectsCommitted()
        case "adopt-gating-matrix": try runAdoptGatingMatrix()
        case "verifying-setup": try await setupVerifying()
        case "verifying-commit-recover": try await recoverVerifyingCommit()
        case "verifying-restore-recover": try await recoverVerifyingRestore()
        case "restored-health-failure-setup": try await setupRestoredHealthFailure()
        case "restored-health-failure-recover": try await recoverRestoredHealthFailure()
        case "restoring-setup": try await setupRestoring()
        case "restoring-recover": try await recoverRestoringIdempotently()
        case "resuming-restore-setup": try await setupResumingInterruptedRestore()
        case "resuming-restore-recover": try await recoverResumingInterruptedRestore()
        case "interrupted-restore-leftover": try await verifyInterruptedRestoreKeepsLeftover()
        case "stale-staging-restore-setup": try await setupRestoreWithStaleStaging()
        case "stale-staging-restore-recover": try await recoverRestoreWithStaleStaging()
        case "recovery-required-missing-profile-setup": try await setupRecoveryRequiredMissingProfile()
        case "recovery-required-missing-profile-recover": try await recoverRecoveryRequiredMissingProfile()
        case "m2-rollback-selection": try await verifyInterruptedRollbackSurvivesSelectionSync()
        case "staging-sweep": try await verifyStagingSweep()
        case "selection-preserves-open-transaction":
            try await verifySelectionPreservesRecoverableTransaction()
        case "selection-settles-unrecoverable":
            try await verifySelectionSettlesUnrecoverableTransaction()
        case "dangling-profile-symlink-guards": try await verifyDanglingProfileSymlinkGuards()
        case "dangling-profile-symlink-adopt-setup": try await setupDanglingProfileSymlinkAdopt()
        case "dangling-profile-symlink-adopt-recover": try await recoverDanglingProfileSymlinkAdopt()
        case "snapshot-sweep-symlink-guard": try await verifySnapshotSweepSymlinkGuard()
        case "restoring-cleanup-setup": try await setupRestoringAfterSnapshotDeletion()
        case "restoring-cleanup-recover": try await recoverRestoringAfterSnapshotDeletion()
        case "committed": try await runCommittedRetention()
        case "cancel-before-record": try await runCancelledBeforeRecord()
        case "cancel-during-mutation": try await runCancelledDuringMutation()
        case "cancel-during-mutation-recovery-failure": try await runCancelledDuringMutation(restoreFails: true)
        case "cancel-during-verify": try await runCancelledDuringVerify()
        case "capacity-contract": try runSnapshotCapacityContract()
        case "install-downgrade-gate": try runInstallDowngradeGate()
        case "owned-snapshot-delete-guard": try await runOwnedSnapshotDeleteGuard()
        case "batch-failure": try await runBatchFailure()
        case "corrupt-record": try await runCorruptRecord()
        case "structurally-invalid-record": try await runStructurallyInvalidRecord()
        case "missing-snapshot-setup": try await setupRestorationGuard("missing")
        case "missing-snapshot-recover": try await recoverRestorationGuard("missing")
        case "ownership-mismatch-setup": try await setupRestorationGuard("ownership")
        case "ownership-mismatch-recover": try await recoverRestorationGuard("ownership")
        case "external-setup": try await setupExternalModification()
        case "external-recover": try await recoverExternalModification()
        default:
            fputs("FAIL: unknown scenario \(scenario)\n", stderr)
            exit(2)
        }
        print("plugin operation scenario \(scenario) passed")
    }
}
