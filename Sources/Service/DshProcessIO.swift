import Foundation

public enum DshProcessIOError: Error, LocalizedError, Sendable {
    case timedOut(String)
    case processExited(String)
    case runtimeBootstrapFailed(String)
    case generationMismatch
    case policyMismatch
    case endpointConflict
    case invalidEndpoint(String)

    public var errorDescription: String? {
        switch self {
        case .timedOut(let detail):
            return detail.isEmpty ? "等待 DSH 桌面控制握手超时。" : "等待 DSH 桌面控制握手超时：\n\n\(detail)"
        case .processExited(let detail):
            return "DSH 进程在完成桌面控制握手前退出：\n\n\(detail)"
        case .runtimeBootstrapFailed(let detail):
            return detail.isEmpty
                ? "Runtime 插件树加载失败。"
                : "Runtime 插件树加载失败：\n\n\(detail)"
        case .generationMismatch:
            return "DSH 桌面控制代际不匹配。"
        case .policyMismatch:
            return "DSH 桌面浏览器访问策略确认不匹配。"
        case .endpointConflict:
            return "DSH 进程报告了相互冲突的 Web 地址。"
        case .invalidEndpoint(let detail):
            return detail.isEmpty ? "DSH 进程报告了无效的 Web 地址。" : "DSH 进程报告了无效的 Web 地址：\(detail)"
        }
    }
}

/// Drains child stdout/stderr for the complete process lifetime and resolves
/// readiness only after both the structurally validated Web URL and the
/// matching desktop handshake. The authentication mode is discovered from the
/// URL and is validated again by the MainWindowController health gate.
public final class DshProcessIO: @unchecked Sendable {
    private static let readyRegex = try! NSRegularExpression(
        pattern: #"dsh web:\s+(\S+)"#
    )
    private static let controlReadyRegex = try! NSRegularExpression(
        pattern: #"dsh desktop control ready: ([0-9A-Fa-f-]{36})\b"#
    )
    /// A Runtime that cannot load its plugin tree reports this and then stays
    /// alive without ever completing the handshake. Recognizing it turns a
    /// timeout with an unreadable output blob into the reason the Host died.
    /// Anchored at the line start: the producer writes the line itself, so a
    /// longer line that merely quotes it is not a failure.
    private static let bootstrapFailedRegex = try! NSRegularExpression(
        pattern: #"^dsh runtime bootstrap failed:\s*(.+)"#
    )
    private static let missingPackageRegex = try! NSRegularExpression(
        pattern: #"Cannot find package '([^']+)'"#
    )
    private static let policyRegex = try! NSRegularExpression(
        pattern: #"dsh desktop policy applied: ([0-9A-Fa-f-]{36}) (\d+) (true|false) (loopback|lan)\b"#
    )
    /// The Host asks the shell to open the Platform authorization page of a
    /// sign-in that is waiting for approval. Matching the whole line keeps a
    /// Runtime log line that merely quotes the prefix out of the exemption.
    private static let openExternalRegex = try! NSRegularExpression(
        pattern: #"^dsh desktop open external:\s+(\S+)\s*$"#
    )
    private static let maxLogBytes = 256 * 1024

    private let proc: Process
    private let stdoutPipe: Pipe
    private let stderrPipe: Pipe
    private let expectedGeneration: UUID
    private let redactor: DshSecretRedactor
    private let lock = NSLock()

    private var stdoutPartial = ""
    private var stderrPartial = ""
    private var ringBuffer = Data()
    private var webEndpoint: DshWebEndpoint?
    private var controlReadyGeneration: UUID?
    private var readyContinuation: CheckedContinuation<DshWebEndpoint, Error>?
    private var readyTimeoutTask: DispatchWorkItem?
    private var readySettled = false
    private var policyAcks: [Int: (generation: UUID, enabled: Bool, exposure: DshNetworkExposure)] = [:]
    private var policyContinuations: [Int: CheckedContinuation<Void, Error>] = [:]
    private var policyExpectations: [Int: Bool] = [:]
    private var policyExposureExpectations: [Int: DshNetworkExposure] = [:]
    private var policyTimeoutTasks: [Int: DispatchWorkItem] = [:]
    private var terminalError: Error?
    private var started = false
    private var externalURLHandler: (@Sendable (URL) -> Void)?

    public init(
        proc: Process,
        stdoutPipe: Pipe,
        stderrPipe: Pipe,
        expectedGeneration: UUID,
        expectedPort: Int = 3080,
        secrets: [String] = []
    ) {
        self.proc = proc
        self.stdoutPipe = stdoutPipe
        self.stderrPipe = stderrPipe
        self.expectedGeneration = expectedGeneration
        self.expectedPort = expectedPort
        self.redactor = DshSecretRedactor(secrets: secrets)
    }

    private let expectedPort: Int

    /// Install the browser-handoff callback. Set before `start()`; the reading
    /// queue takes it under the same lock that guards the rest of the state.
    public func setExternalURLHandler(_ handler: (@Sendable (URL) -> Void)?) {
        lock.lock()
        externalURLHandler = handler
        lock.unlock()
    }

    public func start() {
        lock.lock()
        guard !started else {
            lock.unlock()
            return
        }
        started = true
        lock.unlock()

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consume(handle.availableData, isStdout: true, handle: handle)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consume(handle.availableData, isStdout: false, handle: handle)
        }
        proc.terminationHandler = { [weak self] terminatedProcess in
            self?.processTerminated(terminatedProcess)
        }
    }

    public func waitForReady(timeout: TimeInterval = 60) async throws -> DshWebEndpoint {
        try await withCheckedThrowingContinuation { continuation in
            var immediateResult: Result<DshWebEndpoint, Error>?
            lock.lock()
            if let terminalError {
                immediateResult = .failure(terminalError)
            } else if let webEndpoint, controlReadyGeneration == expectedGeneration {
                immediateResult = .success(webEndpoint)
            } else {
                readyContinuation = continuation
                let timeoutTask = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.failReady(DshProcessIOError.timedOut(self.diagnosticOutput()))
                }
                readyTimeoutTask = timeoutTask
                DispatchQueue.global(qos: .utility).asyncAfter(
                    deadline: .now() + timeout,
                    execute: timeoutTask
                )
            }
            lock.unlock()

            if let immediateResult {
                continuation.resume(with: immediateResult)
            }
        }
    }

    public func diagnosticOutput() -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: ringBuffer, encoding: .utf8) ?? ""
    }

    /// One readable reason out of the Runtime's bootstrap failure line: what the
    /// failure means when it is recognizable, then the line itself, both capped
    /// so a single long line cannot fill the diagnostic panel.
    private static func bootstrapFailureDetail(_ reason: String) -> String {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let capped = trimmed.count > 600 ? String(trimmed.prefix(600)) + "…" : trimmed
        if let hint = nativeModuleMismatchHint(capped) {
            return "\(hint)\n\n\(capped)"
        }
        let range = NSRange(capped.startIndex..., in: capped)
        guard let match = missingPackageRegex.firstMatch(in: capped, range: range),
              let packageRange = Range(match.range(at: 1), in: capped) else {
            return capped
        }
        return "找不到包 \(String(capped[packageRange]))。\n\n\(capped)"
    }

    /// What a plugin tree failed on when a prebuilt native module is the cause.
    ///
    /// Plugins are installed with `--ignore-scripts` (see `DshPluginManager`),
    /// so nothing is compiled locally: a package that ships a `.node` binary is
    /// tied to the Node ABI, and to the CPU architecture, it was built for. An
    /// App update changes the bundled Node while the Profile keeps the packages
    /// installed for the previous one, and Node then reports the mismatch in
    /// terms of `NODE_MODULE_VERSION` — which says nothing about what the user
    /// can do about it.
    public enum NativeModuleFailure: Equatable, Sendable {
        /// Built for another Node.js ABI (`NODE_MODULE_VERSION`).
        case nodeVersion
        /// Built for another CPU architecture.
        case architecture
        /// The `.node` binary the loader asked for is not there.
        case missingBinary
        /// The `.node` binary is there, but a library it loads is not.
        case missingDependency

        /// One line to lead the recovery surface with.
        public var summary: String {
            switch self {
            case .nodeVersion:
                return "插件的原生模块与当前内置的 Node.js 版本不匹配。"
            case .architecture:
                return "插件的原生模块是另一个 CPU 架构的二进制。"
            case .missingBinary:
                return "插件的原生模块缺失。"
            case .missingDependency:
                return "插件的原生模块缺少它依赖的库。"
            }
        }

        /// What the user can do about it. Three of the four are a binary built
        /// for the wrong Node or the wrong CPU, which a reinstall replaces; a
        /// missing dependency is a library the module loads, which reinstalling
        /// the plugin does not necessarily restore — promising it would send the
        /// user in a circle.
        public var remedy: String {
            switch self {
            case .nodeVersion, .architecture, .missingBinary:
                return "在「设置 → 插件」重新安装受影响的插件即可获取匹配的二进制。"
            case .missingDependency:
                return "该库由插件依赖的外部组件提供（常见于 Homebrew 升级或移动后路径失效）："
                    + "先恢复或重新安装它，再重启 DSH。重新安装插件本身通常无法补齐这个库。"
            }
        }
    }

    /// The native-module failure `detail` describes, or nil when it is something
    /// else — a missing host package, for instance, which has its own remedy.
    public static func nativeModuleFailure(in detail: String) -> NativeModuleFailure? {
        let lowered = detail.lowercased()
        let abiSignals = [
            "node_module_version",
            "was compiled against a different node.js version",
        ]
        if abiSignals.contains(where: lowered.contains) {
            return .nodeVersion
        }
        if lowered.contains("incompatible architecture") {
            return .architecture
        }
        // "Library not loaded: …/libfoo.dylib" means the loader found the module
        // and failed inside it, not that the module is gone. It is only this
        // failure when the output shows a dyld dependency structure — a library
        // it could not load, or the module it was referenced from — because
        // `dlopen(<the .node path>): image not found` carries `image not found`
        // too and means the opposite: the module itself is not there.
        //
        // The signal also has to sit inside a native-module load: the same two
        // sentences describe a missing page asset, and reporting those as a
        // broken native module would send the user to reinstall the wrong thing.
        let dependencySignals = ["library not loaded", "image not found"]
        let nativeModuleContext = lowered.contains("dlopen") || lowered.contains(".node")
        let dependencyStructure = lowered.contains("library not loaded")
            || lowered.contains("referenced from")
        if nativeModuleContext, dependencyStructure, dependencySignals.contains(where: lowered.contains) {
            return .missingDependency
        }
        // A `.node` binary that is absent fails at load time with `dlopen`, and
        // the path is part of the signal so a missing ordinary dylib is not
        // filed here.
        if lowered.contains("dlopen"), lowered.contains(".node"),
           (lowered.contains("no such file or directory") || lowered.contains("image not found")) {
            return .missingBinary
        }
        return nil
    }

    /// What to do about the failure `detail` describes, or nil when it carries
    /// no native-module signal.
    public static func nativeModuleMismatchHint(_ detail: String) -> String? {
        guard let failure = nativeModuleFailure(in: detail) else { return nil }
        return "\(failure.summary)\(failure.remedy)"
    }

    /// Whether `detail` carries a native-module signal.
    public static func isNativeModuleMismatch(_ detail: String) -> Bool {
        nativeModuleFailure(in: detail) != nil
    }

    public func waitForPolicyApplied(
        generation: UUID,
        revision: Int,
        ordinaryBrowserEnabled: Bool,
        networkExposure: DshNetworkExposure,
        timeout: TimeInterval = 10
    ) async throws {
        guard generation == expectedGeneration, revision >= 1 else {
            throw DshProcessIOError.policyMismatch
        }

        try await withCheckedThrowingContinuation { continuation in
            var immediateResult: Result<Void, Error>?
            lock.lock()
            if let terminalError {
                immediateResult = .failure(terminalError)
            } else if let ack = policyAcks.removeValue(forKey: revision) {
                immediateResult = ack.generation == generation && ack.enabled == ordinaryBrowserEnabled && ack.exposure == networkExposure
                    ? .success(())
                    : .failure(DshProcessIOError.policyMismatch)
            } else if policyContinuations[revision] != nil {
                immediateResult = .failure(DshProcessIOError.policyMismatch)
            } else {
                policyContinuations[revision] = continuation
                policyExpectations[revision] = ordinaryBrowserEnabled
                policyExposureExpectations[revision] = networkExposure
                let timeoutTask = DispatchWorkItem { [weak self] in
                    self?.failPolicy(revision: revision, error: DshProcessIOError.timedOut(self?.diagnosticOutput() ?? ""))
                }
                policyTimeoutTasks[revision] = timeoutTask
                DispatchQueue.global(qos: .utility).asyncAfter(
                    deadline: .now() + timeout,
                    execute: timeoutTask
                )
            }
            lock.unlock()

            if let immediateResult {
                continuation.resume(with: immediateResult)
            }
        }
    }

    public func fail(_ error: Error) {
        failReady(error)
    }

    private func consume(_ data: Data, isStdout: Bool, handle: FileHandle) {
        guard !data.isEmpty else {
            handle.readabilityHandler = nil
            finishPartial(isStdout: isStdout)
            return
        }
        guard let chunk = String(data: data, encoding: .utf8) else {
            appendLog("[非 UTF-8 输出已忽略]")
            return
        }

        var lines: [String] = []
        lock.lock()
        if isStdout {
            stdoutPartial.append(chunk)
            while let newline = stdoutPartial.firstIndex(of: "\n") {
                lines.append(String(stdoutPartial[..<newline]).trimmingCharacters(in: .newlines))
                stdoutPartial.removeSubrange(...newline)
            }
        } else {
            stderrPartial.append(chunk)
            while let newline = stderrPartial.firstIndex(of: "\n") {
                lines.append(String(stderrPartial[..<newline]).trimmingCharacters(in: .newlines))
                stderrPartial.removeSubrange(...newline)
            }
        }
        for line in lines where !(isStdout && Self.isOpenExternalLine(line)) {
            // The browser handoff is an instruction to the shell, not output to
            // keep: an authorization URL in the diagnostic bundle would outlive
            // the attempt it belongs to.
            let redacted = redactor.redactDiagnostic(line)
            ringBuffer.append(contentsOf: Data((redacted + "\n").utf8))
        }
        if ringBuffer.count > Self.maxLogBytes {
            ringBuffer.removeFirst(ringBuffer.count - Self.maxLogBytes)
        }
        lock.unlock()

        for line in lines {
            inspect(line, isStdout: isStdout)
        }
    }

    /// Whether this stdout line is the browser handoff rather than output.
    static func isOpenExternalLine(_ line: String) -> Bool {
        let normalizedLine = DshSecretRedactor.stripANSI(line)
        let range = NSRange(normalizedLine.startIndex..., in: normalizedLine)
        return Self.openExternalRegex.firstMatch(in: normalizedLine, range: range) != nil
    }

    /// Whether the shell may hand this URL to the user's browser: HTTPS, a real
    /// host, and no credentials or fragment embedded in it — the same bar the
    /// shell applies to any external link. A deployment that points the account
    /// provider at a loopback HTTP origin can still sign in through the
    /// copy-link action its UI offers, but the shell never launches a browser at
    /// an `http` URL on its own.
    static func isOpenableExternalURL(_ url: URL) -> Bool {
        guard url.scheme?.caseInsensitiveCompare("https") == .orderedSame,
              let host = url.host,
              !host.isEmpty,
              url.user == nil,
              url.password == nil,
              url.fragment == nil else { return false }
        return true
    }

    /// Hand one Host-named URL to the shell, but only in the shape the shell is
    /// willing to open. The Host validated the URL against the configured
    /// Platform origin before it named it; this is the shell's own check, and a
    /// URL that fails it is dropped rather than reported.
    private func deliverExternalURL(_ raw: String) {
        guard let url = URL(string: raw), Self.isOpenableExternalURL(url) else { return }
        lock.lock()
        let handler = externalURLHandler
        lock.unlock()
        handler?(url)
    }

    /// Whether this process already completed the handshake, either through a
    /// pending wait or before one was registered. A bootstrap failure reported
    /// after that cannot describe this launch, and treating it as terminal
    /// would fail the policy acknowledgement that follows readiness.
    private var hasCompletedHandshake: Bool {
        lock.lock()
        defer { lock.unlock() }
        return readySettled || (webEndpoint != nil && controlReadyGeneration == expectedGeneration)
    }

    private func inspect(_ line: String, isStdout: Bool) {
        let normalizedLine = DshSecretRedactor.stripANSI(line)
        let range = NSRange(normalizedLine.startIndex..., in: normalizedLine)
        // Only stdout can carry the Host's browser handoff. Stderr is where the
        // Runtime reports failures, and a line there must never move the user's
        // browser.
        if isStdout,
           let match = Self.openExternalRegex.firstMatch(in: normalizedLine, range: range),
           let urlRange = Range(match.range(at: 1), in: normalizedLine) {
            deliverExternalURL(String(normalizedLine[urlRange]))
            return
        }
        if let match = Self.bootstrapFailedRegex.firstMatch(in: normalizedLine, range: range),
           let detailRange = Range(match.range(at: 1), in: normalizedLine),
           !hasCompletedHandshake {
            failReady(
                DshProcessIOError.runtimeBootstrapFailed(
                    Self.bootstrapFailureDetail(String(normalizedLine[detailRange]))
                )
            )
            return
        }
        if let match = Self.readyRegex.firstMatch(in: normalizedLine, range: range),
           let urlRange = Range(match.range(at: 1), in: normalizedLine),
           let url = URL(string: String(normalizedLine[urlRange])) {
            do {
                let endpoint = try DshWebEndpoint.parse(url, expectedPort: expectedPort)
                lock.lock()
                guard terminalError == nil else {
                    lock.unlock()
                    return
                }
                let isConflict = webEndpoint != nil && webEndpoint != endpoint
                if !isConflict { webEndpoint = endpoint }
                lock.unlock()
                if isConflict {
                    failReady(DshProcessIOError.endpointConflict)
                } else {
                    resolveReadyIfPossible()
                }
            } catch let error as DshWebEndpointError {
                failReady(DshProcessIOError.invalidEndpoint(error.localizedDescription))
            } catch {
                failReady(DshProcessIOError.invalidEndpoint("解析失败"))
            }
            return
        }

        if let match = Self.controlReadyRegex.firstMatch(in: normalizedLine, range: range),
           let generationRange = Range(match.range(at: 1), in: normalizedLine),
           let generation = UUID(uuidString: String(normalizedLine[generationRange])) {
            lock.lock()
            guard terminalError == nil else {
                lock.unlock()
                return
            }
            controlReadyGeneration = generation
            lock.unlock()
            if generation != expectedGeneration {
                failReady(DshProcessIOError.generationMismatch)
            } else {
                resolveReadyIfPossible()
            }
            return
        }

        if let match = Self.policyRegex.firstMatch(in: normalizedLine, range: range),
           let generationRange = Range(match.range(at: 1), in: normalizedLine),
           let revisionRange = Range(match.range(at: 2), in: normalizedLine),
           let enabledRange = Range(match.range(at: 3), in: normalizedLine),
           let exposureRange = Range(match.range(at: 4), in: normalizedLine),
           let generation = UUID(uuidString: String(normalizedLine[generationRange])),
           let revision = Int(normalizedLine[revisionRange]) {
            let enabled = String(normalizedLine[enabledRange]) == "true"
            guard let exposure = DshNetworkExposure(rawValue: String(normalizedLine[exposureRange])) else { return }
            var continuation: CheckedContinuation<Void, Error>?
            var result: Result<Void, Error> = .success(())
            lock.lock()
            guard terminalError == nil else {
                lock.unlock()
                return
            }
            policyAcks[revision] = (generation, enabled, exposure)
            continuation = policyContinuations.removeValue(forKey: revision)
            let expectedEnabled = policyExpectations.removeValue(forKey: revision)
            let expectedExposure = policyExposureExpectations.removeValue(forKey: revision)
            policyTimeoutTasks.removeValue(forKey: revision)?.cancel()
            if continuation != nil {
                if generation != expectedGeneration {
                    result = .failure(DshProcessIOError.generationMismatch)
                } else if expectedEnabled != enabled || expectedExposure != exposure {
                    result = .failure(DshProcessIOError.policyMismatch)
                }
            }
            lock.unlock()
            continuation?.resume(with: result)
        }
    }

    private func resolveReadyIfPossible() {
        lock.lock()
        guard !readySettled,
              terminalError == nil,
              let webEndpoint,
              controlReadyGeneration == expectedGeneration,
              let continuation = readyContinuation else {
            lock.unlock()
            return
        }
        readySettled = true
        readyContinuation = nil
        readyTimeoutTask?.cancel()
        readyTimeoutTask = nil
        lock.unlock()
        continuation.resume(returning: webEndpoint)
    }

    private func failReady(_ error: Error) {
        var readyContinuation: CheckedContinuation<DshWebEndpoint, Error>?
        var policyContinuations: [CheckedContinuation<Void, Error>] = []
        lock.lock()
        if terminalError == nil { terminalError = error }
        if !readySettled {
            readySettled = true
            readyContinuation = self.readyContinuation
            self.readyContinuation = nil
            readyTimeoutTask?.cancel()
            readyTimeoutTask = nil
        }
        policyContinuations = Array(self.policyContinuations.values)
        self.policyContinuations.removeAll()
        self.policyExpectations.removeAll()
        self.policyExposureExpectations.removeAll()
        for task in policyTimeoutTasks.values { task.cancel() }
        policyTimeoutTasks.removeAll()
        lock.unlock()
        readyContinuation?.resume(throwing: error)
        for continuation in policyContinuations { continuation.resume(throwing: error) }
    }

    private func failPolicy(revision: Int, error: Error) {
        lock.lock()
        let continuation = policyContinuations.removeValue(forKey: revision)
        policyExpectations.removeValue(forKey: revision)
        policyExposureExpectations.removeValue(forKey: revision)
        policyTimeoutTasks.removeValue(forKey: revision)
        lock.unlock()
        continuation?.resume(throwing: error)
    }


    private func processTerminated(_ terminatedProcess: Process) {
        let detail = "退出码 \(terminatedProcess.terminationStatus)，信号 \(terminatedProcess.terminationReason.rawValue)\n\(diagnosticOutput())"
        failReady(DshProcessIOError.processExited(detail))
    }

    private func appendLog(_ line: String) {
        lock.lock()
        let redacted = redactor.redactDiagnostic(line)
        ringBuffer.append(contentsOf: Data((redacted + "\n").utf8))
        if ringBuffer.count > Self.maxLogBytes {
            ringBuffer.removeFirst(ringBuffer.count - Self.maxLogBytes)
        }
        lock.unlock()
    }

    private func finishPartial(isStdout: Bool) {
        var line: String?
        lock.lock()
        if isStdout, !stdoutPartial.isEmpty {
            line = stdoutPartial
            stdoutPartial = ""
        } else if !isStdout, !stderrPartial.isEmpty {
            line = stderrPartial
            stderrPartial = ""
        }
        if let line {
            // A trailing partial line reaches the same routing and the same
            // exemption: the handoff may be the last thing the Host writes.
            if !(isStdout && Self.isOpenExternalLine(line)) {
                let redacted = redactor.redactDiagnostic(line)
                ringBuffer.append(contentsOf: Data((redacted + "\n").utf8))
            }
            if ringBuffer.count > Self.maxLogBytes {
                ringBuffer.removeFirst(ringBuffer.count - Self.maxLogBytes)
            }
        }
        lock.unlock()
        if let line { inspect(line, isStdout: isStdout) }
    }
}
