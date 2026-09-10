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

private func failAcquired(_ detail: String) -> Never {
    fputs("FAIL: \(detail)\n", stderr)
    exit(1)
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
                failAcquired("a free lock must be acquirable")
            case .blocked(let detail):
                failAcquired("lock blocked: \(detail)")
            case .unavailable(let detail):
                failAcquired("lock unavailable: \(detail)")
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
                failAcquired("a held lock must not be acquired by a second process")
            case .blocked(let detail):
                failAcquired("lock blocked: \(detail)")
            case .unavailable(let detail):
                failAcquired("lock unavailable: \(detail)")
            }

        case "expect-free":
            switch DshInstanceLock.acquire(at: directory(), holder: holder()) {
            case .acquired(let lock):
                lock.release()
                print("instance lock acquired after the holder died")
            case .heldBy:
                failAcquired("SIGKILL must release the kernel-owned lock")
            case .blocked(let detail):
                failAcquired("lock blocked: \(detail)")
            case .unavailable(let detail):
                failAcquired("lock unavailable: \(detail)")
            }

        case "release-in-process":
            let directory = directory()
            guard case .acquired(let first) = DshInstanceLock.acquire(at: directory, holder: holder()) else {
                failAcquired("first acquire must succeed")
            }
            first.release()
            guard case .acquired(let second) = DshInstanceLock.acquire(at: directory, holder: holder()) else {
                failAcquired("an explicit release must free the lock")
            }
            second.release()
            print("instance lock release and reacquire passed")

        case "isolated-roots":
            let root = directory()
            let first = root.appendingPathComponent("root-a", isDirectory: true)
            let second = root.appendingPathComponent("root-b", isDirectory: true)
            guard case .acquired(let lockA) = DshInstanceLock.acquire(at: first, holder: holder()) else {
                failAcquired("root A must be acquirable")
            }
            guard case .acquired(let lockB) = DshInstanceLock.acquire(at: second, holder: holder()) else {
                failAcquired("a different Application Support root must not be blocked")
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
                print("instance lock reports a limited environment instead of blocking startup")
            case .acquired(let lock):
                // Running privileged ignores the permission bits; the fail-open
                // path is then simply not exercised.
                lock.release()
                print("instance lock permission probe skipped (running privileged)")
            case .heldBy:
                failAcquired("a read-only root cannot be held by anyone")
            case .blocked(let detail):
                failAcquired("a limited environment must not be reported as a blocked lock path: \(detail)")
            }

        // A directory planted at the lock path used to surface as a generic
        // `unavailable` (EISDIR through `open`), which the app treats as
        // fail-open — i.e. sabotaging the path silently disabled the
        // single-instance guarantee. It is now a hard failure.
        case "blocked-when-directory":
            let root = directory()
            let lockPath = root.appendingPathComponent(DshInstanceLock.fileName, isDirectory: true)
            try? FileManager.default.createDirectory(at: lockPath, withIntermediateDirectories: true)
            var isDirectory: ObjCBool = false
            require(
                FileManager.default.fileExists(atPath: lockPath.path, isDirectory: &isDirectory) && isDirectory.boolValue,
                "fixture: the directory must exist at the lock path"
            )
            defer { try? FileManager.default.removeItem(at: lockPath) }
            switch DshInstanceLock.acquire(at: root, holder: holder()) {
            case .blocked(let detail):
                require(detail.contains(DshInstanceLock.fileName), "the report must name the lock path")
                print("instance lock refuses a directory at the lock path")
            case .acquired(let lock):
                lock.release()
                failAcquired("a directory at the lock path must not be acquired")
            case .heldBy:
                failAcquired("a directory at the lock path is not a holder")
            case .unavailable(let detail):
                failAcquired("a planted directory must fail closed, not fail open: \(detail)")
            }

        // A symlink is the same class of defeat: `open(..., O_CREAT)` would
        // either lock an unrelated inode or create the link target.
        case "blocked-when-symlink":
            let root = directory()
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let target = root.appendingPathComponent("symlink-target", isDirectory: false)
            try? Data("not a lock".utf8).write(to: target)
            let lockPath = root.appendingPathComponent(DshInstanceLock.fileName, isDirectory: false)
            try? FileManager.default.removeItem(at: lockPath)
            try? FileManager.default.createSymbolicLink(atPath: lockPath.path, withDestinationPath: target.path)
            require(
                (try? FileManager.default.destinationOfSymbolicLink(atPath: lockPath.path)) != nil,
                "fixture: the symlink must exist before the lock is attempted"
            )
            defer {
                try? FileManager.default.removeItem(at: lockPath)
                try? FileManager.default.removeItem(at: target)
            }
            switch DshInstanceLock.acquire(at: root, holder: holder()) {
            case .blocked:
                print("instance lock refuses a symlink at the lock path")
            case .acquired(let lock):
                lock.release()
                failAcquired("a symlink at the lock path must not redirect the lock")
            case .heldBy:
                failAcquired("a symlink at the lock path is not a holder")
            case .unavailable(let detail):
                failAcquired("a planted symlink must fail closed, not fail open: \(detail)")
            }

        // A dangling symlink is the sharpest variant: without the `lstat`
        // check, `O_CREAT` creates the link target and the lock is taken on a
        // file the app never intended to own.
        case "blocked-when-dangling-symlink":
            let root = directory()
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let lockPath = root.appendingPathComponent(DshInstanceLock.fileName, isDirectory: false)
            let target = root.appendingPathComponent("missing-symlink-target", isDirectory: false)
            try? FileManager.default.removeItem(at: lockPath)
            try? FileManager.default.createSymbolicLink(atPath: lockPath.path, withDestinationPath: target.path)
            require(
                (try? FileManager.default.destinationOfSymbolicLink(atPath: lockPath.path)) != nil,
                "fixture: the dangling symlink must exist before the lock is attempted"
            )
            defer {
                try? FileManager.default.removeItem(at: lockPath)
                try? FileManager.default.removeItem(at: target)
            }
            switch DshInstanceLock.acquire(at: root, holder: holder()) {
            case .blocked:
                require(
                    !FileManager.default.fileExists(atPath: target.path),
                    "a blocked lock must not create the symlink target"
                )
                print("instance lock refuses a dangling symlink without creating its target")
            case .acquired(let lock):
                lock.release()
                failAcquired("a dangling symlink at the lock path must not be acquired")
            case .heldBy:
                failAcquired("a dangling symlink at the lock path is not a holder")
            case .unavailable(let detail):
                failAcquired("a planted dangling symlink must fail closed, not fail open: \(detail)")
            }

        default:
            fputs("FAIL: unknown scenario \(mode)\n", stderr)
            exit(3)
        }
    }
}
