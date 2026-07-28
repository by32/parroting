import ArgumentParser
import CoreGraphics

/// A modifier key usable as the push-to-talk trigger.
///
/// Detection reads `CGEventFlags` rather than keycodes so it keeps working on
/// keyboards that report nonstandard keycodes for these keys. Left and right
/// variants of the same modifier are told apart by the device-dependent flag
/// bits macOS sets alongside the generic modifier bit (see IOLLEvent.h) —
/// checking `.maskAlternate` alone would fire for either option key.
enum Hotkey: String, CaseIterable, ExpressibleByArgument {
    case fn
    case rightOption = "right-option"
    case rightCommand = "right-command"

    /// Flag bit set while the key is held.
    var flagMask: CGEventFlags {
        switch self {
        case .fn: return .maskSecondaryFn
        case .rightOption: return CGEventFlags(rawValue: 0x0000_0040)   // NX_DEVICERALTKEYMASK
        case .rightCommand: return CGEventFlags(rawValue: 0x0000_0010)  // NX_DEVICERCMDKEYMASK
        }
    }

    var displayName: String {
        switch self {
        case .fn: return "fn"
        case .rightOption: return "right option"
        case .rightCommand: return "right command"
        }
    }

    static var allValueStrings: [String] { allCases.map(\.rawValue) }
}
