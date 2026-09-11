import Foundation
import Darwin

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

let active = NpmRuntimeDescriptor(
    version: "0.1.1-rc.2",
    registry: "https://registry.npmjs.org",
    integrity: "sha512-active"
)
let candidate = NpmRuntimeDescriptor(
    version: "0.1.2-rc.1",
    registry: "https://registry.npmjs.org",
    integrity: "sha512-candidate"
)

func state(
    phase: DshRuntimeTransactionPhase,
    selected: String?,
    previous: NpmRuntimeDescriptor? = active,
    pending: NpmRuntimeDescriptor? = candidate
) -> DshStateConfig {
    DshStateConfig(
        selectedVersion: selected,
        autoFollowLatest: false,
        runtimeState: DshRuntimeState(
            active: selected == candidate.version ? candidate : active,
            previous: previous,
            pending: pending,
            phase: phase,
            updatePolicy: .notify,
            channel: .latest
        )
    )
}

@main
struct RuntimeRecoveryHarness {
    static func main() {
        let initial = DshRuntimeTransaction.begin(
            active: active,
            candidate: candidate,
            updatePolicy: .notify,
            channel: .latest
        )

        // Profile switches must survive a process interruption with enough
        // information to restore the previously healthy Profile.
        let profileSwitch = DshProfileSwitchTransaction(
            from: .desktop,
            to: .web,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        var interruptedProfileState = DshStateConfig(
            appProfile: .web,
            pendingProfileSwitch: profileSwitch,
            autoFollowLatest: false
        )
        let encodedProfileState = try! JSONEncoder().encode(interruptedProfileState)
        let decodedProfileState = try! JSONDecoder().decode(DshStateConfig.self, from: encodedProfileState)
        require(decodedProfileState.pendingProfileSwitch == profileSwitch, "Profile switch transaction must persist")
        interruptedProfileState.appProfile = profileSwitch.from
        interruptedProfileState.pendingProfileSwitch = nil
        require(interruptedProfileState.appProfile == .desktop, "Profile recovery must restore the source Profile")

        // Inject a candidate-install failure before activation. The old
        // active descriptor must survive the rollback transition.
        var candidateInstallFailure = DshRuntimeTransaction.beginRollback(initial)
        candidateInstallFailure = DshRuntimeTransaction.finishRollback(
            candidateInstallFailure,
            active: active
        )
        require(candidateInstallFailure.active == active, "candidate install failure must keep active")
        require(candidateInstallFailure.pending == nil, "candidate install failure must clear pending")
        require(candidateInstallFailure.phase == .idle, "candidate install failure must settle idle")

        // A rollback failure must remain recoverable. In particular, do not
        // clear previous/pending or pretend the transaction is idle.
        let rollbackFailure = DshRuntimeTransaction.recordRollbackFailure(
            DshRuntimeTransaction.beginRollback(
                DshRuntimeTransaction.activateCandidate(initial)
            ),
            diagnostic: "old runtime did not start"
        )
        require(rollbackFailure.phase == .rollingBack, "rollback failure must remain rolling back")
        require(rollbackFailure.previous == active, "rollback failure must retain previous")
        require(rollbackFailure.pending == candidate, "rollback failure must retain pending")
        require(rollbackFailure.lastDiagnostic == "old runtime did not start", "rollback failure must retain diagnostic")

        // Inject a startup/health failure after switching to candidate. The
        // same rollback path must restore the old descriptor.
        var startupFailure = DshRuntimeTransaction.activateCandidate(initial)
        startupFailure = DshRuntimeTransaction.beginVerification(startupFailure)
        startupFailure = DshRuntimeTransaction.beginRollback(startupFailure)
        startupFailure = DshRuntimeTransaction.finishRollback(startupFailure, active: active)
        require(startupFailure.active == active, "startup failure must restore active")
        require(startupFailure.pending == nil, "startup failure must clear pending")
        require(startupFailure.previous == nil, "startup failure must clear previous")

        let confirmed = DshRuntimeTransaction.confirm(
            DshRuntimeTransaction.beginVerification(
                DshRuntimeTransaction.activateCandidate(initial)
            )
        )
        require(confirmed.active == candidate, "successful transaction must activate candidate")
        require(confirmed.pending == nil, "successful transaction must clear pending")
        require(confirmed.phase == .confirmed, "successful transaction must confirm")

        let snapshotted = DshRuntimeTransaction.attachWebProfileSnapshot(initial, id: "snapshot-id")
        require(snapshotted.webProfileSnapshotID == "snapshot-id", "transaction must retain Profile snapshot id")

        if case .finalizeConfirmed(let recovered) = DshRuntimeRecoveryPlanner.plan(
            state: state(phase: .confirmed, selected: candidate.version),
            installedVersions: [active.version, candidate.version]
        ) {
            require(recovered == candidate, "confirmed candidate should be finalized")
        } else {
            require(false, "confirmed candidate should be finalized")
        }

        for phase in [DshRuntimeTransactionPhase.staging, .switching, .verifying, .rollingBack] {
            if case .rollback(let recovered, let discarded) = DshRuntimeRecoveryPlanner.plan(
                state: state(phase: phase, selected: candidate.version),
                installedVersions: [active.version, candidate.version]
            ) {
                require(recovered == active, "unconfirmed phase should restore previous")
                require(discarded == candidate, "unconfirmed phase should discard candidate")
            } else {
                require(false, "unconfirmed phase should plan rollback")
            }
        }

        if case .reset(let discarded) = DshRuntimeRecoveryPlanner.plan(
            state: state(phase: .verifying, selected: candidate.version, previous: nil),
            installedVersions: [candidate.version]
        ) {
            require(discarded == candidate, "missing previous should reset and discard candidate")
        } else {
            require(false, "missing previous should plan reset")
        }

        require(
            DshRuntimeRecoveryPlanner.plan(
                state: state(phase: .idle, selected: active.version, pending: nil),
                installedVersions: [active.version]
            ) == nil,
            "state without pending transaction should not recover"
        )

        let legacy = try! JSONDecoder().decode(
            DshStateConfig.self,
            from: Data(#"{"selectedVersion":"0.1.1-rc.2"}"#.utf8)
        )
        require(legacy.runtimeState.updatePolicy == .notify, "new state default should be notify")
        require(legacy.autoFollowLatest == false, "new state default should not auto-follow latest")
        require(legacy.runtimeState.webProfileSnapshotID == nil, "legacy state should default without Profile snapshot")

        let nextState = DshRuntimeState(updatePolicy: .automaticStable, channel: .next)
        require(nextState.updatePolicy == .notify, "next channel must never persist automatic updates")
        let alphaState = DshRuntimeState(updatePolicy: .automaticStable, channel: .alpha)
        require(alphaState.updatePolicy == .notify, "alpha channel must never persist automatic updates")

        // M2: a user-initiated rollback from the confirmed cleanup window has
        // no pending candidate. The rollingBack transition must keep the
        // confirmed new Runtime active until the settle, retain the previous
        // one for the rollback start, and the settle must keep a retained
        // snapshot id for later cleanup instead of pretending it is gone.
        var confirmedRollback = DshRuntimeTransaction.beginRollback(confirmed)
        require(confirmedRollback.phase == .rollingBack, "confirmed rollback must enter rollingBack")
        require(confirmedRollback.active == candidate,
                "confirmed rollback must keep the new runtime active until settle")
        require(confirmedRollback.previous == active, "confirmed rollback must retain the previous runtime")
        require(confirmedRollback.pending == nil, "confirmed rollback has no pending candidate")
        confirmedRollback = DshRuntimeTransaction.finishRollback(
            confirmedRollback,
            active: active,
            retainedWebProfileSnapshotID: "snapshot-id"
        )
        require(confirmedRollback.active == active, "confirmed rollback settle must reactivate previous")
        require(confirmedRollback.previous == nil, "confirmed rollback settle must clear previous")
        require(confirmedRollback.phase == .idle, "confirmed rollback settle must be idle")
        require(confirmedRollback.transactionID == nil, "confirmed rollback settle must clear the owner")
        require(confirmedRollback.webProfileSnapshotID == "snapshot-id",
                "a failed snapshot cleanup must retain the snapshot id for the startup retry")

        // R1: a settled idle state that still carries transaction bookkeeping
        // locks the mutation gates forever, because no transition clears
        // `previous` while idle. The repair must clear only the bookkeeping and
        // must keep a retained snapshot reference (that snapshot still has to
        // be deleted by the cleanup path).
        var idleResidue = DshRuntimeState(updatePolicy: .notify, channel: .latest)
        idleResidue.phase = .idle
        idleResidue.previous = active
        idleResidue.transactionID = "stale-owner"
        idleResidue.webProfileSnapshotID = "retained-snapshot"
        require(!DshRuntimeMutationGate.allowsPluginMutation(
            DshStateConfig(appProfile: .desktop, runtimeState: idleResidue)
        ), "an idle residue must be treated as locked before repair")

        let repairedResidue = DshRuntimeTransaction.repairIdleTransactionResidue(idleResidue)
        require(repairedResidue != nil, "an idle residue must be repairable")
        require(repairedResidue?.previous == nil, "repair must clear the stale previous runtime")
        require(repairedResidue?.transactionID == nil, "repair must clear the stale transaction owner")
        require(repairedResidue?.phase == .idle, "repair must keep the settled idle phase")
        require(repairedResidue?.webProfileSnapshotID == "retained-snapshot",
                "repair must keep the retained snapshot reference for cleanup")
        require(repairedResidue?.lastDiagnostic?.isEmpty == false,
                "repair must record a diagnostic")

        var repairedState = DshStateConfig(appProfile: .desktop, runtimeState: repairedResidue!)
        repairedState.runtimeState.webProfileSnapshotID = nil
        require(DshRuntimeMutationGate.allowsPluginMutation(repairedState),
                "a repaired idle state must reopen plugin mutations")

        // A settled idle state without residue, and any open transaction, must
        // not be rewritten by the repair.
        let cleanIdle = DshRuntimeState(updatePolicy: .notify, channel: .latest)
        require(DshRuntimeTransaction.repairIdleTransactionResidue(cleanIdle) == nil,
                "a clean idle state must not be rewritten")
        var openRollback = DshRuntimeTransaction.beginRollback(confirmed)
        require(DshRuntimeTransaction.repairIdleTransactionResidue(openRollback) == nil,
                "an open transaction must never be repaired away")

        // T7: resetting an abandoned transaction must clear every field,
        // including the transaction owner. Leaving the owner behind keeps
        // `DshRuntimeMutationGate` closed for the rest of the session because
        // its idle branch requires previous/transactionID/snapshot to be empty.
        var resetCandidate = DshRuntimeState(updatePolicy: .notify, channel: .latest)
        resetCandidate.phase = .verifying
        resetCandidate.active = candidate
        resetCandidate.previous = active
        resetCandidate.pending = candidate
        resetCandidate.transactionID = "tx-reset"
        resetCandidate.webProfileSnapshotID = "snapshot-reset"
        resetCandidate.healthyStartCount = 1
        let settledReset = DshRuntimeTransaction.settleAbandoned(
            resetCandidate,
            diagnostic: "reset diagnostic"
        )
        require(settledReset.phase == .idle, "reset settle must be idle")
        require(settledReset.active == nil && settledReset.previous == nil && settledReset.pending == nil,
                "reset settle must clear every runtime reference")
        require(settledReset.webProfileSnapshotID == nil,
                "reset settle must clear the snapshot reference")
        require(settledReset.transactionID == nil,
                "reset settle must clear the transaction owner")
        require(settledReset.healthyStartCount == 0,
                "reset settle must clear the healthy-start count")
        require(settledReset.lastDiagnostic == "reset diagnostic",
                "reset settle must record the diagnostic")
        require(DshRuntimeMutationGate.allowsPluginMutation(
            DshStateConfig(appProfile: .desktop, runtimeState: settledReset)
        ), "a settled reset must reopen plugin/Runtime mutations in the same session")

        // T9: a Profile repair is required for every open, *owned* Runtime
        // transaction whose Profile disagrees with `appProfile`. A confirmed
        // transaction has no pending descriptor, and that is exactly the state
        // an older build could persist after switching Profiles; skipping the
        // repair there left the app locked forever (the health count refuses to
        // settle, the Profile switch is gated on idle, and the Runtime rollback
        // action only applies to desktop).
        var stuckConfirmed = DshRuntimeState(updatePolicy: .notify, channel: .latest)
        stuckConfirmed.phase = .confirmed
        stuckConfirmed.active = candidate
        stuckConfirmed.previous = active
        stuckConfirmed.transactionID = "tx-stuck"
        stuckConfirmed.profile = .desktop
        require(
            !DshRuntimeMutationGate.allowsProfileTreeMutation(
                DshStateConfig(appProfile: .web, runtimeState: stuckConfirmed)
            ),
            "the stuck state must be locked, which is why the repair is required"
        )
        require(
            DshRuntimeTransactionOwnership.profileRepairTarget(
                runtime: stuckConfirmed,
                appProfile: .web,
                hasPendingProfileSwitch: false
            ) == .desktop,
            "a confirmed transaction with a cleared pending descriptor must still repair the Profile"
        )
        require(
            DshRuntimeTransactionOwnership.profileRepairTarget(
                runtime: stuckConfirmed,
                appProfile: .desktop,
                hasPendingProfileSwitch: false
            ) == nil,
            "a matching Profile must not be rewritten"
        )
        require(
            DshRuntimeTransactionOwnership.profileRepairTarget(
                runtime: stuckConfirmed,
                appProfile: .web,
                hasPendingProfileSwitch: true
            ) == nil,
            "a pending Profile switch owns the Profile decision for this launch"
        )
        var ownerlessLegacy = stuckConfirmed
        ownerlessLegacy.transactionID = nil
        require(
            DshRuntimeTransactionOwnership.profileRepairTarget(
                runtime: ownerlessLegacy,
                appProfile: .web,
                hasPendingProfileSwitch: false
            ) == .desktop,
            "a legacy transaction without an owner id must repair using descriptor evidence"
        )
        var settledState = stuckConfirmed
        settledState.phase = .idle
        require(
            DshRuntimeTransactionOwnership.profileRepairTarget(
                runtime: settledState,
                appProfile: .web,
                hasPendingProfileSwitch: false
            ) == nil,
            "a settled idle state must not be rewritten"
        )
        var emptyOpenPhase = DshRuntimeState(updatePolicy: .notify, channel: .latest)
        emptyOpenPhase.phase = .rollingBack
        require(
            DshRuntimeTransactionOwnership.profileRepairTarget(
                runtime: emptyOpenPhase,
                appProfile: .web,
                hasPendingProfileSwitch: false
            ) == nil,
            "an open phase without ownership evidence must not be rewritten"
        )

        // R12: a displaced Profile tree is only reclaimed with the durable
        // completion proof AND a canonical Profile in place. Anything else can
        // be the only complete copy of the user's Profile.
        let profilesRoot = URL(fileURLWithPath: "/tmp/dsh-recovery-home/profiles", isDirectory: true)
        let displaced = profilesRoot.appendingPathComponent(
            DshProfileRestoreCleanup.displacedNamePrefix + "3F2504E0-4F89-41D3-9A0C-0305E82C3301",
            isDirectory: true
        )
        let unproven = DshProfileRestoreCleanup(
            profile: .web,
            snapshotID: "3F2504E0-4F89-41D3-9A0C-0305E82C3301",
            displacedPath: displaced,
            completed: false
        )
        require(
            !DshProfileRestoreCleanup.mayReclaim(
                unproven,
                canonicalProfileIsRealDirectory: true,
                trustedProfilesRoots: [profilesRoot]
            ),
            "an unproven restore must never be reclaimed"
        )
        require(
            !DshProfileRestoreCleanup.mayReclaim(
                unproven,
                canonicalProfileIsRealDirectory: false,
                trustedProfilesRoots: [profilesRoot]
            ),
            "an unproven restore must never be reclaimed"
        )

        // The canonical Profile is derived from the record itself, because the
        // record lives in Application Support (shared by every DSH_HOME): a
        // canonical Profile from a *different* home must never authorise
        // deleting this tree, and the same home must not be assumed.
        require(
            unproven.profilesRootURL == profilesRoot.standardizedFileURL,
            "the profiles root must come from the recorded path"
        )
        require(
            unproven.canonicalProfileURL
                == profilesRoot.appendingPathComponent("web", isDirectory: true),
            "the canonical Profile must be the recorded tree's sibling"
        )
        require(unproven.hasWellFormedDisplacedName, "the record must recognise its own displaced name")
        require(
            unproven.matches(profile: .web, snapshotID: "3F2504E0-4F89-41D3-9A0C-0305E82C3301"),
            "the record must match its own identity"
        )
        require(
            !unproven.matches(profile: .desktop, snapshotID: "3F2504E0-4F89-41D3-9A0C-0305E82C3301"),
            "the record must not match another Profile"
        )

        var proven = unproven
        proven.completed = true
        require(
            DshProfileRestoreCleanup.mayReclaim(
                proven,
                canonicalProfileIsRealDirectory: true,
                trustedProfilesRoots: [profilesRoot]
            ),
            "a proven restore with a canonical Profile may be reclaimed"
        )
        require(
            !DshProfileRestoreCleanup.mayReclaim(
                proven,
                canonicalProfileIsRealDirectory: false,
                trustedProfilesRoots: [profilesRoot]
            ),
            "a missing canonical Profile must keep the displaced tree"
        )

        // `dsh-state.json` is user-writable, so the recorded path is untrusted
        // input: a path that is not this app's exact displaced name for the
        // recorded snapshot must never authorise a recursive delete.
        var foreignTree = proven
        foreignTree.displacedPath = profilesRoot.appendingPathComponent(
            DshProfileRestoreCleanup.displacedNamePrefix + "1B4E28BA-2FA1-11D2-883F-0016D3CCA427",
            isDirectory: true
        ).path
        require(!foreignTree.hasWellFormedDisplacedName, "a foreign displaced name must be rejected")
        require(
            !DshProfileRestoreCleanup.mayReclaim(
                foreignTree,
                canonicalProfileIsRealDirectory: true,
                trustedProfilesRoots: [profilesRoot]
            ),
            "a snapshot-id mismatch must never be reclaimed"
        )
        var arbitraryPath = proven
        arbitraryPath.displacedPath = "/Users/someone/Documents"
        require(
            !DshProfileRestoreCleanup.mayReclaim(
                arbitraryPath,
                canonicalProfileIsRealDirectory: true,
                trustedProfilesRoots: [profilesRoot]
            ),
            "an arbitrary absolute path must never be reclaimed"
        )

        // Round-5 hardening: the snapshot id must be a UUID, and the enclosing
        // directory must be one of the Profile roots this app creates. A bare
        // `profiles` name is not evidence (round-6 reproduction below).
        var nonUUID = proven
        nonUUID.displacedPath = profilesRoot.appendingPathComponent(
            DshProfileRestoreCleanup.displacedNamePrefix + "snapshot-r12",
            isDirectory: true
        ).path
        require(!nonUUID.hasWellFormedDisplacedName, "a non-UUID snapshot id must be rejected")
        require(
            !DshProfileRestoreCleanup.mayReclaim(
                nonUUID,
                canonicalProfileIsRealDirectory: true,
                trustedProfilesRoots: [profilesRoot]
            ),
            "a non-UUID snapshot id must never authorise a delete"
        )
        var outsideRoot = proven
        outsideRoot.displacedPath = URL(fileURLWithPath: "/Users/someone/Documents", isDirectory: true)
            .appendingPathComponent(
                DshProfileRestoreCleanup.displacedNamePrefix + "3F2504E0-4F89-41D3-9A0C-0305E82C3301",
                isDirectory: true
            ).path
        require(
            !outsideRoot.displacedRootIsTrusted([profilesRoot]),
            "a displaced tree outside the app's Profile root must not be trusted"
        )
        require(
            !DshProfileRestoreCleanup.mayReclaim(
                outsideRoot,
                canonicalProfileIsRealDirectory: true,
                trustedProfilesRoots: [profilesRoot]
            ),
            "a displaced tree outside the app's Profile root must never be reclaimed"
        )

        // Round-6 reproduction: a directory merely *named* `profiles` is not
        // evidence. This record is fully well-formed by name — UUID snapshot and
        // the exact displaced name — but it points at an unrelated project
        // directory, so reclamation must refuse it even when a sibling canonical
        // Profile exists there.
        let unrelatedRoot = URL(fileURLWithPath: "/tmp/unrelated-project/profiles", isDirectory: true)
        let unrelatedRecord = DshProfileRestoreCleanup(
            profile: .web,
            snapshotID: "3F2504E0-4F89-41D3-9A0C-0305E82C3301",
            displacedPath: unrelatedRoot.appendingPathComponent(
                DshProfileRestoreCleanup.displacedNamePrefix + "3F2504E0-4F89-41D3-9A0C-0305E82C3301",
                isDirectory: true
            ),
            completed: true
        )
        require(
            unrelatedRecord.hasWellFormedDisplacedName,
            "the name check alone accepts the unrelated tree, which is why the root must be verified"
        )
        require(
            !unrelatedRecord.displacedRootIsTrusted([profilesRoot]),
            "a profiles directory outside the app's DSH home is not a trusted root"
        )
        require(
            !DshProfileRestoreCleanup.mayReclaim(
                unrelatedRecord,
                canonicalProfileIsRealDirectory: true,
                trustedProfilesRoots: [profilesRoot]
            ),
            "an unrelated profiles directory must never authorise a recursive delete"
        )

        // Debt is a collection: a later restore must not drop the reference to a
        // tree that is still on disk, because nothing reclaims an unreferenced
        // displaced tree.
        var stateWithCleanup = DshStateConfig(appProfile: .web)
        stateWithCleanup.pendingProfileRestoreCleanups = [proven, foreignTree]
        let encodedState = try! JSONEncoder().encode(stateWithCleanup)
        let decodedState = try! JSONDecoder().decode(DshStateConfig.self, from: encodedState)
        let restoredCleanups = decodedState.pendingProfileRestoreCleanups
        require(restoredCleanups.count == 2, "every cleanup debt must round-trip")
        require(restoredCleanups.first?.completed == true, "the completion proof must round-trip")
        require(restoredCleanups.first?.snapshotID == "3F2504E0-4F89-41D3-9A0C-0305E82C3301", "the snapshot id must round-trip")
        require(restoredCleanups.first?.profile == .web, "the owning Profile must round-trip")
        require(
            restoredCleanups.first?.displacedPath == displaced.standardizedFileURL.path,
            "the displaced path must round-trip"
        )
        require(
            restoredCleanups.last?.displacedPath == foreignTree.displacedPath,
            "a second debt must not be dropped"
        )

        // Legacy single-slot state (the format this app wrote before the record
        // became a collection) must fold into the collection instead of being
        // dropped, which would leak the retained tree forever.
        let legacyData = try! JSONSerialization.data(withJSONObject: [
            "appProfile": "web",
            "pendingProfileRestoreCleanup": [
                "profile": "web",
                "snapshotID": "3F2504E0-4F89-41D3-9A0C-0305E82C3301",
                "displacedPath": displaced.standardizedFileURL.path,
                "completed": true,
                "createdAt": 0,
            ],
        ])
        let legacyDebtState = try! JSONDecoder().decode(DshStateConfig.self, from: legacyData)
        require(
            legacyDebtState.pendingProfileRestoreCleanups.count == 1,
            "the legacy single-slot record must migrate into the collection"
        )
        require(
            legacyDebtState.pendingProfileRestoreCleanups.first?.snapshotID == "3F2504E0-4F89-41D3-9A0C-0305E82C3301",
            "the legacy record must keep its snapshot id"
        )
        require(
            legacyDebtState.pendingProfileRestoreCleanups.first?.completed == true,
            "the legacy record must keep its completion proof"
        )

        let legacyState = try! JSONDecoder().decode(
            DshStateConfig.self,
            from: Data(#"{"appProfile":"desktop"}"#.utf8)
        )
        require(
            legacyState.pendingProfileRestoreCleanups.isEmpty,
            "a state file without the cleanup field must decode"
        )

        print("runtime recovery integration harness passed")
    }
}
