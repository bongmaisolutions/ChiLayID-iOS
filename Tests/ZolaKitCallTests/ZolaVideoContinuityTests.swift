import Foundation
import XCTest
@testable import ZolaKit

#if canImport(AVFoundation) && canImport(VideoToolbox) && canImport(CoreMedia) && canImport(CoreVideo) && canImport(CoreGraphics)
final class ZolaVideoContinuityTests: XCTestCase {
    private enum ContinuityPacket: CaseIterable {
        case padding, fec
    }

    /// Hand-built RTP fragments make the expected NAL independent of our packetizer.
    private func packet(sequence: UInt16, payload: [UInt8], marker: Bool = false,
                        payloadType: UInt8 = 98, padding: Bool = false,
                        timestamp: UInt32 = 90_000) -> Data {
        var bytes: [UInt8] = [padding ? 0xA0 : 0x80, (marker ? 0x80 : 0) | payloadType,
                             UInt8(sequence >> 8), UInt8(sequence & 0xFF)]
        bytes += [UInt8(timestamp >> 24), UInt8((timestamp >> 16) & 0xFF),
                  UInt8((timestamp >> 8) & 0xFF), UInt8(timestamp & 0xFF)]
        bytes += [0x55, 0xAA, 0x77, 0x88] // One video SSRC throughout.
        return Data(bytes + payload)
    }

    private func continuity(_ kind: ContinuityPacket, sequence: UInt16) -> Data {
        switch kind {
        case .padding:
            return packet(sequence: sequence, payload: [0, 0, 0, 4], padding: true, timestamp: 12_345)
        case .fec:
            return packet(sequence: sequence, payload: [0x11, 0x22], payloadType: 116, timestamp: 12_345)
        }
    }

    private func parameterSets(sequence: UInt16) -> Data {
        packet(sequence: sequence, payload: [0x78, 0, 4, 0x67, 0x42, 0xC0, 0x1E,
                                             0, 4, 0x68, 0xCE, 0x3C, 0x80])
    }

    func testMidFragmentContinuityPacketsPreserveIDRIncludingReorderAndSequenceWrap() {
        for kind in ContinuityPacket.allCases {
            for reorderWindow in [0, 16] {
                for startSequence: UInt16 in [10, 65_534] {
                    var receiver = ZolaH264RtpDepacketizer(reorderWindow: reorderWindow)
                    _ = receiver.ingestRtpPacket(parameterSets(sequence: startSequence &- 1), arrivalUptime: 1)
                    _ = receiver.ingestRtpPacket(packet(sequence: startSequence, payload: [0x7C, 0x85, 0x11, 0x22]), arrivalUptime: 1.001)
                    let filler = continuity(kind, sequence: startSequence &+ 1)
                    let end = packet(sequence: startSequence &+ 2, payload: [0x7C, 0x45, 0x33, 0x44], marker: true)
                    // Reordered delivery must wait for the continuity packet, then finish the same IDR.
                    let packets = reorderWindow == 0 ? [filler, end] : [end, filler]
                    let units = packets.flatMap { receiver.ingestRtpPacket($0, arrivalUptime: 1.002) }
                    let context = "kind=\(kind), reorder=\(reorderWindow), seq=\(startSequence)"
                    XCTAssertEqual(units.count, 1, context)
                    XCTAssertEqual(units.first?.vclNalUnits, [Data([0x65, 0x11, 0x22, 0x33, 0x44])], context)
                    XCTAssertEqual(units.first?.rtpTimestamp, 90_000, context)
                    XCTAssertEqual(units.first?.containsIdr, true, context)
                    XCTAssertFalse(receiver.needsKeyframePli, context)
                }
            }
        }
    }

    func testContinuityPacketCannotHideAnActuallyMissingFuFragment() {
        for kind in ContinuityPacket.allCases {
            for reorderWindow in [0, 16] {
                var receiver = ZolaH264RtpDepacketizer(reorderWindow: reorderWindow)
                _ = receiver.ingestRtpPacket(parameterSets(sequence: 9), arrivalUptime: 1)
                _ = receiver.ingestRtpPacket(packet(sequence: 10, payload: [0x7C, 0x85, 0x11, 0x22]), arrivalUptime: 1.001)
                // Fragment 11 really was lost; packet 12 is only a probe/FEC, not a replacement.
                var units = receiver.ingestRtpPacket(continuity(kind, sequence: 12), arrivalUptime: 1.002)
                units += receiver.ingestRtpPacket(packet(sequence: 13, payload: [0x7C, 0x45, 0x33, 0x44], marker: true), arrivalUptime: 1.003)
                units += receiver.flushExpiredReorderBuffer(nowUptime: 1.1)
                XCTAssertTrue(units.isEmpty)
                XCTAssertTrue(receiver.needsKeyframePli)
                receiver.clearPliFlag()
                let recovery = receiver.ingestRtpPacket(packet(sequence: 14, payload: [0x65, 0x55], marker: true, timestamp: 180_000), arrivalUptime: 1.2)
                XCTAssertEqual(recovery.first?.vclNalUnits, [Data([0x65, 0x55])])
                XCTAssertFalse(receiver.needsKeyframePli)
            }
        }
    }
}
#endif
