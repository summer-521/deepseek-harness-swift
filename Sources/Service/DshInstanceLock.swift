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
        /// The lock cannot be established for a reason that does **not**
        /// describe an environment limitation: the lock path is occupied by
        /// something that is not this app's regular lock file (directory,
        /// symlink, socket...), or `open`/`flock` failed for an unexpected
        /// reason. Starting anyway would silently drop the single-instance
        /// guarantee, so callers must fail closed.
        case blocked(String)
        /// The environment cannot hold the lock (read-only volume, no write
        /// permission on that path, no space). Callers must fail closed as
        /// well: the failure can be specific to the lock file while the shared
        /// state file stays writable (round-5 reproduction: a `000` mode lock
        /// file next to a writable `dsh-state.json`), so continuing would
        /// silently drop the single-instance guarantee. The value only selects
        /// the diagnostic text.
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
        // `lstat` deliberately: a regular file is the only shape this app ever
        // creates, and it is the only shape `flock` can meaningfully protect.
        // A symlink would redirect the lock to an unrelated inode (or, with
        // `O_CREAT`, create the link target), and a directory fails at `open`
        // with a misleading errno — both are reports of a sabotaged or foreign
        // lock path, not of a limited environment.
        var info = stat()
        let lstatResult = url.path.withCString { lstat($0, &info) }
        if lstatResult == 0, (info.st_mode & S_IFMT) != S_IFREG {
            return .blocked(
                "实例锁路径被非普通文件占用（\(Self.describe(info.st_mode))）：\(url.path)。"
                    + "请移除该对象后重新启动。"
            )
        }
        // O_CLOEXEC matters: without it the managed Node child could inherit
        // the descriptor and keep the lock held after the app itself died.
        // O_NOFOLLOW closes the window between the `lstat` above and this
        // `open`: a path swapped for a symlink in between fails with ELOOP
        // (reported as blocked) instead of redirecting the lock to another
        // inode, or creating the link target with `O_CREAT`.
        let descriptor = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else {
            let code = errno
            return Self.failure(code: code, "无法打开实例锁文件", url: url)
        }
        // Re-check the opened file itself. `lstat` + `O_NOFOLLOW` already
        // reject symlinks, but the descriptor is the object the lock is
        // actually taken on, so verify it directly rather than trusting the
        // path that was inspected a moment ago.
        var opened = stat()
        if fstat(descriptor, &opened) != 0 || (opened.st_mode & S_IFMT) != S_IFREG {
            close(descriptor)
            return .blocked("实例锁路径不是普通文件：\(url.path)。请移除该对象后重新启动。")
        }
        if flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            let existingHolder = readHolder(at: url)
            close(descriptor)
            if code == EWOULDBLOCK {
                return .heldBy(existingHolder)
            }
            return Self.failure(code: code, "无法获取实例锁", url: url)
        }
        // The lock is ours; the payload is best-effort diagnostics only.
        writeHolder(holder, to: descriptor)
        return .acquired(DshInstanceLock(descriptor: descriptor, url: url))
    }

    /// Classify an `open`/`flock` failure. Permission- and capacity-shaped
    /// errors describe an environment that cannot hold the lock at all (and
    /// that equally cannot persist a second instance's state), so they stay
    /// recoverable; everything else means the lock path itself is unusable and
    /// must stop startup.
    private static func failure(code: Int32, _ detail: String, url: URL) -> Acquisition {
        switch code {
        case EACCES, EPERM, EROFS, ENOSPC:
            return .unavailable("\(detail)（errno \(code)）：\(url.path)")
        default:
            return .blocked("\(detail)（errno \(code)）：\(url.path)")
        }
    }

    private static func describe(_ mode: mode_t) -> String {
        switch mode & S_IFMT {
        case S_IFDIR: return "目录"
        case S_IFLNK: return "符号链接"
        case S_IFIFO: return "管道"
        case S_IFSOCK: return "套接字"
        case S_IFCHR, S_IFBLK: return "设备文件"
        default: return "类型 \(mode & S_IFMT)"
        }
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
