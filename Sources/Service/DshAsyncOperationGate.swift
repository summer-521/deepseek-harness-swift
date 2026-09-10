import Foundation

/// Non-blocking FIFO gate shared by service startup and the desktop shell's
/// wider Runtime/Profile operation. Waiting callers suspend instead of
/// blocking the main actor.
final class DshAsyncOperationGate: @unchecked Sendable {
    /// One queued acquisition. `state` is guarded by the gate lock, so a
    /// cancellation and a hand-off can never both win: whoever changes the
    /// state under the lock decides the outcome.
    private final class Waiter: @unchecked Sendable {
        enum State {
            case queued
            case handedOff
            case cancelled
        }

        let continuation: CheckedContinuation<Void, Error>
        var state: State = .queued

        init(continuation: CheckedContinuation<Void, Error>) {
            self.continuation = continuation
        }
    }

    /// Carries the enqueued waiter from the continuation body to the
    /// cancellation handler; both touch it under the gate lock.
    private final class WaiterSlot: @unchecked Sendable {
        var waiter: Waiter?
    }

    private let lock = NSLock()
    private var isHeld = false
    private var waiters: [Waiter] = []

    /// Cancel-aware in all three directions:
    /// - a task that is already cancelled when it arrives fails immediately;
    ///   queueing it would leave the gate unheld with a parked continuation
    ///   that only an unrelated acquire+release could resume;
    /// - a waiter cancelled while queued is marked under the lock and skipped
    ///   by the release pop, so its operation never runs and the FIFO among
    ///   live waiters is preserved;
    /// - a cancellation that loses the race against a hand-off is still
    ///   observed after the resume, and the just-acquired lock is released
    ///   before the error is reported, so a cancelled caller neither runs its
    ///   operation nor leaks the gate.
    func acquire() async throws {
        let slot = WaiterSlot()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                var resumeNow = false
                var resumeCancelled = false
                lock.lock()
                if Task.isCancelled {
                    resumeCancelled = true
                } else if isHeld {
                    let waiter = Waiter(continuation: continuation)
                    slot.waiter = waiter
                    waiters.append(waiter)
                } else {
                    isHeld = true
                    resumeNow = true
                }
                lock.unlock()
                if resumeCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if resumeNow {
                    continuation.resume()
                }
            }
        }, onCancel: {
            // Runs concurrently with the enqueue path; the gate lock makes the
            // outcome unambiguous. A waiter that was already handed off is left
            // alone: the caller owns the lock now and decides below.
            lock.lock()
            if let waiter = slot.waiter, waiter.state == .queued {
                waiter.state = .cancelled
            }
            lock.unlock()
        })

        // The hand-off and a cancellation can race between the release pop and
        // the continuation resume. If the cancellation lost that race it is
        // still observable here; release the lock before reporting it.
        if Task.isCancelled {
            release()
            throw CancellationError()
        }
    }

    func release() {
        var cancelledWaiters: [Waiter] = []
        var next: Waiter?
        lock.lock()
        while let candidate = waiters.first, candidate.state == .cancelled {
            cancelledWaiters.append(candidate)
            waiters.removeFirst()
        }
        if waiters.isEmpty {
            isHeld = false
            next = nil
        } else {
            next = waiters.removeFirst()
            next?.state = .handedOff
        }
        lock.unlock()
        for waiter in cancelledWaiters {
            waiter.continuation.resume(throwing: CancellationError())
        }
        next?.continuation.resume()
    }
}
