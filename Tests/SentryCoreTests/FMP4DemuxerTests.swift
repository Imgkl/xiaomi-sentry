import CoreMedia
import Foundation
import Testing
import VideoToolbox
@testable import SentryCore

/// Fixtures are silent test patterns:
/// - go2rtc-hevc.mp4: captured from go2rtc 1.9.14 /api/stream.mp4 (one frame per moof+mdat, hev1),
///   cut mid-fragment at the end like a live socket.
/// - ffmpeg-hevc-bframes.mp4: hvc1 with B-frames, several samples per fragment.
/// - ffmpeg-h264.mp4: avc1, one frame per fragment.
struct FMP4DemuxerTests {
    static let fixtures = ["go2rtc-hevc.mp4", "ffmpeg-hevc-bframes.mp4", "ffmpeg-h264.mp4"]

    @Test(arguments: fixtures)
    func demuxesAndHardwareDecodesEveryFrame(_ name: String) throws {
        let demuxer = FMP4Demuxer()
        let frames = try feed(name, into: demuxer, chunk: 3001)

        #expect(frames.count >= 15)
        #expect(frames.first?.isKeyframe == true)
        #expect(demuxer.width == 320 && demuxer.height == 180)
        #expect(try decode(frames) == frames.count)
    }

    @Test(arguments: fixtures)
    func chunkSizeDoesNotChangeTheResult(_ name: String) throws {
        let whole = try feed(name, into: FMP4Demuxer(), chunk: .max)
        let tiny = try feed(name, into: FMP4Demuxer(), chunk: 7)
        #expect(whole.count == tiny.count)
    }

    @Test func detectsCodecs() throws {
        let hevc = FMP4Demuxer()
        _ = try feed("go2rtc-hevc.mp4", into: hevc, chunk: .max)
        #expect(hevc.codec == .hevc)

        let h264 = FMP4Demuxer()
        _ = try feed("ffmpeg-h264.mp4", into: h264, chunk: .max)
        #expect(h264.codec == .h264)
    }

    @Test func garbageProducesNoFramesAndDoesNotCrash() {
        let demuxer = FMP4Demuxer()
        let noise = Data((0..<20_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        #expect(demuxer.append(noise).isEmpty)
        // A box that claims to be shorter than its own header resets the parser.
        #expect(demuxer.append(Data([0, 0, 0, 4, 0x6D, 0x6F, 0x6F, 0x66])).isEmpty)
    }

    @Test func fragmentsBeforeTheInitSegmentAreSkipped() throws {
        let data = try fixture("go2rtc-hevc.mp4")
        let demuxer = FMP4Demuxer()
        // Drop the init segment (ftyp + moov): media fragments alone cannot be decoded.
        let moovEnd = try #require(topLevelBoxEnd(named: "moov", in: data))
        #expect(demuxer.append(data.subdata(in: moovEnd..<data.count)).isEmpty)
    }

    // MARK: Malformed input (each of these used to trap)

    @Test func hugeSixtyFourBitTopLevelSizeIsCorruption() {
        let box = Data([0, 0, 0, 1]) + Data("free".utf8) + Data(repeating: 0xFF, count: 8)
        #expect(FMP4Demuxer().append(box).isEmpty)
    }

    @Test func hugeSixtyFourBitChildSizeIsIgnored() {
        var child = Data([0, 0, 0, 1]) + Data("trak".utf8)
        child += Data([0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFE])
        #expect(FMP4Demuxer().append(box("moov", child)).isEmpty)
    }

    @Test func truncatedTrunHeaderAtTheEndOfTheBuffer() {
        let tfhd = box("tfhd", Data([0, 0, 0, 0, 0, 0, 0, 0]))           // track 0
        let trun = box("trun", Data([0, 0, 0, 5, 0, 0, 0, 0]))           // data offset + first flags, no room
        #expect(FMP4Demuxer().append(box("moof", box("traf", tfhd + trun))).isEmpty)
    }

    @Test func absurdSampleCountIsRejectedWithoutAllocating() {
        let tfhd = box("tfhd", Data([0, 0, 0, 0, 0, 0, 0, 0]))
        let trun = box("trun", Data([0, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF]))  // 4 billion samples, no fields
        #expect(FMP4Demuxer().append(box("moof", box("traf", tfhd + trun))).isEmpty)
    }

    @Test func decodeTimesThatDoNotFitAreSkipped() throws {
        var data = [UInt8](try fixture("go2rtc-hevc.mp4"))
        // Set the top bit of every 64-bit tfdt base decode time.
        var i = 0
        while let range = data[i...].firstRange(of: Array("tfdt".utf8)) {
            if data[range.lowerBound + 4] == 1 { data[range.lowerBound + 8] |= 0x80 }
            i = range.upperBound
        }
        #expect(FMP4Demuxer().append(Data(data)).isEmpty)
    }

    // MARK: Helpers

    private func box(_ type: String, _ payload: Data) -> Data {
        let size = UInt32(8 + payload.count)
        return Data([UInt8(size >> 24), UInt8(size >> 16 & 0xFF), UInt8(size >> 8 & 0xFF), UInt8(size & 0xFF)])
            + Data(type.utf8) + payload
    }

    private func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    private func feed(_ name: String, into demuxer: FMP4Demuxer, chunk: Int) throws -> [DemuxedFrame] {
        let data = try fixture(name)
        var frames: [DemuxedFrame] = []
        var offset = 0
        while offset < data.count {
            let end = chunk == .max ? data.count : min(offset + chunk, data.count)
            frames += demuxer.append(data.subdata(in: offset..<end))
            offset = end
        }
        return frames
    }

    private func topLevelBoxEnd(named name: String, in data: Data) -> Int? {
        let bytes = [UInt8](data)
        var p = 0
        while p + 8 <= bytes.count {
            let size = Int(bytes[p]) << 24 | Int(bytes[p + 1]) << 16 | Int(bytes[p + 2]) << 8 | Int(bytes[p + 3])
            guard size >= 8 else { return nil }
            if String(decoding: bytes[(p + 4)..<(p + 8)], as: UTF8.self) == name { return p + size }
            p += size
        }
        return nil
    }

    /// Decodes with VideoToolbox, like AVSampleBufferDisplayLayer does, and counts the pictures.
    private func decode(_ frames: [DemuxedFrame]) throws -> Int {
        let first = try #require(frames.first)
        let format = try #require(CMSampleBufferGetFormatDescription(first.sampleBuffer))
        var session: VTDecompressionSession?
        let attributes = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        try #require(VTDecompressionSessionCreate(
            allocator: nil, formatDescription: format, decoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary, outputCallback: nil,
            decompressionSessionOut: &session) == noErr)
        let decoder = try #require(session)
        defer { VTDecompressionSessionInvalidate(decoder) }

        var pictures = 0
        for frame in frames {
            let status = VTDecompressionSessionDecodeFrame(
                decoder, sampleBuffer: frame.sampleBuffer, flags: [], infoFlagsOut: nil
            ) { status, _, image, _, _ in
                if status == noErr, image != nil { pictures += 1 }
            }
            #expect(status == noErr)
        }
        VTDecompressionSessionWaitForAsynchronousFrames(decoder)
        return pictures
    }
}
