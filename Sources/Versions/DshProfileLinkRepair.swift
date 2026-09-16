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
    /// The links one repair pass moved, the ones it could not move, and the
    /// places it could not look.
    public struct Outcome: Equatable, Sendable {
        /// Absolute paths of the links that now resolve through a candidate.
        public let repointed: [String]
        /// Absolute paths of the links that still resolve through the source
        /// Runtime because no candidate supplies the same package.
        public let unresolved: [String]
        /// Directories the pass could not read. Without this, a failed listing
        /// is indistinguishable from a Profile that holds no links at all, and
        /// the caller would delete a Runtime the Profile still resolves
        /// through.
        public let scanFailures: [String]
        /// Links whose reverse swap failed while an all-or-nothing pass was
        /// rolling back. The Profile may now resolve through two Runtimes, and
        /// the caller has to be told rather than handed an empty result.
        public let rollbackFailures: [String]

        public init(
            repointed: [String] = [],
            unresolved: [String] = [],
            scanFailures: [String] = [],
            rollbackFailures: [String] = []
        ) {
            self.repointed = repointed
            self.unresolved = unresolved
            self.scanFailures = scanFailures
            self.rollbackFailures = rollbackFailures
        }

        /// Whether the Runtime those links named may be removed: anything left
        /// unresolved would resolve through nothing afterwards, and anything
        /// unread may be a link this pass never saw.
        public var canRemoveSourceRuntime: Bool {
            unresolved.isEmpty && scanFailures.isEmpty && rollbackFailures.isEmpty
        }

        /// Whether the pass found no link that resolves through the source
        /// Runtime at all, and could read everything it needed to.
        public var isNoop: Bool {
            repointed.isEmpty
                && unresolved.isEmpty
                && scanFailures.isEmpty
                && rollbackFailures.isEmpty
        }

        /// Whether the Profile may have been left split across two Runtimes.
        public var leftProfilePartiallyMoved: Bool { !rollbackFailures.isEmpty }
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

    /// Prefix of the sibling link a swap creates before renaming it into place.
    /// The scanner skips it so an interrupted swap never becomes a dependency.
    private static let temporaryLinkPrefix = ".dsh-link-"

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
        var scanFailures: [String] = []
        let scan = scannedDirectories(
            profilesRoot: profilesRoot,
            profiles: profiles,
            fileManager: fileManager
        )
        scanFailures.append(contentsOf: scan.failures)
        for directory in scan.directories {
            let listing = links(in: directory, fileManager: fileManager)
            if let failure = listing.failure {
                // An unreadable directory is not an empty one: nothing may be
                // moved on the strength of a listing that failed.
                scanFailures.append(failure)
                continue
            }
            for link in listing.links {
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

        if allOrNothing, !unresolved.isEmpty || !scanFailures.isEmpty {
            return Outcome(repointed: [], unresolved: unresolved, scanFailures: scanFailures)
        }

        var repointed: [String] = []
        var applied: [Move] = []
        for move in moves {
            do {
                try replaceLink(at: move.link, withDestination: move.next, fileManager: fileManager)
                repointed.append(move.link.standardizedFileURL.path)
                applied.append(move)
            } catch {
                // Nothing to restore: the swap either happened in one step or
                // not at all, so the Profile still resolves through the link it
                // had before this pass.
                unresolved.append(move.link.standardizedFileURL.path)
            }
        }

        if allOrNothing, !unresolved.isEmpty {
            // A rollback that only partly succeeds leaves the Profile resolving
            // through two Runtimes — exactly the state this pass exists to
            // avoid — so its failures travel back with the result.
            var rollbackFailures: [String] = []
            for move in applied.reversed() {
                do {
                    try replaceLink(at: move.link, withDestination: move.original, fileManager: fileManager)
                } catch {
                    rollbackFailures.append(move.link.standardizedFileURL.path)
                }
            }
            return Outcome(
                repointed: [],
                unresolved: unresolved,
                scanFailures: scanFailures,
                rollbackFailures: rollbackFailures
            )
        }
        return Outcome(repointed: repointed, unresolved: unresolved, scanFailures: scanFailures)
    }

    /// Point the link at `link`'s path to `destination` in one atomic step.
    ///
    /// `removeItem` followed by `createSymbolicLink` leaves a window in which
    /// the link does not exist — a plugin loader that reads the tree there sees
    /// a missing package — and a crash inside that window loses the link
    /// outright. A sibling temporary link renamed over the target replaces it
    /// atomically, and a failure before the rename leaves the previous link
    /// exactly as it was, so no restore step is needed.
    private static func replaceLink(
        at link: URL,
        withDestination destination: String,
        fileManager: FileManager
    ) throws {
        let temporary = link.deletingLastPathComponent()
            .appendingPathComponent("\(temporaryLinkPrefix)\(UUID().uuidString)")
        try fileManager.createSymbolicLink(atPath: temporary.path, withDestinationPath: destination)
        guard rename(temporary.path, link.path) == 0 else {
            let code = errno
            try? fileManager.removeItem(at: temporary)
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(code),
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "renaming \(temporary.path) over \(link.path) failed: \(String(cString: strerror(code)))"
                ]
            )
        }
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

    /// Directory URLs whose direct entries may link into a Runtime, plus the
    /// ones that could not be enumerated.
    ///
    /// A directory that cannot be listed must not look like one that holds no
    /// links: the caller deletes a Runtime on the strength of "nothing resolves
    /// through it any more", so a permission or I/O failure is reported and the
    /// pass stays away from the tree.
    private static func scannedDirectories(
        profilesRoot: URL,
        profiles: [URL]?,
        fileManager: FileManager
    ) -> (directories: [URL], failures: [String]) {
        var directories = [profilesRoot.appendingPathComponent("node_modules", isDirectory: true)]
        var failures: [String] = []
        let entries: [URL]
        if let profiles {
            entries = profiles
        } else {
            do {
                entries = try fileManager.contentsOfDirectory(
                    at: profilesRoot,
                    includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                    options: []
                )
            } catch {
                failures.append(profilesRoot.path)
                entries = []
            }
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
        return (directories, failures)
    }

    /// The links directly inside one of those directories, including one level
    /// of scope directories, or the reason the directory could not be read.
    /// Nothing recurses into a package or a `.pnpm` store: the links that name a
    /// Runtime live at exactly these two depths.
    private static func links(
        in directory: URL,
        fileManager: FileManager
    ) -> (links: [URL], failure: String?) {
        // A directory that does not exist is simply not part of this Profile;
        // anything else is a read failure the caller has to know about.
        guard fileManager.fileExists(atPath: directory.path) else { return ([], nil) }
        let entries: [URL]
        do {
            entries = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey],
                options: []
            )
        } catch {
            return ([], directory.path)
        }
        var found: [URL] = []
        for entry in entries {
            // A sibling temporary link from an interrupted swap is not part of
            // the Profile's dependency tree; the next pass would otherwise keep
            // inspecting its own leftovers.
            guard !entry.lastPathComponent.hasPrefix(temporaryLinkPrefix) else { continue }
            let values = try? entry.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            if values?.isSymbolicLink == true {
                found.append(entry)
                continue
            }
            guard values?.isDirectory == true, entry.lastPathComponent.hasPrefix("@") else { continue }
            let scoped: [URL]
            do {
                scoped = try fileManager.contentsOfDirectory(
                    at: entry,
                    includingPropertiesForKeys: [.isSymbolicLinkKey],
                    options: []
                )
            } catch {
                // A scope directory this pass cannot read may hold links into
                // the Runtime; report it instead of reporting an empty family.
                return (found, entry.path)
            }
            for candidate in scoped
            where (try? candidate.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
                && !candidate.lastPathComponent.hasPrefix(temporaryLinkPrefix) {
                found.append(candidate)
            }
        }
        return (found, nil)
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
