import Foundation
import Darwin

/// Cross-process instance lock for one Application Support root.
///
/// Everything durable lives under `~/Library/Application Support/DSH`
/// (`dsh-state.json`, the runtime and plugin snapshots, the plugin-operation
/// record, the managed service record, and the port), and that root is **not**
/// keyed by `DSH_HOME`: `DSH_HOME` only selects the Profile tree. Two instances
/// therefore overwrite each other's state (whole-file last-writer-wins), race
/// the same Profile tree and port, and can sweep away a peer's only rollback
/// snapshot. One instance per Application Support root is the correct
/// granularity; test harnesses isolate the root through
/// `DSH_TEST_APP_SUPPORT` and keep running in parallel.
///
/// The lock is a POSIX `flock` held for the process lifetime. The kernel
/// releases it on normal exit, a crash, or `SIGKILL`, so there is no
/// stale-lock state to detect and no PID-reuse heuristic to get wrong. The
/// file content is diagnostics only: who holds it and since when.
public final class DshInstanceLock {
    /// Diagnostics written beside the lock. Never used as a decision input:
    /// only the kernel-owned `flock` decides ownership.
    public struct Holder: Codable, Equatable, Sendable {
        public let pid: Int32
        public let appVersion: String
        public let dshHome: String
        public let acquiredAt: Date

        public init(pid: Int32, appVersion: String, dshHome: String, acquiredAt: Date) {
            self.pid = pid
            self.appVersion = appVersion
            self.dshHome = dshHome
            self.acquiredAt = acquiredAt
        }
    }

    public enum Acquisition {
        case acquired(DshInstanceLock)
        /// Another live process holds the lock; the payload is best-effort
        /// diagnostics and may be missing.
        case heldBy(Holder?)
        /// The lock mechanism itself is unavailable (permissions, read-only
        /// file system, unsupported `flock`, descriptor exhaustion...).
        /// Callers decide the policy; the app continues without cross-process
        /// protection and records the detail, because a broken lock file must
        /// not make the app impossible to start.
        case unavailable(String)
    }

    public static let fileName = "dsh-instance.lock"

    private let lock = NSLock()
    private var descriptor: Int32
    public let url: URL

    private init(descriptor: Int32, url: URL) {
        self.descriptor = descriptor
        self.url = url
    }

    deinit {
        release()
    }

    /// Acquire the instance lock for `directory`, writing `holder` as the
    /// diagnostic payload when the lock is taken.
    public static func acquire(at directory: URL, holder: Holder) -> Acquisition {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: directory.path) {
            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                return .unavailable("无法创建应用数据目录：\(error.localizedDescription)")
            }
        }
        let url = directory.appendingPathComponent(fileName, isDirectory: false)
        // O_CLOEXEC matters: without it the managed Node child could inherit
        // the descriptor and keep the lock held after the app itself died.
        let descriptor = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            return .unavailable("无法打开实例锁文件（errno \(errno)）")
        }
        if flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            let existingHolder = readHolder(at: url)
            close(descriptor)
            if code == EWOULDBLOCK {
                return .heldBy(existingHolder)
            }
            return .unavailable("无法获取实例锁（errno \(code)）")
        }
        // The lock is ours; the payload is best-effort diagnostics only.
        writeHolder(holder, to: descriptor)
        return .acquired(DshInstanceLock(descriptor: descriptor, url: url))
    }

    /// Release the lock explicitly (process exit does this anyway).
    public func release() {
        lock.lock()
        let descriptor = self.descriptor
        self.descriptor = -1
        lock.unlock()
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }

    private static func writeHolder(_ holder: Holder, to descriptor: Int32) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(holder) else { return }
        ftruncate(descriptor, 0)
        lseek(descriptor, 0, SEEK_SET)
        _ = data.withUnsafeBytes { buffer in
            write(descriptor, buffer.baseAddress, buffer.count)
        }
    }

    private static func readHolder(at url: URL) -> Holder? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Holder.self, from: data)
    }
}
