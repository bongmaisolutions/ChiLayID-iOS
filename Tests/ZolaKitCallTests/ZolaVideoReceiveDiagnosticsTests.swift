import Foundation
import XCTest
@testable import ZolaKit

#if canImport(AVFoundation) && canImport(VideoToolbox) && canImport(CoreMedia) && canImport(CoreVideo) && canImport(CoreGraphics)
final class ZolaVideoReceiveDiagnosticsTests: XCTestCase {
    private func packet(_ seq: UInt16, _ payload: [UInt8], marker: Bool = false) -> Data {
        Data([0x80, marker ? 0xE2 : 0x62, UInt8(seq >> 8), UInt8(seq & 255),
              0, 1, 0x5F, 0x90, 0x11, 0x22, 0x33, 0x44] + payload)
    }

    func testCountersDistinguishParameterSetsFromCompletedAndLostAccessUnits() {
        var receiver = ZolaH264RtpDepacketizer()
        _ = receiver.ingestRtpPacket(packet(1, [0x78, 0, 2, 0x67, 0x42, 0, 2, 0x68, 0xCE]))
        XCTAssertEqual(receiver.receiveStageCounters.sps, 1)
        XCTAssertEqual(receiver.receiveStageCounters.pps, 1)
        XCTAssertEqual(receiver.receiveStageCounters.assembled, 0)
        _ = receiver.ingestRtpPacket(packet(2, [0x7C, 0x85, 0x11]))
        // The actual missing FU fragment must be distinguishable from a decoder failure.
        _ = receiver.ingestRtpPacket(packet(4, [0x7C, 0x45, 0x22], marker: true))
        XCTAssertEqual(receiver.receiveStageCounters.rejectedFu, 1)
        XCTAssertEqual(receiver.receiveStageCounters.assembled, 0)
        _ = receiver.ingestRtpPacket(packet(5, [0x65, 0x33], marker: true))
        XCTAssertEqual(receiver.receiveStageCounters.assembled, 1)
        XCTAssertEqual(receiver.receiveStageCounters.sps, 1)
        XCTAssertEqual(receiver.receiveStageCounters.pps, 1)
    }

    func testCorruptMultiSliceUnitIsCountedAtAssemblyBeforeDecoder() {
        var receiver = ZolaH264RtpDepacketizer()
        _ = receiver.ingestRtpPacket(packet(1, [0x61, 0x11]))
        _ = receiver.ingestRtpPacket(packet(3, [0x61, 0x22], marker: true))
        XCTAssertEqual(receiver.receiveStageCounters.corrupt, 1)
        XCTAssertEqual(receiver.receiveStageCounters.assembled, 0)
    }

    func testEngineLogSeparatesMissingParameterSetsFromVideoToolboxErrors() {
        let receiver = ZolaVoipVideoEngine(callId: 88_901)
        receiver.ensureDecoderRunning()
        defer { receiver.stop() }
        receiver.handleInboundVideoPacket(packet(1, [0x65, 0x11], marker: true), isRtcp: false)
        // Existing queue barrier waits for ingress processing without using camera/network.
        XCTAssertEqual(receiver.currentDecodedFrameCount, 0)
        let line = receiver.diagnosticsLine
        XCTAssertTrue(line.contains("nal=[5:1]"), line)
        XCTAssertTrue(line.contains("sps-pps=0/0 au=1/0 fu-loi=0"), line)
        XCTAssertTrue(line.contains("cho-sps=1 cho-idr=0 vt-vao=0 vt-loi=none:0"), line)
        XCTAssertTrue(line.contains("loi-giaima=0"), line)
    }

    func testInvalidParameterSetsReportNumericFormatErrorBeforeDecodeSubmission() {
        let receiver = ZolaVoipVideoEngine(callId: 88_902)
        receiver.ensureDecoderRunning()
        defer { receiver.stop() }
        receiver.handleInboundVideoPacket(packet(1, [0x78, 0, 2, 0x67, 0x42, 0, 2, 0x68, 0xCE]), isRtcp: false)
        receiver.handleInboundVideoPacket(packet(2, [0x65, 0x11], marker: true), isRtcp: false)
        XCTAssertEqual(receiver.currentDecodedFrameCount, 0)
        let line = receiver.diagnosticsLine
        XCTAssertTrue(line.contains("sps-pps=1/1 au=1/0"), line)
        XCTAssertTrue(line.contains("vt-vao=0 vt-loi=format:-"), line)
        XCTAssertTrue(line.contains("loi-giaima=1"), line)
    }
}
#endif
