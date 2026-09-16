import Foundation

/// The environment a managed child process — the `dsh` service or the bundled
/// pnpm — inherits from this app.
///
/// The app normally launches from Finder, but a terminal launch, or a session
/// started by `npm run` during development, hands it the whole shell
/// environment. Package-manager and Node variables are not this app's runtime
/// configuration: `npm_config_*`, `pnpm_*` and `corepack_*` left over from an
/// unrelated install change how the bundled pnpm resolves, caches and stores
/// packages, and `NODE_PATH` / `NODE_OPTIONS` change how Node loads modules.
/// The archived Electron shell removed the same set before spawning its host
/// process (`host-process.ts:117-119`).
///
/// Everything this shell actually needs — the user PATH, the registry, the
/// isolated store/cache/state, `DSH_HOME`, `DSH_DESKTOP*` — is assigned
/// explicitly after sanitizing, so nothing here can take configuration away
/// from the app itself.
public enum NodeChildEnvironment {
    /// Exact variable names, compared lowercased, that describe the launching
    /// shell rather than the child.
    static let scrubbedNames: Set<String> = ["node_options", "node_path"]

    /// Prefixes, compared lowercased, of a package-manager session. The
    /// trailing underscore is deliberate: `npmlog` or `PNPMFILE` are ordinary
    /// names, while `npm_config_registry`, `NPM_CONFIG_STRICT_SSL`,
    /// `pnpm_config_store_dir`, `PNPM_HOME` and `corepack_home` are all
    /// session configuration.
    static let scrubbedPrefixes = ["npm_", "pnpm_", "corepack_", "dsh_desktop_"]

    /// True when `name` must not reach a managed child.
    public static func isInheritedToolchainVariable(_ name: String) -> Bool {
        let lowered = name.lowercased()
        if scrubbedNames.contains(lowered) { return true }
        return scrubbedPrefixes.contains { lowered.hasPrefix($0) }
    }

    /// `inherited` without the launching shell's toolchain variables. Every
    /// other entry is preserved byte for byte, including `NODE_ENV` and the
    /// user's `HOME` / `TMPDIR` / `LANG`.
    public static func sanitized(_ inherited: [String: String]) -> [String: String] {
        inherited.filter { !isInheritedToolchainVariable($0.key) }
    }
}
