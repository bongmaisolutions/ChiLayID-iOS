import Foundation
import XCTest
@testable import ZolaKit

#if canImport(AVFoundation) && canImport(VideoToolbox) && canImport(CoreMedia) && canImport(CoreVideo) && canImport(CoreGraphics)
final class ZolaNativeVideoFrameTests: XCTestCase {
    private func bytes(_ hex: String) -> Data {
        let chars = Array(hex)
        return Data(stride(from: 0, to: chars.count, by: 2).map {
            UInt8(String(chars[$0...($0 + 1)]), radix: 16)!
        })
    }

    private func rtp(_ payload: Data, seq: UInt16, marker: Bool, pt: UInt8 = 98,
                     timestamp: UInt32 = 90_000) -> Data {
        Data([0x80, (marker ? 0x80 : 0) | pt, UInt8(seq >> 8), UInt8(seq & 255),
              UInt8(timestamp >> 24), UInt8((timestamp >> 16) & 255),
              UInt8((timestamp >> 8) & 255), UInt8(timestamp & 255), 0x11, 0x22, 0x33, 0x44]) + payload
    }

    // Golden payloads emitted by the unmodified native261002 packetizer (mode0,
    // headerLength0) from synthetic bytes, independent of ZolaKit's packetizer.
    func testNativeTypeZeroFuReassemblesWholeAnnexBFrame() {
        let fixtures: [[String]] = [
            [
                "1c80000000016742c01eda02800000000168ce3c80000000016530313233343536",
                "1c003738393a3b3c3d3e3f404142434445464748494a4b4c4d3031323334353637",
                "1c0038393a3b3c3d3e3f404142434445464748494a4b4c4d303132333435363738",
                "1c40393a3b3c3d3e3f404142434445464748494a4b4c4d30313233343536373839",
            ],
            [
                "1c800000016742c01eda028000000168ce3c800000016530313233343536373839",
                "1c003a3b3c3d3e3f404142434445464748494a4b4c4d303132333435363738393a",
                "1c003b3c3d3e3f404142434445464748494a4b4c4d303132333435363738393a3b",
                "1c403c3d3e3f404142434445464748494a4b4c4d30313233343536373839",
            ],
        ]
        let expectedIDR = Data([0x65] + (0..<100).map { UInt8(0x30 + $0 % 30) })
        for fixture in fixtures {
            for reorder in [0, 16] {
                var receiver = ZolaH264RtpDepacketizer(reorderWindow: reorder)
                let packets = fixture.enumerated().map {
                    rtp(bytes($0.element), seq: UInt16($0.offset + 100), marker: $0.offset == fixture.count - 1)
                }
                var order = Array(packets.indices)
                if reorder > 0 { order.swapAt(1, 2) }
                let units = order.flatMap { receiver.ingestRtpPacket(packets[$0], arrivalUptime: 1) }
                XCTAssertEqual(units.count, 1)
                XCTAssertEqual(units.first?.sps, bytes("6742c01eda0280"))
                XCTAssertEqual(units.first?.pps, bytes("68ce3c80"))
                XCTAssertEqual(units.first?.vclNalUnits, [expectedIDR])
                XCTAssertEqual(units.first?.containsIdr, true)
                XCTAssertEqual(receiver.receiveStageCounters.assembled, 1)
                XCTAssertFalse(receiver.needsKeyframePli)
            }
        }
    }
    private func nativeFragments(_ frame: Data, seq: UInt16 = 1, pt: UInt8 = 98,
                                 timestamp: UInt32 = 90_000, chunkSize: Int = 17) -> [Data] {
        let chunks = stride(from: 0, to: frame.count, by: chunkSize).map {
            frame.subdata(in: $0..<min(frame.count, $0 + chunkSize))
        }
        return chunks.enumerated().map { index, chunk in
            let end = index == chunks.count - 1
            return rtp(Data([0x1C, (index == 0 ? 0x80 : 0) | (end ? 0x40 : 0)]) + chunk,
                       seq: seq &+ UInt16(index), marker: end, pt: pt, timestamp: timestamp)
        }
    }

    func testRawNativeSmallAnnexBFrameAndMixedStartCodes() {
        for frame in ["00000001418884", "000001418884"] {
            var receiver = ZolaH264RtpDepacketizer()
            let units = receiver.ingestRtpPacket(rtp(bytes(frame), seq: 1, marker: true, pt: 97))
            XCTAssertEqual(units.first?.vclNalUnits, [bytes("418884")])
            XCTAssertEqual(units.first?.containsIdr, false)
        }
        var receiver = ZolaH264RtpDepacketizer()
        let mixed = bytes("000000016742c01eda028000000168ce3c8000000001651234000001612345")
        let packets = nativeFragments(mixed, chunkSize: 2) // Split start codes across packets.
        let units = packets.flatMap { receiver.ingestRtpPacket($0) }
        XCTAssertEqual(units.count, 1)
        XCTAssertEqual(units.first?.sps, bytes("6742c01eda0280"))
        XCTAssertEqual(units.first?.pps, bytes("68ce3c80"))
        XCTAssertEqual(units.first?.vclNalUnits, [bytes("651234"), bytes("612345")])
    }

    func testIncompleteNativeFrameNeverPublishesPartialParameterSetsAndNextIDRRecovers() {
        let frame = bytes("000000016742c01eda02800000000168ce3c800000000165123456789abc")
        let packets = nativeFragments(frame, chunkSize: 5)
        for missing in packets.indices {
            var receiver = ZolaH264RtpDepacketizer()
            let incomplete = packets.enumerated().filter { $0.offset != missing }
                .flatMap { receiver.ingestRtpPacket($0.element) }
            XCTAssertTrue(incomplete.isEmpty)
            XCTAssertNil(receiver.latestSps)
            XCTAssertNil(receiver.latestPps)
            let next = nativeFragments(frame, seq: UInt16(packets.count + 1), timestamp: 180_000)
                .flatMap { receiver.ingestRtpPacket($0) }
            XCTAssertEqual(next.count, 1, "Missing fragment \(missing) must not poison next intact IDR")
        }
    }

    func testRawFrameCancelsOlderIncompleteNativeFragment() {
        var receiver = ZolaH264RtpDepacketizer()
        _ = receiver.ingestRtpPacket(rtp(bytes("1c8000000001651234"), seq: 1, marker: false))
        let raw = receiver.ingestRtpPacket(rtp(bytes("00000001655678"), seq: 2,
                                               marker: true, timestamp: 180_000))
        XCTAssertEqual(raw.first?.vclNalUnits, [bytes("655678")])
        let late = receiver.ingestRtpPacket(rtp(bytes("1c409abc"), seq: 3, marker: true))
        XCTAssertTrue(late.isEmpty)
        XCTAssertEqual(receiver.receiveStageCounters.rejectedFu, 1)
    }

    func testMalformedNativeBundleCannotPartiallyUpdateParameterSets() {
        for frame in ["000000016742c01eda02800000000100abcd", "000000016742c01eda028000000001",
                      "123400000001651234", "00000001851234"] {
            var receiver = ZolaH264RtpDepacketizer()
            let units = nativeFragments(bytes(frame)).flatMap { receiver.ingestRtpPacket($0) }
            XCTAssertTrue(units.isEmpty)
            XCTAssertNil(receiver.latestSps)
            XCTAssertNil(receiver.latestPps)
            XCTAssertTrue(receiver.needsKeyframePli)
        }
    }

    func testNativeFramePacketsReachHardwareDecoderAndProduceRemoteImages() async throws {
        final class EncodedPackets: @unchecked Sendable {
            let lock = NSLock()
            var packets: [Data] = []
        }
        let state = EncodedPackets()
        let encoded = expectation(description: "Three synthetic frames encoded")
        encoded.expectedFulfillmentCount = 3
        let sender = ZolaVoipVideoEngine(callId: 900_101)
        let receiver = ZolaVoipVideoEngine(callId: 900_102)
        defer { sender.stop(); receiver.stop() }
        sender.onOutboundVideoPacket = { packet, isRtcp in
            guard !isRtcp, let parsed = ZolaH264RtpDepacketizer.parseRtpPacket(packet) else { return }
            state.lock.withLock { state.packets.append(packet) }
            if parsed.marker { encoded.fulfill() }
        }
        sender.ensureDecoderRunning()
        for index in 0..<3 {
            XCTAssertTrue(sender.encodeSyntheticFrame(width: 640, height: 480,
                r: UInt8(30 + index * 30), forceKeyframe: index == 0))
        }
        await fulfillment(of: [encoded], timeout: 5)
        var standardAssembler = ZolaH264RtpDepacketizer()
        let standardPackets = state.lock.withLock { state.packets }
        let units = standardPackets.flatMap { standardAssembler.ingestRtpPacket($0) }
        XCTAssertEqual(units.count, 3)
        let decoded = expectation(description: "Native mode0 IDR and delta frames produce images")
        decoded.expectedFulfillmentCount = 3
        receiver.onRemoteVideoFrame = { image in
            XCTAssertEqual(image.width, 640)
            XCTAssertEqual(image.height, 480)
            decoded.fulfill()
        }
        receiver.ensureDecoderRunning()
        var seq: UInt16 = 65_530
        for unit in units {
            var nals = unit.vclNalUnits
            if unit.containsIdr {
                nals = [try XCTUnwrap(unit.sps), try XCTUnwrap(unit.pps)] + nals
            }
            let annexB = nals.reduce(into: Data()) { result, nal in
                result.append(contentsOf: [0, 0, 0, 1]); result.append(nal)
            }
            // Header/framing matches the separately captured native golden fixtures.
            var packets = nativeFragments(annexB, seq: seq, pt: unit.containsIdr ? 98 : 97,
                                          timestamp: unit.rtpTimestamp, chunkSize: 100)
            seq = seq &+ UInt16(packets.count)
            if packets.count > 2 { packets.swapAt(1, 2) }
            for packet in packets { receiver.handleInboundVideoPacket(packet, isRtcp: false) }
        }
        await fulfillment(of: [decoded], timeout: 5)
        XCTAssertEqual(receiver.currentDecodedFrameCount, 3)
        XCTAssertTrue(receiver.diagnosticsLine.contains("annexb=3"), receiver.diagnosticsLine)
    }

}
#endif
