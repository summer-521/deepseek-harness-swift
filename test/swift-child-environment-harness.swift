import Foundation

/// Hermetic checks for the environment this app hands to managed Node
/// processes. `NodeChildEnvironment` is pure, so every case here is exact:
/// no shell is spawned, no bundled Node is involved, and nothing is written.
@main
struct NodeChildEnvironmentHarness {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("child environment assertion failed: \(message)\n", stderr)
            exit(1)
        }
    }

    static func main() {
        // A Finder launch carries almost nothing; these cases describe the
        // hostile case — the app started from a developer shell in the middle
        // of an unrelated package-manager session.
        let inherited: [String: String] = [
            // The launching shell's package-manager session.
            "npm_config_registry": "https://mirror.example.test",
            "npm_config_user_agent": "npm/10.9.0 node/v22.0.0",
            "NPM_CONFIG_STRICT_SSL": "false",
            "npm_package_name": "some-unrelated-package",
            "npm_lifecycle_event": "test",
            "pnpm_config_store_dir": "/tmp/unrelated-store",
            "PNPM_HOME": "/tmp/unrelated-pnpm-home",
            "corepack_home": "/tmp/unrelated-corepack",
            "COREPACK_ENABLE_DOWNLOAD_PROMPT": "0",
            // Node module resolution.
            "NODE_OPTIONS": "--require /tmp/injected-hook.js",
            "node_path": "/tmp/injected-modules",
            // A stale marker from a parent launch.
            "DSH_DESKTOP_LAUNCH": "1",
            "DSH_DESKTOP_PORT": "9",
            // Ordinary variables the child keeps untouched.
            "PATH": "/usr/bin:/bin",
            "HOME": "/Users/example",
            "TMPDIR": "/tmp/example",
            "LANG": "zh_CN.UTF-8",
            "DSH_DESKTOP": "1",
            "DSH_HOME": "/Users/example/.dsh",
            "NODE_ENV": "production",
            "npmlog": "kept-without-underscore",
            "PNPMFILE": "kept-without-separator",
            "NODE_OPTIONS_EXTRA": "kept-because-the-name-is-not-exact",
        ]
        let scrubbed = [
            "npm_config_registry",
            "npm_config_user_agent",
            "NPM_CONFIG_STRICT_SSL",
            "npm_package_name",
            "npm_lifecycle_event",
            "pnpm_config_store_dir",
            "PNPM_HOME",
            "corepack_home",
            "COREPACK_ENABLE_DOWNLOAD_PROMPT",
            "NODE_OPTIONS",
            "node_path",
            "DSH_DESKTOP_LAUNCH",
            "DSH_DESKTOP_PORT",
        ]
        let kept = [
            "PATH",
            "HOME",
            "TMPDIR",
            "LANG",
            "DSH_DESKTOP",
            "DSH_HOME",
            "NODE_ENV",
            "npmlog",
            "PNPMFILE",
            "NODE_OPTIONS_EXTRA",
        ]
        expect(scrubbed.count + kept.count == inherited.count, "every case is classified")

        let sanitized = NodeChildEnvironment.sanitized(inherited)
        for name in scrubbed {
            expect(
                sanitized[name] == nil,
                "\(name) must not reach a managed child, got \(sanitized[name] ?? "<nil>")"
            )
        }
        for name in kept {
            expect(
                sanitized[name] == inherited[name],
                "\(name) must survive sanitizing unchanged, got \(sanitized[name] ?? "<nil>")"
            )
        }
        expect(
            sanitized.count == kept.count,
            "only the launching shell's toolchain variables are removed, got \(sanitized.count) entries"
        )

        // The match is case-insensitive on both spellings of the same variable,
        // because a shell and npm disagree about the case: zsh users export
        // `NPM_CONFIG_*`, npm exports `npm_config_*`.
        for name in ["npm_config_registry", "NPM_CONFIG_REGISTRY", "NoDe_OpTiOnS", "pnpm_home", "DSH_desktop_port"] {
            expect(
                NodeChildEnvironment.isInheritedToolchainVariable(name),
                "\(name) is session toolchain configuration"
            )
        }
        // ...but it is anchored: the underscore in the prefix is what makes a
        // name session configuration instead of an ordinary variable.
        for name in ["npm", "npmlog", "PNPMFILE", "node", "nodeEnv", "DSH_DESKTOP", "PATH", "HOME"] {
            expect(
                !NodeChildEnvironment.isInheritedToolchainVariable(name),
                "\(name) is not session toolchain configuration"
            )
        }

        // An empty inherited environment stays empty instead of inventing keys.
        expect(NodeChildEnvironment.sanitized([:]).isEmpty, "an empty environment stays empty")

        print("swift child environment harness passed")
    }
}
