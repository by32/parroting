import XCTest

@testable import parrot

final class StylesTests: XCTestCase {
    private func styles(_ toml: String) throws -> Styles {
        try Styles.parse(toml)
    }

    func testEmptyFileYieldsNoStyles() throws {
        XCTAssertTrue(try styles("").isEmpty)
        XCTAssertTrue(try styles("# only a comment").isEmpty)
    }

    func testParsesBundleIDToStyle() throws {
        let s = try styles(
            #"""
            "com.apple.mail" = "formal"
            "com.apple.MobileSMS" = "casual"
            """#
        )
        XCTAssertEqual(s.style(for: "com.apple.mail"), "formal")
        XCTAssertEqual(s.style(for: "com.apple.MobileSMS"), "casual")
    }

    func testCountsApps() throws {
        let s = try styles(
            #"""
            "com.apple.mail" = "formal"
            "com.apple.MobileSMS" = "casual"
            """#
        )
        XCTAssertEqual(s.count, 2)
    }

    func testUnmatchedBundleIDReturnsNil() throws {
        let s = try styles(#""com.apple.mail" = "formal""#)
        XCTAssertNil(s.style(for: "com.other.app"))
    }

    func testEmptyStylesReturnsNilForAnyBundle() {
        XCTAssertNil(Styles.empty.style(for: "com.apple.mail"))
    }

    func testRejectsDuplicateBundleID() {
        XCTAssertThrowsError(
            try styles(
                #"""
                "com.apple.mail" = "formal"
                "com.apple.mail" = "casual"
                """#
            )
        ) { error in
            XCTAssertTrue("\(error)".contains("duplicate style"), "\(error)")
        }
    }

    func testRejectsEmptyKey() {
        XCTAssertThrowsError(try styles("\"\" = \"formal\"")) { error in
            XCTAssertTrue("\(error)".contains("cannot be empty"), "\(error)")
        }
    }

    func testRejectsUnquotedStyle() {
        XCTAssertThrowsError(try styles(#""com.apple.mail" = bare"#))
    }

    func testErrorReportsLineNumber() {
        XCTAssertThrowsError(
            try Styles.parse(
                #""com.apple.mail" = "formal""# + "\n" + #""com.apple.mail" = "casual""#,
                source: "/tmp/styles.toml"
            )
        ) { error in
            XCTAssertTrue("\(error)".contains("/tmp/styles.toml:2"), "\(error)")
        }
    }

    func testLoadReturnsEmptyWhenFileMissing() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("parrot-styles-missing-\(UUID().uuidString).toml")
        XCTAssertTrue(try Styles.load(from: url).isEmpty)
    }

    func testLoadReadsFromDisk() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("parrot-styles-\(UUID().uuidString).toml")
        try #""com.apple.mail" = "formal""#.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(try Styles.load(from: url).style(for: "com.apple.mail"), "formal")
    }

    func testBundleIDsList() throws {
        let s = try styles(
            #"""
            "com.apple.mail" = "formal"
            "com.apple.MobileSMS" = "casual"
            """#
        )
        let ids = s.bundleIDs
        XCTAssertEqual(Set(ids), Set(["com.apple.mail", "com.apple.MobileSMS"]))
    }
}
