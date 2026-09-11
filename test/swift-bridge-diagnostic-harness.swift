import Foundation

@main
struct DshBridgeDiagnosticHarness {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("bridge/diagnostic assertion failed: \(message)\n", stderr)
            exit(1)
        }
    }

    static func makeBody(
        type: String,
        launchID: UUID,
        generationID: UUID,
        payload: Any? = nil,
        extra: [String: Any] = [:]
    ) -> [String: Any] {
        var body: [String: Any] = [
            "type": type,
            "launchID": launchID.uuidString,
            "generationID": generationID.uuidString
        ]
        if let payload { body["payload"] = payload }
        for (key, value) in extra { body[key] = value }
        return body
    }

    static func main() throws {
        let launchID = UUID(uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA")!
        let generationID = UUID(uuidString: "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB")!
        let origin = DshBridgeOrigin(scheme: "http", host: "127.0.0.1", port: 4321)
        let expectedWebView = DshBridgeWebViewIdentity(rawValue: 42)
        var current: DshBridgeValidationContext? = DshBridgeValidationContext(
            webViewIdentity: expectedWebView,
            launchID: launchID,
            generationID: generationID,
            origin: origin
        )
        let validator = DshBridgeMessageValidator(currentContext: { current })

        func incoming(
            body: Any,
            handler: String = "dshDesktop",
            mainFrame: Bool = true,
            webView: DshBridgeWebViewIdentity? = expectedWebView,
            messageOrigin: DshBridgeOrigin = origin
        ) -> DshBridgeIncomingMessage {
            DshBridgeIncomingMessage(
                handlerName: handler,
                isMainFrame: mainFrame,
                webViewIdentity: webView,
                origin: messageOrigin,
                body: body
            )
        }

        let validReady = validator.validate(incoming(body: makeBody(
            type: "ready", launchID: launchID, generationID: generationID
        )))
        if case .success(let message) = validReady {
            require(message.type == .ready, "ready should be accepted")
        } else { require(false, "ready should be accepted") }

        let validTheme = validator.validate(incoming(body: makeBody(
            type: "theme", launchID: launchID, generationID: generationID,
            payload: ["colorScheme": "dark", "externalTheme": "default"]
        )))
        require({ if case .success = validTheme { return true }; return false }(), "theme should be accepted")

        // The desktop-host bridge (`assets/dsh-desktop-host/client.js`) sends
        // `{colorScheme, preference, externalTheme}` and reports a missing
        // external theme as null. The validator used to whitelist only
        // colorScheme/externalTheme, which silently rejected every theme
        // update and left the ready-time fallback as the only path.
        let themeWithPreference = validator.validate(incoming(body: makeBody(
            type: "theme", launchID: launchID, generationID: generationID,
            payload: ["colorScheme": "dark", "preference": "dark", "externalTheme": "default"]
        )))
        require(
            { if case .success = themeWithPreference { return true }; return false }(),
            "theme with the plugin's preference field should be accepted"
        )

        let themeWithNullExternal = validator.validate(incoming(body: makeBody(
            type: "theme", launchID: launchID, generationID: generationID,
            payload: ["colorScheme": "light", "preference": "light", "externalTheme": NSNull()]
        )))
        if case .success(let message) = themeWithNullExternal {
            require(message.type == .theme, "a null externalTheme must stay a theme message")
        } else {
            require(false, "a null externalTheme should be accepted")
        }

        // The desktop-host bridge also reports a task that is blocked waiting
        // for the user (an approval prompt or an agent question) with the same
        // payload plus `kind`/`reason`. Those must reach the notification path
        // instead of being rejected as unknown fields.
        let needsInput = validator.validate(incoming(body: makeBody(
            type: "notify", launchID: launchID, generationID: generationID,
            payload: ["sessionId": "s1", "kind": "needs-input", "reason": "需要执行 sudo 命令"]
        )))
        if case .success(let message) = needsInput {
            require(message.type == .notify, "a needs-input notification must stay a notify message")
        } else {
            require(false, "a needs-input notification should be accepted")
        }

        let needsApproval = validator.validate(incoming(body: makeBody(
            type: "notify", launchID: launchID, generationID: generationID,
            payload: ["sessionId": "s1", "kind": "needs-approval", "reason": "覆盖文件需要确认"]
        )))
        if case .success(let message) = needsApproval {
            require(message.type == .notify, "a needs-approval notification must stay a notify message")
        } else {
            require(false, "a needs-approval notification should be accepted")
        }

        let needsReview = validator.validate(incoming(body: makeBody(
            type: "notify", launchID: launchID, generationID: generationID,
            payload: ["sessionId": "s1", "kind": "needs-review", "reason": "通知去重方案"]
        )))
        if case .success(let message) = needsReview {
            require(message.type == .notify, "a needs-review notification must stay a notify message")
        } else {
            require(false, "a needs-review notification should be accepted")
        }

        let completionOnly = validator.validate(incoming(body: makeBody(
            type: "notify", launchID: launchID, generationID: generationID,
            payload: ["title": "任务", "sessionId": "s1", "completedAt": 1234]
        )))
        require(
            { if case .success = completionOnly { return true }; return false }(),
            "a completion notification without kind/need must stay accepted"
        )

        func failure(_ result: Result<DshBridgeValidatedMessage, DshBridgeMessageValidationError>, _ expected: DshBridgeMessageValidationError, _ label: String) {
            guard case .failure(let error) = result else {
                require(false, "\(label) should be rejected")
                return
            }
            require(error == expected, "\(label) rejected with \(error), expected \(expected)")
        }

        failure(validator.validate(incoming(body: makeBody(
            type: "ready", launchID: launchID, generationID: generationID), mainFrame: false)), .notMainFrame, "iframe")
        failure(validator.validate(incoming(body: makeBody(
            type: "ready", launchID: launchID, generationID: generationID), webView: DshBridgeWebViewIdentity(rawValue: 99))), .webViewMismatch, "old WebView")
        failure(validator.validate(incoming(body: makeBody(
            type: "ready", launchID: launchID, generationID: generationID), messageOrigin: DshBridgeOrigin(scheme: "http", host: "127.0.0.1", port: 4322))), .wrongOriginPort, "wrong port")
        failure(validator.validate(incoming(body: makeBody(
            type: "ready", launchID: UUID(), generationID: generationID))), .launchMismatch, "old launch")
        failure(validator.validate(incoming(body: makeBody(
            type: "ready", launchID: launchID, generationID: UUID()))), .generationMismatch, "old generation")
        failure(validator.validate(incoming(body: makeBody(
            type: "ready", launchID: launchID, generationID: generationID,
            extra: ["unexpected": "field"]))), .unsupportedBodyField("unexpected"), "unknown body field")
        failure(validator.validate(incoming(body: makeBody(
            type: "theme", launchID: launchID, generationID: generationID,
            payload: ["unknown": "field"]))), .unsupportedPayloadField("unknown"), "unknown payload field")
        failure(validator.validate(incoming(body: makeBody(
            type: "ready", launchID: launchID, generationID: generationID,
            payload: ["unexpected": "value"]))), .payloadForbidden, "payload on ready")
        failure(validator.validate(incoming(body: makeBody(
            type: "notify", launchID: launchID, generationID: generationID,
            payload: ["title": 42]))), .invalidPayload, "wrong payload value type")
        failure(validator.validate(incoming(body: makeBody(
            type: "notify", launchID: launchID, generationID: generationID,
            payload: ["kind": "unknown-kind"]))), .invalidPayload, "unknown notify kind")
        failure(validator.validate(incoming(body: makeBody(
            type: "notify", launchID: launchID, generationID: generationID,
            payload: ["kind": "needs-input", "reason": 7]))), .invalidPayload, "non-string notify reason")
        failure(validator.validate(incoming(body: makeBody(
            type: "unknown", launchID: launchID, generationID: generationID))), .unknownType, "unknown message")
        failure(validator.validate(incoming(body: makeBody(
            type: "debug", launchID: launchID, generationID: generationID, payload: "debug"))), .messageNotAllowed, "debug in normal capability")

        current = DshBridgeValidationContext(
            webViewIdentity: expectedWebView,
            launchID: launchID,
            generationID: generationID,
            origin: origin,
            allowedMessageTypes: DshBridgeMessageType.recoveryCapability
        )
        let recoveryReady = validator.validate(incoming(body: makeBody(
            type: "ready", launchID: launchID, generationID: generationID
        )))
        require({ if case .success = recoveryReady { return true }; return false }(), "recovery ready should be accepted")
        failure(validator.validate(incoming(body: makeBody(
            type: "debug", launchID: launchID, generationID: generationID, payload: "debug"))), .messageNotAllowed, "debug in recovery capability")

        let context = DshDiagnosticLaunchContext(
            launchID: launchID,
            generationID: generationID,
            runtimeVersion: "1.2.3",
            profile: "swift-desktop",
            startedAt: Date(timeIntervalSince1970: 100)
        )
        let token = String(repeating: "a", count: 43)
        let record = DshDiagnosticRecord(
            launchID: launchID,
            generationID: generationID,
            runtimeVersion: "1.2.3",
            profile: "swift-desktop",
            timestamp: Date(timeIntervalSince1970: 101),
            phase: .connectionValidation,
            code: .connectionFailed,
            summary: "连接失败 token=\(token)",
            technicalDetail: "Cookie: session=short-cookie; path=/Users/alice/private/project",
            retryability: .retryable,
            source: .healthCheck,
            evidence: [DshDiagnosticEvidence(
                source: .pluginInspector,
                confidence: .suspected,
                summary: "插件异常",
                pluginName: "sample-plugin",
                generationID: generationID
            )]
        )
        let snapshot = DshDiagnosticSnapshot(
            context: context,
            phase: .connectionValidation,
            records: [record],
            log: String(repeating: "日志 ", count: 20_000)
                + "\nauthorization: short-token\nCookie: session=short-cookie\n/Users/alice/private/project\n",
            generatedAt: Date(timeIntervalSince1970: 102)
        )
        let exporter = DshDiagnosticExporter(
            limits: DshDiagnosticExportLimits(
                maximumRecords: 4,
                maximumPlugins: 4,
                maximumLogBytes: 8 * 1024,
                maximumFieldBytes: 1024,
                maximumPreviewBytes: 64 * 1024
            ),
            redactor: DshSecretRedactor(secrets: ["short-token"]),
            pathPrefixes: ["/Users/alice"]
        )
        let metadata = DshDiagnosticExportMetadata(
            appVersion: "1.0.0",
            buildNumber: "7",
            runtimeVersion: "1.2.3",
            systemArchitecture: "arm64",
            operatingSystem: "macOS test",
            plugins: [DshDiagnosticExportPlugin(name: "sample-plugin", version: "2.0.0")]
        )
        let preview = try exporter.preview(snapshot: snapshot, metadata: metadata)
        require(preview.schemaVersion == 1, "preview schema version")
        require(preview.byteCount == Data(preview.json.utf8).count, "preview byte count")
        require(preview.byteCount <= 64 * 1024, "preview is bounded")
        require(!preview.json.contains(token), "token is redacted")
        require(!preview.json.contains("short-cookie"), "cookie is redacted")
        require(!preview.json.contains("/Users/alice"), "user path is redacted")
        require(preview.json.contains("[USER_HOME]"), "path marker is present")
        require(preview.json.contains("sample-plugin"), "plugin metadata is retained")

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsh-bridge-diagnostic-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("report.json")
        let plan = try exporter.makePlan(snapshot: snapshot, metadata: metadata, suggestedFilename: "report.json")
        require(!FileManager.default.fileExists(atPath: destination.path), "plan does not create a file")
        try plan.writeAtomically(to: destination)
        require(FileManager.default.fileExists(atPath: destination.path), "explicit write creates the file")
        let writtenData = try Data(contentsOf: destination)
        require(writtenData == plan.data, "atomic file contains planned bytes")

        print("swift bridge and diagnostic harness passed")
    }
}
