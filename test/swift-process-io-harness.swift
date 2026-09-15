import Foundation

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
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
        let script = bootstrapFailure ? bootstrapScript : """
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
        """

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
        io.start()

        do {
            try process.run()
        } catch {
            fputs("FAIL: unable to run fixture: \(error)\n", stderr)
            exit(1)
        }

        if bootstrapFailure {
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
                require(
                    message.contains("@earendil-works/pi-ai"),
                    "bootstrap failure must name the package the Host could not import"
                )
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
