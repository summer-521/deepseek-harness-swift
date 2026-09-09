import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

private func rootURL() -> URL {
    guard let value = ProcessInfo.processInfo.environment["DSH_TEST_APP_SUPPORT"], !value.isEmpty else {
        fatalError("test requires DSH_TEST_APP_SUPPORT")
    }
    return URL(fileURLWithPath: value, isDirectory: true)
}

private func stateURL() -> URL {
    DshStateManager.appSupportDirectory.appendingPathComponent("dsh-state.json")
}

private func requireWriteFailure(_ result: Result<Void, DshStatePersistenceError>, _ message: String) {
    guard case .failure(.writeFailed) = result else {
        require(false, message)
        return
    }
}

@main
struct StatePersistenceHarness {
    static func main() {
        let mode = CommandLine.arguments.dropFirst().first ?? ""
        let fileManager = FileManager.default

        switch mode {
        case "first-launch":
            let manager = DshStateManager.shared
            require(manager.loadResult == .absent, "missing state must be a first-launch result")
            require(manager.current == .default, "missing state must retain default first-launch config")
            guard case .success = manager.update({ $0.selectedVersion = "0.1.1-rc.2" }) else {
                require(false, "first-launch state update should persist")
                return
            }
            require(manager.loadResult == .loaded, "successful first write must mark state as loaded")
            require(fileManager.fileExists(atPath: stateURL().path), "first state write must create the state file")

        case "legacy":
            let legacy = Data(#"{"selectedVersion":"0.1.1-rc.2","autoFollowLatest":true}"#.utf8)
            try! fileManager.createDirectory(
                at: DshStateManager.appSupportDirectory,
                withIntermediateDirectories: true
            )
            try! legacy.write(to: stateURL(), options: .atomic)
            let manager = DshStateManager.shared
            require(manager.loadResult == .loaded, "legacy state must decode as loaded")
            require(manager.current.selectedVersion == "0.1.1-rc.2", "legacy selected version must survive")
            require(manager.current.dshPort == 3080, "legacy missing port must retain its compatibility default")

        case "corrupt":
            try! fileManager.createDirectory(
                at: DshStateManager.appSupportDirectory,
                withIntermediateDirectories: true
            )
            try! Data("{not-json".utf8).write(to: stateURL(), options: .atomic)
            let manager = DshStateManager.shared
            guard case .corrupted(let detail) = manager.loadResult else {
                require(false, "corrupt state must be observable as corrupted")
                return
            }
            require(!detail.isEmpty, "corrupt state must expose a diagnostic")
            require(manager.current == .default, "corrupt state must not be treated as a loaded config")
            let result = manager.update { $0.selectedVersion = "must-not-overwrite" }
            guard case .failure(.stateUnavailable) = result else {
                require(false, "corrupt state update must fail closed")
                return
            }
            require(manager.current == .default, "failed corrupt-state update must not mutate memory")

        case "unreadable":
            try! fileManager.createDirectory(
                at: DshStateManager.appSupportDirectory,
                withIntermediateDirectories: true
            )
            try! fileManager.createDirectory(at: stateURL(), withIntermediateDirectories: false)
            let manager = DshStateManager.shared
            guard case .unreadable(let detail) = manager.loadResult else {
                require(false, "unreadable state must be observable as unreadable")
                return
            }
            require(!detail.isEmpty, "unreadable state must expose a diagnostic")
            guard case .failure(.stateUnavailable) = manager.update({ $0.selectedVersion = "must-not-overwrite" }) else {
                require(false, "unreadable state update must fail closed")
                return
            }

        case "write-failure":
            let dshDirectory = rootURL().appendingPathComponent("DSH", isDirectory: true)
            try! fileManager.createDirectory(at: rootURL(), withIntermediateDirectories: true)
            try! Data("directory-is-not-writable".utf8).write(to: dshDirectory, options: .atomic)
            let manager = DshStateManager.shared
            require(manager.loadResult == .absent, "missing state under an unusable support path is still not loaded")
            requireWriteFailure(manager.update { $0.selectedVersion = "must-not-claim-success" }, "state write failure must be returned")
            require(manager.current == .default, "failed state write must not mutate memory")
            require(manager.lastPersistenceError != nil, "state write failure must remain observable")

        case "startup-decision":
            require(
                DshStateStartupDecision.decide(for: .absent) == .proceed,
                "first launch must proceed"
            )
            require(
                DshStateStartupDecision.decide(for: .loaded) == .proceed,
                "valid state must proceed"
            )
            guard case .block = DshStateStartupDecision.decide(for: .corrupted("bad JSON")) else {
                require(false, "corrupt state must block startup")
                return
            }
            guard case .block = DshStateStartupDecision.decide(for: .unreadable("permission denied")) else {
                require(false, "unreadable state must block startup")
                return
            }

        default:
            fatalError("unknown state persistence harness mode: \(mode)")
        }

        print("swift state persistence harness passed: \(mode)")
    }
}
