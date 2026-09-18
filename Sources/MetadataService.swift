import Foundation

// Component 2: pure-Swift tag I/O (no TagLib). MP3 = ID3v2 TBPM frame, FLAC = VorbisComment BPM entry.
// Audio PCM reading for the analysis engine lives in BPMEngine (AVAudioFile only, never AVAsset).

// MARK: - Protocol (a TagLib backend could be swapped in behind this)

/// Lightweight display metadata for aside personalization (read-only).
struct BasicTags: Equatable, Sendable {
    var artist: String? = nil
    var title: String? = nil
    var album: String? = nil
    var year: String? = nil
}

protocol MetadataServiceProtocol: Sendable {
    func readBPM(url: URL) throws -> Double?
    func readBasicTags(url: URL) throws -> BasicTags
    func writeBPM(url: URL, bpm: Double) throws
    func eraseBPM(url: URL) throws
}

enum MetadataError: Error {
    case unsupportedFormat
    case corruptFile
}

// MARK: - Syncsafe integers (ID3)

func syncsafeEncode(_ value: UInt32) -> [UInt8] {
    [UInt8((value >> 21) & 0x7F), UInt8((value >> 14) & 0x7F),
     UInt8((value >> 7) & 0x7F), UInt8(value & 0x7F)]
}

func syncsafeDecode(_ b: [UInt8]) -> UInt32 {
    guard b.count >= 4 else { return 0 }
    return (UInt32(b[0] & 0x7F) << 21) | (UInt32(b[1] & 0x7F) << 14)
        | (UInt32(b[2] & 0x7F) << 7) | UInt32(b[3] & 0x7F)
}

// MARK: - ID3v2 model

struct ID3Frame: Equatable {
    var id: String      // 4 ASCII chars, e.g. "TBPM"
    var flags: [UInt8]  // 2 bytes
    var data: [UInt8]   // payload (encoding byte + content for text frames)
}

struct ID3Tag: Equatable {
    var major: UInt8             // 3 or 4
    var revision: UInt8
    var flags: UInt8
    var extendedHeader: [UInt8]? // raw bytes, preserved verbatim
    var frames: [ID3Frame]
    var paddingLength: Int
}

func parseID3Tag(_ bytes: [UInt8]) -> (tag: ID3Tag, audioOffset: Int)? {
    guard bytes.count >= 10, bytes[0] == 0x49, bytes[1] == 0x44, bytes[2] == 0x33 else { return nil } // "ID3"
    let major = bytes[3]
    guard major == 3 || major == 4 else { return nil }
    let revision = bytes[4]
    let flags = bytes[5]
    let tagSize = Int(syncsafeDecode(Array(bytes[6..<10])))
    var tagEnd = 10 + tagSize
    if major == 4 && (flags & 0x10) != 0 { tagEnd += 10 } // v2.4 footer present
    guard tagEnd <= bytes.count else { return nil }

    var pos = 10
    var extHeader: [UInt8]?
    if (flags & 0x40) != 0 { // extended header
        if major == 3 {
            guard pos + 4 <= tagEnd else { return nil }
            let extSize = Int(UInt32(bytes[pos]) << 24 | UInt32(bytes[pos + 1]) << 16
                | UInt32(bytes[pos + 2]) << 8 | UInt32(bytes[pos + 3]))
            let total = 4 + extSize // v2.3 size excludes its own 4 bytes
            guard total >= 4, pos + total <= tagEnd else { return nil }
            extHeader = Array(bytes[pos..<(pos + total)])
            pos += total
        } else {
            guard pos + 4 <= tagEnd else { return nil }
            let extSize = Int(syncsafeDecode(Array(bytes[pos..<(pos + 4)]))) // v2.4 includes itself
            guard extSize >= 6, pos + extSize <= tagEnd else { return nil }
            extHeader = Array(bytes[pos..<(pos + extSize)])
            pos += extSize
        }
    }

    var frames: [ID3Frame] = []
    while pos + 10 <= tagEnd {
        let idBytes = Array(bytes[pos..<(pos + 4)])
        if idBytes.allSatisfy({ $0 == 0 }) { break } // padding reached
        guard let id = String(bytes: idBytes, encoding: .isoLatin1),
              id.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) }) else { break }
        let size: Int
        if major == 3 { // v2.3: plain big-endian u32
            size = Int(UInt32(bytes[pos + 4]) << 24 | UInt32(bytes[pos + 5]) << 16
                | UInt32(bytes[pos + 6]) << 8 | UInt32(bytes[pos + 7]))
        } else { // v2.4: syncsafe
            size = Int(syncsafeDecode(Array(bytes[(pos + 4)..<(pos + 8)])))
        }
        let frameFlags = [bytes[pos + 8], bytes[pos + 9]]
        let dataStart = pos + 10
        guard size >= 0, dataStart + size <= tagEnd else { break }
        frames.append(ID3Frame(id: id, flags: frameFlags, data: Array(bytes[dataStart..<(dataStart + size)])))
        pos = dataStart + size
    }
    let padding = max(0, tagEnd - pos)
    return (ID3Tag(major: major, revision: revision, flags: flags,
                   extendedHeader: extHeader, frames: frames, paddingLength: padding), tagEnd)
}

func buildID3Tag(_ tag: ID3Tag) -> [UInt8] {
    var body: [UInt8] = []
    if let ext = tag.extendedHeader { body.append(contentsOf: ext) }
    for frame in tag.frames {
        var idBytes = Array(frame.id.utf8)
        while idBytes.count < 4 { idBytes.append(0) }
        body.append(contentsOf: idBytes.prefix(4))
        if tag.major == 3 {
            let s = UInt32(frame.data.count)
            body.append(contentsOf: [UInt8((s >> 24) & 0xFF), UInt8((s >> 16) & 0xFF),
                                     UInt8((s >> 8) & 0xFF), UInt8(s & 0xFF)])
        } else {
            body.append(contentsOf: syncsafeEncode(UInt32(frame.data.count)))
        }
        body.append(contentsOf: frame.flags.count == 2 ? frame.flags : [0, 0])
        body.append(contentsOf: frame.data)
    }
    body.append(contentsOf: [UInt8](repeating: 0, count: max(0, tag.paddingLength)))

    var flags = tag.flags
    if tag.extendedHeader == nil { flags &= ~0x40 }
    if tag.major == 4 { flags &= ~0x10 } // we never write a footer
    flags &= ~0x80 // we never write unsynchronised data — never claim it

    var out: [UInt8] = [0x49, 0x44, 0x33, tag.major, tag.revision, flags]
    out.append(contentsOf: syncsafeEncode(UInt32(body.count)))
    out.append(contentsOf: body)
    return out
}

/// Clean tag text: whole numbers stay whole ("122"), fractions keep 2 decimals.
func bpmTagText(_ bpm: Double) -> String {
    bpm.rounded() == bpm ? String(format: "%.0f", bpm) : String(format: "%.2f", bpm)
}

/// Add (or remove, when bpm == nil) the TBPM frame; all other frames untouched.
func id3SettingTBPM(_ tag: inout ID3Tag, bpm: Double?) {
    tag.frames.removeAll { $0.id == "TBPM" }
    if let bpm = bpm {
        let text = bpmTagText(bpm)
        tag.frames.append(ID3Frame(id: "TBPM", flags: [0, 0], data: [0x00] + Array(text.utf8))) // 0x00 = ISO-8859-1
    }
}

func id3ReadTBPM(_ tag: ID3Tag) -> Double? {
    guard let frame = tag.frames.first(where: { $0.id == "TBPM" }), !frame.data.isEmpty else { return nil }
    let payload = Data(frame.data.dropFirst())
    let text: String?
    switch frame.data[0] { // text encoding byte
    case 0: text = String(data: payload, encoding: .isoLatin1)
    case 1: text = String(data: payload, encoding: .utf16)
    case 2: text = String(data: payload, encoding: .utf16BigEndian)
    default: text = String(data: payload, encoding: .utf8)
    }
    guard let raw = text else { return nil }
    let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\0").union(.whitespacesAndNewlines))
    return Double(trimmed)
}

// MARK: - Basic tag reads (aside personalization; read-only)

/// Decode any ID3 text frame (encoding byte + payload; first value if multi-valued).
func id3FrameText(_ frame: ID3Frame) -> String? {
    guard !frame.data.isEmpty else { return nil }
    let payload = Data(frame.data.dropFirst())
    let text: String?
    switch frame.data[0] {
    case 0: text = String(data: payload, encoding: .isoLatin1)
    case 1: text = String(data: payload, encoding: .utf16)
    case 2: text = String(data: payload, encoding: .utf16BigEndian)
    default: text = String(data: payload, encoding: .utf8)
    }
    guard let raw = text else { return nil }
    let first = raw.components(separatedBy: "\0").first ?? raw
    let trimmed = first.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

/// First non-empty text among candidate frame ids (e.g. ["TDRC", "TYER"]).
func id3ReadText(_ tag: ID3Tag, ids: [String]) -> String? {
    for id in ids {
        if let frame = tag.frames.first(where: { $0.id == id }), let t = id3FrameText(frame) { return t }
    }
    return nil
}

/// First non-empty value among candidate Vorbis keys (case-insensitive, order = priority).
func vorbisReadKey(_ vc: VorbisComment, keys: [String]) -> String? {
    for key in keys {
        for entry in vc.comments {
            guard let eq = entry.firstIndex(of: "="), entry[..<eq].uppercased() == key else { continue }
            let value = entry[entry.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if !value.isEmpty { return String(value) }
        }
    }
    return nil
}

// MARK: - FLAC model

struct FLACBlock: Equatable {
    var type: UInt8 // 0 STREAMINFO, 1 PADDING, 4 VORBIS_COMMENT, 6 PICTURE ...
    var data: [UInt8]
}

func parseFLAC(_ bytes: [UInt8]) -> (blocks: [FLACBlock], audioOffset: Int)? {
    guard bytes.count >= 4, bytes[0] == 0x66, bytes[1] == 0x4C, bytes[2] == 0x61, bytes[3] == 0x43 else { return nil } // "fLaC"
    var pos = 4
    var blocks: [FLACBlock] = []
    while true {
        guard pos + 4 <= bytes.count else { return nil }
        let header = bytes[pos]
        let isLast = (header & 0x80) != 0
        let type = header & 0x7F
        let len = Int(UInt32(bytes[pos + 1]) << 16 | UInt32(bytes[pos + 2]) << 8 | UInt32(bytes[pos + 3]))
        guard pos + 4 + len <= bytes.count else { return nil }
        blocks.append(FLACBlock(type: type, data: Array(bytes[(pos + 4)..<(pos + 4 + len)])))
        pos += 4 + len
        if isLast { break }
    }
    guard !blocks.isEmpty else { return nil }
    return (blocks, pos)
}

func buildFLAC(blocks: [FLACBlock]) -> [UInt8] {
    var out: [UInt8] = [0x66, 0x4C, 0x61, 0x43]
    for (index, block) in blocks.enumerated() {
        let lastFlag: UInt8 = index == blocks.count - 1 ? 0x80 : 0x00
        out.append(block.type | lastFlag)
        let len = UInt32(block.data.count)
        out.append(contentsOf: [UInt8((len >> 16) & 0xFF), UInt8((len >> 8) & 0xFF), UInt8(len & 0xFF)])
        out.append(contentsOf: block.data)
    }
    return out
}

struct VorbisComment: Equatable {
    var vendor: String
    var comments: [String] // "KEY=value"
}

func parseVorbisComment(_ data: [UInt8]) -> VorbisComment? {
    func le32(_ p: Int) -> Int? {
        guard p + 4 <= data.count else { return nil }
        return Int(UInt32(data[p]) | UInt32(data[p + 1]) << 8 | UInt32(data[p + 2]) << 16 | UInt32(data[p + 3]) << 24)
    }
    var pos = 0
    guard let vendorLen = le32(pos), pos + 4 + vendorLen <= data.count else { return nil }
    pos += 4
    let vendor = String(bytes: data[pos..<(pos + vendorLen)], encoding: .utf8) ?? ""
    pos += vendorLen
    guard let count = le32(pos) else { return nil }
    pos += 4
    var comments: [String] = []
    comments.reserveCapacity(count)
    for _ in 0..<count {
        guard let len = le32(pos), pos + 4 + len <= data.count else { return nil }
        pos += 4
        comments.append(String(bytes: data[pos..<(pos + len)], encoding: .utf8) ?? "")
        pos += len
    }
    return VorbisComment(vendor: vendor, comments: comments)
}

func buildVorbisComment(_ vc: VorbisComment) -> [UInt8] {
    func le32(_ v: Int) -> [UInt8] {
        let u = UInt32(v)
        return [UInt8(u & 0xFF), UInt8((u >> 8) & 0xFF), UInt8((u >> 16) & 0xFF), UInt8((u >> 24) & 0xFF)]
    }
    var out: [UInt8] = []
    let vendor = Array(vc.vendor.utf8)
    out.append(contentsOf: le32(vendor.count))
    out.append(contentsOf: vendor)
    out.append(contentsOf: le32(vc.comments.count))
    for comment in vc.comments {
        let bytes = Array(comment.utf8)
        out.append(contentsOf: le32(bytes.count))
        out.append(contentsOf: bytes)
    }
    return out
}

/// Add (or remove, when bpm == nil) the BPM= entry; key match is case-insensitive.
func vorbisSettingBPM(_ vc: inout VorbisComment, bpm: Double?) {
    vc.comments.removeAll { entry in
        guard let eq = entry.firstIndex(of: "=") else { return false }
        return entry[..<eq].uppercased() == "BPM"
    }
    if let bpm = bpm {
        vc.comments.append("BPM=" + bpmTagText(bpm))
    }
}

func vorbisReadBPM(_ vc: VorbisComment) -> Double? {
    for entry in vc.comments {
        guard let eq = entry.firstIndex(of: "="), entry[..<eq].uppercased() == "BPM" else { continue }
        return Double(entry[entry.index(after: eq)...].trimmingCharacters(in: .whitespaces))
    }
    return nil
}

// MARK: - Atomic write helpers (temp file then move; dates restored afterwards)

func fileDates(_ url: URL) -> (creation: Date?, modification: Date?) {
    let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
    return (attrs?[.creationDate] as? Date, attrs?[.modificationDate] as? Date)
}

func atomicWrite(_ bytes: [UInt8], to url: URL,
                 preserveDates dates: (creation: Date?, modification: Date?)) throws {
    let dir = url.deletingLastPathComponent()
    let tmp = dir.appendingPathComponent("." + url.lastPathComponent + ".tmp-" + UUID().uuidString)
    try Data(bytes).write(to: tmp)
    defer { try? FileManager.default.removeItem(at: tmp) }
    do {
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    } catch {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.moveItem(at: tmp, to: url)
    }
    var attrs: [FileAttributeKey: Any] = [:]
    if let creation = dates.creation { attrs[.creationDate] = creation }
    if let modification = dates.modification { attrs[.modificationDate] = modification }
    if !attrs.isEmpty {
        try FileManager.default.setAttributes(attrs, ofItemAtPath: url.path)
    }
}

// MARK: - Tag-region reads

/// Read just the leading metadata (tag) region of an audio file instead of
/// the whole file — MP3 tags declare their size in the header; FLAC keeps all
/// metadata up front. Returns nil when the file carries no tag at all. The
/// write path still reads whole files (atomic in-place rewrites need the
/// audio bytes regardless).
private func readTagRegion(url: URL) throws -> [UInt8]? {
    let handle: FileHandle
    do {
        handle = try FileHandle(forReadingFrom: url)
    } catch {
        throw error
    }
    defer { try? handle.close() }
    guard let headData = try handle.read(upToCount: 10), headData.count >= 3 else { return nil }
    let head = [UInt8](headData)
    if head[0] == 0x49, head[1] == 0x44, head[2] == 0x33 { // "ID3"
        guard headData.count == 10 else { return nil } // truncated header
        let size = Int(syncsafeDecode(Array(head[6..<10])))
        var total = 10 + size
        if head[3] == 4 && (head[5] & 0x10) != 0 { total += 10 } // v2.4 footer
        try handle.seek(toOffset: 0)
        return [UInt8](try handle.read(upToCount: total) ?? Data())
    }
    if head[0] == 0x66, head[1] == 0x4C, head[2] == 0x61, head[3] == 0x43 { // "fLaC"
        // Walk the block headers to find where metadata ends.
        var total = 4
        try handle.seek(toOffset: 4)
        var isLast = false
        while !isLast {
            guard let hdr = try handle.read(upToCount: 4), hdr.count == 4 else { return nil }
            isLast = (hdr[0] & 0x80) != 0
            let len = Int(hdr[1]) << 16 | Int(hdr[2]) << 8 | Int(hdr[3])
            total += 4 + len
            if len > 0 {
                try handle.seek(toOffset: handle.offsetInFile + UInt64(len))
            }
        }
        try handle.seek(toOffset: 0)
        return [UInt8](try handle.read(upToCount: total) ?? Data())
    }
    return nil
}

// MARK: - Concrete service

final class NativeMetadataService: MetadataServiceProtocol, @unchecked Sendable {
    init() {}

    func readBPM(url: URL) throws -> Double? {
        switch url.pathExtension.lowercased() {
        case "mp3":
            guard let bytes = try readTagRegion(url: url) else { return nil }
            guard let (tag, _) = parseID3Tag(bytes) else {
                if Self.hasUnparsableID3Tag(bytes) { throw MetadataError.corruptFile }
                return nil
            }
            return id3ReadTBPM(tag)
        case "flac":
            guard let bytes = try readTagRegion(url: url), let (blocks, _) = parseFLAC(bytes) else {
                throw MetadataError.corruptFile
            }
            guard let block = blocks.first(where: { $0.type == 4 }),
                  let vc = parseVorbisComment(block.data) else { return nil }
            return vorbisReadBPM(vc)
        default:
            throw MetadataError.unsupportedFormat
        }
    }

    func writeBPM(url: URL, bpm: Double) throws {
        try setBPM(url: url, bpm: bpm)
    }

    /// Artist/title/album/year for aside personalization. Missing tags yield nils, not errors.
    func readBasicTags(url: URL) throws -> BasicTags {
        switch url.pathExtension.lowercased() {
        case "mp3":
            guard let bytes = try readTagRegion(url: url) else { return BasicTags() }
            guard let (tag, _) = parseID3Tag(bytes) else {
                if Self.hasUnparsableID3Tag(bytes) { throw MetadataError.corruptFile }
                return BasicTags()
            }
            return BasicTags(artist: id3ReadText(tag, ids: ["TPE1"]),
                             title: id3ReadText(tag, ids: ["TIT2"]),
                             album: id3ReadText(tag, ids: ["TALB"]),
                             year: id3ReadText(tag, ids: ["TDRC", "TYER"]))
        case "flac":
            guard let bytes = try readTagRegion(url: url), let (blocks, _) = parseFLAC(bytes) else {
                throw MetadataError.corruptFile
            }
            guard let block = blocks.first(where: { $0.type == 4 }),
                  let vc = parseVorbisComment(block.data) else { return BasicTags() }
            return BasicTags(artist: vorbisReadKey(vc, keys: ["ARTIST"]),
                             title: vorbisReadKey(vc, keys: ["TITLE"]),
                             album: vorbisReadKey(vc, keys: ["ALBUM"]),
                             year: vorbisReadKey(vc, keys: ["DATE", "YEAR"]))
        default:
            throw MetadataError.unsupportedFormat
        }
    }

    func eraseBPM(url: URL) throws {
        try setBPM(url: url, bpm: nil)
    }

    private func setBPM(url: URL, bpm: Double?) throws {
        switch url.pathExtension.lowercased() {
        case "mp3": try setMP3BPM(url: url, bpm: bpm)
        case "flac": try setFLACBPM(url: url, bpm: bpm)
        default: throw MetadataError.unsupportedFormat
        }
    }

    /// True when the bytes start with an ID3v2 magic we can't parse — either
    /// an unsupported version (v2.2) or a structurally corrupt v2.3/v2.4 tag.
    /// Rewriting such a file would orphan the existing tag (a fresh v2.3 tag
    /// prepended in front of the unreadable one), so writes must refuse.
    private static func hasUnparsableID3Tag(_ bytes: [UInt8]) -> Bool {
        bytes.count >= 3 && bytes[0] == 0x49 && bytes[1] == 0x44 && bytes[2] == 0x33 // "ID3"
    }

    private func setMP3BPM(url: URL, bpm: Double?) throws {
        let bytes = [UInt8](try Data(contentsOf: url))
        let dates = fileDates(url)
        let tag: ID3Tag
        let audio: [UInt8]
        if let (parsed, offset) = parseID3Tag(bytes) {
            tag = parsed
            audio = Array(bytes[offset...])
        } else if Self.hasUnparsableID3Tag(bytes) {
            // ID3v2.2 or corrupt v2.3/v2.4: writing would dual-tag the file.
            throw MetadataError.corruptFile
        } else { // no ID3 tag -> create a fresh v2.3 tag, keep file bytes as audio
            tag = ID3Tag(major: 3, revision: 0, flags: 0, extendedHeader: nil, frames: [], paddingLength: 256)
            audio = bytes
        }
        var mutableTag = tag
        id3SettingTBPM(&mutableTag, bpm: bpm)
        try atomicWrite(buildID3Tag(mutableTag) + audio, to: url, preserveDates: dates)
    }

    private func setFLACBPM(url: URL, bpm: Double?) throws {
        let bytes = [UInt8](try Data(contentsOf: url))
        let dates = fileDates(url)
        guard let (parsed, audioOffset) = parseFLAC(bytes) else { throw MetadataError.corruptFile }
        var blocks = parsed
        if let index = blocks.firstIndex(where: { $0.type == 4 }) {
            var vc = parseVorbisComment(blocks[index].data) ?? VorbisComment(vendor: "BPMPLS", comments: [])
            vorbisSettingBPM(&vc, bpm: bpm)
            blocks[index] = FLACBlock(type: 4, data: buildVorbisComment(vc))
        } else if bpm != nil {
            // No VorbisComment block: insert a new one right after STREAMINFO.
            var vc = VorbisComment(vendor: "BPMPLS", comments: [])
            vorbisSettingBPM(&vc, bpm: bpm)
            let insertAt = blocks.isEmpty ? 0 : 1
            blocks.insert(FLACBlock(type: 4, data: buildVorbisComment(vc)), at: min(insertAt, blocks.count))
        }
        try atomicWrite(buildFLAC(blocks: blocks) + bytes[audioOffset...], to: url, preserveDates: dates)
    }
}
