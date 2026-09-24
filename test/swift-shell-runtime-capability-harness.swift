import Foundation

@main
struct DshShellRuntimeCapabilityHarness {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("shell runtime capability assertion failed: \(message)\n", stderr)
            exit(1)
        }
    }

    /// The shell's own decision, spelled the way `DshWebShell` spells it: an
    /// unparseable version is not a capability.
    static func drawsOwnMacOSLayout(_ version: String) -> Bool {
        DshSemanticVersion(version)?.supportsNativeMacOSShell ?? false
    }

    static func main() {
        // Every release the App can still be pointed at from npm today.
        expect(!drawsOwnMacOSLayout("0.1.5-rc.3"), "0.1.5-rc.3 is the npm latest tag and has no macOS layout")
        expect(!drawsOwnMacOSLayout("0.1.6-alpha.1"), "0.1.6-alpha.1 has no macOS layout")
        // The trap: this one honors the marker for its collapsed width but has
        // no leading seat, so its sidebar would collapse with no way back.
        expect(
            !drawsOwnMacOSLayout("0.1.6-alpha.2"),
            "0.1.6-alpha.2 collapses to zero width without mounting a leading seat"
        )

        // From the floor on, the Runtime owns the layout.
        expect(drawsOwnMacOSLayout("0.1.7-alpha.1"), "0.1.7-alpha.1 mounts the leading seat")
        expect(drawsOwnMacOSLayout("0.1.7-alpha.2"), "0.1.7-alpha.2 mounts the leading seat")
        expect(drawsOwnMacOSLayout("0.1.7-rc.1"), "0.1.7-rc.1 mounts the leading seat")
        expect(drawsOwnMacOSLayout("0.1.7"), "a stable 0.1.7 mounts the leading seat")
        expect(drawsOwnMacOSLayout("0.2.0"), "a later release mounts the leading seat")

        // Prerelease ordering decides this, so the floor must not be reached
        // by a lower prerelease of the same core version.
        expect(!drawsOwnMacOSLayout("0.1.7-alpha.0"), "0.1.7-alpha.0 precedes the floor")
        expect(drawsOwnMacOSLayout("0.1.7-alpha.10"), "numeric prerelease identifiers compare as numbers")

        // A version the shell cannot parse must fall back to its own rail
        // rather than claim a layout that may not be there.
        expect(!drawsOwnMacOSLayout(""), "an empty version keeps the shell rail")
        expect(!drawsOwnMacOSLayout("nightly"), "an unparseable version keeps the shell rail")
        expect(!drawsOwnMacOSLayout("0.1"), "a partial version keeps the shell rail")

        print("swift shell runtime capability harness passed")
    }
}
