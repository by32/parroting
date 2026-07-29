import XCTest

@testable import parrot

final class ConfigWritebackTests: XCTestCase {
    func testEmptyConfigProducesEmptyTOML() {
        XCTAssertEqual(Config.empty.toTOML(), "")
    }

    func testRoundTripsAllKeys() throws {
        var original = Config()
        original.model = "openai_whisper-large-v3-turbo"
        original.hotkey = .rightOption
        original.language = .auto
        original.sensitivity = .high
        original.overlay = false
        original.refine = .local
        original.refineStyle = "formal"

        let toml = original.toTOML()
        let reparsed = try Config.parse(toml)

        XCTAssertEqual(reparsed, original)
    }

    func testWriteCreatesDirectoryAndFile() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("parrot-writeback-\(UUID().uuidString)")
        let file = dir.appendingPathComponent("config.toml")

        var config = Config()
        config.refine = .local

        try config.write(to: file)
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.contains("refine = \"local\""))
    }

    func testWritePreservesCanonicalOrder() throws {
        var config = Config()
        config.refine = .cloud
        config.model = "test-model"
        config.hotkey = .fn

        let toml = config.toTOML()
        let lines = toml.split(separator: "\n").map(String.init)
        let keys = lines.map { $0.split(separator: " ").first.map(String.init) }

        XCTAssertEqual(keys, ["model", "hotkey", "refine"])
    }

    func testBoolSerializedAsLowercase() {
        var config = Config()
        config.overlay = true
        XCTAssertTrue(config.toTOML().contains("overlay = true"))

        config.overlay = false
        XCTAssertTrue(config.toTOML().contains("overlay = false"))
    }
}
