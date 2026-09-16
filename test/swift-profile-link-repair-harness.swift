import Foundation

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

/// Behavioral fixture for `DshProfileLinkRepair`.
///
/// Every path is created under one private temporary root, so the pass is
/// exercised against a real filesystem while the user's own DSH home stays
/// untouched.
@main
struct ProfileLinkRepairHarness {
    static func main() throws {
        let fileManager = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("dsh-profile-link-repair-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let versions = root.appendingPathComponent("dsh-versions", isDirectory: true)
        let profiles = root.appendingPathComponent("profiles", isDirectory: true)
        let workspaceScope = profiles
            .appendingPathComponent("node_modules/@earendil-works", isDirectory: true)
        let profileScope = profiles
            .appendingPathComponent("swift-desktop/node_modules/@deepseek-ai", isDirectory: true)
        let fallbackScope = profiles
            .appendingPathComponent("swift-desktop/.dsh-module-fallback/node_modules/@deepseek-ai", isDirectory: true)
        let otherProfileScope = profiles
            .appendingPathComponent("web/node_modules/@earendil-works", isDirectory: true)
        let swiftProfile = profiles.appendingPathComponent("swift-desktop", isDirectory: true)

        func makeDirectory(_ url: URL) throws {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
        for directory in [workspaceScope, profileScope, fallbackScope, otherProfileScope] {
            try makeDirectory(directory)
        }

        /// Materialize a package inside a Runtime tree and return its path.
        @discardableResult
        func packageFile(_ version: String, _ relativePath: String) throws -> URL {
            let url = versions
                .appendingPathComponent(version, isDirectory: true)
                .appendingPathComponent(relativePath, isDirectory: true)
            try makeDirectory(url)
            try Data("package".utf8).write(to: url.appendingPathComponent("package.json"))
            return url
        }

        func link(_ destination: String, at url: URL) throws {
            try? fileManager.removeItem(at: url)
            try fileManager.createSymbolicLink(atPath: url.path, withDestinationPath: destination)
        }

        func link(_ destination: URL, at url: URL) throws {
            try link(destination.path, at: url)
        }

        func resolves(_ url: URL) -> Bool {
            fileManager.fileExists(atPath: url.path)
        }

        func destination(_ url: URL) -> String? {
            try? fileManager.destinationOfSymbolicLink(atPath: url.path)
        }

        let activeRuntime = versions.appendingPathComponent("0.1.6-alpha.1", isDirectory: true)
        let oldRuntime = versions.appendingPathComponent("0.1.5-rc.2", isDirectory: true)

        // A package both Runtimes carry at the Runtime's own root.
        let directOld = try packageFile("0.1.5-rc.2", "node_modules/@earendil-works/pi-ai")
        let directNew = try packageFile("0.1.6-alpha.1", "node_modules/@earendil-works/pi-ai")
        // A package both carry through the hoisted store.
        let storeOld = try packageFile("0.1.5-rc.2", "node_modules/.pnpm/node_modules/@earendil-works/pi-telemetry")
        let storeNew = try packageFile("0.1.6-alpha.1", "node_modules/.pnpm/node_modules/@earendil-works/pi-telemetry")
        // The pnpm virtual-store shape: the directory embeds the version and an
        // install hash, so the surviving Runtime carries the package elsewhere.
        let hashedOld = try packageFile(
            "0.1.5-rc.2",
            "node_modules/.pnpm/@deepseek-ai+tool-x@0.1.5-alpha.1_aaaa/node_modules/@deepseek-ai/tool-x"
        )
        let hashedNew = try packageFile("0.1.6-alpha.1", "node_modules/.pnpm/node_modules/@deepseek-ai/tool-x")
        // A package only the old Runtime carries: the link pins it.
        let onlyOld = try packageFile(
            "0.1.5-rc.2",
            "node_modules/.pnpm/node_modules/@deepseek-ai/dsh-workflow-worker-thread"
        )
        // A link into an unrelated Runtime is not this pass's business.
        let unrelated = try packageFile("0.1.3-alpha.2", "node_modules/@hono/node-server")

        let movableDirect = workspaceScope.appendingPathComponent("pi-ai")
        let movableStore = workspaceScope.appendingPathComponent("pi-telemetry")
        let movableHash = profileScope.appendingPathComponent("tool-x")
        let movableFallback = fallbackScope.appendingPathComponent("pi-telemetry")
        let pinned = profileScope.appendingPathComponent("dsh-workflow-worker-thread")
        let untouched = workspaceScope.appendingPathComponent("node-server")
        try link(directOld, at: movableDirect)
        try link(storeOld, at: movableStore)
        try link(hashedOld, at: movableHash)
        try link(storeOld, at: movableFallback)
        try link(onlyOld, at: pinned)
        try link(unrelated, at: untouched)
        // A regular file beside them proves the pass only rewrites links.
        let bystander = workspaceScope.appendingPathComponent("README")
        try Data("keep".utf8).write(to: bystander)

        // One link no Runtime can satisfy must hold the whole pass back: a
        // Profile resolved through two Runtimes at once is worse than one that
        // still reads the Runtime it was installed against.
        let pinnedPass = DshProfileLinkRepair.repointLinks(
            profilesRoot: profiles,
            versionsDirectory: versions,
            fromVersion: "0.1.5-rc.2",
            toCandidates: [activeRuntime]
        )
        require(pinnedPass.unresolved.count == 1, "the pinned link must be reported, saw \(pinnedPass.unresolved)")
        require(pinnedPass.repointed.isEmpty, "a pass that cannot place every link must move none")
        require(!pinnedPass.canRemoveSourceRuntime, "a pinned link must keep the old Runtime")
        require(destination(movableDirect) == directOld.path, "an incomplete pass must not move the direct link")
        require(destination(movableStore) == storeOld.path, "an incomplete pass must not move the store link")
        require(destination(movableHash) == hashedOld.path, "an incomplete pass must not move the hash-form link")
        require(destination(pinned) == onlyOld.path, "the pinned link must stay as it was")
        require(destination(untouched) == unrelated.path, "a link into another Runtime must stay as it was")
        require(fileManager.fileExists(atPath: bystander.path), "non-link entries must survive the pass")

        // With the pin gone every link moves together — including the
        // virtual-store one, which only package identity can place.
        try fileManager.removeItem(at: pinned)
        let complete = DshProfileLinkRepair.repointLinks(
            profilesRoot: profiles,
            versionsDirectory: versions,
            fromVersion: "0.1.5-rc.2",
            toCandidates: [activeRuntime]
        )
        require(complete.unresolved.isEmpty, "nothing pins the Runtime any more, saw \(complete.unresolved)")
        require(complete.repointed.count == 4, "all four links must move, saw \(complete.repointed)")
        require(complete.canRemoveSourceRuntime, "every link moved, so the Runtime may go")
        require(destination(movableDirect) == directNew.path, "the direct link must follow the package")
        require(destination(movableStore) == storeNew.path, "the store link must follow the package")
        require(
            destination(movableHash) == hashedNew.path,
            "the hash-form link must follow the package, not the old store path"
        )
        require(resolves(movableHash), "the hash-form link must resolve afterwards")
        require(
            destination(movableFallback) == storeNew.path,
            "a fallback-tree link must follow the package"
        )
        require(resolves(movableDirect), "the direct link must resolve afterwards")
        require(
            destination(untouched) == unrelated.path,
            "a link into another Runtime must not be touched by this pass"
        )

        // The same link is what pins its own Runtime when that one is removed.
        let pinnedOther = DshProfileLinkRepair.repointLinks(
            profilesRoot: profiles,
            versionsDirectory: versions,
            fromVersion: "0.1.3-alpha.2",
            toCandidates: [activeRuntime]
        )
        require(!pinnedOther.canRemoveSourceRuntime, "a Runtime one link resolves through must be kept")
        require(pinnedOther.unresolved.count == 1, "that link must be the reported reason")

        // A link left behind by an earlier cleanup is repaired at launch, and
        // one that cannot be supplied is reported rather than deleted.
        try fileManager.removeItem(at: oldRuntime)
        let danglingRepairable = workspaceScope.appendingPathComponent("pi-ai-legacy")
        let danglingPinned = profileScope.appendingPathComponent("worker-thread-legacy")
        try link(directOld, at: danglingRepairable)
        try link(onlyOld, at: danglingPinned)
        let dangling = DshProfileLinkRepair.repairDanglingLinks(
            profilesRoot: profiles,
            versionsDirectory: versions,
            toRuntime: activeRuntime
        )
        require(dangling.repointed.count == 1, "the dangling link must be re-pointed, saw \(dangling.repointed)")
        require(dangling.unresolved.count == 1, "an unsuppliable dangling link must be reported")
        require(resolves(danglingRepairable), "the repaired link must resolve after the Runtime is gone")
        require(!resolves(danglingPinned), "the unsuppliable link must stay dangling")
        require(
            destination(danglingPinned) == onlyOld.path,
            "a dangling link must not be deleted or mis-pointed"
        )

        // Launch-time repair is scoped to the Profile the launch owns: another
        // Profile's own tree is shared with the terminal CLI and stays out.
        let webDangling = otherProfileScope.appendingPathComponent("pi-ai")
        let ownedDangling = profileScope.appendingPathComponent("pi-ai-owned")
        try link(directOld, at: webDangling)
        try link(directOld, at: ownedDangling)
        let scoped = DshProfileLinkRepair.repairDanglingLinks(
            profilesRoot: profiles,
            versionsDirectory: versions,
            toRuntime: activeRuntime,
            restrictingTo: [swiftProfile]
        )
        require(scoped.repointed.count == 1, "only the launched Profile's link may move, saw \(scoped.repointed)")
        require(resolves(ownedDangling), "the launched Profile's dangling link must be repaired")
        require(!resolves(webDangling), "another Profile's tree must not be written to")
        require(
            destination(webDangling) == directOld.path,
            "another Profile's link must keep its destination"
        )

        // The explicit repair entry point drops that scope: when the user asks
        // for a repair, every Profile is covered, including the CLI-shared one
        // a launch must leave alone.
        let repairedEverywhere = DshProfileLinkRepair.repairDanglingLinks(
            profilesRoot: profiles,
            versionsDirectory: versions,
            toRuntime: activeRuntime
        )
        require(
            !repairedEverywhere.isNoop,
            "an explicit repair must find the other Profile's dangling link"
        )
        require(resolves(webDangling), "an explicit repair must cover every Profile")
        require(
            destination(webDangling) == directNew.path,
            "the other Profile's link must follow the package, saw \(destination(webDangling) ?? "<nil>")"
        )

        // A swap replaces the link in one step and leaves no sibling behind,
        // and a sibling an interrupted swap did leave is not a dependency: the
        // pass ignores it instead of re-pointing or counting it.
        let interrupted = profileScope.appendingPathComponent(".dsh-link-interrupted")
        let swapTarget = profileScope.appendingPathComponent("tool-x-swap")
        try link(hashedOld, at: interrupted)
        try link(hashedOld, at: swapTarget)
        let swapped = DshProfileLinkRepair.repairDanglingLinks(
            profilesRoot: profiles,
            versionsDirectory: versions,
            toRuntime: activeRuntime,
            restrictingTo: [swiftProfile]
        )
        require(
            swapped.repointed == [swapTarget.standardizedFileURL.path],
            "only the real link may move, saw \(swapped.repointed)"
        )
        require(
            !swapped.unresolved.contains(swapTarget.standardizedFileURL.path)
                && !swapped.unresolved.contains(interrupted.standardizedFileURL.path),
            "neither the swap nor the leftover may be reported unresolved, saw \(swapped.unresolved)"
        )
        require(resolves(swapTarget), "the swapped link must resolve through the candidate Runtime")
        require(
            destination(swapTarget) == hashedNew.path,
            "the swapped link must name the package the candidate carries, saw \(destination(swapTarget) ?? "<nil>")"
        )
        require(
            destination(interrupted) == hashedOld.path,
            "an interrupted swap's temporary link must stay exactly as it was"
        )
        let leftovers = (try? fileManager.contentsOfDirectory(atPath: profileScope.path))?
            .filter { $0.hasPrefix(".dsh-link-") } ?? []
        require(
            leftovers == [".dsh-link-interrupted"],
            "a completed swap must leave no temporary link, saw \(leftovers)"
        )

        // Nothing to do against a Profile with no Runtime links at all.
        let emptyRoot = root.appendingPathComponent("empty-profiles", isDirectory: true)
        try makeDirectory(emptyRoot.appendingPathComponent("node_modules", isDirectory: true))
        let noop = DshProfileLinkRepair.repointLinks(
            profilesRoot: emptyRoot,
            versionsDirectory: versions,
            fromVersion: "0.1.5-rc.2",
            toCandidates: [activeRuntime]
        )
        require(noop.isNoop, "an empty workspace must produce a no-op")

        print("swift profile link repair harness passed")
    }
}
