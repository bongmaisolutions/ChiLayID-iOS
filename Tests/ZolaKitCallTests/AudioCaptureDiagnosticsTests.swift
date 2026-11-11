import XCTest
@testable import ZolaKit

final class AudioCaptureDiagnosticsTests: XCTestCase {
    func testPlaybackOnlyDistinguishesPermissionFromHardwareAndDuplexStart() {
        var permission = ZolaAudioCaptureDiagnostics()
        permission.beginStartup(authorization: .denied)
        permission.recordFallback(.permission)
        permission.started(.playbackOnly)
        XCTAssertTrue(permission.line.contains("mic-auth=denied audio-path=playbackOnly"))
        XCTAssertTrue(permission.line.contains("audio-fallback=permission:0"))

        var hardware = ZolaAudioCaptureDiagnostics()
        hardware.beginStartup(authorization: .granted)
        hardware.recordFallback(.inputFormat)
        hardware.started(.playbackOnly)
        XCTAssertTrue(hardware.line.contains("audio-fallback=inputFormat:0"))

        var start = ZolaAudioCaptureDiagnostics()
        start.beginStartup(authorization: .granted)
        start.recordFallback(.duplexStart, code: -10875)
        start.started(.playbackOnly)
        XCTAssertTrue(start.line.contains("audio-fallback=duplexStart:-10875"))
        XCTAssertTrue(start.line.contains("audio-start-error=none:0"))
        XCTAssertNotEqual(permission.line, hardware.line)
        XCTAssertNotEqual(hardware.line, start.line)
    }

    func testPlaybackFailureRetainsOriginalDuplexFailure() {
        var diag = ZolaAudioCaptureDiagnostics()
        diag.beginStartup(authorization: .granted)
        diag.recordFallback(.duplexStart, code: -10875)
        diag.failedStartup(.playbackStart, code: -50)
        XCTAssertEqual(diag.path, .failed)
        XCTAssertTrue(diag.line.contains("audio-fallback=duplexStart:-10875"))
        XCTAssertTrue(diag.line.contains("audio-start-error=playbackStart:-50"))
    }

    func testRecoveryClearsStartupCauseButPreservesCallCounters() {
        var diag = ZolaAudioCaptureDiagnostics()
        diag.beginStartup(authorization: .undetermined)
        diag.recordFallback(.permission)
        diag.started(.playbackOnly)
        diag.captureBuffers = 2
        diag.converted(byteCount: 3840)
        diag.converted(byteCount: nil)
        diag.beginStartup(authorization: .granted)
        diag.started(.duplex)
        XCTAssertEqual(diag.authorization, .granted)
        XCTAssertEqual(diag.path, .duplex)
        XCTAssertEqual(diag.fallback.stage, .none)
        XCTAssertEqual(diag.startupFailure.stage, .none)
        XCTAssertEqual(diag.captureBuffers, 2)
        XCTAssertEqual(diag.convertedBytes, 3840)
        XCTAssertEqual(diag.conversionFailures, 1)
    }

    func testConversionAndEncodingFailuresRemainIndependent() {
        var diag = ZolaAudioCaptureDiagnostics()
        diag.captureBuffers = 3
        diag.converted(byteCount: nil)
        diag.converted(byteCount: 1920)
        diag.converted(byteCount: 1920)
        diag.failedEncoding(.encoderCreate, code: -50)
        diag.encodedPackets += 1
        XCTAssertEqual(diag.convertedBuffers, 2)
        XCTAssertEqual(diag.convertedBytes, 3840)
        XCTAssertEqual(diag.conversionFailures, 1)
        XCTAssertEqual(diag.encodingFailures, 1)
        XCTAssertEqual(diag.encodedPackets, 1)
        XCTAssertTrue(diag.line.contains("pcm=2/3840 pcm-fail=1 encoded=1 encode-fail=1"))
    }

    func testEncoderStatusDistinguishesNoOutputFromNumericFailure() {
        var diag = ZolaAudioCaptureDiagnostics()
        diag.failedEncoding(.encoderNoOutput)
        XCTAssertTrue(diag.line.contains("encode-error=encoderNoOutput:0"))
        diag.failedEncoding(.encoderFill, code: -50)
        XCTAssertTrue(diag.line.contains("encode-error=encoderFill:-50"))
        diag.failedEncoding(.encoderOutputBounds)
        XCTAssertEqual(diag.encodingFailures, 3)
        XCTAssertTrue(diag.line.contains("encode-error=encoderOutputBounds:0"))
        // Repeated failures update fixed fields, not an ever-growing history or error text.
        for _ in 0..<1000 { diag.failedEncoding(.encoderFill, code: -50) }
        XCTAssertLessThan(diag.line.utf8.count, 400)
        XCTAssertEqual(diag.line.filter { $0 == "\n" }.count, 0)
    }
}
