import Foundation

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

/// Collects handoffs from the reading queue, which is not the harness's thread.
final class OpenedURLBox: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []

    func append(_ url: URL) {
        lock.lock()
        urls.append(url)
        lock.unlock()
    }

    var contents: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return urls
    }
}

@main
struct ProcessIOHarness {
    static func main() async {
        let generation = UUID(uuidString: "8B5E2C3E-3F3C-4A0E-9B51-4F2B3B7E8C10")!
        let launchToken = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ"
        let rendererToken = "1234567890123456789012345678901234567890123"
        let cookieSecret = "cookie-secret"
        let authorizationSecret = "authorization-secret"
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        let shortJSONSamples = #"{"token":"abc"} {"cookie":"sid=abc"} {"authorization":"Bearer abc"}"#
        let conflict = CommandLine.arguments.contains("--conflict")
        let lateWait = CommandLine.arguments.contains("--late-wait")
        let bootstrapFailure = CommandLine.arguments.contains("--bootstrap-failure")
        let nativeModuleFailure = CommandLine.arguments.contains("--native-module-failure")
        let openExternal = CommandLine.arguments.contains("--open-external")

        // The browser handoff: what the shell refuses matters as much as what it
        // opens, so the decision is checked without a process in the way.
        require(
            DshProcessIO.isOpenableExternalURL(
                URL(string: "https://platform.deepseek.com/dsh/authorize?authorize_id=fixture&theme=light")!
            ),
            "an https Platform authorization page may be opened"
        )
        for refused in [
            "http://platform.deepseek.com/dsh/authorize?authorize_id=fixture",
            "https://user:secret@platform.deepseek.com/dsh/authorize?authorize_id=fixture",
            "https://platform.deepseek.com/dsh/authorize?authorize_id=fixture#fragment",
        ] {
            require(
                !DshProcessIO.isOpenableExternalURL(URL(string: refused)!),
                "the shell must refuse \(refused)"
            )
        }
        require(
            DshProcessIO.isOpenExternalLine(
                "dsh desktop open external: https://platform.deepseek.com/dsh/authorize?authorize_id=fixture"
            ),
            "the handoff line must be recognized"
        )
        require(
            !DshProcessIO.isOpenExternalLine(
                "log: dsh desktop open external: https://platform.deepseek.com/dsh/authorize?authorize_id=fixture"
            ),
            "a log line that only quotes the prefix is not a handoff"
        )

        let legacy = try? DshWebEndpoint.parse(
            URL(string: "http://127.0.0.1:3187/")!,
            expectedPort: 3187
        )
        require(legacy?.authMode == .legacy, "clean root must use legacy mode")
        require(legacy?.bootstrapURL == nil, "legacy endpoint must not have a bootstrap URL")

        let encodedBootstrap = try? DshWebEndpoint.parse(
            URL(string: "http://127.0.0.1:3187/?token=opaque%2Btoken")!,
            expectedPort: 3187
        )
        require(encodedBootstrap?.authMode == .browserTokenCookie, "token root must use token-cookie mode")
        require(encodedBootstrap?.bootstrapURL?.absoluteString.contains("opaque%2Btoken") == true, "encoded bootstrap bytes must be retained")

        for invalidURL in [
            "https://127.0.0.1:3187/",
            "http://localhost:3187/",
            "http://127.0.0.1:3188/",
            "http://user@127.0.0.1:3187/",
            "http://127.0.0.1:3187/app",
            "http://127.0.0.1:3187/#fragment",
            "http://127.0.0.1:3187/?token=one&token=two",
            "http://127.0.0.1:3187/?dsh-auth=wrong"
        ] {
            do {
                _ = try DshWebEndpoint.parse(URL(string: invalidURL)!, expectedPort: 3187)
                require(false, "invalid endpoint accepted: \(invalidURL)")
            } catch {
                // Expected: parser failures expose only a safe reason.
            }
        }

        let secondReady = conflict
            ? "printf 'dsh web: http://127.0.0.1:3187/?token=second-token\\n';"
            : ""
        // The producer writes this line to stderr (`assets/dsh-runtime-bootstrap.mjs`)
        // and then exits; the fixture keeps the process alive so the reported
        // reason is the line rather than the exit.
        let bootstrapScript = """
        printf '%s\\n' "dsh runtime bootstrap failed: dsh: plugin tree failed to load: failed to import loader entry codex-subscription (dsh-codex-subscription): Cannot find package '@earendil-works/pi-ai' imported from /tmp/plugin.js" >&2;
        sleep 5
        """
        // The same producer line, but the failure is a prebuilt native module
        // built for another Node ABI — what an App update can leave behind.
        let nativeModuleScript = """
        printf '%s\\n' "dsh runtime bootstrap failed: dsh: plugin tree failed to load: failed to import loader entry native (dsh-native): Error: The module '/tmp/better_sqlite3.node' was compiled against a different Node.js version using NODE_MODULE_VERSION 115. This version of Node.js requires NODE_MODULE_VERSION 127." >&2;
        sleep 5
        """
        // Recognition is a pure decision; check it without a process in the way.
        require(
            DshProcessIO.nativeModuleFailure(
                in: "Error: The module '/tmp/x.node' was compiled against a different Node.js version using NODE_MODULE_VERSION 115."
            ) == .nodeVersion,
            "an NODE_MODULE_VERSION mismatch is a Node-version failure"
        )
        require(
            DshProcessIO.nativeModuleFailure(
                in: "mach-o file, but is an incompatible architecture (have 'x86_64', need 'arm64e')"
            ) == .architecture,
            "a foreign architecture is an architecture failure"
        )
        require(
            DshProcessIO.nativeModuleFailure(
                in: "dlopen(/tmp/x.node, 0x0001): tried: '/tmp/x.node' (no such file or directory)"
            ) == .missingBinary,
            "a missing .node binary is a missing-binary failure"
        )
        // `image not found` is what dyld says when the module itself is not
        // there, so a bare `dlopen(<the .node>): image not found` is a missing
        // module — not a missing library, which would send the user to restore a
        // Homebrew package that is fine.
        require(
            DshProcessIO.nativeModuleFailure(
                in: "Error: dlopen(/tmp/x.node, 0x0001): image not found"
            ) == .missingBinary,
            "a .node that is not there is a missing binary, however dyld words it"
        )
        // A `.node` that exists but cannot load a library it needs reports the
        // same `dlopen`/`no such file or directory` text as an absent module.
        require(
            DshProcessIO.nativeModuleFailure(
                in: "Error: dlopen(/tmp/better_sqlite3.node, 0x0001): Library not loaded: /opt/homebrew/opt/sqlite/lib/libsqlite3.dylib\n"
                    + "  Referenced from: /tmp/better_sqlite3.node\n"
                    + "  Reason: tried: '/opt/homebrew/opt/sqlite/lib/libsqlite3.dylib' (no such file or directory)"
            ) == .missingDependency,
            "a missing dependency library is not a missing module"
        )
        require(
            DshProcessIO.isNativeModuleMismatch(
                "Error: The module '/tmp/x.node' was compiled against a different Node.js version using NODE_MODULE_VERSION 115."
            ),
            "the boolean form stays available for callers that only branch"
        )
        require(
            !DshProcessIO.isNativeModuleMismatch("Cannot find package '@earendil-works/pi-ai' imported from /tmp/plugin.js"),
            "a missing package is not a native-module failure"
        )
        require(!DshProcessIO.isNativeModuleMismatch(""), "empty detail carries no signal")
        require(
            !DshProcessIO.isNativeModuleMismatch(
                "dlopen(/tmp/libsomething.dylib, 0x0001): tried: '/tmp/libsomething.dylib' (no such file or directory)"
            ),
            "a missing ordinary dylib is not a plugin native module"
        )
        // The dependency sentences describe anything the Host cannot find, so
        // they only count as a native-module failure inside a module load: a
        // missing page asset must not send the user to reinstall a plugin.
        require(
            DshProcessIO.nativeModuleFailure(in: "Error: image not found") == nil,
            "a loose 'image not found' is not a native module"
        )
        require(
            DshProcessIO.nativeModuleFailure(
                in: "Error: Library not loaded: /usr/lib/libSystem.B.dylib"
            ) == nil,
            "a loose 'library not loaded' is not a native module"
        )
        require(
            DshProcessIO.nativeModuleFailure(
                in: "dlopen(/tmp/libsomething.dylib, 0x0001): Library not loaded: /tmp/libother.dylib"
            ) == .missingDependency,
            "a dlopen context is a native-module load, whatever it loads"
        )
        // Each shape says what it is, instead of collapsing into one sentence.
        let summaries = [
            DshProcessIO.NativeModuleFailure.nodeVersion.summary,
            DshProcessIO.NativeModuleFailure.architecture.summary,
            DshProcessIO.NativeModuleFailure.missingBinary.summary,
            DshProcessIO.NativeModuleFailure.missingDependency.summary,
        ]
        require(Set(summaries).count == 4, "the four failures must read differently, saw \(summaries)")
        require(
            summaries.allSatisfy { !$0.isEmpty },
            "every failure needs a summary the recovery surface can lead with"
        )
        // The remedy is not the same story either: a reinstall replaces a binary
        // built for the wrong Node or CPU, but it does not put back a library
        // the module loads, so promising that would send the user in a circle.
        let remedies = [
            DshProcessIO.NativeModuleFailure.nodeVersion.remedy,
            DshProcessIO.NativeModuleFailure.architecture.remedy,
            DshProcessIO.NativeModuleFailure.missingBinary.remedy,
            DshProcessIO.NativeModuleFailure.missingDependency.remedy,
        ]
        require(
            Set(remedies).count == 2,
            "the three binary failures share a remedy and the dependency failure has its own, saw \(remedies)"
        )
        require(
            DshProcessIO.NativeModuleFailure.missingDependency.remedy
                != DshProcessIO.NativeModuleFailure.missingBinary.remedy,
            "a missing library must not be answered with the reinstall advice"
        )
        require(
            !DshProcessIO.NativeModuleFailure.missingDependency.remedy
                .contains("重新安装受影响的插件即可获取匹配的二进制"),
            "the dependency remedy must not promise a reinstall fixes it"
        )

        // One valid handoff on stdout, one the shell must refuse on stdout, and
        // the same line on stderr — where it is output, never an instruction.
        let openExternalScript = """
        printf '%s\\n' 'dsh desktop open external: https://platform.deepseek.com/dsh/authorize?authorize_id=opened&theme=light';
        printf '%s\\n' 'dsh desktop open external: http://platform.deepseek.com/dsh/authorize?authorize_id=refused';
        printf '%s\\n' 'dsh desktop open external: https://platform.deepseek.com/dsh/authorize?authorize_id=stderr-copy' >&2;
        printf 'dsh web: http://127.0.0.1:3187/?token=\(launchToken)\\n';
        printf 'dsh desktop control ready: \(generation.uuidString)\\n';
        sleep 1
        """

        let script = bootstrapFailure
            ? bootstrapScript
            : (nativeModuleFailure
                ? nativeModuleScript
                : (openExternal ? openExternalScript : """
                printf 'dsh web: http://127.0.0.1:3187/?token=\(launchToken)';
                printf '\\033[32m\\n';
                printf 'Cookie: dsh_swift_renderer=\(rendererToken); dsh-auth-fixture=\(cookieSecret)\\n' >&2;
                printf 'Authorization: Bearer \(authorizationSecret)\\n' >&2;
                printf 'URL: http://127.0.0.1:3187/?token=percent%%2Bsecret%%2F%%3D\\n' >&2;
                printf '%s\\n' '\(shortJSONSamples)' >&2;
                printf 'path: \(homePath)/diagnostics\\n' >&2;
                \(secondReady)
                printf 'dsh desktop control ready: \(generation.uuidString)\\n';
                sleep 1
                """))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        let stdout = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdout
        process.standardError = stderrPipe
        let io = DshProcessIO(
            proc: process,
            stdoutPipe: stdout,
            stderrPipe: stderrPipe,
            expectedGeneration: generation,
            expectedPort: 3187,
            secrets: [rendererToken, cookieSecret, authorizationSecret, "percent+secret/="]
        )
        let opened = OpenedURLBox()
        io.setExternalURLHandler { url in opened.append(url) }
        io.start()

        do {
            try process.run()
        } catch {
            fputs("FAIL: unable to run fixture: \(error)\n", stderr)
            exit(1)
        }

        if bootstrapFailure || nativeModuleFailure {
            let started = Date()
            do {
                _ = try await io.waitForReady(timeout: 8)
                require(false, "a bootstrap failure must never be reported as ready")
            } catch let error as DshProcessIOError {
                let message = error.localizedDescription
                require(
                    message.contains("Runtime 插件树加载失败"),
                    "bootstrap failure must name the Runtime plugin tree, saw: \(message)"
                )
                if bootstrapFailure {
                    require(
                        message.contains("@earendil-works/pi-ai"),
                        "bootstrap failure must name the package the Host could not import"
                    )
                }
                if nativeModuleFailure {
                    require(
                        message.contains("原生模块") && message.contains("Node.js 版本不匹配"),
                        "a native-module failure must say what it is, saw: \(message)"
                    )
                    require(
                        !message.contains("找不到包"),
                        "an ABI mismatch must not be reported as a missing package, saw: \(message)"
                    )
                }
                require(
                    Date().timeIntervalSince(started) < 5,
                    "bootstrap failure must fail fast instead of waiting for the handshake timeout"
                )
            } catch {
                require(false, "unexpected bootstrap error: \(error)")
            }
            process.terminate()
            while process.isRunning { usleep(10_000) }
            print("swift process IO endpoint and redaction harness passed")
            return
        }

        if openExternal {
            do {
                _ = try await io.waitForReady(timeout: 8)
            } catch {
                require(false, "the handoff fixture must still complete the handshake: \(error)")
            }
            let urls = opened.contents
            require(urls.count == 1, "exactly one handoff may open, saw \(urls.count)")
            require(
                urls.first?.absoluteString.contains("authorize_id=opened") == true,
                "the opened URL must be the one the Host named"
            )
            let diagnostics = io.diagnosticOutput()
            require(
                !diagnostics.contains("authorize_id=opened"),
                "a handoff the shell acts on must stay out of the diagnostic log"
            )
            require(
                diagnostics.contains("authorize_id=stderr-copy"),
                "a stderr line is output, never an instruction to open a browser"
            )
            process.terminate()
            while process.isRunning { usleep(10_000) }
            print("swift process IO endpoint and redaction harness passed")
            return
        }

        if conflict {
            if lateWait {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            do {
                _ = try await io.waitForReady(timeout: 2)
                require(false, "conflicting ready URLs must fail")
            } catch let error as DshProcessIOError {
                require(error.localizedDescription.contains("冲突"), "conflict should have a safe diagnostic")
            } catch {
                require(false, "unexpected conflict error: \(error)")
            }
        } else {
            do {
                let endpoint = try await io.waitForReady(timeout: 2)
                require(endpoint.authMode == .browserTokenCookie, "token endpoint must use token-cookie mode")
                require(endpoint.originURL.absoluteString == "http://127.0.0.1:3187/", "origin must be clean")
                require(endpoint.bootstrapURL?.absoluteString == "http://127.0.0.1:3187/?token=\(launchToken)", "bootstrap token must be preserved")
            } catch {
                fputs("FAIL: ready fixture failed: \(error)\n", stderr)
                exit(1)
            }
        }

        let diagnostics = io.diagnosticOutput()
        for secret in [launchToken, rendererToken, cookieSecret, authorizationSecret, "percent+secret/=", "percent%2Bsecret%2F%3D"] {
            require(!diagnostics.contains(secret), "diagnostic leaked secret \(secret)")
        }
        require(diagnostics.contains("http://127.0.0.1:3187/"), "diagnostic should retain the safe origin")
        require(diagnostics.contains("[REDACTED]"), "diagnostic should show redaction marker")
        for sample in ["\"abc\"", "sid=abc", "Bearer abc", homePath] {
            require(!diagnostics.contains(sample), "diagnostic leaked short fixture \(sample)")
        }

        process.terminate()
        while process.isRunning { usleep(10_000) }
        print("swift process IO endpoint and redaction harness passed")
    }
}
