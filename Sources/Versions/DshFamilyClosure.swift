import Foundation

/// The outcome of one registry manifest request.
///
/// `notFound` and `unreachable` are kept apart on purpose: only a definitive
/// "this registry has no such version" is evidence that a release is
/// incomplete. A timeout, a 5xx, or a proxy error must never be reported to
/// the user as "this version was never published".
enum DshFamilyManifestResult: Sendable {
    case manifest(Data)
    case notFound
    case unreachable
}

/// The plugin family of one target version, derived from the registry's own
/// dependency graph.
///
/// The aggregate package reaches its seam plugins through runtime imports, so
/// the shell has to make them resolvable at the top level of the managed tree.
/// Which packages those are is a property of the release, not something a
/// frozen list can keep in step with upstream: 0.1.6 replaced
/// `@deepseek-ai/dsh-code-runtime` with the jobs/terminal/tool packages. This
/// value is that set, read from the graph before a single byte is downloaded.
struct DshFamilyClosure: Sendable, Codable {
    /// Prefixed names the target graph declares and the registry publishes at
    /// the target version. These become the top-level pins.
    let available: [String]
    /// Required names the registry does not publish at the target version.
    /// Non-empty means the selected registry cannot serve the release.
    let missing: [String]
    /// Names reached only through optional edges and not published; harmless,
    /// because pnpm does not need them either. Reported for diagnostics.
    let optionalMissing: [String]
    /// Prefixed names whose manifest could not be read at all. Availability is
    /// unknown, so the graph cannot be trusted.
    let unreachable: [String]
    /// Roots that did not resolve. An empty graph must never pass a gate.
    let unresolvedRoots: [String]
    /// Every prefixed name the target graph declares, resolvable or not. The
    /// legacy roster is scoped by this set.
    let declared: [String]
    /// True when a safety cap ended the walk before the graph was exhausted.
    let truncated: Bool

    /// A closure may only be pinned and re-used when nothing weakened it.
    var isComplete: Bool {
        missing.isEmpty && unreachable.isEmpty && unresolvedRoots.isEmpty && !truncated
    }
}

/// A positive-only memo for closure derivations.
///
/// A complete closure can only become more complete (registries gain releases,
/// they do not lose them), so caching one is safe. Incomplete results are never
/// stored: a mirror that is fixed five minutes later must be re-checked, not
/// answered from a stale negative.
///
/// The memo survives the process when it is given `storage`: deriving a family
/// costs one registry request per package in the graph (hundreds of them), and
/// installing a Runtime, switching versions and activating a candidate would
/// otherwise repeat that walk every time the App restarts.
final class DshFamilyClosureCache: @unchecked Sendable {
    /// Bumped when the stored shape changes, so an older file is ignored rather
    /// than decoded into the wrong meaning.
    static let fileFormatVersion = 1

    private let lock = NSLock()
    private var entries: [String: DshFamilyClosure] = [:]
    /// Insertion order, oldest first, so a full cache drops the entry least
    /// likely to be asked for again instead of everything at once.
    private var order: [String] = []
    private let capacity: Int
    private let storage: URL?

    init(capacity: Int = 8, storage: URL? = nil) {
        self.capacity = max(1, capacity)
        self.storage = storage
        if let storage {
            load(from: storage)
        }
    }

    func value(for key: String) -> DshFamilyClosure? {
        lock.lock()
        defer { lock.unlock() }
        return entries[key]
    }

    func store(_ closure: DshFamilyClosure, for key: String) {
        lock.lock()
        defer { lock.unlock() }
        if entries[key] == nil {
            order.append(key)
        }
        entries[key] = closure
        while order.count > capacity {
            let evicted = order.removeFirst()
            entries.removeValue(forKey: evicted)
        }
        persist()
    }

    /// The keys currently memoized, oldest first. Test seam.
    var keysInEvictionOrder: [String] {
        lock.lock()
        defer { lock.unlock() }
        return order
    }

    private struct StoredFile: Codable {
        let formatVersion: Int
        let entries: [String: DshFamilyClosure]
    }

    /// Best-effort: a missing, unreadable or older-shaped file only means the
    /// walk runs again.
    private func load(from storage: URL) {
        guard let data = try? Data(contentsOf: storage),
              let file = try? JSONDecoder().decode(StoredFile.self, from: data),
              file.formatVersion == Self.fileFormatVersion else {
            return
        }
        for (key, closure) in file.entries where closure.isComplete {
            entries[key] = closure
            order.append(key)
        }
        order.sort()
    }

    /// Best-effort and atomic: a sibling temporary file renamed over the target
    /// cannot leave a half-written cache behind, and a failure to write costs
    /// only the next walk.
    private func persist() {
        guard let storage, let data = encode() else { return }
        let temporary = storage.deletingLastPathComponent()
            .appendingPathComponent(".\(storage.lastPathComponent).\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(
                at: storage.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: temporary)
            if rename(temporary.path, storage.path) != 0 {
                try? FileManager.default.removeItem(at: temporary)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
        }
    }

    private func encode() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(StoredFile(
            formatVersion: Self.fileFormatVersion,
            entries: entries
        ))
    }
}

/// Derives the DSH plugin family from the npm dependency graph.
///
/// This mirrors the original Electron shell, which read its family from
/// `package.json` (`dshFamilyPins`) and therefore never needed maintenance. The
/// Swift shell installs from a registry instead of a bundled manifest, so the
/// same roster is read from the registry, for any version, before installing.
enum DshFamilyGraph {
    /// Runtime roots: the aggregate the shell launches plus the two profile
    /// bundles it composes. Nothing else is installed at the managed tree's
    /// top level.
    static let rootPackages = [
        "@deepseek-ai/dsh",
        "@deepseek-ai/dsh-base",
        "@deepseek-ai/dsh-web-app"
    ]
    /// Seam plugin packages share this prefix. Other `@deepseek-ai` packages
    /// (cordis, schemastery, …) are ordinary static dependencies that pnpm
    /// resolves on its own and are deliberately not pinned.
    static let packagePrefix = "@deepseek-ai/dsh-"
    /// Measured graphs (0.1.5-rc.1: 231 names, 0.1.6-alpha.1: 236 names) are
    /// four levels deep. The caps are headroom, not policy: hitting one means
    /// the graph is no longer the shape this walk understands, which fails
    /// closed instead of silently verifying less.
    static let maximumDepth = 6
    static let maximumPackages = 400
    static let requestConcurrency = 16
    static let requestTimeout: TimeInterval = 10
    /// Attempts per manifest, and the backoff between them (attempt × delay).
    /// Three attempts turn one flaky response in a few hundred into a retry
    /// instead of a failed install, without hiding a registry that is down.
    static let requestAttempts = 3
    static let retryDelay: TimeInterval = 0.2

    typealias ManifestLoader = @Sendable (_ package: String, _ version: String) async -> DshFamilyManifestResult

    /// Walk the graph breadth-first from the runtime roots.
    ///
    /// A declared name is required when at least one non-optional edge points
    /// at it; a name that is only ever an optional peer is reported separately
    /// so a valid release is never rejected for a package pnpm would skip.
    /// Requirement status is resolved after the walk, because a name can be
    /// declared again by a manifest processed later than the one that put it in
    /// the queue.
    static func derive(version: String, loader: @escaping ManifestLoader) async -> DshFamilyClosure {
        var published = Set<String>()
        var unavailable = Set<String>()
        var unreachable = Set<String>()
        var unresolvedRoots = Set<String>()
        var declared = Set<String>()
        var required = Set<String>()
        var visited = Set(rootPackages)
        var frontier = rootPackages
        var depth = 0
        var truncated = false

        while !frontier.isEmpty {
            guard depth <= maximumDepth, visited.count <= maximumPackages else {
                truncated = true
                break
            }

            let batches = stride(from: 0, to: frontier.count, by: requestConcurrency).map { start in
                Array(frontier[start ..< min(start + requestConcurrency, frontier.count)])
            }
            var next: [String] = []

            for batch in batches {
                let results = await withTaskGroup(
                    of: (String, DshFamilyManifestResult).self
                ) { group -> [(String, DshFamilyManifestResult)] in
                    for package in batch {
                        group.addTask { (package, await loader(package, version)) }
                    }
                    var collected: [(String, DshFamilyManifestResult)] = []
                    for await result in group {
                        collected.append(result)
                    }
                    return collected
                }

                for (package, result) in results {
                    switch result {
                    case .manifest(let data):
                        guard let edges = declaredEdges(in: data) else {
                            // A manifest that cannot be parsed is not evidence
                            // that the package is absent.
                            if rootPackages.contains(package) {
                                unresolvedRoots.insert(package)
                            } else {
                                unreachable.insert(package)
                            }
                            continue
                        }
                        published.insert(package)
                        for edge in edges {
                            declared.insert(edge.name)
                            if edge.required {
                                required.insert(edge.name)
                            }
                            if visited.insert(edge.name).inserted {
                                next.append(edge.name)
                            }
                        }
                    case .notFound:
                        if rootPackages.contains(package) {
                            unresolvedRoots.insert(package)
                        } else {
                            unavailable.insert(package)
                        }
                    case .unreachable:
                        if rootPackages.contains(package) {
                            unresolvedRoots.insert(package)
                        } else {
                            unreachable.insert(package)
                        }
                    }
                }
            }

            frontier = next
            depth += 1
        }

        return DshFamilyClosure(
            available: published.filter { $0.hasPrefix(packagePrefix) }.sorted(),
            missing: unavailable.filter { required.contains($0) }.sorted(),
            optionalMissing: unavailable.filter { !required.contains($0) }.sorted(),
            unreachable: unreachable.sorted(),
            unresolvedRoots: unresolvedRoots.sorted(),
            declared: declared.sorted(),
            truncated: truncated
        )
    }

    /// Resolve the closure for a registry, re-using a complete result if one is
    /// already cached. `loader` exists so tests can drive the walk from a stub
    /// registry instead of the network.
    static func resolve(
        version: String,
        registry: String,
        loader: ManifestLoader? = nil,
        cache: DshFamilyClosureCache? = nil
    ) async -> DshFamilyClosure {
        let key = "\(registry)|\(version)"
        if let cached = cache?.value(for: key) {
            return cached
        }
        let closure = await derive(version: version, loader: loader ?? registryLoader(registry: registry))
        if let cache, closure.isComplete {
            cache.store(closure, for: key)
        }
        return closure
    }

    /// The frozen roster (`assets/dsh-family.json`) is applied only while the
    /// target graph still declares every name in it. A release that reorganises
    /// the family retires the roster instead of failing on it: 0.1.6 replaced
    /// `@deepseek-ai/dsh-code-runtime`, and a frozen list must not be able to
    /// veto an official release. For as long as old versions are installed this
    /// stays an independent cross-check on the derived graph, not the gate.
    static func legacyShortfall(roster: [String], closure: DshFamilyClosure) -> [String] {
        roster.filter { name in
            closure.declared.contains(name) && !closure.available.contains(name)
        }
    }

    /// The family packages a managed tree declares as its own direct
    /// dependencies.
    ///
    /// A tree that already exists was installed by whichever derivation was in
    /// force at the time: 1.2.x pinned the 18-name roster, later builds pin the
    /// whole derived family. Verifying exactly what the tree claims keeps the
    /// reuse check meaningful without rejecting a tree built before the family
    /// was derived, which would strand every existing install.
    static func declaredPins(inInstallRoot root: URL) -> [String] {
        let manifestURL = root.appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dependencies = object["dependencies"] as? [String: Any] else {
            return []
        }
        return dependencies.keys.filter { $0.hasPrefix(packagePrefix) }.sorted()
    }

    /// Fetch one package manifest by exact version.
    ///
    /// The single-version endpoint is used instead of the full packument: the
    /// graph walk asks for hundreds of manifests, and only the version under
    /// consideration matters. It must be requested with the default accept
    /// header — npm answers `406` when the packument-only
    /// `application/vnd.npm.install-v1+json` format is asked of a
    /// version-specific URL, which would make every release look unreachable.
    ///
    /// A transport failure or a 5xx is retried a couple of times with a short
    /// backoff: one flaky response in a walk of a few hundred requests must not
    /// fail an install, and the walk already treats "unreadable" as fail-closed
    /// rather than as absence. A 404 is an answer, not a failure, and is never
    /// retried.
    static func registryLoader(registry: String) -> ManifestLoader {
        let base = normalizedBase(registry)
        return { package, version in
            guard let url = URL(string: "\(base)/\(package)/\(version)") else {
                return .unreachable
            }
            var attempt = 1
            while true {
                let outcome = await requestManifest(at: url)
                switch outcome {
                case .manifest, .notFound:
                    return outcome
                case .unreachable:
                    guard attempt < requestAttempts else { return .unreachable }
                    do {
                        try await Task.sleep(
                            nanoseconds: UInt64(retryDelay * Double(attempt) * 1_000_000_000)
                        )
                    } catch {
                        // Cancellation ends the walk instead of turning into a
                        // tight retry loop.
                        return .unreachable
                    }
                    attempt += 1
                }
            }
        }
    }

    /// One attempt at one manifest URL.
    private static func requestManifest(at url: URL) async -> DshFamilyManifestResult {
        var request = URLRequest(url: url)
        request.timeoutInterval = requestTimeout
        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return .unreachable
            }
            switch httpResponse.statusCode {
            case 200 ... 299:
                return .manifest(data)
            case 404:
                return .notFound
            default:
                return .unreachable
            }
        } catch {
            return .unreachable
        }
    }

    /// A registry URL without trailing separators, which the manifest URL is
    /// built from.
    static func normalizedBase(_ registry: String) -> String {
        var base = registry.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") {
            base.removeLast()
        }
        return base
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = requestConcurrency
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = requestTimeout * 3
        return URLSession(configuration: configuration)
    }()

    private static func declaredEdges(in data: Data) -> [(name: String, required: Bool)]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let peerMeta = (root["peerDependenciesMeta"] as? [String: Any]) ?? [:]
        var edges: [(name: String, required: Bool)] = []
        for kind in ["dependencies", "optionalDependencies", "peerDependencies"] {
            guard let entries = root[kind] as? [String: Any] else { continue }
            for name in entries.keys where name.hasPrefix(packagePrefix) {
                let optionalPeer = kind == "peerDependencies"
                    && ((peerMeta[name] as? [String: Any])?["optional"] as? Bool == true)
                edges.append((name, !(kind == "optionalDependencies" || optionalPeer)))
            }
        }
        return edges
    }
}
