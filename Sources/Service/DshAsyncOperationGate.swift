import Foundation

/// Non-blocking FIFO gate shared by service startup and the desktop shell's
/// wider Runtime/Profile operation. Waiting callers suspend instead of
/// blocking the main actor.
final class DshAsyncOperationGate: @unchecked Sendable {
    private final class Waiter: @unchecked Sendable {
        let continuation: CheckedContinuation<Void, Error>
        let cancelled: CancelledFlag

        init(
            continuation: CheckedContinuation<Void, Error>,
            cancelled: CancelledFlag
        ) {
            self.continuation = continuation
            self.cancelled = cancelled
        }
    }

    private final class CancelledFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        func mark() {
            lock.lock()
            value = true
            lock.unlock()
        }

        var isSet: Bool {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private let lock = NSLock()
    private var isHeld = false
    private var waiters: [Waiter] = []

    /// A waiter cancelled while queued must not run the caller's operation
    /// once its turn arrives. The cancellation flag is set both by the waiter
    /// itself (checked at enqueue time) and by the cancellation handler, so
    /// the release pop can skip the waiter and resume it with
    /// CancellationError without breaking the FIFO between live waiters.
    /// A task that is already cancelled before it enqueues fails immediately:
    /// queueing it would leave the gate unheld with a parked continuation that
    /// nothing can resume (only a later, unrelated acquire+release would),
    /// which hangs the caller instead of cancelling it.
    func acquire() async throws {
        let cancelled = CancelledFlag()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                var resumeNow = false
                var resumeCancelled = false
                lock.lock()
                if Task.isCancelled {
                    cancelled.mark()
                    resumeCancelled = true
                } else if isHeld {
                    waiters.append(Waiter(continuation: continuation, cancelled: cancelled))
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
            // Marks this task's enqueued waiter (if it is still queued) so
            // the release pop skips it; the waiter itself also sets the flag,
            // so either ordering is safe.
            cancelled.mark()
        })
    }

    func release() {
        var cancelledWaiters: [Waiter] = []
        var next: Waiter?
        lock.lock()
        while let candidate = waiters.first, candidate.cancelled.isSet {
            cancelledWaiters.append(candidate)
            waiters.removeFirst()
        }
        if waiters.isEmpty {
            isHeld = false
            next = nil
        } else {
            next = waiters.removeFirst()
        }
        lock.unlock()
        for waiter in cancelledWaiters {
            waiter.continuation.resume(throwing: CancellationError())
        }
        next?.continuation.resume()
    }
}
