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

@main
struct RuntimeUIGateHarness {
    static func main() {
        // Reproduce the exact successful update path: candidate activation,
        // verification, healthy in-process restart, then confirmation.
        var afterSuccessfulUpdate = DshStateConfig(
            selectedVersion: candidate.version,
            autoFollowLatest: false
        )
        var transaction = DshRuntimeTransaction.begin(
            active: active,
            candidate: candidate,
            updatePolicy: .notify,
            channel: .latest
        )
        transaction = DshRuntimeTransaction.activateCandidate(transaction)
        transaction = DshRuntimeTransaction.beginVerification(transaction)
        transaction = DshRuntimeTransaction.confirm(transaction)
        afterSuccessfulUpdate.runtimeState = transaction

        require(afterSuccessfulUpdate.runtimeState.phase == .confirmed,
                "successful update must retain confirmed cleanup phase")
        require(afterSuccessfulUpdate.runtimeState.previous?.version == active.version,
                "successful update must retain previous Runtime for the second-start safety window")
        require(
            DshRuntimeMutationGate.allowsPluginMutation(afterSuccessfulUpdate),
            "plugin/settings mutations must be enabled immediately after a healthy update")
        require(
            !DshRuntimeMutationGate.allowsRuntimeUpdate(afterSuccessfulUpdate),
            "a second Runtime update must remain blocked until the previous Runtime is cleaned")

        // Switching the update channel is a settings mutation, not a second
        // Runtime install. It must remain usable without restarting the app.
        afterSuccessfulUpdate.runtimeState.channel = .alpha
        require(
            DshRuntimeMutationGate.allowsPluginMutation(afterSuccessfulUpdate),
            "channel picker state must remain editable during confirmed cleanup")

        // Once the second healthy start has committed cleanup, both gates are
        // open again and the old transaction owner is gone.
        afterSuccessfulUpdate.runtimeState.previous = nil
        afterSuccessfulUpdate.runtimeState.phase = .idle
        afterSuccessfulUpdate.runtimeState.transactionID = nil
        require(
            DshRuntimeMutationGate.allowsPluginMutation(afterSuccessfulUpdate),
            "idle Runtime must allow plugin/settings mutations")
        require(
            DshRuntimeMutationGate.allowsRuntimeUpdate(afterSuccessfulUpdate),
            "idle Runtime must allow the next Runtime update")

        // All in-flight and rollback phases stay fail-closed for both gates.
        for phase in [DshRuntimeTransactionPhase.staging, .switching, .verifying, .rollingBack] {
            var blocked = afterSuccessfulUpdate
            blocked.runtimeState.phase = phase
            blocked.runtimeState.previous = active
            blocked.runtimeState.transactionID = "transaction"
            require(
                !DshRuntimeMutationGate.allowsPluginMutation(blocked),
                "\(phase.rawValue) must keep plugin mutations blocked")
            require(
                !DshRuntimeMutationGate.allowsRuntimeUpdate(blocked),
                "\(phase.rawValue) must keep Runtime updates blocked")
        }

        print("swift runtime UI gate harness passed")
    }
}
