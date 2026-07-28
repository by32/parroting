import CoreGraphics
import XCTest

@testable import parrot

final class HotkeyTests: XCTestCase {
    func testParsesEveryDocumentedName() {
        XCTAssertEqual(Hotkey(rawValue: "fn"), .fn)
        XCTAssertEqual(Hotkey(rawValue: "right-option"), .rightOption)
        XCTAssertEqual(Hotkey(rawValue: "right-command"), .rightCommand)
    }

    func testRejectsUnknownNames() {
        XCTAssertNil(Hotkey(rawValue: "left-option"))
        XCTAssertNil(Hotkey(rawValue: "Fn"))
        XCTAssertNil(Hotkey(rawValue: ""))
    }

    func testAdvertisedValuesMatchTheParsableCases() {
        XCTAssertEqual(Hotkey.allValueStrings, ["fn", "right-option", "right-command"])
        for name in Hotkey.allValueStrings {
            XCTAssertNotNil(Hotkey(rawValue: name), "\(name) is advertised but not parsable")
        }
    }

    func testEveryCaseHasADistinctMaskAndName() {
        let masks = Set(Hotkey.allCases.map(\.flagMask.rawValue))
        XCTAssertEqual(masks.count, Hotkey.allCases.count, "hotkeys must not share a flag bit")

        let names = Set(Hotkey.allCases.map(\.displayName))
        XCTAssertEqual(names.count, Hotkey.allCases.count)
    }

    func testMasksMatchTheSystemFlagBits() {
        XCTAssertEqual(Hotkey.fn.flagMask, .maskSecondaryFn)
        // Device-dependent bits from IOLLEvent.h, which is how a right-hand
        // modifier is told apart from its left-hand twin.
        XCTAssertEqual(Hotkey.rightOption.flagMask.rawValue, 0x0000_0040)
        XCTAssertEqual(Hotkey.rightCommand.flagMask.rawValue, 0x0000_0010)
    }

    /// The generic `.maskAlternate` / `.maskCommand` bits are set by both the
    /// left and right key, so relying on them would fire on the wrong key.
    func testRightHandMasksAreNotTheGenericModifierBits() {
        XCTAssertNotEqual(Hotkey.rightOption.flagMask, .maskAlternate)
        XCTAssertNotEqual(Hotkey.rightCommand.flagMask, .maskCommand)
    }

    func testDeviceBitsAreDistinguishableFromTheLeftHandTwin() {
        // What a tap sees while left option alone is held: generic bit plus the
        // left device bit. Right option must not read as pressed.
        let leftOptionHeld = CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x20)
        XCTAssertFalse(leftOptionHeld.contains(Hotkey.rightOption.flagMask))

        let rightOptionHeld = CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x40)
        XCTAssertTrue(rightOptionHeld.contains(Hotkey.rightOption.flagMask))
    }

    func testDisplayNamesAreHumanReadable() {
        XCTAssertEqual(Hotkey.fn.displayName, "fn")
        XCTAssertEqual(Hotkey.rightOption.displayName, "right option")
        XCTAssertEqual(Hotkey.rightCommand.displayName, "right command")
    }
}
