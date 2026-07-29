import XCTest

@testable import parrot

final class CaptureGateTests: XCTestCase {
    private let rate = AudioCapture.targetSampleRate

    private func samples(seconds: Double) -> Int {
        Int(seconds * rate)
    }

    func testEmptyCaptureIsRejected() {
        XCTAssertEqual(CaptureGate.evaluate(sampleCount: 0, rms: 0.5), .empty)
    }

    func testShortCaptureIsRejectedEvenWhenLoud() {
        let verdict = CaptureGate.evaluate(sampleCount: samples(seconds: 0.05), rms: 0.9)
        XCTAssertEqual(verdict, .tooShort(seconds: 0.05))
    }

    func testQuietCaptureIsRejectedEvenWhenLong() {
        let verdict = CaptureGate.evaluate(sampleCount: samples(seconds: 3), rms: 0.0001)
        XCTAssertEqual(verdict, .tooQuiet(rms: 0.0001))
    }

    func testNormalSpeechIsAccepted() {
        let verdict = CaptureGate.evaluate(sampleCount: samples(seconds: 2.5), rms: 0.08)
        XCTAssertEqual(verdict, .transcribe)
        XCTAssertNil(verdict.rejectionReason)
    }

    func testDurationIsCheckedBeforeLevel() {
        // A clip that fails both checks reports the more fundamental reason.
        let verdict = CaptureGate.evaluate(sampleCount: samples(seconds: 0.01), rms: 0)
        XCTAssertEqual(verdict, .tooShort(seconds: 0.01))
    }

    func testThresholdBoundariesAreInclusive() {
        let atMinDuration = CaptureGate.evaluate(
            sampleCount: samples(seconds: CaptureGate.minSeconds),
            rms: 0.5
        )
        XCTAssertEqual(atMinDuration, .transcribe)

        let atMinLevel = CaptureGate.evaluate(
            sampleCount: samples(seconds: 1),
            rms: CaptureGate.Sensitivity.normal.minRMS
        )
        XCTAssertEqual(atMinLevel, .transcribe)
    }

    // MARK: - Sensitivity

    func testHighSensitivityAcceptsWhisperQuietSpeech() {
        // A level that normal treats as silence, which is what makes whispered
        // dictation impossible at the default threshold.
        let whisper: Float = 0.002
        XCTAssertEqual(
            CaptureGate.evaluate(sampleCount: samples(seconds: 2), rms: whisper),
            .tooQuiet(rms: whisper)
        )
        XCTAssertEqual(
            CaptureGate.evaluate(
                sampleCount: samples(seconds: 2),
                rms: whisper,
                sensitivity: .high
            ),
            .transcribe
        )
    }

    func testHighSensitivityStillRejectsTrueSilence() {
        XCTAssertEqual(
            CaptureGate.evaluate(sampleCount: samples(seconds: 2), rms: 0, sensitivity: .high),
            .tooQuiet(rms: 0)
        )
    }

    func testHighSensitivityStillEnforcesMinimumDuration() {
        XCTAssertEqual(
            CaptureGate.evaluate(
                sampleCount: samples(seconds: 0.05),
                rms: 0.9,
                sensitivity: .high
            ),
            .tooShort(seconds: 0.05)
        )
    }

    func testHighThresholdIsLowerThanNormal() {
        XCTAssertLessThan(
            CaptureGate.Sensitivity.high.minRMS,
            CaptureGate.Sensitivity.normal.minRMS
        )
    }

    func testSensitivityParsesFromItsAdvertisedNames() {
        XCTAssertEqual(CaptureGate.Sensitivity.allValueStrings, ["normal", "high"])
        for name in CaptureGate.Sensitivity.allValueStrings {
            XCTAssertNotNil(CaptureGate.Sensitivity(rawValue: name))
        }
        XCTAssertNil(CaptureGate.Sensitivity(rawValue: "maximum"))
    }

    func testRejectionReasonsAreHumanReadable() {
        XCTAssertEqual(CaptureGate.Verdict.empty.rejectionReason, "no audio captured")
        XCTAssertEqual(
            CaptureGate.Verdict.tooShort(seconds: 0.05).rejectionReason,
            "too short (0.05s)"
        )
        XCTAssertEqual(
            CaptureGate.Verdict.tooQuiet(rms: 0.0012).rejectionReason,
            "too quiet (rms 0.0012)"
        )
    }
}

final class RMSTests: XCTestCase {
    func testEmptyBufferIsSilent() {
        XCTAssertEqual(computeRMS([]), 0)
    }

    func testSilenceIsZero() {
        XCTAssertEqual(computeRMS([0, 0, 0, 0]), 0)
    }

    func testFullScaleSquareWaveIsOne() {
        XCTAssertEqual(computeRMS([1, -1, 1, -1]), 1, accuracy: 1e-6)
    }

    func testMatchesKnownRMS() {
        // rms([3,4]) = sqrt((9+16)/2) = sqrt(12.5)
        XCTAssertEqual(computeRMS([3, 4]), Float(12.5.squareRoot()), accuracy: 1e-5)
    }

    func testSignIsIgnored() {
        XCTAssertEqual(computeRMS([0.5, -0.5]), computeRMS([0.5, 0.5]), accuracy: 1e-6)
    }
}

final class WAVWriterTests: XCTestCase {
    private func write(_ samples: [Float], sampleRate: Int = 16_000) throws -> Data {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("parrot-wav-\(UUID().uuidString).wav")
        try WAVWriter.write(samples: samples, sampleRate: sampleRate, to: url.path)
        defer { try? FileManager.default.removeItem(at: url) }
        return try Data(contentsOf: url)
    }

    private func uint32(_ data: Data, at offset: Int) -> UInt32 {
        data[offset..<offset + 4].reversed().reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    private func uint16(_ data: Data, at offset: Int) -> UInt16 {
        data[offset..<offset + 2].reversed().reduce(UInt16(0)) { ($0 << 8) | UInt16($1) }
    }

    func testHeaderDescribes16BitMonoPCM() throws {
        let data = try write([0, 0.5, -0.5], sampleRate: 16_000)

        XCTAssertEqual(String(decoding: data[0..<4]), "RIFF")
        XCTAssertEqual(String(decoding: data[8..<12]), "WAVE")
        XCTAssertEqual(String(decoding: data[12..<16]), "fmt ")
        XCTAssertEqual(String(decoding: data[36..<40]), "data")

        XCTAssertEqual(uint32(data, at: 16), 16, "fmt chunk size")
        XCTAssertEqual(uint16(data, at: 20), 1, "PCM format tag")
        XCTAssertEqual(uint16(data, at: 22), 1, "mono")
        XCTAssertEqual(uint32(data, at: 24), 16_000, "sample rate")
        XCTAssertEqual(uint16(data, at: 34), 16, "bits per sample")
    }

    func testSizeFieldsMatchPayload() throws {
        let samples = [Float](repeating: 0.25, count: 100)
        let data = try write(samples)

        let dataSize = UInt32(samples.count * 2)
        XCTAssertEqual(uint32(data, at: 40), dataSize, "data chunk size")
        XCTAssertEqual(uint32(data, at: 4), 36 + dataSize, "RIFF chunk size")
        XCTAssertEqual(data.count, 44 + Int(dataSize))
    }

    func testSampleRateIsHonored() throws {
        let data = try write([0.1], sampleRate: 48_000)
        XCTAssertEqual(uint32(data, at: 24), 48_000)
        XCTAssertEqual(uint32(data, at: 28), 48_000 * 2, "byte rate")
    }

    func testSamplesAreScaledToInt16() throws {
        let data = try write([0, 1, -1])
        XCTAssertEqual(Int16(bitPattern: uint16(data, at: 44)), 0)
        XCTAssertEqual(Int16(bitPattern: uint16(data, at: 46)), 32_767)
        XCTAssertEqual(Int16(bitPattern: uint16(data, at: 48)), -32_767)
    }

    func testOutOfRangeSamplesAreClamped() throws {
        let data = try write([2.5, -2.5])
        XCTAssertEqual(Int16(bitPattern: uint16(data, at: 44)), 32_767)
        XCTAssertEqual(Int16(bitPattern: uint16(data, at: 46)), -32_767)
    }

    func testEmptyInputWritesHeaderOnly() throws {
        let data = try write([])
        XCTAssertEqual(data.count, 44)
        XCTAssertEqual(uint32(data, at: 40), 0)
    }
}

extension String {
    fileprivate init(decoding slice: Data) {
        self = String(decoding: slice, as: UTF8.self)
    }
}
