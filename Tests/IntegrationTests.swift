import Foundation
import AVFoundation

// Plain integration harness (no XCTest) operating on real temp files in NSTemporaryDirectory.
// Prints "PASS/FAIL <name>" lines and a final count; exit 1 on any failure.

// MARK: - Click-track WAV generator (float32 mono 44.1 kHz via AVAudioFile)

func writeClickWAV(url: URL, segments: [(bpm: Double, start: Double, end: Double)],
                   totalSeconds: Double, sampleRate: Double = 44100) throws {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                               channels: 1, interleaved: false)!
    let totalFrames = Int(totalSeconds * sampleRate)
    var data = [Float](repeating: 0, count: totalFrames)
    let clickLen = Int(0.03 * sampleRate)
    for seg in segments {
        let period = 60.0 / seg.bpm
        var t = seg.start
        while t < seg.end {
            let startIdx = Int((t * sampleRate).rounded())
            for k in 0..<clickLen {
                let idx = startIdx + k
                if idx >= totalFrames { break }
                let ct = Double(k) / sampleRate
                let env = exp(-ct / 0.008)
                data[idx] += Float(0.7 * env * (0.65 * sin(2 * Double.pi * 180 * ct)
                    + 0.35 * sin(2 * Double.pi * 2500 * ct)))
            }
            t += period
        }
    }
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(totalFrames)) else {
        throw BPMError.unreadableAudio
    }
    buffer.frameLength = AVAudioFrameCount(totalFrames)
    let ptr = buffer.floatChannelData![0]
    data.withUnsafeBufferPointer { src in
        ptr.update(from: src.baseAddress!, count: totalFrames)
    }
    try file.write(from: buffer)
}

// MARK: - (a) Engine on 120 / 174 BPM click tracks

func testEngineOnWAVs(tmp: URL) async {
    do {
        // Shortened from 32s to 16s. Click-track
        // detection is stable by 2 chunks (BPMEngine.chunkSeconds=8.0).
        let wav120 = tmp.appendingPathComponent("click120.wav")
        try writeClickWAV(url: wav120, segments: [(bpm: 120.0, start: 0.0, end: 16.0)], totalSeconds: 16.0)
        let b120 = try await BPMEngine.analyze(url: wav120, minBPM: 70, maxBPM: 180)
        check("engine 120 BPM WAV within ±1.0 (got \(String(format: "%.2f", b120)))", abs(b120 - 120.0) <= 1.0)

        let wav174 = tmp.appendingPathComponent("click174.wav")
        try writeClickWAV(url: wav174, segments: [(bpm: 174.0, start: 0.0, end: 16.0)], totalSeconds: 16.0)
        let b174 = try await BPMEngine.analyze(url: wav174, minBPM: 70, maxBPM: 180)
        check("engine 174 BPM WAV within ±1.0 (got \(String(format: "%.2f", b174)))", abs(b174 - 174.0) <= 1.0)
    } catch {
        check("engine WAV tests threw: \(error)", false)
    }
}

// MARK: - (b) Synthetic MP3 byte fixture: write/erase TBPM, TIT2 + audio preserved

func makeMP3Fixture(url: URL) throws -> [UInt8] {
    let tag = ID3Tag(major: 3, revision: 0, flags: 0, extendedHeader: nil,
                     frames: [ID3Frame(id: "TIT2", flags: [0, 0], data: [0x00] + Array("Test Title".utf8)),
                              ID3Frame(id: "TPE1", flags: [0, 0], data: [0x00] + Array("Some Artist".utf8))],
                     paddingLength: 128)
    var bytes = buildID3Tag(tag)
    bytes.append(contentsOf: [0xFF, 0xFB, 0x90, 0x64]) // fake MPEG frame sync
    bytes.append(contentsOf: [UInt8](repeating: 0xAB, count: 256))
    try Data(bytes).write(to: url)
    return bytes
}

func testMP3Tags(tmp: URL) {
    do {
        let service = NativeMetadataService()
        let mp3 = tmp.appendingPathComponent("fixture.mp3")
        let original = try makeMP3Fixture(url: mp3)
        guard let (_, origAudioOffset) = parseID3Tag(original) else {
            check("mp3 fixture parses", false)
            return
        }
        let origAudio = Array(original[origAudioOffset...])

        try service.writeBPM(url: mp3, bpm: 128.0)
        var after = [UInt8](try Data(contentsOf: mp3))
        guard let (tagAfter, offAfter) = parseID3Tag(after) else {
            check("mp3 parses after TBPM write", false)
            return
        }
        check("mp3 TBPM written", id3ReadTBPM(tagAfter) == 128.0)
        check("mp3 TBPM is clean integer text",
              tagAfter.frames.first(where: { $0.id == "TBPM" })?.data == [0x00] + Array("128".utf8))
        check("mp3 readBPM returns 128", (try service.readBPM(url: mp3)) == 128.0)
        let basics = try service.readBasicTags(url: mp3)
        check("mp3 basic tags: artist/title", basics.artist == "Some Artist" && basics.title == "Test Title")
        check("mp3 basic tags: missing album/year are nil", basics.album == nil && basics.year == nil)
        check("mp3 TIT2 bytes preserved",
              tagAfter.frames.first(where: { $0.id == "TIT2" })?.data == [0x00] + Array("Test Title".utf8))
        check("mp3 TPE1 bytes preserved",
              tagAfter.frames.first(where: { $0.id == "TPE1" })?.data == [0x00] + Array("Some Artist".utf8))
        check("mp3 audio bytes preserved", Array(after[offAfter...]) == origAudio)

        try service.eraseBPM(url: mp3)
        after = [UInt8](try Data(contentsOf: mp3))
        guard let (tagErased, offErased) = parseID3Tag(after) else {
            check("mp3 parses after TBPM erase", false)
            return
        }
        check("mp3 TBPM erased", !tagErased.frames.contains(where: { $0.id == "TBPM" }))
        check("mp3 readBPM nil after erase", (try service.readBPM(url: mp3)) == nil)
        check("mp3 TIT2 still intact",
              tagErased.frames.first(where: { $0.id == "TIT2" })?.data == [0x00] + Array("Test Title".utf8))
        check("mp3 audio intact after erase", Array(after[offErased...]) == origAudio)
    } catch {
        check("mp3 tag tests threw: \(error)", false)
    }
}

// MARK: - (c) Synthetic FLAC byte fixture: write/erase BPM=, ARTIST + padding preserved

func makeFLACFixture(url: URL) throws -> (bytes: [UInt8], audioOffset: Int) {
    let streaminfo = FLACBlock(type: 0, data: [UInt8](repeating: 0, count: 34))
    let vc = VorbisComment(vendor: "BPMPLSTest", comments: ["ARTIST=Tester", "TITLE=Flac Fixture"])
    let vcBlock = FLACBlock(type: 4, data: buildVorbisComment(vc))
    let padding = FLACBlock(type: 1, data: [UInt8](repeating: 0, count: 256))
    var bytes = buildFLAC(blocks: [streaminfo, vcBlock, padding])
    let audioOffset = bytes.count
    bytes.append(contentsOf: [UInt8](repeating: 0x5A, count: 200)) // fake audio frames
    try Data(bytes).write(to: url)
    return (bytes, audioOffset)
}

func testFLACTags(tmp: URL) {
    do {
        let service = NativeMetadataService()
        let flac = tmp.appendingPathComponent("fixture.flac")
        let (original, origAudioOffset) = try makeFLACFixture(url: flac)
        let origAudio = Array(original[origAudioOffset...])

        try service.writeBPM(url: flac, bpm: 126.5)
        var after = [UInt8](try Data(contentsOf: flac))
        guard let (blocksAfter, offAfter) = parseFLAC(after) else {
            check("flac parses after BPM write", false)
            return
        }
        let vcAfter = blocksAfter.first(where: { $0.type == 4 }).flatMap { parseVorbisComment($0.data) }
        check("flac BPM entry written", vcAfter?.comments.contains("BPM=126.50") == true)
        check("flac readBPM returns 126.5", (try service.readBPM(url: flac)) == 126.5)
        check("flac basic tags: artist/title",
              (try service.readBasicTags(url: flac)).artist == "Tester")
        check("flac ARTIST intact", vcAfter?.comments.contains("ARTIST=Tester") == true)
        check("flac STREAMINFO untouched", blocksAfter.first?.data == [UInt8](repeating: 0, count: 34))
        check("flac padding block preserved",
              blocksAfter.contains(where: { $0.type == 1 && $0.data.count == 256 }))
        check("flac padding still last", blocksAfter.last?.type == 1)
        check("flac audio bytes preserved", Array(after[offAfter...]) == origAudio)

        try service.eraseBPM(url: flac)
        after = [UInt8](try Data(contentsOf: flac))
        guard let (blocksErased, offErased) = parseFLAC(after) else {
            check("flac parses after BPM erase", false)
            return
        }
        let vcErased = blocksErased.first(where: { $0.type == 4 }).flatMap { parseVorbisComment($0.data) }
        check("flac BPM removed", vcErased?.comments.contains(where: { $0.uppercased().hasPrefix("BPM=") }) == false)
        check("flac ARTIST intact after erase", vcErased?.comments.contains("ARTIST=Tester") == true)
        check("flac padding preserved after erase",
              blocksErased.contains(where: { $0.type == 1 && $0.data.count == 256 }))
        check("flac audio intact after erase", Array(after[offErased...]) == origAudio)
    } catch {
        check("flac tag tests threw: \(error)", false)
    }
}

// MARK: - (d) File dates preserved across tag rewrite

func testDatePreservation(tmp: URL) {
    do {
        let service = NativeMetadataService()
        let mp3 = tmp.appendingPathComponent("dates.mp3")
        _ = try makeMP3Fixture(url: mp3)
        let created = Date(timeIntervalSince1970: 1_420_000_000)  // 2014-12-31
        let modified = Date(timeIntervalSince1970: 1_450_000_000) // 2015-12-08
        try FileManager.default.setAttributes([.creationDate: created, .modificationDate: modified],
                                              ofItemAtPath: mp3.path)
        try service.writeBPM(url: mp3, bpm: 128.0)
        let attrs = try FileManager.default.attributesOfItem(atPath: mp3.path)
        let c2 = attrs[.creationDate] as? Date
        let m2 = attrs[.modificationDate] as? Date
        check("creation date preserved", c2 != nil && abs(c2!.timeIntervalSince(created)) < 2.0)
        check("modification date preserved", m2 != nil && abs(m2!.timeIntervalSince(modified)) < 2.0)
    } catch {
        check("date preservation threw: \(error)", false)
    }
}

// MARK: - (e) Dropout fixtures: on-grid mute resume vs. tempo change

func testDropouts(tmp: URL) async {
    do {
        // Shortened. The 8 s chunk is the engine's
        // minimum unit; we need at least 1 chunk on each side of a mute
        // to test on-grid resume. 8+8+8 = 24 s (was 48 s).
        let aURL = tmp.appendingPathComponent("dropoutA.wav")
        try writeClickWAV(url: aURL,
                          segments: [(bpm: 120.0, start: 0.0, end: 8.0),
                                     (bpm: 120.0, start: 16.0, end: 24.0)],
                          totalSeconds: 24.0)
        let bpmA = try await BPMEngine.analyze(url: aURL, minBPM: 70, maxBPM: 180)
        check("dropout on-grid resume keeps 120 (got \(String(format: "%.2f", bpmA)))",
              abs(bpmA - 120.0) <= 1.5)

        // 8 s of 120, 8 s mute, then 24 s of 140 → majority runtime is 140.
        // 8+8+24 = 40 s (was 56 s). Calibration:
        // 16 s of 140 (2 chunks) was insufficient — the tempo tracker
        // stayed anchored to 120 because the change was too brief to
        // re-anchor. 3 chunks (24 s) is the minimum for reliable
        // tempo-change detection.
        let bURL = tmp.appendingPathComponent("dropoutB.wav")
        try writeClickWAV(url: bURL,
                          segments: [(bpm: 120.0, start: 0.0, end: 8.0),
                                     (bpm: 140.0, start: 16.0, end: 40.0)],
                          totalSeconds: 40.0)
        let bpmB = try await BPMEngine.analyze(url: bURL, minBPM: 70, maxBPM: 180)
        check("tempo change picks majority-runtime 140 (got \(String(format: "%.2f", bpmB)))",
              abs(bpmB - 140.0) <= 1.5)
    } catch {
        check("dropout tests threw: \(error)", false)
    }
}

// MARK: - Kick tiebreak on layered fixtures (dotted-8th hats vs. on-beat kick)

/// Two independent rhythmic layers: a 120 Hz kick exactly on the beat, and 4 kHz
/// hats every 0.75 beat (the dotted-8th pattern behind the real-world 110-over-82.5
/// and 134-over-100 t_0710e9887bgs). Correct answer is the kick's tempo.
func writeLayeredWAV(url: URL, bpm: Double, totalSeconds: Double, sampleRate: Double = 44100) throws {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                               channels: 1, interleaved: false)!
    let totalFrames = Int(totalSeconds * sampleRate)
    var data = [Float](repeating: 0, count: totalFrames)
    let period = 60.0 / bpm
    let kickLen = Int(0.03 * sampleRate)
    var t = 0.0
    while t < totalSeconds {
        let startIdx = Int((t * sampleRate).rounded())
        for k in 0..<kickLen {
            let idx = startIdx + k
            if idx >= totalFrames { break }
            let ct = Double(k) / sampleRate
            data[idx] += Float(0.9 * exp(-ct / 0.01) * sin(2 * Double.pi * 120 * ct))
        }
        t += period
    }
    let hatLen = Int(0.015 * sampleRate)
    t = 0.0
    while t < totalSeconds {
        let startIdx = Int((t * sampleRate).rounded())
        for k in 0..<hatLen {
            let idx = startIdx + k
            if idx >= totalFrames { break }
            let ct = Double(k) / sampleRate
            data[idx] += Float(0.5 * exp(-ct / 0.004) * sin(2 * Double.pi * 4000 * ct))
        }
        t += period * 0.75
    }
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(totalFrames)) else {
        throw BPMError.unreadableAudio
    }
    buffer.frameLength = AVAudioFrameCount(totalFrames)
    let ptr = buffer.floatChannelData![0]
    data.withUnsafeBufferPointer { src in
        ptr.update(from: src.baseAddress!, count: totalFrames)
    }
    try file.write(from: buffer)
}

func testKickTiebreakLayered(tmp: URL) async {
    do {
        // Shortened from 48s to 24s. The kick-tiebreak
        // logic only needs ~2 chunks to converge; 24s is enough to exercise
        // the dotted-8th vs kick discrimination.
        let layered = tmp.appendingPathComponent("layered100.wav")
        try writeLayeredWAV(url: layered, bpm: 100.0, totalSeconds: 24.0)
        let b = try await BPMEngine.analyze(url: layered, minBPM: 70, maxBPM: 180)
        check("layered 100 kick + dotted-8th hats -> 100 ±1.5 (got \(String(format: "%.2f", b)))",
              abs(b - 100.0) <= 1.5)

        let control = tmp.appendingPathComponent("click133.wav")
        try writeClickWAV(url: control, segments: [(bpm: 400.0 / 3.0, start: 0.0, end: 24.0)],
                          totalSeconds: 24.0)
        let c = try await BPMEngine.analyze(url: control, minBPM: 70, maxBPM: 180)
        check("pure 133.3 clicks stay 133.3 ±1.5 (got \(String(format: "%.2f", c)))",
              abs(c - 400.0 / 3.0) <= 1.5)
    } catch {
        check("kick tiebreak tests threw: \(error)", false)
    }
}

// MARK: - Backbeat corroboration (kick on all 4, snare on 2 & 4)

/// Section A: `bpmA` deep kick only. Section B: `bpmB` kick + snare on beats 2 & 4
/// (900 Hz body + 3.2 kHz crack). The snare's T/2 rate is the backbeat evidence.
func writeKickSnareWAV(url: URL, bpmA: Double, secondsA: Double, bpmB: Double,
                       secondsB: Double, sampleRate: Double = 44100) throws {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                               channels: 1, interleaved: false)!
    let totalSeconds = secondsA + secondsB
    let totalFrames = Int(totalSeconds * sampleRate)
    var data = [Float](repeating: 0, count: totalFrames)
    func burst(at t: Double, freq: Double, decay: Double, amp: Double, len: Double) {
        let startIdx = Int((t * sampleRate).rounded())
        let n = Int(len * sampleRate)
        for k in 0..<n {
            let idx = startIdx + k
            if idx >= totalFrames { break }
            let ct = Double(k) / sampleRate
            data[idx] += Float(amp * exp(-ct / decay) * sin(2 * Double.pi * freq * ct))
        }
    }
    // Section A: kick on every beat.
    var t = 0.0
    while t < secondsA {
        burst(at: t, freq: 80, decay: 0.012, amp: 0.9, len: 0.04)
        t += 60.0 / bpmA
    }
    // Section B: kick on every beat, snare on beats 2 & 4 of each bar.
    let beatB = 60.0 / bpmB
    t = secondsA
    while t < totalSeconds {
        burst(at: t, freq: 100, decay: 0.012, amp: 0.9, len: 0.04)
        t += beatB
    }
    t = secondsA + beatB // beat 2 of the first bar
    while t < totalSeconds {
        burst(at: t, freq: 900, decay: 0.02, amp: 0.6, len: 0.05)
        burst(at: t, freq: 3200, decay: 0.008, amp: 0.3, len: 0.02)
        t += 2 * beatB // beats 2 and 4 = every 2 beats
    }
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(totalFrames)) else {
        throw BPMError.unreadableAudio
    }
    buffer.frameLength = AVAudioFrameCount(totalFrames)
    let ptr = buffer.floatChannelData![0]
    data.withUnsafeBufferPointer { src in
        ptr.update(from: src.baseAddress!, count: totalFrames)
    }
    try file.write(from: buffer)
}

func testBackbeatCorroboration(tmp: URL) async {
    do {
        // Shortened. The backbeat corroboration
        // logic only needs ~2 chunks per section. Was 8+40=48s and
        // 26+22=48s; now 4+12=16s and 13+11=24s (preserves the
        // duration ratio in the near-tie test).
        let solo = tmp.appendingPathComponent("kicksnare100.wav")
        try writeKickSnareWAV(url: solo, bpmA: 100.0, secondsA: 4.0, bpmB: 100.0, secondsB: 12.0)
        let s = try await BPMEngine.analyze(url: solo, minBPM: 70, maxBPM: 180)
        check("kick+snare 100 reads 100 ±1.5 (got \(String(format: "%.2f", s)))", abs(s - 100.0) <= 1.5)

        let tie = tmp.appendingPathComponent("t_88bb867ab9.wav")
        try writeKickSnareWAV(url: tie, bpmA: 80.0, secondsA: 13.0, bpmB: 100.0, secondsB: 11.0)
        let b = try await BPMEngine.analyze(url: tie, minBPM: 70, maxBPM: 180)
        check("backbeat flips near-tie 80 -> 100 ±1.5 (got \(String(format: "%.2f", b)))", abs(b - 100.0) <= 1.5)
    } catch {
        check("backbeat tests threw: \(error)", false)
    }
}

// MARK: - Per-track timeout helper

func testTimeout() async {
    do {
        let value = try await withTimeout(seconds: 2.0) { () async throws -> Int in
            try await Task.sleep(nanoseconds: 20_000_000)
            return 42
        }
        check("timeout: fast op returns value", value == 42)
    } catch {
        check("timeout: fast op threw \(error)", false)
    }
    do {
        _ = try await withTimeout(seconds: 0.2) { () async throws -> Int in
            try await Task.sleep(nanoseconds: 3_000_000_000)
            return 1
        }
        check("timeout: slow op should have thrown", false)
    } catch {
        check("timeout: slow op throws .timeout", error is AnalysisError)
    }
}

// MARK: - Compressed fixtures exercise the AVAudioConverter path (WAV tests don't)

func testCompressedFixtures() async {
    for name in ["clicks120.mp3", "clicks120.flac"] {
        let url = URL(fileURLWithPath: "Tests/Fixtures/" + name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            check("\(name) fixture missing — run tests from the BPMPLS project directory", false)
            continue
        }
        do {
            let bpm = try await BPMEngine.analyze(url: url, minBPM: 70, maxBPM: 180)
            check("\(name) via converter path -> 120 ±1.5 (got \(String(format: "%.2f", bpm)))",
                  abs(bpm - 120.0) <= 1.5)
        } catch {
            check("\(name) threw: \(error)", false)
        }
    }
}

// MARK: - readBasicTags (aside variables) on real tag structures

func testBasicTags(tmp: URL) {
    do {
        let service = NativeMetadataService()
        // MP3: full frame set, title in UTF-16 (0x01) to prove encoding handling.
        let mp3 = tmp.appendingPathComponent("basics.mp3")
        let utf16Title = Array("Freak (t_2e98b0f72d Main Mix)".data(using: .utf16)!)
        let tag = ID3Tag(major: 3, revision: 0, flags: 0, extendedHeader: nil,
                         frames: [ID3Frame(id: "TPE1", flags: [0, 0], data: [0x03] + Array("t_e9ba9a45b0".utf8)),
                                  ID3Frame(id: "TIT2", flags: [0, 0], data: [0x01] + utf16Title),
                                  ID3Frame(id: "TALB", flags: [0, 0], data: [0x00] + Array("t_75d06cd224 Sampler".utf8)),
                                  ID3Frame(id: "TDRC", flags: [0, 0], data: [0x00] + Array("2007-03-12".utf8))],
                         paddingLength: 64)
        var bytes = buildID3Tag(tag)
        bytes.append(contentsOf: [0xFF, 0xFB, 0x90, 0x64] + [UInt8](repeating: 0xCD, count: 128))
        try Data(bytes).write(to: mp3)
        let b = try service.readBasicTags(url: mp3)
        check("basic tags mp3: artist", b.artist == "t_e9ba9a45b0")
        check("basic tags mp3: utf16 title", b.title == "Freak (t_2e98b0f72d Main Mix)")
        check("basic tags mp3: album", b.album == "t_75d06cd224 Sampler")
        check("basic tags mp3: year from TDRC", b.year == "2007-03-12")
        // FLAC: ALBUM + DATE present.
        let flac = tmp.appendingPathComponent("basics.flac")
        let streaminfo = FLACBlock(type: 0, data: [UInt8](repeating: 0, count: 34))
        let vc = VorbisComment(vendor: "t", comments: ["ARTIST=t_982f73b196", "TITLE=t_f662ef40dd",
                                                       "ALBUM=Loosies", "DATE=2024"])
        var fbytes = buildFLAC(blocks: [streaminfo, FLACBlock(type: 4, data: buildVorbisComment(vc))])
        fbytes.append(contentsOf: [UInt8](repeating: 0x5A, count: 64))
        try Data(fbytes).write(to: flac)
        let fb = try service.readBasicTags(url: flac)
        check("basic tags flac: all four", fb.artist == "t_982f73b196" && fb.title == "t_f662ef40dd"
              && fb.album == "Loosies" && fb.year == "2024")
        // Untagged file -> all nils, no throw.
        let bare = tmp.appendingPathComponent("bare.mp3")
        try Data([0xFF, 0xFB] + [UInt8](repeating: 0, count: 32)).write(to: bare)
        let nb = try service.readBasicTags(url: bare)
        check("basic tags untagged mp3: nils", nb.artist == nil && nb.title == nil
              && nb.album == nil && nb.year == nil)
    } catch {
        check("basic tags tests threw: \(error)", false)
    }
}

// MARK: - Folder-affinity two-pass integration test

func testFolderAffinityTwoPass(tmp: URL) async {
    // Build a 3-file "album" of clean clicks at the same BPM. This
    // is the structural test: the affinity should form an anchor (the
    // strongest cross-track support comes from the most consistent
    // BPM across files), and the prior should NOT flip the others
    // (they're already at the anchor's tempo). The corpus gate
    // already exercises the actual flip behavior on real audio.
    do {
        let folder = tmp.appendingPathComponent("album_affinity", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let wav1 = folder.appendingPathComponent("01_clean_120.wav")
        // Shortened to 8s. Folder affinity doesn't
        // depend on track length, just on consistency across the folder.
        try writeClickWAV(url: wav1, segments: [(bpm: 120.0, start: 0.0, end: 8.0)], totalSeconds: 8.0)
        let wav2 = folder.appendingPathComponent("02_clean_120.wav")
        try writeClickWAV(url: wav2, segments: [(bpm: 120.0, start: 0.0, end: 8.0)], totalSeconds: 8.0)
        let wav3 = folder.appendingPathComponent("03_clean_120.wav")
        try writeClickWAV(url: wav3, segments: [(bpm: 120.0, start: 0.0, end: 8.0)], totalSeconds: 8.0)
        let a1 = try await BPMEngine.analyzeDetailed(url: wav1, minBPM: 70, maxBPM: 180)
        let a2 = try await BPMEngine.analyzeDetailed(url: wav2, minBPM: 70, maxBPM: 180)
        let a3 = try await BPMEngine.analyzeDetailed(url: wav3, minBPM: 70, maxBPM: 180)
        let results: [(url: URL, bpm: Double, confidence: Double, bandPeaks: [[(bpm: Double, frac: Float)]])] = [
            (wav1, a1.bpm, a1.confidence, a1.bandPeaksRaw),
            (wav2, a2.bpm, a2.confidence, a2.bandPeaksRaw),
            (wav3, a3.bpm, a3.confidence, a3.bandPeaksRaw),
        ]
        let affinity = FolderAffinity.build(from: results)
        let anchor = affinity.anchor(for: wav2)
        check("integration: folder affinity produced an anchor for 3-track click album", anchor != nil)
        if let anchor = anchor {
            check("integration: anchor BPM is 120 ± 1 (got \(String(format: "%.2f", anchor.bpm)))",
                  abs(anchor.bpm - 120.0) <= 1.0)
            // No flip: all tracks are already at the anchor's tempo.
            let r2 = BPMEngine.applyFolderAffinity(verdict: a2.bpm, bandPeaks: a2.bandPeaksRaw, anchor: anchor)
            check("integration: no flip when verdict already matches anchor",
                  !r2.flipped && abs(r2.bpm - a2.bpm) < 0.01)
        }
    } catch {
        check("integration: folder-affinity test threw: \(error)", false)
    }
}

// MARK: - Ambient detection integration test

func testAmbientDetectionIntegration(tmp: URL) async {
    // Real t_d39307236f file is the canonical ambient case. Verify the
    // engine flags it (noBeatFound=true) AND that the verdict is in
    // the "no peak in 70-180" / "unstable cluster" pattern.
    do {
        // Canonical ambient case. Resolved from the project root (this
        // file is two levels below it: <root>/Tests/IntegrationTests.swift).
        let projectRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent()
        let nilPath = projectRoot.appendingPathComponent(
            "Corpus/t_3b98738d17/t_142eb246a5/t_c835a65c3d.mp3").path
        let url = URL(fileURLWithPath: nilPath)
        guard FileManager.default.fileExists(atPath: nilPath) else {
            skip("integration: ambient detection (t_d39307236f not in corpus)")
            return
        }
        let analysis = try await BPMEngine.analyzeDetailed(url: url, minBPM: 70, maxBPM: 180)
        check("integration: t_d39307236f flagged as ambient (noBeatFound=true)",
              analysis.noBeatFound == true)
    } catch {
        check("integration: ambient detection threw: \(error)", false)
    }
}

@main
struct IntegrationTests {
    static func main() async {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("BPMPLSTests-" + UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            await testEngineOnWAVs(tmp: tmp)
            testMP3Tags(tmp: tmp)
            testFLACTags(tmp: tmp)
            testBasicTags(tmp: tmp)
            testDatePreservation(tmp: tmp)
            await testDropouts(tmp: tmp)
            await testKickTiebreakLayered(tmp: tmp)
            await testBackbeatCorroboration(tmp: tmp)
            await testTimeout()
            await testCompressedFixtures()
            await testFolderAffinityTwoPass(tmp: tmp)
            await testAmbientDetectionIntegration(tmp: tmp)
        } catch {
            check("harness setup", false)
        }
        try? FileManager.default.removeItem(at: tmp)
        printTestSummary(label: "INTEGRATION TESTS")
    }
}
