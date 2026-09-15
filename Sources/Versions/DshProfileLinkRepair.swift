import Foundation

/// Keeps a Profile's own dependency links working across a Runtime change.
///
/// The Profile workspace (`<DSH home>/profiles`) links the packages its plugins
/// import into the managed Runtime that installed them
/// (`<App Support>/DSH/dsh-versions/<version>`). Deleting that Runtime — the
/// normal end of a version transaction — turns every one of those links into
/// `Cannot find package …` while the Host loads its plugin tree, and the App can
/// only observe the result as a desktop-handshake timeout. This type answers
/// the question that cleanup actually needs answered: which links resolve
/// through the Runtime about to be removed, and can each of them be re-pointed
/// at a Runtime that stays.
///
/// Two properties matter more than coverage here:
///
/// - **Package identity, not store path.** pnpm's virtual store names a
///   directory after the package *and* the exact build it resolved
///   (`.pnpm/@scope+pkg@1.0.0_<hash>/node_modules/@scope/pkg`), so the literal
///   path only exists in the Runtime that pinned that build. A candidate is
///   therefore also asked for the package's own path — its `node_modules` root
///   entry, then its hoisted store copy — before a link counts as unsatisfiable.
/// - **All or nothing.** A Profile whose packages resolve through two Runtimes
///   at once is the state that breaks plugin loading, so a pass that cannot
///   place every link it owns moves none of them, and the caller keeps the
///   Runtime the Profile was installed against.
///
/// Only links are touched, and only links whose target names a path inside the
/// managed versions directory. Package contents, lockfiles, `.pnpm` stores, and
/// the Profile's own dependency declarations are never read for validity or
/// rewritten: the next `pnpm install` owns those.
public enum DshProfileLinkRepair {
    /// The links one repair pass moved, and the ones it could not move.
    public struct Outcome: Equatable, Sendable {
        /// Absolute paths of the links that now resolve through a candidate.
        public let repointed: [String]
        /// Absolute paths of the links that still resolve through the source
        /// Runtime because no candidate supplies the same package.
        public let unresolved: [String]

        public init(repointed: [String] = [], unresolved: [String] = []) {
            self.repointed = repointed
            self.unresolved = unresolved
        }

        /// Whether the Runtime those links named may be removed: anything left
        /// unresolved would resolve through nothing afterwards.
        public var canRemoveSourceRuntime: Bool { unresolved.isEmpty }

        /// Whether the pass found no link that resolves through the source
        /// Runtime at all.
        public var isNoop: Bool { repointed.isEmpty && unresolved.isEmpty }
    }

    /// Re-point every link that resolves through `fromVersion` at the same
    /// package inside a candidate Runtime.
    ///
    /// Moves are all-or-nothing: when any link has no candidate, nothing is
    /// written and that link is reported, so the caller can keep the Runtime
    /// instead of leaving the Profile split across two of them.
    ///
    /// - Parameters:
    ///   - profilesRoot: the `profiles` directory of the DSH home.
    ///   - versionsDirectory: the managed `dsh-versions` directory.
    ///   - fromVersion: the version whose tree is about to be removed.
    ///   - toCandidates: Runtime directories to prefer, in order.
    /// - Returns: the links moved, and the links that pin the old version.
    public static func repointLinks(
        profilesRoot: URL,
        versionsDirectory: URL,
        fromVersion: String,
        toCandidates: [URL],
        fileManager: FileManager = .default
    ) -> Outcome {
        let sourceRuntime = versionsDirectory.appendingPathComponent(fromVersion, isDirectory: true)
        let prefix = PathPrefix(root: sourceRuntime)
        return repair(
            profilesRoot: profilesRoot,
            profiles: nil,
            candidates: toCandidates,
            fileManager: fileManager,
            allOrNothing: true
        ) { target in
            prefix.suffix(of: target)
        }
    }

    /// Re-point every dangling link that names a path inside the managed
    /// versions directory at the corresponding package of `toRuntime`.
    ///
    /// A link left dangling by an earlier cleanup fails deep inside the Host's
    /// plugin loader, so callers run this before launching. This pass is
    /// best-effort rather than all-or-nothing: there is no Runtime to keep, so
    /// every link it can place is an improvement. A link whose package the
    /// target Runtime does not have stays untouched rather than being deleted,
    /// because `pnpm install` is the only writer allowed to decide what the
    /// Profile depends on.
    ///
    /// - Parameters:
    ///   - profilesRoot: the `profiles` directory of the DSH home.
    ///   - versionsDirectory: the managed `dsh-versions` directory.
    ///   - toRuntime: the Runtime directory the App is about to launch.
    ///   - profiles: Profile directories to scan; nil scans every Profile under
    ///     `profilesRoot`. Callers that must not write into a Profile they do
    ///     not own pass the one they are launching. The workspace's hoisted
    ///     `node_modules` is always scanned — it is where a host-provided
    ///     package is linked for every Profile at once.
    /// - Returns: the links moved, and the dangling links still unresolved.
    public static func repairDanglingLinks(
        profilesRoot: URL,
        versionsDirectory: URL,
        toRuntime: URL,
        restrictingTo profiles: [URL]? = nil,
        fileManager: FileManager = .default
    ) -> Outcome {
        let prefix = PathPrefix(root: versionsDirectory)
        return repair(
            profilesRoot: profilesRoot,
            profiles: profiles,
            candidates: [toRuntime],
            fileManager: fileManager,
            allOrNothing: false
        ) { target in
            guard !fileManager.fileExists(atPath: target),
                  let relative = prefix.suffix(of: target),
                  let separator = relative.firstIndex(of: "/") else {
                return nil
            }
            // `relative` is `<version>/node_modules/…`; the candidate root
            // replaces the version segment.
            return String(relative[relative.index(after: separator)...])
        }
    }

    /// One link this pass intends to move.
    private struct Move {
        let link: URL
        let original: String
        let next: String
    }

    /// Shared pass: scan the Profile's link directories, and for every link the
    /// caller classifies as one this pass owns, plan a move to the first
    /// candidate that carries the same package.
    private static func repair(
        profilesRoot: URL,
        profiles: [URL]?,
        candidates: [URL],
        fileManager: FileManager,
        allOrNothing: Bool,
        suffix: (String) -> String?
    ) -> Outcome {
        var preferred: [URL] = []
        for candidate in candidates {
            let path = candidate.standardizedFileURL.path
            guard !preferred.contains(where: { $0.standardizedFileURL.path == path }),
                  fileManager.fileExists(atPath: path) else { continue }
            preferred.append(candidate)
        }

        // Plan before writing: an all-or-nothing pass must know whether every
        // link can move before the first one leaves the old Runtime.
        var moves: [Move] = []
        var unresolved: [String] = []
        for directory in scannedDirectories(
            profilesRoot: profilesRoot,
            profiles: profiles,
            fileManager: fileManager
        ) {
            for link in links(in: directory, fileManager: fileManager) {
                guard let storedDestination = try? fileManager.destinationOfSymbolicLink(atPath: link.path) else {
                    continue
                }
                let target = absolutePath(of: storedDestination, at: link)
                guard target != link.standardizedFileURL.path,
                      let path = suffix(target) else { continue }
                guard let next = destination(forPackageAt: path, candidates: preferred, fileManager: fileManager) else {
                    unresolved.append(link.standardizedFileURL.path)
                    continue
                }
                moves.append(Move(link: link, original: storedDestination, next: next))
            }
        }

        if allOrNothing, !unresolved.isEmpty {
            return Outcome(repointed: [], unresolved: unresolved)
        }

        var repointed: [String] = []
        var applied: [Move] = []
        for move in moves {
            do {
                try fileManager.removeItem(at: move.link)
            } catch {
                unresolved.append(move.link.standardizedFileURL.path)
                continue
            }
            do {
                try fileManager.createSymbolicLink(atPath: move.link.path, withDestinationPath: move.next)
                repointed.append(move.link.standardizedFileURL.path)
                applied.append(move)
            } catch {
                // Restore the original link so a failed move never deletes a
                // resolution the Profile had before it.
                try? fileManager.createSymbolicLink(atPath: move.link.path, withDestinationPath: move.original)
                unresolved.append(move.link.standardizedFileURL.path)
            }
        }

        if allOrNothing, !unresolved.isEmpty {
            for move in applied.reversed() {
                try? fileManager.removeItem(at: move.link)
                try? fileManager.createSymbolicLink(
                    atPath: move.link.path,
                    withDestinationPath: move.original
                )
            }
            return Outcome(repointed: [], unresolved: unresolved)
        }
        return Outcome(repointed: repointed, unresolved: unresolved)
    }

    /// Where the candidate Runtime keeps the package a link at `path` names, or
    /// nil when no candidate carries it.
    ///
    /// The literal path is asked first so two Runtimes that pinned the same
    /// build keep the exact layout they had. The package's own path comes next,
    /// because a pnpm store directory embeds the version and an install hash —
    /// a link into `.pnpm/<pkg>@<version>_<hash>/node_modules/<pkg>` never
    /// matches a Runtime that pinned a different build, even when that Runtime
    /// carries the very same package.
    private static func destination(
        forPackageAt path: String,
        candidates: [URL],
        fileManager: FileManager
    ) -> String? {
        var relatives = [path]
        if let packagePath = packagePath(in: path) {
            for relative in [
                "node_modules/" + packagePath,
                "node_modules/.pnpm/node_modules/" + packagePath,
            ] where !relatives.contains(relative) {
                relatives.append(relative)
            }
        }
        for candidate in candidates {
            for relative in relatives {
                let next = candidate.appendingPathComponent(relative)
                if fileManager.fileExists(atPath: next.path) {
                    return next.path
                }
            }
        }
        return nil
    }

    /// The package's own path: everything below its last `node_modules`
    /// segment, e.g. `@scope/pkg` for both `node_modules/@scope/pkg` and
    /// `.pnpm/@scope+pkg@1.0.0_hash/node_modules/@scope/pkg`.
    private static func packagePath(in path: String) -> String? {
        guard let range = path.range(of: "node_modules/", options: .backwards) else { return nil }
        let candidate = String(path[range.upperBound...])
        return candidate.isEmpty ? nil : candidate
    }

    /// Directory URLs whose direct entries may link into a Runtime: the
    /// workspace's hoisted `node_modules`, and each selected Profile's
    /// `node_modules` plus the fallback tree the Host materializes beside it.
    private static func scannedDirectories(
        profilesRoot: URL,
        profiles: [URL]?,
        fileManager: FileManager
    ) -> [URL] {
        var directories = [profilesRoot.appendingPathComponent("node_modules", isDirectory: true)]
        let entries: [URL]
        if let profiles {
            entries = profiles
        } else {
            entries = (try? fileManager.contentsOfDirectory(
                at: profilesRoot,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: []
            )) ?? []
        }
        for entry in entries {
            guard let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true,
                  values.isSymbolicLink != true else { continue }
            directories.append(entry.appendingPathComponent("node_modules", isDirectory: true))
            directories.append(
                entry.appendingPathComponent(".dsh-module-fallback", isDirectory: true)
                    .appendingPathComponent("node_modules", isDirectory: true)
            )
        }
        return directories
    }

    /// The links directly inside one of those directories, including one level
    /// of scope directories. Nothing recurses into a package or a `.pnpm`
    /// store: the links that name a Runtime live at exactly these two depths.
    private static func links(in directory: URL, fileManager: FileManager) -> [URL] {
        let entries = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey],
            options: []
        )) ?? []
        var found: [URL] = []
        for entry in entries {
            let values = try? entry.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            if values?.isSymbolicLink == true {
                found.append(entry)
                continue
            }
            guard values?.isDirectory == true, entry.lastPathComponent.hasPrefix("@") else { continue }
            let scoped = (try? fileManager.contentsOfDirectory(
                at: entry,
                includingPropertiesForKeys: [.isSymbolicLinkKey],
                options: []
            )) ?? []
            for candidate in scoped
            where (try? candidate.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
                found.append(candidate)
            }
        }
        return found
    }

    /// Resolve one link's stored destination into an absolute standardized path.
    private static func absolutePath(of destination: String, at link: URL) -> String {
        if destination.hasPrefix("/") {
            return URL(fileURLWithPath: destination).standardizedFileURL.path
        }
        return link.deletingLastPathComponent()
            .appendingPathComponent(destination)
            .standardizedFileURL.path
    }

    /// The part of a link target below one root directory.
    ///
    /// A Runtime reached through a symlinked parent — a `/tmp`-based
    /// `DSH_HOME`, or macOS' `/var` → `/private/var` — records whichever form it
    /// was created with, so the resolved form is compared too. Both forms are
    /// computed once per pass; the resolved one is only consulted when the
    /// literal form does not match.
    private struct PathPrefix {
        private let literal: String
        private let resolved: String?

        init(root: URL) {
            literal = root.standardizedFileURL.path
            let resolvedPath = root.resolvingSymlinksInPath().standardizedFileURL.path
            resolved = resolvedPath == literal ? nil : resolvedPath
        }

        func suffix(of target: String) -> String? {
            if let value = Self.relative(target, under: literal) { return value }
            guard let resolved else { return nil }
            let resolvedTarget = URL(fileURLWithPath: target)
                .resolvingSymlinksInPath()
                .standardizedFileURL
                .path
            return Self.relative(resolvedTarget, under: resolved)
        }

        private static func relative(_ path: String, under root: String) -> String? {
            guard path.hasPrefix(root + "/") else { return nil }
            return String(path.dropFirst(root.count + 1))
        }
    }
}
