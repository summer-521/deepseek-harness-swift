import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

private func directory() -> URL {
    guard let raw = ProcessInfo.processInfo.environment["DSH_INSTANCE_LOCK_DIR"], !raw.isEmpty else {
        fputs("FAIL: DSH_INSTANCE_LOCK_DIR is required\n", stderr)
        exit(2)
    }
    return URL(fileURLWithPath: raw, isDirectory: true)
}

private func holder(appVersion: String = "harness") -> DshInstanceLock.Holder {
    DshInstanceLock.Holder(
        pid: ProcessInfo.processInfo.processIdentifier,
        appVersion: appVersion,
        dshHome: "/tmp/dsh-instance-lock-harness-home",
        acquiredAt: Date()
    )
}

@main
struct InstanceLockHarness {
    static func main() {
        let mode = CommandLine.arguments.dropFirst().first ?? ""
        switch mode {
        case "hold":
            switch DshInstanceLock.acquire(at: directory(), holder: holder()) {
            case .acquired(let lock):
                // Keep the lock object (and therefore the descriptor and its
                // flock) alive until the parent kills this process. Releasing
                // it early would silently free the lock.
                print("instance lock held")
                fflush(stdout)
                withExtendedLifetime(lock) {
                    Thread.sleep(forTimeInterval: 30)
                }
                print("holder exiting on its own")
            case .heldBy:
                fputs("FAIL: a free lock must be acquirable\n", stderr)
                exit(1)
            case .unavailable(let detail):
                fputs("FAIL: lock unavailable: \(detail)\n", stderr)
                exit(1)
            }

        case "expect-held":
            switch DshInstanceLock.acquire(at: directory(), holder: holder()) {
            case .heldBy(let existing):
                guard let existing else {
                    fputs("FAIL: the holder payload must be readable\n", stderr)
                    exit(1)
                }
                require(existing.appVersion == "harness", "holder payload must round-trip")
                require(existing.pid > 0, "holder pid must be recorded")
                print("instance lock held by pid \(existing.pid)")
            case .acquired:
                fputs("FAIL: a held lock must not be acquired by a second process\n", stderr)
                exit(1)
            case .unavailable(let detail):
                fputs("FAIL: lock unavailable: \(detail)\n", stderr)
                exit(1)
            }

        case "expect-free":
            switch DshInstanceLock.acquire(at: directory(), holder: holder()) {
            case .acquired(let lock):
                lock.release()
                print("instance lock acquired after the holder died")
            case .heldBy:
                fputs("FAIL: SIGKILL must release the kernel-owned lock\n", stderr)
                exit(1)
            case .unavailable(let detail):
                fputs("FAIL: lock unavailable: \(detail)\n", stderr)
                exit(1)
            }

        case "release-in-process":
            let directory = directory()
            guard case .acquired(let first) = DshInstanceLock.acquire(at: directory, holder: holder()) else {
                fputs("FAIL: first acquire must succeed\n", stderr)
                exit(1)
            }
            first.release()
            guard case .acquired(let second) = DshInstanceLock.acquire(at: directory, holder: holder()) else {
                fputs("FAIL: an explicit release must free the lock\n", stderr)
                exit(1)
            }
            second.release()
            print("instance lock release and reacquire passed")

        case "isolated-roots":
            let root = directory()
            let first = root.appendingPathComponent("root-a", isDirectory: true)
            let second = root.appendingPathComponent("root-b", isDirectory: true)
            guard case .acquired(let lockA) = DshInstanceLock.acquire(at: first, holder: holder()) else {
                fputs("FAIL: root A must be acquirable\n", stderr)
                exit(1)
            }
            guard case .acquired(let lockB) = DshInstanceLock.acquire(at: second, holder: holder()) else {
                fputs("FAIL: a different Application Support root must not be blocked\n", stderr)
                exit(1)
            }
            lockA.release()
            lockB.release()
            print("instance lock is scoped per Application Support root")

        case "unavailable-when-readonly":
            let root = directory()
            let readonly = root.appendingPathComponent("readonly", isDirectory: true)
            try? FileManager.default.createDirectory(at: readonly, withIntermediateDirectories: true)
            try? FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: readonly.path)
            defer {
                try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: readonly.path)
            }
            switch DshInstanceLock.acquire(at: readonly, holder: holder()) {
            case .unavailable:
                print("instance lock reports an unusable root instead of blocking startup")
            case .acquired(let lock):
                // Running privileged ignores the permission bits; the fail-open
                // path is then simply not exercised.
                lock.release()
                print("instance lock permission probe skipped (running privileged)")
            case .heldBy:
                fputs("FAIL: a read-only root cannot be held by anyone\n", stderr)
                exit(1)
            }

        default:
            fputs("FAIL: unknown scenario \(mode)\n", stderr)
            exit(3)
        }
    }
}
