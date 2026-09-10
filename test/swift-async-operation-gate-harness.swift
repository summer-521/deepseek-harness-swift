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
        default:
            fputs("FAIL: unknown scenario \(scenario)\n", stderr)
            exit(3)
        }
        print("async operation gate scenario \(scenario) passed")
    }
}
