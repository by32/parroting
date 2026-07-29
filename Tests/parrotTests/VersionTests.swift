import XCTest

@testable import parrot

final class VersionTests: XCTestCase {
    /// The release workflow compares `parrot --version` against the git tag with
    /// a plain string match, and the Homebrew formula and Info.plist both
    /// interpolate this value. A stray "v" prefix or whitespace breaks all three.
    func testCurrentIsBarePlainSemver() {
        let version = Version.current

        XCTAssertFalse(version.hasPrefix("v"), "tags carry the v, the constant should not")
        XCTAssertEqual(version, version.trimmingCharacters(in: .whitespacesAndNewlines))

        let components = version.split(separator: ".", omittingEmptySubsequences: false)
        XCTAssertEqual(components.count, 3, "expected major.minor.patch, got \(version)")
        for component in components {
            XCTAssertFalse(component.isEmpty, "empty component in \(version)")
            XCTAssertTrue(
                component.allSatisfy(\.isNumber),
                "non-numeric component \(component) in \(version)"
            )
        }
    }

    /// CFBundleVersion rejects a leading zero in a component (e.g. "1.01").
    func testComponentsHaveNoLeadingZeros() {
        for component in Version.current.split(separator: ".") {
            if component.count > 1 {
                XCTAssertNotEqual(component.first, "0", "leading zero in \(Version.current)")
            }
        }
    }
}
