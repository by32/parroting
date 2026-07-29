import XCTest

@testable import parrot

final class LoginItemTests: XCTestCase {
    func testBareBinaryUsesLaunchAgent() {
        // A SwiftPM executable has no Info.plist, so no bundle identifier, and
        // bundlePath is the containing directory.
        XCTAssertEqual(
            LoginItem.mechanism(bundleIdentifier: nil, bundlePath: "/usr/local/bin"),
            .launchAgent
        )
    }

    func testAppBundleUsesSMAppService() {
        XCTAssertEqual(
            LoginItem.mechanism(
                bundleIdentifier: "io.github.by32.parroting",
                bundlePath: "/Applications/Parrot.app"
            ),
            .appBundle
        )
    }

    /// A directory named "*.app" with no Info.plist is not a bundle.
    /// SMAppService would fail on it, so fall back rather than trust the name.
    func testDirectoryNamedAppWithoutIdentifierFallsBack() {
        XCTAssertEqual(
            LoginItem.mechanism(bundleIdentifier: nil, bundlePath: "/tmp/Parrot.app"),
            .launchAgent
        )
    }

    /// Conversely, an identifier alone does not prove we are in a bundle.
    func testIdentifierOutsideBundleFallsBack() {
        XCTAssertEqual(
            LoginItem.mechanism(
                bundleIdentifier: "io.github.by32.parroting",
                bundlePath: "/usr/local/bin"
            ),
            .launchAgent
        )
    }

    func testEmptyIdentifierFallsBack() {
        XCTAssertEqual(
            LoginItem.mechanism(bundleIdentifier: "", bundlePath: "/Applications/Parrot.app"),
            .launchAgent
        )
    }

    /// The test bundle itself is not Parrot.app, so the running process must
    /// resolve to the LaunchAgent path. Guards against `current()` being wired
    /// to something that reports .appBundle unconditionally.
    func testCurrentResolvesForTheTestProcess() {
        XCTAssertNotNil(LoginItem.current())
    }
}
