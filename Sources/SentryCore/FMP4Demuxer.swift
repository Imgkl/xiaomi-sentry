import CoreMedia
import Foundation

/// One decodable video frame cut out of a fragmented MP4 stream.
public struct DemuxedFrame {
    public let sampleBuffer: CMSampleBuffer
    public let isKeyframe: Bool
}

/// Streaming parser for the fragmented MP4 that go2rtc sends on `/api/ws` in `mse` mode.
///
/// go2rtc writes `ftyp` + `moov` once, then one `moof` + `mdat` pair per frame
/// (pkg/mp4/muxer.go and pkg/iso/atoms.go at v1.9.14). The parser also accepts
/// several samples per `trun`, so files written by ffmpeg work too.
/// Not thread safe: call it from one queue.
public final class FMP4Demuxer {
    public enum Codec { case hevc, h264 }

    public private(set) var codec: Codec?
    public private(set) var width = 0
    public private(set) var height = 0

    private var buf: [UInt8] = []
    private var videoTrackID: UInt32 = 0
    private var timescale: Int32 = 90_000
    private var nalLengthSize = 4
    private var parameterSets: [Data] = []
    private var formatDescription: CMVideoFormatDescription?
    private var trackDefaults: [UInt32: (duration: UInt32, size: UInt32, flags: UInt32)] = [:]
    private var fragment: Fragment?

    /// Larger boxes are treated as corruption. One go2rtc fragment holds one frame,
    /// so real boxes are far smaller; the WebSocket also caps messages at 16 MB.
    private static let maxBoxSize = 32 << 20
    /// A fragment carries at most a group of pictures; a bigger sample count is corruption.
    private static let maxSamplesPerFragment = 10_000

    private struct Sample {
        var duration: UInt32
        var size: UInt32
        var flags: UInt32
        var cts: Int32
    }

    private struct Fragment {
        var trackID: UInt32 = 0
        var baseDecodeTime: UInt64 = 0
        var dataOffset: Int32 = 0
        var moofSize = 0
        var samples: [Sample] = []
    }

    public init() {}

    /// Feeds raw bytes in any chunking and returns the frames that became complete.
    public func append(_ data: Data) -> [DemuxedFrame] {
        buf.append(contentsOf: data)
        var frames: [DemuxedFrame] = []
        var pos = 0
        while buf.count - pos >= 8 {
            var size = Int(be32(pos))
            var header = 8
            if size == 1 {
                guard buf.count - pos >= 16 else { break }
                size = Int(exactly: be64(pos + 8)) ?? -1
                header = 16
            } else if size == 0 {
                size = buf.count - pos
            }
            guard size >= header, size <= Self.maxBoxSize else {
                // Corrupt length. Drop everything and wait for the next init segment.
                buf.removeAll()
                fragment = nil
                return frames
            }
            guard buf.count - pos >= size else { break }
            let body = (pos + header)..<(pos + size)
            switch fourCC(pos + 4) {
            case "moov":
                parseMoov(body)
            case "moof":
                fragment = parseMoof(body, boxSize: size)
            case "mdat":
                if let f = fragment {
                    frames += samples(of: f, mdatStart: pos, mdatBody: body)
                    fragment = nil
                }
            default:
                break
            }
            pos += size
        }
        if pos > 0 { buf.removeFirst(pos) }
        return frames
    }

    // MARK: - Init segment

    private func parseMoov(_ r: Range<Int>) {
        for c in children(r) {
            switch c.type {
            case "trak":
                parseTrak(c.body)
            case "mvex":
                for t in children(c.body) where t.type == "trex" && t.body.count >= 24 {
                    let b = t.body.lowerBound
                    trackDefaults[be32(b + 4)] = (be32(b + 12), be32(b + 16), be32(b + 20))
                }
            default:
                break
            }
        }
    }

    private func parseTrak(_ r: Range<Int>) {
        var trackID: UInt32 = 0
        var handler = ""
        var mediaTimescale: UInt32 = 0
        var stsd: Range<Int>?

        for c in children(r) {
            switch c.type {
            case "tkhd" where c.body.count >= 24:
                let b = c.body.lowerBound
                trackID = be32(b + (buf[b] == 1 ? 20 : 12))
            case "mdia":
                for m in children(c.body) {
                    switch m.type {
                    case "mdhd" where m.body.count >= 24:
                        let b = m.body.lowerBound
                        mediaTimescale = be32(b + (buf[b] == 1 ? 20 : 12))
                    case "hdlr" where m.body.count >= 12:
                        handler = fourCC(m.body.lowerBound + 8)
                    case "minf":
                        for s in children(m.body) where s.type == "stbl" {
                            for d in children(s.body) where d.type == "stsd" { stsd = d.body }
                        }
                    default:
                        break
                    }
                }
            default:
                break
            }
        }

        guard handler == "vide", let stsd, stsd.count >= 16 else { return }
        videoTrackID = trackID
        timescale = Int32(clamping: mediaTimescale == 0 ? 90_000 : mediaTimescale)

        // stsd: version+flags (4), entry count (4), then the first sample entry.
        let entry = stsd.lowerBound + 8
        let entrySize = Int(be32(entry))
        let visualFields = entry + 8
        guard entrySize >= 86, entry + entrySize <= stsd.upperBound else { return }
        width = Int(be16(visualFields + 24))
        height = Int(be16(visualFields + 26))

        // VisualSampleEntry fields take 78 bytes, then child boxes (hvcC or avcC, pasp).
        for c in children((visualFields + 78)..<(entry + entrySize)) {
            switch c.type {
            case "hvcC":
                codec = .hevc
                parameterSets = parseHVCC(c.body)
            case "avcC":
                codec = .h264
                parameterSets = parseAVCC(c.body)
            default:
                break
            }
        }
        formatDescription = makeFormatDescription(parameterSets)
        updateDimensions()
    }

    private func parseHVCC(_ r: Range<Int>) -> [Data] {
        guard r.count >= 23 else { return [] }
        let b = r.lowerBound
        nalLengthSize = Int(buf[b + 21] & 0x03) + 1
        var sets: [UInt8: Data] = [:]
        var p = b + 23
        for _ in 0..<Int(buf[b + 22]) {
            guard p + 3 <= r.upperBound else { break }
            let type = buf[p] & 0x3F
            let count = Int(be16(p + 1))
            p += 3
            for _ in 0..<count {
                guard p + 2 <= r.upperBound else { break }
                let len = Int(be16(p))
                p += 2
                guard p + len <= r.upperBound else { break }
                if (32...34).contains(type) { sets[type] = Data(buf[p..<(p + len)]) }
                p += len
            }
        }
        return sets.keys.sorted().compactMap { sets[$0] }
    }

    private func parseAVCC(_ r: Range<Int>) -> [Data] {
        guard r.count >= 7 else { return [] }
        let b = r.lowerBound
        nalLengthSize = Int(buf[b + 4] & 0x03) + 1
        var sps: Data?
        var pps: Data?
        var p = b + 5
        for i in 0..<2 {
            guard p < r.upperBound else { break }
            let count = i == 0 ? Int(buf[p] & 0x1F) : Int(buf[p])
            p += 1
            for _ in 0..<count {
                guard p + 2 <= r.upperBound else { break }
                let len = Int(be16(p))
                p += 2
                guard p + len <= r.upperBound else { break }
                if i == 0 { sps = Data(buf[p..<(p + len)]) } else { pps = Data(buf[p..<(p + len)]) }
                p += len
            }
        }
        return [sps, pps].compactMap { $0 }
    }

    // MARK: - Media segments

    private func parseMoof(_ r: Range<Int>, boxSize: Int) -> Fragment? {
        var f = Fragment()
        f.moofSize = boxSize
        for traf in children(r) where traf.type == "traf" {
            var trackID: UInt32 = 0
            var defaults = (duration: UInt32(0), size: UInt32(0), flags: UInt32(0))
            for t in children(traf.body) {
                let b = t.body.lowerBound
                let end = t.body.upperBound
                switch t.type {
                case "tfhd" where t.body.count >= 8:
                    let flags = be24(b + 1)
                    trackID = be32(b + 4)
                    if let d = trackDefaults[trackID] { defaults = d }
                    var p = b + 8
                    if flags & 0x01 != 0 { p += 8 } // base data offset: go2rtc sets default-base-is-moof instead
                    if flags & 0x02 != 0 { p += 4 } // sample description index
                    if flags & 0x08 != 0, p + 4 <= end { defaults.duration = be32(p); p += 4 }
                    if flags & 0x10 != 0, p + 4 <= end { defaults.size = be32(p); p += 4 }
                    if flags & 0x20 != 0, p + 4 <= end { defaults.flags = be32(p); p += 4 }
                case "tfdt" where trackID == videoTrackID && t.body.count >= 8:
                    f.baseDecodeTime = buf[b] == 1 && t.body.count >= 12 ? be64(b + 4) : UInt64(be32(b + 4))
                case "trun" where trackID == videoTrackID && t.body.count >= 8:
                    f.trackID = trackID
                    let version = buf[b]
                    let flags = be24(b + 1)
                    let count = Int(be32(b + 4))
                    var p = b + 8
                    if flags & 0x001 != 0 {
                        guard p + 4 <= end else { return nil }
                        f.dataOffset = Int32(bitPattern: be32(p))
                        p += 4
                    }
                    var firstFlags: UInt32?
                    if flags & 0x004 != 0 {
                        guard p + 4 <= end else { return nil }
                        firstFlags = be32(p)
                        p += 4
                    }
                    let fields = [0x100, 0x200, 0x400, 0x800].filter { flags & UInt32($0) != 0 }.count
                    guard count <= Self.maxSamplesPerFragment, p + count * fields * 4 <= end else { return nil }
                    for i in 0..<count {
                        var s = Sample(duration: defaults.duration, size: defaults.size,
                                       flags: (i == 0 ? firstFlags : nil) ?? defaults.flags, cts: 0)
                        if flags & 0x100 != 0 { s.duration = be32(p); p += 4 }
                        if flags & 0x200 != 0 { s.size = be32(p); p += 4 }
                        if flags & 0x400 != 0 { s.flags = be32(p); p += 4 }
                        if flags & 0x800 != 0 {
                            let raw = be32(p)
                            s.cts = version == 0 ? Int32(clamping: raw) : Int32(bitPattern: raw)
                            p += 4
                        }
                        f.samples.append(s)
                    }
                default:
                    break
                }
            }
        }
        return f.samples.isEmpty ? nil : f
    }

    private func samples(of f: Fragment, mdatStart: Int, mdatBody: Range<Int>) -> [DemuxedFrame] {
        guard f.trackID == videoTrackID, codec != nil else { return [] }
        // data_offset counts from the start of moof. mdat follows moof directly.
        var p = f.dataOffset == 0 ? mdatBody.lowerBound : mdatStart + Int(f.dataOffset) - f.moofSize
        var dts = f.baseDecodeTime
        var frames: [DemuxedFrame] = []
        for s in f.samples {
            let size = Int(s.size)
            guard p >= mdatBody.lowerBound, p + size <= mdatBody.upperBound else { break }
            if let frame = makeFrame(p..<(p + size), dts: dts, sample: s) { frames.append(frame) }
            p += size
            dts = dts &+ UInt64(s.duration)
        }
        return frames
    }

    private func makeFrame(_ r: Range<Int>, dts: UInt64, sample s: Sample) -> DemuxedFrame? {
        guard let codec else { return nil }
        var payload: [UInt8] = []
        payload.reserveCapacity(r.count)
        var inBand: [UInt8: Data] = [:]
        var keyframe = false
        var p = r.lowerBound
        while p + nalLengthSize <= r.upperBound {
            var len = 0
            for i in 0..<nalLengthSize { len = len << 8 | Int(buf[p + i]) }
            let start = p + nalLengthSize
            guard len > 0, start + len <= r.upperBound else { break }
            let header = buf[start]
            let type: UInt8
            let isParameterSet: Bool
            switch codec {
            case .hevc:
                type = (header >> 1) & 0x3F
                isParameterSet = (32...34).contains(type)
                if (16...21).contains(type) { keyframe = true }
            case .h264:
                type = header & 0x1F
                isParameterSet = type == 7 || type == 8
                if type == 5 { keyframe = true }
            }
            if isParameterSet {
                inBand[type] = Data(buf[start..<(start + len)])
            } else {
                payload.append(contentsOf: buf[p..<(start + len)])
            }
            p = start + len
        }

        // go2rtc can write placeholder parameter sets in hvcC when the source has none,
        // and the real ones then arrive in the keyframe. Rebuild the format when they change.
        if !inBand.isEmpty {
            let sets = inBand.keys.sorted().compactMap { inBand[$0] }
            if sets.count >= (codec == .hevc ? 3 : 2), sets != parameterSets,
               let fd = makeFormatDescription(sets) {
                parameterSets = sets
                formatDescription = fd
                updateDimensions()
            }
        }

        guard let fd = formatDescription, !payload.isEmpty else { return nil }

        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: payload.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: payload.count, flags: 0, blockBufferOut: &block) == noErr, let block else { return nil }
        let copied = payload.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
                                          offsetIntoDestination: 0, dataLength: payload.count)
        }
        guard copied == noErr else { return nil }

        // Timestamps from the wire are untrusted: skip a frame whose times do not fit.
        guard let decodeTime = Int64(exactly: dts) else { return nil }
        let (presentationTime, overflow) = decodeTime.addingReportingOverflow(Int64(s.cts))
        guard !overflow else { return nil }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: Int64(s.duration), timescale: timescale),
            presentationTimeStamp: CMTime(value: presentationTime, timescale: timescale),
            decodeTimeStamp: CMTime(value: decodeTime, timescale: timescale))
        var size = payload.count
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: fd,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sampleBuffer) == noErr,
            let sampleBuffer else { return nil }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            set(dict, kCMSampleAttachmentKey_DisplayImmediately, kCFBooleanTrue)
            if !keyframe { set(dict, kCMSampleAttachmentKey_NotSync, kCFBooleanTrue) }
        }
        return DemuxedFrame(sampleBuffer: sampleBuffer, isKeyframe: keyframe)
    }

    private func makeFormatDescription(_ sets: [Data]) -> CMVideoFormatDescription? {
        guard let codec, !sets.isEmpty else { return nil }
        let storage = sets.map { set -> UnsafeMutablePointer<UInt8> in
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: max(set.count, 1))
            set.copyBytes(to: p, count: set.count)
            return p
        }
        defer { storage.forEach { $0.deallocate() } }
        let pointers = storage.map { UnsafePointer($0) }
        let sizes = sets.map(\.count)
        var fd: CMVideoFormatDescription?
        let status: OSStatus
        switch codec {
        case .hevc:
            status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: sets.count,
                parameterSetPointers: pointers, parameterSetSizes: sizes,
                nalUnitHeaderLength: Int32(nalLengthSize), extensions: nil, formatDescriptionOut: &fd)
        case .h264:
            status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: sets.count,
                parameterSetPointers: pointers, parameterSetSizes: sizes,
                nalUnitHeaderLength: Int32(nalLengthSize), formatDescriptionOut: &fd)
        }
        return status == noErr ? fd : nil
    }

    private func updateDimensions() {
        guard let formatDescription else { return }
        let d = CMVideoFormatDescriptionGetDimensions(formatDescription)
        if d.width > 0 { width = Int(d.width); height = Int(d.height) }
    }

    // MARK: - Byte helpers

    private func children(_ r: Range<Int>) -> [(type: String, body: Range<Int>)] {
        var list: [(String, Range<Int>)] = []
        var p = r.lowerBound
        while p + 8 <= r.upperBound {
            var size = Int(be32(p))
            var header = 8
            if size == 1 {
                guard p + 16 <= r.upperBound, let large = Int(exactly: be64(p + 8)) else { break }
                size = large
                header = 16
            } else if size == 0 {
                size = r.upperBound - p
            }
            guard size >= header, size <= r.upperBound - p else { break }
            list.append((fourCC(p + 4), (p + header)..<(p + size)))
            p += size
        }
        return list
    }

    private func be16(_ i: Int) -> UInt16 { UInt16(buf[i]) << 8 | UInt16(buf[i + 1]) }
    private func be24(_ i: Int) -> UInt32 { UInt32(buf[i]) << 16 | UInt32(buf[i + 1]) << 8 | UInt32(buf[i + 2]) }
    private func be32(_ i: Int) -> UInt32 {
        UInt32(buf[i]) << 24 | UInt32(buf[i + 1]) << 16 | UInt32(buf[i + 2]) << 8 | UInt32(buf[i + 3])
    }
    private func be64(_ i: Int) -> UInt64 { UInt64(be32(i)) << 32 | UInt64(be32(i + 4)) }
    private func fourCC(_ i: Int) -> String { String(decoding: buf[i..<(i + 4)], as: UTF8.self) }

    private func set(_ dict: CFMutableDictionary, _ key: CFString, _ value: CFBoolean) {
        CFDictionarySetValue(dict, Unmanaged.passUnretained(key).toOpaque(),
                             Unmanaged.passUnretained(value).toOpaque())
    }
}
