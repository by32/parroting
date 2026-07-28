import XCTest

@testable import parrot

final class ModelRegistryTests: XCTestCase {
    func testRegistryIsNotEmpty() {
        XCTAssertFalse(ModelRegistry.shared.isEmpty)
    }

    func testFindLocatesEveryRegisteredModel() {
        for model in ModelRegistry.shared {
            XCTAssertEqual(ModelRegistry.find(model.id)?.id, model.id)
        }
    }

    func testFindReturnsNilForUnknownID() {
        XCTAssertNil(ModelRegistry.find("whisper-does-not-exist"))
        XCTAssertNil(ModelRegistry.find(""))
    }

    func testIDsAreUnique() {
        let ids = ModelRegistry.shared.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "duplicate model ids: \(ids)")
    }

    func testRecommendedIsResolvable() throws {
        let recommended = try XCTUnwrap(ModelRegistry.recommended())
        XCTAssertEqual(ModelRegistry.find(recommended.id)?.id, recommended.id)
    }

    /// `recommended()` falls back to the first entry, so more than one flagged
    /// model would make the choice depend on declaration order.
    func testAtMostOneModelIsFlaggedRecommended() {
        XCTAssertLessThanOrEqual(ModelRegistry.shared.filter(\.recommended).count, 1)
    }

    func testEveryWhisperKitModelCarriesAnEngineID() {
        for model in ModelRegistry.shared where model.engine == .whisperKit {
            XCTAssertNotNil(model.whisperKitID, "\(model.id) has no WhisperKit id")
            XCTAssertFalse(model.whisperKitID?.isEmpty ?? true)
        }
    }

    func testMetadataIsPopulated() {
        for model in ModelRegistry.shared {
            XCTAssertFalse(model.id.isEmpty)
            XCTAssertFalse(model.displayName.isEmpty)
            XCTAssertGreaterThan(model.sizeMB, 0, "\(model.id) has no size")
            XCTAssertFalse(model.languages.isEmpty, "\(model.id) declares no languages")
        }
    }
}
