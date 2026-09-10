import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

private func sleep(milliseconds: UInt64) async {
    try? await Task.sleep(nanoseconds: milliseconds * 1_000_000)
}

/// A hung scenario must fail loudly instead of hanging the test runner.
private func watchdog(seconds: Double, _ message: String) {
    Task.detached {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        fputs("FAIL: \(message)\n", stderr)
        exit(2)
    }
}

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ value: String) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    var events: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

/// A task that is already cancelled when it reaches the gate must fail
/// immediately. Queueing it would leave the gate unheld with a parked
/// continuation that only a later, unrelated acquire+release could resume —
/// the caller would hang instead of being cancelled.
private func cancelBeforeAcquireFree() async {
    let gate = DshAsyncOperationGate()
    let recorder = Recorder()
    let task = Task {
        while !Task.isCancelled {
            await sleep(milliseconds: 1)
        }
        do {
            try await gate.acquire()
            recorder.append("acquired")
            gate.release()
        } catch {
            recorder.append("cancelled")
        }
    }
    task.cancel()
    await sleep(milliseconds: 300)
    require(recorder.events == ["cancelled"],
            "a cancelled acquire on a free gate must throw immediately, got \(recorder.events)")

    // The cancelled branch must not have taken or leaked the lock.
    do {
        try await gate.acquire()
        recorder.append("reacquired")
        gate.release()
    } catch {
        recorder.append("reacquire-failed")
    }
    require(recorder.events == ["cancelled", "reacquired"],
            "the gate must stay acquirable after a cancelled acquire, got \(recorder.events)")
}

/// A waiter cancelled while queued must be skipped, and the live waiter queued
/// behind it must still be handed the lock (FIFO among live waiters).
private func cancelWhileQueued() async {
    let gate = DshAsyncOperationGate()
    let recorder = Recorder()
    try? await gate.acquire()

    let cancelledWaiter = Task {
        while !Task.isCancelled {
            await sleep(milliseconds: 1)
        }
        do {
            try await gate.acquire()
            recorder.append("cancelled-waiter-acquired")
            gate.release()
        } catch {
            recorder.append("cancelled-waiter-skipped")
        }
    }
    await sleep(milliseconds: 150)
    cancelledWaiter.cancel()

    let liveWaiter = Task {
        do {
            try await gate.acquire()
            recorder.append("live-waiter-acquired")
            gate.release()
        } catch {
            recorder.append("live-waiter-cancelled")
        }
    }
    await sleep(milliseconds: 150)
    gate.release()
    await sleep(milliseconds: 400)

    // Resumption order between the skipped waiter and the live one is a
    // scheduler detail; the contract is that the cancelled waiter never runs
    // its operation and the live waiter still gets the lock.
    let events = recorder.events
    require(events.contains("cancelled-waiter-skipped"),
            "a cancelled waiter must be resumed with CancellationError, got \(events)")
    require(events.contains("live-waiter-acquired"),
            "the live waiter behind a cancelled one must still get the lock, got \(events)")
    require(!events.contains("cancelled-waiter-acquired"),
            "a cancelled waiter must never run its operation, got \(events)")
    require(events.count == 2, "no extra waiter outcome expected, got \(events)")
}

/// Live waiters are served strictly in arrival order.
private func fifoOrder() async {
    let gate = DshAsyncOperationGate()
    let recorder = Recorder()
    try? await gate.acquire()

    for index in 1...5 {
        Task {
            do {
                try await gate.acquire()
                recorder.append("waiter-\(index)")
                gate.release()
            } catch {
                recorder.append("waiter-\(index)-cancelled")
            }
        }
        await sleep(milliseconds: 80)
    }
    gate.release()
    await sleep(milliseconds: 600)

    require(recorder.events == (1...5).map { "waiter-\($0)" },
            "waiters must be served in FIFO order, got \(recorder.events)")
}

/// Stress the cancellation versus hand-off race. Whichever side wins, two
/// invariants must hold: every waiter settles exactly once (either it ran and
/// released, or it threw), and the gate is never left held — a cancelled
/// caller that already received the lock must release it before reporting.
private func cancelStorm() async {
    var badRounds = 0
    for _ in 0..<40 {
        let gate = DshAsyncOperationGate()
        let recorder = Recorder()
        try? await gate.acquire()

        let waiters = (0..<4).map { _ in
            Task {
                do {
                    try await gate.acquire()
                    recorder.append("ran")
                    gate.release()
                } catch {
                    recorder.append("cancelled")
                }
            }
        }
        for (index, waiter) in waiters.enumerated() where index % 2 == 0 {
            waiter.cancel()
        }
        await sleep(milliseconds: 3)
        gate.release()
        await sleep(milliseconds: 30)

        let events = recorder.events
        if events.count != waiters.count {
            badRounds += 1
            continue
        }
        // The gate must be free again; a cancelled hand-off must not leak it.
        do {
            try await gate.acquire()
            gate.release()
        } catch {
            badRounds += 1
        }
    }
    require(badRounds == 0, "cancel/hand-off races must settle without leaking, \(badRounds) bad rounds")
}

/// Deterministic version of the hand-off race: the waiter is popped by
/// `release()` and only then cancelled, so the cancellation loses the race
/// inside the state machine. `acquire()` must still fail, and it must release
/// the lock it just received — otherwise the gate stays held forever.
private func cancelAfterHandoff() async {
    let gate = DshAsyncOperationGate()
    let recorder = Recorder()
    try? await gate.acquire()

    let waiter = Task {
        do {
            try await gate.acquire()
            recorder.append("ran")
            gate.release()
        } catch {
            recorder.append("cancelled")
        }
    }
    await sleep(milliseconds: 50) // let the waiter enqueue
    gate.release()                // hand the lock off (state becomes handedOff)
    waiter.cancel()               // cancels after the hand-off commit
    await sleep(milliseconds: 100)

    require(recorder.events == ["cancelled"],
            "a cancellation that loses the hand-off race must still fail the acquire, got \(recorder.events)")

    // If the failed acquire forgot to release, this hangs and the watchdog
    // reports it as a hung scenario.
    do {
        try await gate.acquire()
        gate.release()
        recorder.append("gate-free")
    } catch {
        recorder.append("gate-locked")
    }
    require(recorder.events == ["cancelled", "gate-free"],
            "a cancelled hand-off must release the gate, got \(recorder.events)")
}

@main
struct AsyncOperationGateHarness {
    static func main() async {
        let scenario = CommandLine.arguments.dropFirst().first ?? ""
        watchdog(seconds: 20, "scenario \(scenario) hung")
        switch scenario {
        case "cancel-before-acquire-free":
            await cancelBeforeAcquireFree()
        case "cancel-while-queued":
            await cancelWhileQueued()
        case "fifo-order":
            await fifoOrder()
        case "cancel-storm":
            await cancelStorm()
        case "cancel-after-handoff":
            await cancelAfterHandoff()
        default:
            fputs("FAIL: unknown scenario \(scenario)\n", stderr)
            exit(3)
        }
        print("async operation gate scenario \(scenario) passed")
    }
}
