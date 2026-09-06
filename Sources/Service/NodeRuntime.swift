import Foundation

/// Discovers and manages the Node.js runtime, bundled pnpm, and user shell environment.
public final class NodeRuntime {
    public static let shared = NodeRuntime()

    private let lock = NSLock()
    private var resolvedPath: String?

    private init() {
        // Initialize with cached PATH if available
        if let cached = DshStateManager.shared.current.cachedUserPath, !cached.isEmpty {
            self.resolvedPath = cached
        }
    }

    /// Resolve the standalone node executable path.
    public func resolveNodeBinary() -> String? {
        // 1. Inside .app bundle
        if let resourcePath = Bundle.main.resourcePath {
            let bundled = (resourcePath as NSString).appendingPathComponent("node/bin/node")
            if FileManager.default.isExecutableFile(atPath: bundled) {
                return bundled
            }
        }

        // 2. Relative to executable or development root
        let execUrl = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        var searchDir = execUrl.deletingLastPathComponent()
        for _ in 0..<8 {
            let devNode = searchDir.appendingPathComponent("assets/node/bin/node").path
            if FileManager.default.isExecutableFile(atPath: devNode) {
                return devNode
            }
            searchDir.deleteLastPathComponent()
        }

        // 3. Well-known global paths
        for candidate in ["/opt/homebrew/bin/node", "/usr/local/bin/node"] {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }

        // 4. Current process PATH, searched directly without spawning a
        // shell. This covers dev shells, CI and test harnesses
        // deterministically; the login-shell fallback below stays for
        // sparse-PATH contexts such as Finder-launched apps.
        if let pathNode = resolveBinaryFromPATH("node") {
            return pathNode
        }

        // 5. Fallback search via login shell environment
        if let shellNode = resolveBinaryFromShell("node") {
            return shellNode
        }

        return nil
    }

    /// Search the current process PATH without spawning a shell. Skips empty
    /// components and relative entries; the caller still verifies the
    /// executable bit.
    private func resolveBinaryFromPATH(_ name: String) -> String? {
        guard let pathValue = ProcessInfo.processInfo.environment["PATH"] else { return nil }
        for component in pathValue.split(separator: ":") {
            let dir = String(component).trimmingCharacters(in: .whitespacesAndNewlines)
            guard dir.hasPrefix("/"), !dir.contains("..") else { continue }
            let candidate = (dir as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    /// Resolve the bundled pnpm executable path.
    public func resolvePnpmBinary() -> String? {
        if let resourcePath = Bundle.main.resourcePath {
            let bundled = (resourcePath as NSString).appendingPathComponent("assets/bin/pnpm")
            if FileManager.default.isExecutableFile(atPath: bundled) {
                return bundled
            }
        }

        let execUrl = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        var searchDir = execUrl.deletingLastPathComponent()
        for _ in 0..<8 {
            let devPnpm = searchDir.appendingPathComponent("assets/bin/pnpm").path
            if FileManager.default.isExecutableFile(atPath: devPnpm) {
                return devPnpm
            }
            searchDir.deleteLastPathComponent()
        }

        return nil
    }

    /// Resolve bundled assets directory.
    public func resolveAssetsDirectory() -> String? {
        if let resourcePath = Bundle.main.resourcePath {
            let dir = (resourcePath as NSString).appendingPathComponent("assets")
            if FileManager.default.fileExists(atPath: dir) {
                return dir
            }
        }

        let execUrl = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        var searchDir = execUrl.deletingLastPathComponent()
        for _ in 0..<8 {
            let devAssets = searchDir.appendingPathComponent("assets").path
            if FileManager.default.fileExists(atPath: devAssets) {
                return devAssets
            }
            searchDir.deleteLastPathComponent()
        }

        return nil
    }

    /// Resolve bundled dsh-desktop-host plugin directory.
    public func resolveDesktopHostBundlePath() -> String? {
        guard let assets = resolveAssetsDirectory() else { return nil }
        let hostDir = (assets as NSString).appendingPathComponent("dsh-desktop-host")
        return FileManager.default.fileExists(atPath: hostDir) ? hostDir : nil
    }

    /// Resolve the app-owned Node bootstrap that receives the private launch
    /// descriptor before dynamically importing the selected DSH version.
    public func resolveRuntimeBootstrap() -> String? {
        guard let assets = resolveAssetsDirectory() else { return nil }
        let bootstrap = (assets as NSString).appendingPathComponent("dsh-runtime-bootstrap.mjs")
        return FileManager.default.isReadableFile(atPath: bootstrap) ? bootstrap : nil
    }

    /// Resolve the full PATH environment variable from the user's interactive login shell.
    public func resolveUserPath() -> String {
        lock.lock()
        if let cached = resolvedPath {
            lock.unlock()
            // Refresh in background for next launch
            DispatchQueue.global(qos: .utility).async { [weak self] in
                self?.refreshUserPathFromShell()
            }
            return cached
        }
        lock.unlock()

        let fresh = fetchUserPathFromShell()
        lock.lock()
        self.resolvedPath = fresh
        lock.unlock()

        DshStateManager.shared.update { state in
            state.cachedUserPath = fresh
        }
        return fresh
    }

    private func refreshUserPathFromShell() {
        let fresh = fetchUserPathFromShell()
        lock.lock()
        self.resolvedPath = fresh
        lock.unlock()
        DshStateManager.shared.update { state in
            state.cachedUserPath = fresh
        }
    }

    private func fetchUserPathFromShell() -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // Same rule as resolveBinaryFromShell: never run an interactive
        // shell for a machine query. ~/.zshrc session plugins print banners
        // to stdout and race on shared state under concurrency, which used
        // to corrupt this PATH with banner fragments and break every child
        // process lookup (pnpm shebang: `env: node: No such file`). nvm is
        // sourced explicitly so its bin dir stays on the returned PATH.
        proc.arguments = ["-lc", "if [ -n \"${NVM_DIR:-}\" ] && [ -s \"$NVM_DIR/nvm.sh\" ]; then source \"$NVM_DIR/nvm.sh\" >/dev/null 2>&1; elif [ -s \"$HOME/.nvm/nvm.sh\" ]; then source \"$HOME/.nvm/nvm.sh\" >/dev/null 2>&1; fi; print -r -- \"$PATH\""]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice

        var resultPath = ""
        do {
            try proc.run()
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global().async {
                proc.waitUntilExit()
                group.leave()
            }
            if group.wait(timeout: .now() + 3.0) == .success {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let text = String(data: data, encoding: .utf8) ?? ""
                // If any login file still prints noise, it lands on its own
                // lines; the PATH itself is the last non-empty line.
                resultPath = text.split(separator: "\n", omittingEmptySubsequences: true)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .last ?? ""
            } else {
                proc.terminate()
            }
        } catch {
            print("[NodeRuntime] Shell PATH resolution failed:", error)
        }

        var parts = resultPath.split(separator: ":").map(String.init)
        // A corrupted shell answer (banner fragment, single bogus entry)
        // must never become the child-process PATH nor the cached value.
        // Fall back to the current process PATH when nothing usable arrived.
        let hasUsableDir = parts.contains { FileManager.default.fileExists(atPath: $0) }
        if parts.isEmpty || !hasUsableDir {
            let envPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
            let envParts = envPath.split(separator: ":").map(String.init)
            if !envParts.isEmpty {
                parts = envParts
            }
        }

        // Union with the inherited process PATH, inherited-first. The login
        // shell legitimately lacks entries the parent already carries (nvm
        // shims, toolchain bins) and vice versa; either side alone can miss
        // the active node under sparse or VDIsolated environments.
        let inherited = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
            .filter { $0.hasPrefix("/") && !$0.contains("..") }
        if !inherited.isEmpty {
            var merged = inherited
            for part in parts where !merged.contains(part) {
                merged.append(part)
            }
            parts = merged
        }

        let standardDirs = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            (NSHomeDirectory() as NSString).appendingPathComponent(".local/bin"),
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]
        for dir in standardDirs {
            if !parts.contains(dir) && FileManager.default.fileExists(atPath: dir) {
                parts.append(dir)
            }
        }

        // Add bundled bin directory if present
        if let assets = resolveAssetsDirectory() {
            let binDir = (assets as NSString).appendingPathComponent("bin")
            if !parts.contains(binDir) && FileManager.default.fileExists(atPath: binDir) {
                parts.insert(binDir, at: 0)
            }
        }

        return parts.joined(separator: ":")
    }

    private func resolveBinaryFromShell(_ name: String) -> String? {
        // Login-shell init can fail transiently under parallel load (user
        // plugins, nvm init IO, fork pressure). A bounded retry keeps this
        // best-effort lookup stable; the success path takes exactly one shot.
        for attempt in 0..<3 {
            if let found = resolveBinaryFromShellOnce(name) {
                return found
            }
            Thread.sleep(forTimeInterval: 0.2 * Double(attempt + 1))
        }
        return nil
    }

    private func resolveBinaryFromShellOnce(_ name: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // Non-interactive login shell on purpose: interactive shells run
        // user plugins (session managers, banners) that race on shared
        // state when many resolutions happen concurrently and garble
        // stdout, which used to make this lookup randomly fail under
        // parallel test load. nvm is sourced explicitly so nvm-managed
        // binaries still resolve without an interactive shell.
        proc.arguments = ["-lc", "if [ -n \"${NVM_DIR:-}\" ] && [ -s \"$NVM_DIR/nvm.sh\" ]; then source \"$NVM_DIR/nvm.sh\" >/dev/null 2>&1; elif [ -s \"$HOME/.nvm/nvm.sh\" ]; then source \"$HOME/.nvm/nvm.sh\" >/dev/null 2>&1; fi; which \(name)"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice

        guard (try? proc.run()) != nil else { return nil }
        proc.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        // Interactive login shells may print session banners or plugin noise
        // to stdout before which(1) output. Only an absolute-path line can be
        // a candidate; which prints the real result last.
        let path = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.hasPrefix("/") }
            .last ?? ""
        return (!path.isEmpty && FileManager.default.isExecutableFile(atPath: path)) ? path : nil
    }

    /// Build clean child process environment dictionary.
    public func buildEnvironment(customPort: Int? = nil) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = resolveUserPath()
        env["NODE_OPTIONS"] = ""
        env["DSH_DESKTOP"] = "1"
        if let nodeBin = resolveNodeBinary() {
            env["DSH_NODE_BIN"] = nodeBin
        }
        return env
    }
}
