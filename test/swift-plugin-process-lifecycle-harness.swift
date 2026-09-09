import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct PluginProcessLifecycleHarness {
    static func main() async throws {
        guard let home = ProcessInfo.processInfo.environment["DSH_HOME"], !home.isEmpty else {
            fputs("FAIL: DSH_HOME is required\n", stderr)
            exit(2)
        }
        let profile = DshPluginManager.profileDirectory(for: .web)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        // Model an already initialized web Profile. `package.json` alone is
        // deliberately classified as existing-uninitialized by the manager;
        // lifecycle tests must reach the pnpm runner rather than exercising
        // the bootstrap safety gate.
        let manifest = #"""
{
  "name": "dsh-profile-web",
  "private": true,
  "dependencies": {},
  "dsh": {
    "profile": {
      "bundles": ["@deepseek-ai/dsh-base", "@deepseek-ai/dsh-web-app"]
    }
  }
}
"""#
        try Data(manifest.utf8)
            .write(to: profile.appendingPathComponent("package.json"), options: .atomic)
        try Data("lockfileVersion: '9.0'\nimporters:\n  .:\n    dependencies: {}\n".utf8)
            .write(to: profile.appendingPathComponent("pnpm-lock.yaml"), options: .atomic)
        let basePackage = profile.appendingPathComponent(
            "node_modules/@deepseek-ai/dsh-base/package.json"
        )
        let webPackage = profile.appendingPathComponent(
            "node_modules/@deepseek-ai/dsh-web-app/package.json"
        )
        try FileManager.default.createDirectory(
            at: basePackage.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: webPackage.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(#"{"name":"@deepseek-ai/dsh-base","version":"1.0.0"}"#.utf8)
            .write(to: basePackage, options: .atomic)
        try Data(#"{"name":"@deepseek-ai/dsh-web-app","version":"1.0.0"}"#.utf8)
            .write(to: webPackage, options: .atomic)

        let manager = DshPluginManager.shared
        let mode = ProcessInfo.processInfo.environment["DSH_FAKE_PNPM_MODE"] ?? ""
        if mode == "bridge-timeout" {
            var failure: Error?
            let started = Date()
            do {
                _ = try await manager.ensureDesktopHostPlugin(
                    registry: "http://127.0.0.1:9",
                    profileDirectory: profile,
                    profile: .web,
                    runtimeVersion: "9.9.9"
                )
            } catch {
                failure = error
            }
            let elapsed = Date().timeIntervalSince(started)
            require(failure != nil, "wedged bridge install must fail on its wall-clock timeout")
            require(elapsed < 5.0, "profile-switch bridge install timeout must be bounded")
            require(
                failure?.localizedDescription.contains("超过最长运行时间") == true,
                "bridge timeout must explain the bounded process failure: \(failure?.localizedDescription ?? "missing error")")
            print("swift plugin process lifecycle \(mode) harness passed")
            return
        }
        if mode == "large-output" {
            var failure: Error?
            do {
                try await manager.addPlugin(
                    spec: "fixture@1.0.0",
                    profileDirectory: profile,
                    profile: .web,
                    registry: "http://127.0.0.1:9"
                )
            } catch {
                failure = error
            }
            let detail = failure?.localizedDescription ?? ""
            require(failure != nil, "large output fixture must fail")
            require(detail.count <= 8_400, "large output diagnostics must stay character-bounded")
            require(Data(detail.utf8).count <= 33_000, "large output diagnostics must stay byte-bounded")
            print("swift plugin process lifecycle \(mode) harness passed")
            return
        }
        let started = Date()
        try await manager.addPlugin(
            spec: "fixture@1.0.0",
            profileDirectory: profile,
            profile: .web,
            registry: "http://127.0.0.1:9"
        )
        let elapsed = Date().timeIntervalSince(started)
        if mode == "child-holds-pipe" {
            // The fake parent exits successfully while its child inherits both
            // output descriptors. The manager must return after a bounded
            // drain instead of waiting forever for EOF from that child.
            require(elapsed < 5.0, "inherited pipe must not block collector completion")
        } else {
            require(elapsed >= 1.0, "silent download fixture must actually remain alive before succeeding")
            require(elapsed < 10.0, "silent download fixture must complete without an inactivity kill")
        }

        print("swift plugin process lifecycle \(mode) harness passed")
    }
}
