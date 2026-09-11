import Foundation
import CryptoKit
import Darwin

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

private func treeDigest(_ root: URL) throws -> String {
    let fileManager = FileManager.default
    let rootPath = root.standardizedFileURL.path
    var entries = [URL]()
    if let enumerator = fileManager.enumerator(
        at: root,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: []
    ) {
        while let entry = enumerator.nextObject() as? URL {
            entries.append(entry)
        }
    }
    var hasher = SHA256()
    for url in entries.sorted(by: { $0.path < $1.path }) {
        let relative = String(url.standardizedFileURL.path.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let values = try url.resourceValues(forKeys: [.isDirectoryKey])
        hasher.update(data: Data(relative.utf8))
        hasher.update(data: Data([0, values.isDirectory == true ? 1 : 0]))
        if values.isDirectory != true {
            hasher.update(data: try Data(contentsOf: url))
        }
        hasher.update(data: Data([0]))
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

@main
struct WebProfileSnapshotHarness {
    static func main() async throws {
        let fileManager = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("dsh-profile-snapshot-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? fileManager.removeItem(at: root)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("DSH_HOME", root.path, 1)

        require(
            DshPluginManagerStartupGate.decision(
                profileReadiness: .freshEmpty,
                inspectionIsComplete: false,
                inspectionHasErrors: false
            ) == .allowFreshProfileBootstrap,
            "A genuinely empty Profile may be bootstrapped after the expected incomplete inspection"
        )
        require(
            DshPluginManagerStartupGate.decision(
                profileReadiness: .existingUninitialized,
                inspectionIsComplete: false,
                inspectionHasErrors: false,
                inspectionHasUnknowns: true
            ) == .blockProfileMutation,
            "An existing unresolved Profile must remain blocked"
        )
        require(
            DshPluginManagerStartupGate.decision(
                profileReadiness: .initialized,
                inspectionIsComplete: true,
                inspectionHasErrors: false
            ) == .allowProfileMutation,
            "A complete initialized Profile may be mutated"
        )

        let profile = root.appendingPathComponent("profiles/web", isDirectory: true)
        let package = profile.appendingPathComponent("package.json")
        let moduleMarker = profile
            .appendingPathComponent("node_modules/plugin", isDirectory: true)
            .appendingPathComponent("marker")
        try fileManager.createDirectory(at: moduleMarker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"dependencies":{"plugin":"1.0.0"}}"#.utf8).write(to: package, options: .atomic)
        try Data("before".utf8).write(to: moduleMarker, options: .atomic)

        let manager = DshPluginManager.shared
        // Route deliberately noisy pnpm output through the manager's error
        // formatter. The helper emits a shaped token and auth headers, plus
        // enough bytes to exercise both diagnostic limits.
        let outputProfile = root.appendingPathComponent("profiles/noisy-pnpm", isDirectory: true)
        setenv("DSH_TEST_PNPM_OUTPUT", "1", 1)
        var outputError: Error?
        do {
            try await manager.addPlugin(
                spec: "file:/controlled-fixture",
                profileDirectory: outputProfile,
                profile: .web
            )
        } catch {
            outputError = error
        }
        unsetenv("DSH_TEST_PNPM_OUTPUT")
        require(outputError != nil, "Noisy pnpm fixture must fail so diagnostics are formatted")
        let outputMessage = outputError?.localizedDescription ?? ""
        let shapedToken = String(repeating: "T", count: 43)
        require(!outputMessage.contains(shapedToken), "Process diagnostics must redact token-shaped credentials")
        require(
            outputMessage.contains("Authorization: Bearer [REDACTED]"),
            "Process diagnostics must redact Authorization headers; prefix: \(outputMessage.prefix(800))"
        )
        require(outputMessage.contains("Cookie: session=[REDACTED]"), "Process diagnostics must redact Cookie headers")
        require(outputMessage.count <= 8_400, "Process diagnostics must have a character limit")
        require(Data(outputMessage.utf8).count <= 33_000, "Process diagnostics must have a byte limit")

        let snapshotID = try await manager.createWebProfileSnapshot()
        try Data(#"{"dependencies":{"plugin":"2.0.0"}}"#.utf8).write(to: package, options: .atomic)
        try Data("after".utf8).write(to: moduleMarker, options: .atomic)
        try await manager.restoreWebProfileSnapshot(snapshotID)
        let restoredPackage = try String(contentsOf: package, encoding: .utf8)
        let restoredMarker = try String(contentsOf: moduleMarker, encoding: .utf8)
        require(restoredPackage.contains("1.0.0"), "Profile manifest must be restored")
        require(restoredMarker == "before", "node_modules must be restored")
        try await manager.deleteWebProfileSnapshot(snapshotID)

        try fileManager.removeItem(at: profile)
        let missingSnapshotID = try await manager.createWebProfileSnapshot()
        try fileManager.createDirectory(at: profile, withIntermediateDirectories: true)
        try Data("temporary".utf8).write(to: profile.appendingPathComponent("unexpected"), options: .atomic)
        try await manager.restoreWebProfileSnapshot(missingSnapshotID)
        require(!fileManager.fileExists(atPath: profile.path), "Missing original Profile must restore as absent")
        try await manager.deleteWebProfileSnapshot(missingSnapshotID)
        require(manager.bootstrapReadiness(at: profile) == .freshEmpty, "An absent Profile must be classified as fresh")

        // An interrupted restore moves the live Profile aside and leaves a
        // partial copy at the canonical path. The resumed attempt must not
        // delete that leftover before the replacement content is verified: it
        // is the only complete copy left. Here the snapshot content is gone, so
        // the restore must fail *and* leave the Profile at its pre-restore
        // state instead of keeping the partial tree.
        let interruptedProfile = root.appendingPathComponent("profiles/interrupted-restore-web", isDirectory: true)
        try fileManager.createDirectory(
            at: interruptedProfile.appendingPathComponent("node_modules/plugin", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data(#"{"dependencies":{"plugin":"1.0.0"}}"#.utf8)
            .write(to: interruptedProfile.appendingPathComponent("package.json"), options: .atomic)
        try Data("before".utf8)
            .write(to: interruptedProfile.appendingPathComponent("node_modules/plugin/marker"), options: .atomic)
        let interruptedSnapshotID = try await manager.createWebProfileSnapshot(
            profile: .web,
            profileDirectory: interruptedProfile
        )
        let interruptedDisplaced = DshPluginManager.displacedProfileRestoreURL(
            profileDirectory: interruptedProfile,
            snapshotID: interruptedSnapshotID
        )
        try fileManager.moveItem(at: interruptedProfile, to: interruptedDisplaced)
        try fileManager.createDirectory(at: interruptedProfile, withIntermediateDirectories: true)
        try Data("partial".utf8)
            .write(to: interruptedProfile.appendingPathComponent("partial-copy"), options: .atomic)
        // The snapshot directory exists but its content copy is gone, and no
        // "was missing" marker was written, so the restore must refuse (-33).
        let interruptedSnapshotURL = DshStateManager.appSupportDirectory
            .appendingPathComponent("dsh-runtime-profile-snapshots", isDirectory: true)
            .appendingPathComponent(interruptedSnapshotID, isDirectory: true)
        try fileManager.removeItem(at: interruptedSnapshotURL.appendingPathComponent("profile", isDirectory: true))
        var interruptedError: Error?
        do {
            try await manager.restoreWebProfileSnapshot(
                interruptedSnapshotID,
                profile: .web,
                profileDirectory: interruptedProfile
            )
        } catch {
            interruptedError = error
        }
        require(interruptedError != nil, "a snapshot without content must fail the restore")
        let recoveredPackage = (try? String(
            contentsOf: interruptedProfile.appendingPathComponent("package.json"),
            encoding: .utf8
        )) ?? ""
        require(
            recoveredPackage.contains("1.0.0"),
            "a failed resumed restore must keep the complete pre-restore Profile, not the partial copy"
        )
        require(
            !fileManager.fileExists(atPath: interruptedProfile.appendingPathComponent("partial-copy").path),
            "the partial copy from the interrupted attempt must not survive as the Profile"
        )
        require(
            !fileManager.fileExists(atPath: interruptedDisplaced.path),
            "the complete leftover must be put back in place, never stranded"
        )
        try await manager.deleteWebProfileSnapshot(interruptedSnapshotID)

        // The same shape with an intact snapshot must complete: the canonical
        // path is replaced by a fresh copy of the snapshot content (never nested
        // inside the partial tree) and only then is the leftover reclaimed.
        let resumedProfile = root.appendingPathComponent("profiles/resumed-restore-web", isDirectory: true)
        try fileManager.createDirectory(
            at: resumedProfile.appendingPathComponent("node_modules/plugin", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data(#"{"dependencies":{"plugin":"1.0.0"}}"#.utf8)
            .write(to: resumedProfile.appendingPathComponent("package.json"), options: .atomic)
        try Data("before".utf8)
            .write(to: resumedProfile.appendingPathComponent("node_modules/plugin/marker"), options: .atomic)
        let resumedSnapshotID = try await manager.createWebProfileSnapshot(
            profile: .web,
            profileDirectory: resumedProfile
        )
        let resumedDisplaced = DshPluginManager.displacedProfileRestoreURL(
            profileDirectory: resumedProfile,
            snapshotID: resumedSnapshotID
        )
        try fileManager.moveItem(at: resumedProfile, to: resumedDisplaced)
        try fileManager.createDirectory(at: resumedProfile, withIntermediateDirectories: true)
        try Data("partial".utf8)
            .write(to: resumedProfile.appendingPathComponent("partial-copy"), options: .atomic)
        let resumedOutcome = try await manager.restoreWebProfileSnapshot(
            resumedSnapshotID,
            profile: .web,
            profileDirectory: resumedProfile
        )
        require(resumedOutcome == .restored, "a resumed restore with complete content must report a clean restore")
        let resumedPackage = try String(
            contentsOf: resumedProfile.appendingPathComponent("package.json"),
            encoding: .utf8
        )
        require(resumedPackage.contains("1.0.0"), "the resumed restore must apply the snapshot content")
        require(
            !fileManager.fileExists(atPath: resumedProfile.appendingPathComponent("profile").path),
            "the snapshot content must not be nested inside the partial tree"
        )
        require(
            !fileManager.fileExists(atPath: resumedProfile.appendingPathComponent("partial-copy").path),
            "the partial copy must not survive a successful restore"
        )
        require(
            !fileManager.fileExists(atPath: resumedDisplaced.path),
            "a successful resumed restore must reclaim its leftover"
        )
        try await manager.deleteWebProfileSnapshot(resumedSnapshotID)

        // R12: the reclamation entry point validates the identity itself,
        // because the path comes from user-writable state.
        let reclaimRoot = root.appendingPathComponent("profiles-reclaim", isDirectory: true)
        try fileManager.createDirectory(at: reclaimRoot, withIntermediateDirectories: true)
        let wellFormedTree = reclaimRoot.appendingPathComponent(
            DshProfileRestoreCleanup.displacedNamePrefix + "9C2A7B86-1E4D-4C21-9F0B-6D1E5A7C3B48",
            isDirectory: true
        )
        try fileManager.createDirectory(at: wellFormedTree, withIntermediateDirectories: true)
        let foreignTree = reclaimRoot.appendingPathComponent(
            DshProfileRestoreCleanup.displacedNamePrefix + "A1B2C3D4-E5F6-4A7B-8C9D-0E1F2A3B4C5D",
            isDirectory: true
        )
        try fileManager.createDirectory(at: foreignTree, withIntermediateDirectories: true)
        let mismatchReclaimed = await manager.removeDisplacedProfileTree(
            at: foreignTree,
            expectedSnapshotID: "9C2A7B86-1E4D-4C21-9F0B-6D1E5A7C3B48"
        )
        require(!mismatchReclaimed, "a recorded path with another snapshot id must be refused")
        require(fileManager.fileExists(atPath: foreignTree.path), "a refused reclamation must leave the tree untouched")
        let symlinkTree = reclaimRoot.appendingPathComponent(
            DshProfileRestoreCleanup.displacedNamePrefix + "5E6F7A8B-9C0D-4E1F-2A3B-4C5D6E7F8A9B",
            isDirectory: true
        )
        try fileManager.createSymbolicLink(atPath: symlinkTree.path, withDestinationPath: wellFormedTree.path)
        let symlinkReclaimed = await manager.removeDisplacedProfileTree(
            at: symlinkTree,
            expectedSnapshotID: "5E6F7A8B-9C0D-4E1F-2A3B-4C5D6E7F8A9B"
        )
        require(!symlinkReclaimed, "a symlink at the recorded path must be refused")
        require(fileManager.fileExists(atPath: wellFormedTree.path), "the symlink target must survive")
        require(
            (try? fileManager.destinationOfSymbolicLink(atPath: symlinkTree.path)) != nil,
            "a refused reclamation must not even unlink the symlink"
        )
        try? fileManager.removeItem(at: symlinkTree)
        let reclaimed = await manager.removeDisplacedProfileTree(
            at: wellFormedTree,
            expectedSnapshotID: "9C2A7B86-1E4D-4C21-9F0B-6D1E5A7C3B48"
        )
        require(reclaimed, "a well-formed displaced tree must be reclaimed")
        require(!fileManager.fileExists(atPath: wellFormedTree.path), "a reclaimed tree must be gone")
        try? fileManager.removeItem(at: reclaimRoot)

        let blockedProfile = root.appendingPathComponent("profiles/existing-uninitialized", isDirectory: true)
        let blockedPayload = blockedProfile.appendingPathComponent("node_modules/user-package/keep", isDirectory: false)
        try fileManager.createDirectory(at: blockedPayload.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("preserve-existing-profile".utf8).write(to: blockedPayload, options: .atomic)
        require(manager.bootstrapReadiness(at: blockedProfile) == .existingUninitialized, "A non-empty manifestless Profile must be classified as existing")
        let blockedBefore = try treeDigest(blockedProfile)
        var bootstrapError: Error?
        do {
            try manager.bootstrapWebProfileManifestIfMissing(at: blockedProfile, profile: .web)
        } catch {
            bootstrapError = error
        }
        require(bootstrapError != nil, "Bootstrap must reject an existing incomplete Profile")
        let bootstrapMessage = bootstrapError?.localizedDescription ?? ""
        require(bootstrapMessage.contains("web Profile manifest"), "Bootstrap rejection must identify the selected Profile")
        require(!bootstrapMessage.contains("selectedProfile.rawValue"), "Bootstrap rejection must interpolate the selected Profile")
        let blockedAfter = try treeDigest(blockedProfile)
        require(blockedAfter == blockedBefore, "Rejected bootstrap must preserve an existing Profile tree")

        let invalidProfile = root.appendingPathComponent("profiles/invalid", isDirectory: true)
        try fileManager.createDirectory(at: invalidProfile, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: invalidProfile.appendingPathComponent("package.json"), options: .atomic)
        var invalidError: Error?
        do {
            try manager.bootstrapWebProfileManifestIfMissing(at: invalidProfile, profile: .desktop)
        } catch {
            invalidError = error
        }
        let invalidMessage = invalidError?.localizedDescription ?? ""
        require(invalidMessage.contains("desktop Profile manifest"), "Invalid manifest rejection must interpolate the selected Profile")

        // A web Profile may contain a user-owned dependency with the same
        // bridge package name. Without the durable marker written by a
        // managed install, cleanup must fail before invoking pnpm or deleting
        // either the manifest or node_modules entry.
        let ownershipProfile = root.appendingPathComponent("profiles/ownership-web", isDirectory: true)
        let userHost = ownershipProfile.appendingPathComponent("node_modules/dsh-desktop-host", isDirectory: true)
        let userWebServer = ownershipProfile.appendingPathComponent("node_modules/@deepseek-ai/dsh-host-webserver", isDirectory: true)
        try fileManager.createDirectory(at: userHost, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: userWebServer, withIntermediateDirectories: true)
        let userPackage = #"{"name":"ownership-web","private":true,"dependencies":{"dsh-desktop-host":"user-local","@deepseek-ai/dsh-host-webserver":"user-local"},"dsh":{"profile":{"bundles":["dsh-desktop-host"]}}}"#
        try Data(userPackage.utf8).write(to: ownershipProfile.appendingPathComponent("package.json"), options: .atomic)
        try Data(#"{"name":"dsh-desktop-host","version":"user"}"#.utf8)
            .write(to: userHost.appendingPathComponent("package.json"), options: .atomic)
        try Data(#"{"name":"@deepseek-ai/dsh-host-webserver","version":"user"}"#.utf8)
            .write(to: userWebServer.appendingPathComponent("package.json"), options: .atomic)
        let userPayload = ownershipProfile.appendingPathComponent("node_modules/dsh-desktop-host/user-file")
        try Data("keep-user-package".utf8).write(to: userPayload, options: .atomic)
        let ownershipBefore = try treeDigest(ownershipProfile)
        var ownershipError: Error?
        do {
            try await manager.removeDesktopHostArtifacts(
                from: .web,
                profileDirectory: ownershipProfile,
                registry: "https://registry.invalid"
            )
        } catch {
            ownershipError = error
        }
        require(ownershipError != nil, "Cleanup must reject an unproven same-name dependency")
        let ownershipMessage = ownershipError?.localizedDescription ?? "missing error"
        require(ownershipMessage.contains("所有权证明"), "Cleanup error must explain the ownership proof requirement: \(ownershipMessage)")
        let ownershipAfter = try treeDigest(ownershipProfile)
        require(ownershipAfter == ownershipBefore, "Rejected cleanup must preserve the complete Profile tree")
        require(fileManager.fileExists(atPath: userPayload.path), "Rejected cleanup must preserve the user package")

        // Exercise the positive ownership path with the controlled assets and
        // pnpm helper installed by the integration wrapper. The manager must
        // write the marker only after installation postconditions pass, then
        // verify and remove exactly that app-owned bridge.
        let managedProfile = root.appendingPathComponent("profiles/managed-web", isDirectory: true)
        let installed = try await manager.ensureDesktopHostPlugin(
            registry: "https://registry.invalid",
            profileDirectory: managedProfile,
            profile: .web,
            runtimeVersion: "9.9.9"
        )
        require(installed, "Controlled pnpm install must materialize the bridge")
        let managedPackage = try String(contentsOf: managedProfile.appendingPathComponent("package.json"), encoding: .utf8)
        require(managedPackage.contains("dsh-profile-web"), "Fresh bootstrap must interpolate the profile name")
        let ownershipMarker = managedProfile.appendingPathComponent(".dsh-desktop-host-ownership.json")
        require(fileManager.fileExists(atPath: ownershipMarker.path), "Managed install must write the ownership marker")
        require(fileManager.fileExists(atPath: managedProfile.appendingPathComponent("node_modules/dsh-desktop-host/package.json").path), "Managed install must materialize the bridge package")

        // Simulate an app upgrade that changes the bundled bridge in place.
        // The marker still proves that the installed old fingerprint belongs
        // to this app, so the next ensure must refresh only the bridge tree
        // locally and must not invoke a second full pnpm add.
        guard let sourceBundlePath = NodeRuntime.shared.resolveDesktopHostBundlePath() else {
            fatalError("controlled desktop host bundle disappeared")
        }
        try Data("controlled-upgraded-bridge\n".utf8)
            .write(to: URL(fileURLWithPath: sourceBundlePath).appendingPathComponent("index.js"), options: .atomic)
        let rechecked = try await manager.ensureDesktopHostPlugin(
            registry: "https://registry.invalid",
            profileDirectory: managedProfile,
            profile: .web,
            runtimeVersion: "9.9.9"
        )
        require(!rechecked, "stale but app-owned bridge must be repaired locally without pnpm")
        let refreshedIndex = try String(
            contentsOf: managedProfile.appendingPathComponent("node_modules/dsh-desktop-host/index.js"),
            encoding: .utf8
        )
        require(refreshedIndex == "controlled-upgraded-bridge\n", "local bridge refresh must install the current bundled bytes")

        // Simulate a force-quit immediately after the atomic directory
        // publication but before the ownership marker is rewritten. On the
        // next launch the current bundled bytes plus the still-managed
        // manifest must be adopted without another pnpm transaction.
        try Data("controlled-post-publish-bridge\n".utf8)
            .write(to: URL(fileURLWithPath: sourceBundlePath).appendingPathComponent("index.js"), options: .atomic)
        let installedHost = managedProfile.appendingPathComponent("node_modules/dsh-desktop-host", isDirectory: true)
        try fileManager.removeItem(at: installedHost)
        try fileManager.copyItem(at: URL(fileURLWithPath: sourceBundlePath), to: installedHost)
        let recoveredAfterPublish = try await manager.ensureDesktopHostPlugin(
            registry: "https://registry.invalid",
            profileDirectory: managedProfile,
            profile: .web,
            runtimeVersion: "9.9.9"
        )
        require(!recoveredAfterPublish, "post-publication force-quit recovery must not invoke pnpm")
        let recoveredIndex = try String(
            contentsOf: installedHost.appendingPathComponent("index.js"),
            encoding: .utf8
        )
        require(recoveredIndex == "controlled-post-publish-bridge\n", "post-publication recovery must retain current bundled bytes")
        let profileEntries = try fileManager.contentsOfDirectory(atPath: managedProfile.path)
        require(
            !profileEntries.contains(where: { $0.hasPrefix(".dsh-desktop-host-staging-") }),
            "successful local refresh must not retain staging directories"
        )

        // Profile-switch crash window: pnpm and the atomic bridge publication
        // completed, but the process died before the ownership marker write.
        // Cleanup must adopt this exact current App-owned tree before removing
        // it, without invoking another pnpm transaction.
        let interruptedCleanupProfile = root.appendingPathComponent(
            "profiles/interrupted-cleanup-web", isDirectory: true)
        _ = try await manager.ensureDesktopHostPlugin(
            registry: "https://registry.invalid",
            profileDirectory: interruptedCleanupProfile,
            profile: .web,
            runtimeVersion: "9.9.9"
        )
        let interruptedMarker = interruptedCleanupProfile.appendingPathComponent(
            ".dsh-desktop-host-ownership.json")
        try fileManager.removeItem(at: interruptedMarker)
        try await manager.removeDesktopHostArtifacts(
            from: .web,
            profileDirectory: interruptedCleanupProfile,
            registry: "https://registry.invalid"
        )
        require(
            !fileManager.fileExists(atPath: interruptedCleanupProfile
                .appendingPathComponent("node_modules/dsh-desktop-host").path),
            "post-install cleanup recovery must remove the proven bridge")
        require(
            !fileManager.fileExists(atPath: interruptedMarker.path),
            "post-install cleanup recovery must remove its adopted marker")

        // A later force-quit can happen after pnpm removed the direct bridge
        // entries but before bundle/marker finalization. The retained marker
        // and exact installed fingerprint still prove the orphaned tree is
        // App-owned; a user replacement of either declaration would fail.
        let interruptedAfterPnpmProfile = root.appendingPathComponent(
            "profiles/interrupted-after-pnpm-web", isDirectory: true)
        _ = try await manager.ensureDesktopHostPlugin(
            registry: "https://registry.invalid",
            profileDirectory: interruptedAfterPnpmProfile,
            profile: .web,
            runtimeVersion: "9.9.9"
        )
        let interruptedAfterPnpmMarker = interruptedAfterPnpmProfile.appendingPathComponent(
            ".dsh-desktop-host-ownership.json")
        let interruptedAfterPnpmPackage = interruptedAfterPnpmProfile.appendingPathComponent(
            "package.json")
        var interruptedAfterPnpmRoot = try JSONSerialization.jsonObject(
            with: Data(contentsOf: interruptedAfterPnpmPackage), options: []) as! [String: Any]
        var interruptedAfterPnpmDependencies = interruptedAfterPnpmRoot["dependencies"] as! [String: Any]
        interruptedAfterPnpmDependencies.removeValue(forKey: "dsh-desktop-host")
        interruptedAfterPnpmDependencies.removeValue(forKey: "@deepseek-ai/dsh-host-webserver")
        interruptedAfterPnpmRoot["dependencies"] = interruptedAfterPnpmDependencies
        try JSONSerialization.data(withJSONObject: interruptedAfterPnpmRoot, options: [.sortedKeys])
            .write(to: interruptedAfterPnpmPackage, options: .atomic)
        try await manager.removeDesktopHostArtifacts(
            from: .web,
            profileDirectory: interruptedAfterPnpmProfile,
            registry: "https://registry.invalid"
        )
        require(
            !fileManager.fileExists(atPath: interruptedAfterPnpmMarker.path),
            "post-pnpm cleanup recovery must remove its retained marker")
        require(
            !fileManager.fileExists(atPath: interruptedAfterPnpmProfile
                .appendingPathComponent("node_modules/dsh-desktop-host").path),
            "post-pnpm cleanup recovery must remove the orphaned bridge")

        // App upgrades can change the bundled bridge contents before the next
        // cleanup. The marker's installed fingerprint, manifest declarations,
        // and profile binding remain the durable proof, so cleanup must not
        // fail merely because the current source bytes differ.
        let changedSourceProfile = root.appendingPathComponent(
            "profiles/changed-source-web", isDirectory: true)
        _ = try await manager.ensureDesktopHostPlugin(
            registry: "https://registry.invalid",
            profileDirectory: changedSourceProfile,
            profile: .web,
            runtimeVersion: "9.9.9"
        )
        let changedSourceMarker = changedSourceProfile.appendingPathComponent(
            ".dsh-desktop-host-ownership.json")
        try Data("changed-after-install\n".utf8).write(
            to: URL(fileURLWithPath: sourceBundlePath).appendingPathComponent("index.js"),
            options: .atomic)
        try await manager.removeDesktopHostArtifacts(
            from: .web,
            profileDirectory: changedSourceProfile,
            registry: "https://registry.invalid"
        )
        require(
            !fileManager.fileExists(atPath: changedSourceMarker.path),
            "cleanup must remove a marker whose source Bundle changed")
        try Data("controlled-post-publish-bridge\n".utf8).write(
            to: URL(fileURLWithPath: sourceBundlePath).appendingPathComponent("index.js"),
            options: .atomic)

        // Development workflow: the previous App bundle installed the bridge
        // and was then deleted (dist cleanups are routine). The manifest still
        // declares the deleted App-bundle source, the installed tree carries
        // those old bytes, and no ownership marker survived. The declaration
        // inside an App bundle's Resources tree pins App provenance, so ensure
        // must refresh locally from the running bundle without pnpm and
        // without the ownership refusal.
        try Data("controlled-old-dev-bridge\n".utf8).write(
            to: installedHost.appendingPathComponent("index.js"), options: .atomic)
        try fileManager.removeItem(at: ownershipMarker)
        let devPackageURL = managedProfile.appendingPathComponent("package.json")
        let devPackageRoot = try JSONSerialization.jsonObject(
            with: Data(contentsOf: devPackageURL), options: []) as! [String: Any]
        var devDependencies = devPackageRoot["dependencies"] as! [String: Any]
        devDependencies["dsh-desktop-host"] =
            "file:/Users/dev/Library/Developer/Xcode/DerivedData/old/DSH.app/Contents/Resources/assets/dsh-desktop-host"
        var devPackageUpdated = devPackageRoot
        devPackageUpdated["dependencies"] = devDependencies
        try JSONSerialization.data(withJSONObject: devPackageUpdated, options: [.prettyPrinted])
            .write(to: devPackageURL, options: .atomic)
        let devRechecked = try await manager.ensureDesktopHostPlugin(
            registry: "https://registry.invalid",
            profileDirectory: managedProfile,
            profile: .web,
            runtimeVersion: "9.9.9"
        )
        require(!devRechecked, "deleted-source dev bridge must be repaired locally without pnpm")
        let devRefreshedIndex = try String(
            contentsOf: installedHost.appendingPathComponent("index.js"), encoding: .utf8)
        require(
            devRefreshedIndex == "controlled-post-publish-bridge\n",
            "deleted-source dev refresh must install the current bundled bytes")
        require(
            fileManager.fileExists(atPath: ownershipMarker.path),
            "deleted-source dev refresh must re-record the ownership proof")
        let devPackageAfter = try String(contentsOf: devPackageURL, encoding: .utf8)
        let devPackageAfterRoot = try JSONSerialization.jsonObject(
            with: Data(devPackageAfter.utf8), options: []) as! [String: Any]
        let devDependenciesAfter = devPackageAfterRoot["dependencies"] as! [String: String]
        require(
            devDependenciesAfter["dsh-desktop-host"] == "file:\(sourceBundlePath)",
            "deleted-source dev refresh must realign the manifest to the running bundle: \(devPackageAfter.prefix(700))")

        try await manager.removeDesktopHostArtifacts(
            from: .web,
            profileDirectory: managedProfile,
            registry: "https://registry.invalid"
        )
        require(!fileManager.fileExists(atPath: ownershipMarker.path), "Verified cleanup must remove its ownership marker")
        require(!fileManager.fileExists(atPath: managedProfile.appendingPathComponent("node_modules/dsh-desktop-host").path), "Verified cleanup must remove the owned bridge")

        try? fileManager.removeItem(at: root)

        print("web profile snapshot and ownership integration harness passed")
    }
}
