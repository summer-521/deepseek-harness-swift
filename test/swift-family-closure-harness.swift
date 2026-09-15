import Foundation

/// Hermetic scenarios for the registry-graph derivation. Every manifest comes
/// from an in-memory stub, so the assertions describe the walk itself and never
/// depend on what npm currently publishes.
@main
struct DshFamilyClosureHarness {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("family closure assertion failed: \(message)\n", stderr)
            exit(1)
        }
    }

    /// Counts loader invocations so the memo behaviour is observable.
    actor CountingLoader {
        private var calls = 0
        private let body: @Sendable (String, String) async -> DshFamilyManifestResult

        init(_ body: @escaping @Sendable (String, String) async -> DshFamilyManifestResult) {
            self.body = body
        }

        func loader() -> DshFamilyGraph.ManifestLoader {
            { package, version in
                await self.record()
                return await self.body(package, version)
            }
        }

        private func record() {
            calls += 1
        }

        var callCount: Int {
            calls
        }
    }

    static func manifest(
        _ name: String,
        dependencies: [String] = [],
        optionalDependencies: [String] = [],
        peerDependencies: [String] = [],
        optionalPeerDependencies: [String] = []
    ) -> Data {
        var object: [String: Any] = ["name": name, "version": "9.9.9"]
        if !dependencies.isEmpty {
            object["dependencies"] = Dictionary(uniqueKeysWithValues: dependencies.map { ($0, "^9.9.9") })
        }
        if !optionalDependencies.isEmpty {
            object["optionalDependencies"] = Dictionary(
                uniqueKeysWithValues: optionalDependencies.map { ($0, "^9.9.9") }
            )
        }
        if !peerDependencies.isEmpty {
            object["peerDependencies"] = Dictionary(
                uniqueKeysWithValues: peerDependencies.map { ($0, "^9.9.9") }
            )
        }
        if !optionalPeerDependencies.isEmpty {
            var peers = (object["peerDependencies"] as? [String: String]) ?? [:]
            var meta: [String: Any] = [:]
            for name in optionalPeerDependencies {
                peers[name] = "^9.9.9"
                meta[name] = ["optional": true]
            }
            object["peerDependencies"] = peers
            object["peerDependenciesMeta"] = meta
        }
        return try! JSONSerialization.data(withJSONObject: object)
    }

    /// A stub registry: manifests by package name, everything else is a
    /// definitive 404, exactly like a complete public registry.
    final class StubRegistry {
        let packages: [String: Data]

        init(_ packages: [String: Data]) {
            self.packages = packages
        }

        func loader() -> DshFamilyGraph.ManifestLoader {
            { package, _ in
                guard let data = self.packages[package] else { return .notFound }
                return .manifest(data)
            }
        }
    }

    static func main() async throws {
        // `registry <url> <version>` drives the real loader against a stub HTTP
        // registry, so the request contract (URL shape, status handling, accept
        // header) is covered without touching the public npm registry.
        if CommandLine.arguments.count > 3, CommandLine.arguments[1] == "registry" {
            let closure = await DshFamilyGraph.resolve(
                version: CommandLine.arguments[3],
                registry: CommandLine.arguments[2]
            )
            print("available=\(closure.available.joined(separator: ","))")
            print("missing=\(closure.missing.joined(separator: ","))")
            print("optionalMissing=\(closure.optionalMissing.joined(separator: ","))")
            print("unreachable=\(closure.unreachable.joined(separator: ","))")
            print("unresolvedRoots=\(closure.unresolvedRoots.joined(separator: ","))")
            print("complete=\(closure.isComplete)")
            print("swift family closure harness passed")
            return
        }

        let aggregate = "@deepseek-ai/dsh"
        let base = "@deepseek-ai/dsh-base"
        let webApp = "@deepseek-ai/dsh-web-app"

        // A graph shaped like a real release: the aggregate composes two
        // bundles, which depend on seam plugins, one of them reached only
        // through a required peer edge.
        let aligned = StubRegistry([
            aggregate: manifest(
                aggregate,
                dependencies: [base, webApp, "@deepseek-ai/cordis", "@deepseek-ai/dsh-timeout"]
            ),
            base: manifest(base, dependencies: ["@deepseek-ai/dsh-scope"]),
            webApp: manifest(webApp, dependencies: ["@deepseek-ai/dsh-fs"]),
            "@deepseek-ai/dsh-scope": manifest("@deepseek-ai/dsh-scope"),
            "@deepseek-ai/dsh-fs": manifest("@deepseek-ai/dsh-fs", peerDependencies: ["@deepseek-ai/dsh-spill"]),
            "@deepseek-ai/dsh-spill": manifest("@deepseek-ai/dsh-spill", peerDependencies: ["@deepseek-ai/dsh-scope"]),
            "@deepseek-ai/dsh-timeout": manifest("@deepseek-ai/dsh-timeout"),
        ])

        let closure = await DshFamilyGraph.derive(version: "9.9.9", loader: aligned.loader())
        expect(closure.isComplete, "an aligned graph must be complete")
        expect(
            closure.available == [
                "@deepseek-ai/dsh-base",
                "@deepseek-ai/dsh-fs",
                "@deepseek-ai/dsh-scope",
                "@deepseek-ai/dsh-spill",
                "@deepseek-ai/dsh-timeout",
                "@deepseek-ai/dsh-web-app",
            ],
            "available members are the sorted seam packages: \(closure.available)"
        )
        expect(
            closure.declared.contains("@deepseek-ai/dsh-spill"),
            "a name reached only through a required peer edge is part of the family"
        )
        expect(
            !closure.declared.contains("@deepseek-ai/cordis")
                && !closure.available.contains("@deepseek-ai/cordis"),
            "non-seam @deepseek-ai packages stay out of the pinned family"
        )
        expect(
            !closure.available.contains(aggregate),
            "the aggregate itself is the install root, not a family member"
        )
        expect(closure.optionalMissing.isEmpty, "an aligned graph has nothing optional missing")

        // Peer cycles must terminate and still resolve every member.
        let cyclic = StubRegistry([
            aggregate: manifest(aggregate, dependencies: ["@deepseek-ai/dsh-a"]),
            "@deepseek-ai/dsh-a": manifest("@deepseek-ai/dsh-a", peerDependencies: ["@deepseek-ai/dsh-b"]),
            "@deepseek-ai/dsh-b": manifest("@deepseek-ai/dsh-b", peerDependencies: ["@deepseek-ai/dsh-a"]),
        ])
        let cyclicClosure = await DshFamilyGraph.derive(version: "9.9.9", loader: cyclic.loader())
        expect(
            cyclicClosure.available == ["@deepseek-ai/dsh-a", "@deepseek-ai/dsh-b"],
            "a peer cycle terminates with both members available: \(cyclicClosure.available)"
        )

        // A required name the registry does not publish blocks the install.
        let incomplete = StubRegistry([
            aggregate: manifest(aggregate, dependencies: [base, "@deepseek-ai/dsh-missing"]),
            base: manifest(base, dependencies: ["@deepseek-ai/dsh-peer-only"]),
        ])
        let incompleteClosure = await DshFamilyGraph.derive(version: "9.9.9", loader: incomplete.loader())
        expect(!incompleteClosure.isComplete, "a missing required member is never complete")
        expect(
            incompleteClosure.missing == ["@deepseek-ai/dsh-missing", "@deepseek-ai/dsh-peer-only"],
            "both a direct and a peer-only absence are required members: \(incompleteClosure.missing)"
        )
        expect(
            incompleteClosure.optionalMissing.isEmpty,
            "a required absence must not be filed as optional: \(incompleteClosure.optionalMissing)"
        )

        // Optional edges may be absent: pnpm skips them, so the gate must too.
        let optional = StubRegistry([
            aggregate: manifest(
                aggregate,
                dependencies: [base],
                optionalDependencies: ["@deepseek-ai/dsh-optional-dep"],
                optionalPeerDependencies: ["@deepseek-ai/dsh-optional-peer"]
            ),
            base: manifest(base, peerDependencies: ["@deepseek-ai/dsh-real-peer"]),
            "@deepseek-ai/dsh-real-peer": manifest("@deepseek-ai/dsh-real-peer"),
        ])
        let optionalClosure = await DshFamilyGraph.derive(version: "9.9.9", loader: optional.loader())
        expect(
            optionalClosure.missing.isEmpty,
            "an absent optional edge must not block an install: \(optionalClosure.missing)"
        )
        expect(
            optionalClosure.optionalMissing == ["@deepseek-ai/dsh-optional-dep", "@deepseek-ai/dsh-optional-peer"],
            "absent optional edges are reported separately: \(optionalClosure.optionalMissing)"
        )
        expect(
            optionalClosure.available.contains("@deepseek-ai/dsh-real-peer"),
            "a required peer of a required member is pinned"
        )

        // Optionality is resolved from the whole graph, not from whichever edge
        // was walked first: an optional declaration plus a required one is
        // required.
        let mixed = StubRegistry([
            aggregate: manifest(
                aggregate,
                dependencies: [base],
                optionalDependencies: ["@deepseek-ai/dsh-late-required"]
            ),
            base: manifest(base, dependencies: ["@deepseek-ai/dsh-late-required"]),
        ])
        let mixedClosure = await DshFamilyGraph.derive(version: "9.9.9", loader: mixed.loader())
        expect(
            mixedClosure.missing == ["@deepseek-ai/dsh-late-required"],
            "a later required edge outranks an earlier optional one: \(mixedClosure.missing)"
        )

        // Transport failures are not absence, and never a silent pass.
        let flaky = StubRegistry([
            aggregate: manifest(aggregate, dependencies: [base, "@deepseek-ai/dsh-timeout"]),
            base: manifest(base),
        ])
        let flakyClosure = await DshFamilyGraph.derive(version: "9.9.9") { package, _ in
            if package == "@deepseek-ai/dsh-timeout" { return .unreachable }
            return await flaky.loader()(package, "9.9.9")
        }
        expect(
            flakyClosure.unreachable == ["@deepseek-ai/dsh-timeout"] && flakyClosure.missing.isEmpty,
            "an unreadable manifest is reported as unreadable, not as unpublished: \(flakyClosure)"
        )
        expect(!flakyClosure.isComplete, "an unreadable manifest must fail closed")

        let noRoot = await DshFamilyGraph.derive(version: "9.9.9") { _, _ in .notFound }
        expect(
            noRoot.unresolvedRoots == DshFamilyGraph.rootPackages.sorted(),
            "an unresolvable root makes the whole graph untrustworthy: \(noRoot.unresolvedRoots)"
        )
        expect(!noRoot.isComplete, "an empty graph must never pass")

        let garbage = await DshFamilyGraph.derive(version: "9.9.9") { package, _ in
            if package == aggregate { return .manifest(Data("not json".utf8)) }
            return .manifest(manifest(package))
        }
        expect(
            garbage.unresolvedRoots == [aggregate],
            "a malformed root manifest is unresolved rather than treated as empty: \(garbage.unresolvedRoots)"
        )
        expect(!garbage.isComplete, "a malformed root must fail closed")
        let garbageMember = await DshFamilyGraph.derive(version: "9.9.9") { package, _ in
            if package == "@deepseek-ai/dsh" {
                return .manifest(manifest(package, dependencies: ["@deepseek-ai/dsh-broken"]))
            }
            if package == "@deepseek-ai/dsh-broken" { return .manifest(Data("{".utf8)) }
            return .notFound
        }
        expect(
            garbageMember.unreachable == ["@deepseek-ai/dsh-broken"] && garbageMember.missing.isEmpty,
            "a malformed member manifest is unreadable, not absent: \(garbageMember)"
        )

        // Safety caps fail closed instead of verifying less.
        var deep: [String: Data] = [aggregate: manifest(aggregate, dependencies: ["@deepseek-ai/dsh-level-1"])]
        for level in 1 ... (DshFamilyGraph.maximumDepth + 3) {
            deep["@deepseek-ai/dsh-level-\(level)"] = manifest(
                "@deepseek-ai/dsh-level-\(level)",
                dependencies: level == DshFamilyGraph.maximumDepth + 3
                    ? []
                    : ["@deepseek-ai/dsh-level-\(level + 1)"]
            )
        }
        let deepClosure = await DshFamilyGraph.derive(version: "9.9.9", loader: StubRegistry(deep).loader())
        expect(deepClosure.truncated, "a graph deeper than the cap is truncated, not silently accepted")
        expect(!deepClosure.isComplete, "a truncated graph must fail closed")

        var wide: [String: Data] = [
            aggregate: manifest(
                aggregate,
                dependencies: (0 ... DshFamilyGraph.maximumPackages).map { "@deepseek-ai/dsh-wide-\($0)" }
            )
        ]
        for index in 0 ... DshFamilyGraph.maximumPackages {
            wide["@deepseek-ai/dsh-wide-\(index)"] = manifest("@deepseek-ai/dsh-wide-\(index)")
        }
        let wideClosure = await DshFamilyGraph.derive(version: "9.9.9", loader: StubRegistry(wide).loader())
        expect(wideClosure.truncated, "a graph wider than the cap is truncated")
        expect(!wideClosure.isComplete, "a truncated graph must fail closed")

        // The frozen roster cross-checks versions whose graph still declares
        // it, and retires itself once a release reorganises the family.
        let roster = ["@deepseek-ai/dsh-kept", "@deepseek-ai/dsh-retired"]
        expect(
            DshFamilyGraph.legacyShortfall(roster: roster, closure: closure).isEmpty,
            "names the graph no longer declares must not veto a release"
        )
        let rosterShortfall = DshFamilyGraph.legacyShortfall(
            roster: roster,
            closure: DshFamilyClosure(
                available: ["@deepseek-ai/dsh-kept"],
                missing: [],
                optionalMissing: [],
                unreachable: [],
                unresolvedRoots: [],
                declared: roster,
                truncated: false
            )
        )
        expect(
            rosterShortfall == ["@deepseek-ai/dsh-retired"],
            "a declared roster name that is not available is a shortfall: \(rosterShortfall)"
        )

        // A tree installed before the family was derived pins the roster it was
        // built with; the reuse check must verify that set, not the wider one.
        let treeRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dsh-family-closure-tree-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: treeRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: treeRoot) }
        expect(
            DshFamilyGraph.declaredPins(inInstallRoot: treeRoot).isEmpty,
            "a tree without a manifest declares no pins"
        )
        let legacyPins = ["@deepseek-ai/dsh-scope", "@deepseek-ai/dsh-spill"]
        let treeManifest: [String: Any] = [
            "name": "deepseek-harness-desktop-managed-dsh",
            "version": "0.0.0",
            "dependencies": [
                "@deepseek-ai/dsh": "0.1.5-rc.1",
                "@deepseek-ai/dsh-scope": "0.1.5-rc.1",
                "@deepseek-ai/dsh-spill": "0.1.5-rc.1",
                "left-pad": "1.3.0",
            ],
        ]
        try JSONSerialization.data(withJSONObject: treeManifest)
            .write(to: treeRoot.appendingPathComponent("package.json"))
        expect(
            DshFamilyGraph.declaredPins(inInstallRoot: treeRoot) == legacyPins.sorted(),
            "the tree's own family pins are read, without the aggregate or non-dsh deps"
        )
        try Data("{".utf8).write(to: treeRoot.appendingPathComponent("package.json"))
        expect(
            DshFamilyGraph.declaredPins(inInstallRoot: treeRoot).isEmpty,
            "an unreadable tree manifest declares no pins instead of guessing"
        )

        // Only a complete derivation is memoised.
        let counting = CountingLoader(aligned.loader())
        let cache = DshFamilyClosureCache()
        let first = await DshFamilyGraph.resolve(
            version: "9.9.9",
            registry: "https://registry.example.test",
            loader: counting.loader(),
            cache: cache
        )
        let callsAfterFirst = await counting.callCount
        let second = await DshFamilyGraph.resolve(
            version: "9.9.9",
            registry: "https://registry.example.test",
            loader: counting.loader(),
            cache: cache
        )
        let callsAfterSecond = await counting.callCount
        expect(first.isComplete && second.isComplete, "a stubbed complete closure resolves")
        expect(callsAfterFirst > 0, "the first resolution walks the graph")
        expect(
            callsAfterSecond == callsAfterFirst,
            "a complete closure is served from the memo: \(callsAfterSecond) vs \(callsAfterFirst)"
        )
        expect(
            cacheIsRegistryScoped(cache: cache),
            "the memo is scoped by registry"
        )

        let failing = CountingLoader { _, _ in .notFound }
        let negativeCache = DshFamilyClosureCache()
        _ = await DshFamilyGraph.resolve(
            version: "9.9.9",
            registry: "https://registry.example.test",
            loader: failing.loader(),
            cache: negativeCache
        )
        let callsAfterMiss = await failing.callCount
        _ = await DshFamilyGraph.resolve(
            version: "9.9.9",
            registry: "https://registry.example.test",
            loader: failing.loader(),
            cache: negativeCache
        )
        let callsAfterSecondMiss = await failing.callCount
        expect(
            callsAfterSecondMiss > callsAfterMiss,
            "an incomplete closure is never memoised: a fixed mirror must be re-checked"
        )

        // The real registry loader must still be constructible without a graph.
        let liveLoader = DshFamilyGraph.registryLoader(registry: "https://registry.npmjs.org/")
        _ = liveLoader

        print("family members=\(closure.available.count)")
        print("swift family closure harness passed")
    }

    /// A closure cached for one registry must not answer for another.
    static func cacheIsRegistryScoped(cache: DshFamilyClosureCache) -> Bool {
        let complete = DshFamilyClosure(
            available: ["@deepseek-ai/dsh-scope"],
            missing: [],
            optionalMissing: [],
            unreachable: [],
            unresolvedRoots: [],
            declared: ["@deepseek-ai/dsh-scope"],
            truncated: false
        )
        cache.store(complete, for: "https://registry.example.test|9.9.9")
        return cache.value(for: "https://registry.example.test|9.9.9") != nil
            && cache.value(for: "https://registry.other.test|9.9.9") == nil
    }
}
