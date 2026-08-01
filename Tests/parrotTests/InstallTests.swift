import XCTest

@testable import parrot

final class InstallTests: XCTestCase {
    private func exists(_ paths: String...) -> (String) -> Bool {
        let set = Set(paths)
        return { set.contains($0) }
    }

    func testPrefersTheRunningExecutable() {
        XCTAssertEqual(
            Install.agentBinaryPath(
                executablePath: "/opt/homebrew/bin/parrot",
                isExecutable: exists("/opt/homebrew/bin/parrot", "/usr/local/bin/parrot")
            ),
            "/opt/homebrew/bin/parrot"
        )
    }

    /// The regression this guards: a Homebrew install used to register
    /// /usr/local/bin/parrot, a different copy that goes stale on `brew upgrade`
    /// while holding its own Accessibility grant.
    func testDoesNotPreferUsrLocalOverTheRunningExecutable() {
        let path = Install.agentBinaryPath(
            executablePath: "/opt/homebrew/bin/parrot",
            isExecutable: exists("/opt/homebrew/bin/parrot", "/usr/local/bin/parrot")
        )
        XCTAssertNotEqual(path, "/usr/local/bin/parrot")
    }

    func testRegistersADevBuildWhenThatIsWhatIsRunning() {
        XCTAssertEqual(
            Install.agentBinaryPath(
                executablePath: "/Users/me/parroting/.build/release/parrot",
                isExecutable: exists("/Users/me/parroting/.build/release/parrot")
            ),
            "/Users/me/parroting/.build/release/parrot"
        )
    }

    func testFallsBackWhenTheExecutablePathIsRelative() {
        XCTAssertEqual(
            Install.agentBinaryPath(
                executablePath: "parrot",
                isExecutable: exists("/usr/local/bin/parrot")
            ),
            "/usr/local/bin/parrot"
        )
    }

    func testFallsBackWhenTheExecutablePathIsMissing() {
        XCTAssertEqual(
            Install.agentBinaryPath(
                executablePath: nil,
                isExecutable: exists("/opt/homebrew/bin/parrot")
            ),
            "/opt/homebrew/bin/parrot"
        )
    }

    /// A deleted-but-still-reported path should not be written into the plist.
    func testFallsBackWhenTheExecutablePathIsNotExecutable() {
        XCTAssertEqual(
            Install.agentBinaryPath(
                executablePath: "/tmp/gone/parrot",
                isExecutable: exists("/usr/local/bin/parrot")
            ),
            "/usr/local/bin/parrot"
        )
    }

    func testReturnsNilWhenNothingIsExecutable() {
        XCTAssertNil(
            Install.agentBinaryPath(executablePath: nil, isExecutable: { _ in false })
        )
    }

    func testFallbackOrderPrefersUsrLocal() {
        XCTAssertEqual(
            Install.agentBinaryPath(
                executablePath: nil,
                isExecutable: exists("/usr/local/bin/parrot", "/opt/homebrew/bin/parrot")
            ),
            "/usr/local/bin/parrot"
        )
    }
}
