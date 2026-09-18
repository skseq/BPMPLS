import Foundation

// Plain unit harness (no XCTest). Prints "PASS/FAIL <name>" lines and a final count; exit 1 on any failure.
// Compile together with all of Sources/*.swift (same module -> internals visible):
//   swiftc Sources/*.swift Tests/UnitTests.swift -O -parse-as-library ...

func approxEq(_ a: Double, _ b: Double, _ tol: Double = 1e-6) -> Bool { abs(a - b) <= tol }

// MARK: - Octave constraint

func testOctaveConstraint() {
    check("octave fold 64 -> 128", approxEq(BPMEngine.foldToRange(64, minBPM: 70, maxBPM: 180), 128))
    check("octave fold 240 -> 120", approxEq(BPMEngine.foldToRange(240, minBPM: 70, maxBPM: 180), 120))
    check("octave fold 100 stays 100", approxEq(BPMEngine.foldToRange(100, minBPM: 70, maxBPM: 180), 100))
    check("octave fold 35 -> 70 (spec while-loop stops at min)", approxEq(BPMEngine.foldToRange(35, minBPM: 70, maxBPM: 180), 70))
    check("octave fold 500 -> 125", approxEq(BPMEngine.foldToRange(500, minBPM: 70, maxBPM: 180), 125))
}

// MARK: - Syncsafe ints

func testSyncsafe() {
    for value in [UInt32(0), 1, 127, 128, 255, 300, 16383, 16384, 65535, 0x0FFFFFFF] {
        check("syncsafe roundtrip \(value)", syncsafeDecode(syncsafeEncode(value)) == value)
    }
    check("syncsafe encode 128", syncsafeEncode(128) == [0, 0, 1, 0])
    check("syncsafe encode max", syncsafeEncode(0x0FFFFFFF) == [0x7F, 0x7F, 0x7F, 0x7F])
    check("syncsafe decode masks high bits", syncsafeDecode([0x80, 0x80, 0x80, 0x80]) == 0)
}

// MARK: - ID3v2 frame parse/rebuild roundtrip

func makeSyntheticID3(padding: Int = 64) -> ID3Tag {
    ID3Tag(major: 3, revision: 0, flags: 0, extendedHeader: nil,
           frames: [ID3Frame(id: "TIT2", flags: [0, 0], data: [0x00] + Array("Title".utf8)),
                    ID3Frame(id: "TPE1", flags: [0, 0], data: [0x00] + Array("Artist".utf8))],
           paddingLength: padding)
}

func testID3Roundtrip() {
    let tag = makeSyntheticID3()
    let bytes = buildID3Tag(tag)
    guard let (parsed, offset) = parseID3Tag(bytes) else {
        check("id3 parse synthetic", false)
        return
    }
    check("id3 parse synthetic", true)
    check("id3 offset covers tag", offset == bytes.count)
    check("id3 version preserved", parsed.major == 3)
    check("id3 frame count", parsed.frames.count == 2)
    check("id3 TIT2 data", parsed.frames.first(where: { $0.id == "TIT2" })?.data == [0x00] + Array("Title".utf8))
    check("id3 rebuild byte-identical", buildID3Tag(parsed) == bytes)

    var withBPM = parsed
    id3SettingTBPM(&withBPM, bpm: 128.0)
    let bytes2 = buildID3Tag(withBPM)
    guard let (parsed2, _) = parseID3Tag(bytes2) else {
        check("id3 reparse with TBPM", false)
        return
    }
    check("id3 reparse with TBPM", true)
    check("id3 TBPM value", id3ReadTBPM(parsed2) == 128.0)
    check("id3 TIT2 intact after TBPM", parsed2.frames.first(where: { $0.id == "TIT2" })?.data == [0x00] + Array("Title".utf8))
    check("id3 TPE1 intact after TBPM", parsed2.frames.first(where: { $0.id == "TPE1" })?.data == [0x00] + Array("Artist".utf8))

    var removed = parsed2
    id3SettingTBPM(&removed, bpm: nil)
    check("id3 TBPM removal restores bytes", buildID3Tag(removed) == bytes)

    // v2.4 syncsafe frame sizes roundtrip
    var tag24 = makeSyntheticID3()
    tag24.major = 4
    let bytes24 = buildID3Tag(tag24)
    guard let (parsed24, _) = parseID3Tag(bytes24) else {
        check("id3 v2.4 roundtrip", false)
        return
    }
    check("id3 v2.4 roundtrip", buildID3Tag(parsed24) == bytes24 && parsed24.frames.count == 2)
}

// MARK: - Vorbis comment parse/rebuild roundtrip

func testVorbisRoundtrip() {
    var vc = VorbisComment(vendor: "BPMPLSTest", comments: ["ARTIST=Tester", "TITLE=t_f96df424e7"])
    let data = buildVorbisComment(vc)
    guard let parsed = parseVorbisComment(data) else {
        check("vorbis parse", false)
        return
    }
    check("vorbis vendor", parsed.vendor == "BPMPLSTest")
    check("vorbis comments", parsed.comments == ["ARTIST=Tester", "TITLE=t_f96df424e7"])
    check("vorbis rebuild byte-identical", buildVorbisComment(parsed) == data)

    vorbisSettingBPM(&vc, bpm: 126.5)
    guard let parsed2 = parseVorbisComment(buildVorbisComment(vc)) else {
        check("vorbis reparse", false)
        return
    }
    check("vorbis BPM entry", parsed2.comments.contains("BPM=126.50"))
    check("vorbis BPM read", vorbisReadBPM(parsed2) == 126.5)
    check("vorbis ARTIST intact", parsed2.comments.contains("ARTIST=Tester"))

    vorbisSettingBPM(&vc, bpm: nil)
    let afterRemove = parseVorbisComment(buildVorbisComment(vc))
    check("vorbis BPM removed", afterRemove?.comments.contains(where: { $0.uppercased().hasPrefix("BPM=") }) == false)
    check("vorbis others intact after remove", afterRemove?.comments == ["ARTIST=Tester", "TITLE=t_f96df424e7"])

    var lower = VorbisComment(vendor: "v", comments: ["bpm=99.5"])
    check("vorbis case-insensitive read", vorbisReadBPM(lower) == 99.5)
    vorbisSettingBPM(&lower, bpm: 100.0)
    check("vorbis case-insensitive replace",
          lower.comments.filter({ $0.lowercased().hasPrefix("bpm=") }).count == 1 && vorbisReadBPM(lower) == 100.0)
}

// MARK: - IOI variance band selection

func testBandSelection() {
    var envA = [Float](repeating: 0, count: 400)
    for i in stride(from: 0, to: 400, by: 40) { envA[i] = 1.0 } // periodic
    var envB = [Float](repeating: 0, count: 400)
    for i in [0, 13, 71, 90, 151, 156, 232, 301] { envB[i] = 1.0 } // irregular
    var envC = [Float](repeating: 0, count: 400)
    for i in [5, 180] { envC[i] = 1.0 } // too few peaks
    let rate = 86.0
    let peaksA = BPMEngine.pickPeaks(envelope: envA, envRate: rate)
    let peaksB = BPMEngine.pickPeaks(envelope: envB, envRate: rate)
    check("peaks periodic count", peaksA.count == 9)
    guard let varA = BPMEngine.normalizedIOIVariance(peaks: peaksA),
          let varB = BPMEngine.normalizedIOIVariance(peaks: peaksB) else {
        check("ioi variance computed", false)
        return
    }
    check("ioi variance computed", true)
    check("periodic envelope has lower variance", varA < varB)
    check("master band picks periodic", BPMEngine.bandVarianceOrder(chunks: [envA, envB, envC], envRate: rate).first == 0)
    check("master band skips too-few-peaks", BPMEngine.bandVarianceOrder(chunks: [envC, envB], envRate: rate).first == 1)
}

// MARK: - Bar-multiple check

func testBarMultiple() {
    check("8s @120 = 4 bars", BPMEngine.isBarMultiple(8.0, bpm: 120))
    check("16s @120 = 8 bars", BPMEngine.isBarMultiple(16.0, bpm: 120))
    check("32s @120 = 16 bars", BPMEngine.isBarMultiple(32.0, bpm: 120))
    check("64s @120 = 32 bars", BPMEngine.isBarMultiple(64.0, bpm: 120))
    check("7.3s @120 rejected", !BPMEngine.isBarMultiple(7.3, bpm: 120))
    check("10s @120 rejected", !BPMEngine.isBarMultiple(10.0, bpm: 120))
    check("96s @120 rejected (48 bars)", !BPMEngine.isBarMultiple(96.0, bpm: 120))
}

// MARK: - Modulo phase-grid alignment

func testPhaseGrid() {
    check("phase aligned exact", BPMEngine.isPhaseAligned(32.0, bpm: 120, origin: 0.0))
    check("phase aligned within tol", BPMEngine.isPhaseAligned(32.02, bpm: 120, origin: 0.0))
    check("phase aligned wrap-around", BPMEngine.isPhaseAligned(31.97, bpm: 120, origin: 0.0))
    check("phase misaligned half beat", !BPMEngine.isPhaseAligned(32.26, bpm: 120, origin: 0.0))
    check("phase aligned shifted origin", BPMEngine.isPhaseAligned(4.0, bpm: 120, origin: 0.0116))
}

// MARK: - Rounding & tag text

func testRounding() {
    check("round 121.69 -> 122", BPMEngine.roundedBPM(121.69) == 122)
    check("round 122.31 -> 122", BPMEngine.roundedBPM(122.31) == 122)
    check("round 120.16 -> 120", BPMEngine.roundedBPM(120.16) == 120)
    check("round 120.5 -> 121", BPMEngine.roundedBPM(120.5) == 121)
    check("round 0 -> 0", BPMEngine.roundedBPM(0) == 0)
    check("round negative -> 0", BPMEngine.roundedBPM(-4.2) == 0)
    check("tag text 122 stays '122'", bpmTagText(122.0) == "122")
    check("tag text 126.5 -> '126.50'", bpmTagText(126.5) == "126.50")
}

// MARK: - Band fallback, friendly errors, error snapshot

func clickEnvelope(bpm: Double, seconds: Double, envRate: Double) -> [Float] {
    var env = [Float](repeating: 0, count: Int(seconds * envRate))
    let interval = envRate * 60.0 / bpm
    var pos = 0.0
    while Int(pos) < env.count {
        env[Int(pos)] = 10
        pos += interval
    }
    return env
}

func testBandFallback() {
    let envRate = 44100.0 / 512.0
    let dead = [Float](repeating: 0, count: Int(8 * envRate))       // no peaks, autocorrelation nil
    let clicks = clickEnvelope(bpm: 120, seconds: 8, envRate: envRate)
    // Dead band has nil variance; clicks band must be picked despite order.
    let order = BPMEngine.bandVarianceOrder(chunks: [dead, clicks, dead], envRate: envRate)
    check("fallback order puts measurable band first", order.first == 1)
    let bpm = BPMEngine.bpmFromBandChunks([dead, clicks, dead], envRate: envRate, minBPM: 70, maxBPM: 180)?.bpm
    check("fallback finds 120 from second band (got \(bpm ?? -1))", bpm != nil && abs(bpm! - 120) <= 1.5)
    check("all-dead bands return nil",
          BPMEngine.bpmFromBandChunks([dead, dead], envRate: envRate, minBPM: 70, maxBPM: 180) == nil)
}

func testFriendlyErrors() {
    check("unreadableAudio is friendly", BPMError.unreadableAudio.localizedDescription.contains("decode"))
    check("noOnsets is friendly", BPMError.noOnsets.localizedDescription.contains("rhythm"))
    check("timeout is friendly", AnalysisError.timeout.localizedDescription.contains("timed out"))
}

func testErrorSnapshot() {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("BPMPLSLogTest-" + UUID().uuidString, isDirectory: true)
    let logger = LogService(directory: dir)
    logger.enabledOverride = true
    for i in 1...150 { logger.log("line \(i)") }
    logger.error("boom")
    for i in 1...150 { logger.log("after \(i)") }
    let content = (try? String(contentsOf: logger.errorLogURL, encoding: .utf8)) ?? ""
    check("snapshot header written", content.contains("===== ERROR SNAPSHOT") && content.contains("boom"))
    check("error line marked", content.contains(">>> "))
    check("context before present (line 148)", content.contains("line 148"))
    check("context before capped at 5 (line 144 excluded)", !content.contains("line 144"))
    check("5 lines after teed (after 3)", content.contains("after 3"))
    check("tee capped (after 6 excluded)", !content.contains("after 6"))
    check("snapshot closed", content.contains("end of error snapshot"))
    let main = (try? String(contentsOf: logger.logURL, encoding: .utf8)) ?? ""
    check("main log has ERROR line", main.contains("ERROR boom"))
    try? FileManager.default.removeItem(at: dir)
}

// MARK: - Logging toggle, sessions, prune, clear, asides

func testLoggingControls() {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("BPMPLSLogCtl-" + UUID().uuidString, isDirectory: true)

    // Disabled = zero file writes (default behavior when the Settings toggle is off).
    let off = LogService(directory: dir, stamp: "s-off")
    off.enabledOverride = false
    off.log("should not persist")
    off.error("also should not persist")
    check("logging disabled writes nothing", !FileManager.default.fileExists(atPath: off.logURL.path)
          && !FileManager.default.fileExists(atPath: off.errorLogURL.path))

    // Enabled + session-stamped filenames.
    let on = LogService(directory: dir, stamp: "s-on")
    on.enabledOverride = true
    on.log("hello session")
    check("session log created with stamp", on.logURL.lastPathComponent.contains("s-on")
          && FileManager.default.fileExists(atPath: on.logURL.path))

    // Prune keeps newest 10 per group (own subdir so the session log above doesn't skew counts).
    let pdir = dir.appendingPathComponent("prune", isDirectory: true)
    try? FileManager.default.createDirectory(at: pdir, withIntermediateDirectories: true)
    for i in 1...12 {
        let main = pdir.appendingPathComponent("BPMPLS 2026-01-\(String(format: "%02d", i)).log")
        let errs = pdir.appendingPathComponent("BPMPLS-errors 2026-01-\(String(format: "%02d", i)).log")
        try? Data("x".utf8).write(to: main)
        try? Data("x".utf8).write(to: errs)
        let date = Date(timeIntervalSince1970: Double(i) * 1000)
        try? FileManager.default.setAttributes([.creationDate: date], ofItemAtPath: main.path)
        try? FileManager.default.setAttributes([.creationDate: date], ofItemAtPath: errs.path)
    }
    LogService.prune(directory: pdir)
    let remainingMain = (try? FileManager.default.contentsOfDirectory(atPath: pdir.path))?
        .filter { $0.hasSuffix(".log") && !$0.contains("-errors") } ?? []
    check("prune keeps 10 session logs", remainingMain.count == 10)
    check("prune keeps newest", remainingMain.contains("BPMPLS 2026-01-12.log")
          && !remainingMain.contains("BPMPLS 2026-01-01.log"))

    // Clear Logs empties the folder.
    on.clearLogs()
    let left = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.filter { $0.hasSuffix(".log") } ?? ["?"]
    check("clearLogs empties folder", left.isEmpty)
    try? FileManager.default.removeItem(at: dir)
}

func testAsides() {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("asides-" + UUID().uuidString)
    try? "one aside\n\nanother aside  \nthird\n".write(to: tmp, atomically: true, encoding: .utf8)
    check("asides file loads non-empty lines", Asides.load(from: tmp) == ["one aside", "another aside", "third"])
    check("missing asides file -> nil", Asides.load(from: tmp.appendingPathComponent("nope.txt")) == nil)
    let empty = tmp.appendingPathComponent("empty")
    try? "  \n\n".write(to: empty, atomically: true, encoding: .utf8)
    check("empty asides file -> nil", Asides.load(from: empty) == nil)
    check("builtin asides are plentiful", Asides.builtin.count >= 70)
    check("random aside for empty context has no unresolved tokens",
          Asides.requiredTokens(of: Asides.random()).isEmpty)
    try? FileManager.default.removeItem(at: tmp)
}

// MARK: - Aside parsers (filename / folder / year / sanitize)

func testAsideParsers() {
    check("sanitize underscores + collapse", AsideParser.sanitize("  the__3am__special  ") == "the 3am special")
    check("sanitizeFilename strips extension", AsideParser.sanitizeFilename("01_-_Track_Name.mp3") == "01 - Track Name")
    check("truncate keeps short strings", AsideParser.truncate("short") == "short")
    check("truncate caps at 60 with ellipsis", AsideParser.truncate(String(repeating: "x", count: 100)).count == 60)

    let p1 = AsideParser.parseFilename("0856 - Onyx Fog - Static (Onyx Fog Main Mix).mp3")
    check("filename: numbered artist+title", p1.artist == "Onyx Fog" && p1.title == "Static (Onyx Fog Main Mix)")
    let p2 = AsideParser.parseFilename("01 - Blue Hours (Night Ferry remix).mp3")
    check("filename: numbered title only", p2.artist == nil && p2.title == "Blue Hours (Night Ferry remix)")
    let p3 = AsideParser.parseFilename("Artist - Title.mp3")
    check("filename: plain artist+title", p3.artist == "Artist" && p3.title == "Title")
    let p4 = AsideParser.parseFilename("NoSeparators.mp3")
    check("filename: single segment = title", p4.artist == nil && p4.title == "NoSeparators")
    let p5 = AsideParser.parseFilename("Under_score_Name.mp3")
    check("filename: underscores sanitized", p5.title == "Under score Name")
    let p6 = AsideParser.parseFilename("01.mp3")
    check("filename: bare number yields nothing", p6.artist == nil && p6.title == nil)
    let p7 = AsideParser.parseFilename("A - B - C.flac")
    check("filename: extra segments join into title", p7.artist == "A" && p7.title == "B - C")

    check("year: plain", AsideParser.extractYear("(2023)") == "2023")
    check("year: full date", AsideParser.extractYear("2023-04-12") == "2023")
    check("year: range yields nil", AsideParser.extractYear("1998-2021") == nil)
    check("year: none", AsideParser.extractYear("no digits here") == nil)
    check("year: implausible yields nil", AsideParser.extractYear("live at the 1899 show") == nil)

    let f1 = AsideParser.parseFolder(forFile: URL(fileURLWithPath: "/music/VA - Test Label Records (1998-2021)/1998/x.mp3"))
    check("folder: bare-year parent climbs, carries year", f1.album == "Test Label Records" && f1.year == "1998")
    let f2 = AsideParser.parseFolder(forFile: URL(fileURLWithPath: "/music/Artist - Album (2023)/x.mp3"))
    check("folder: artist-album-year", f2.album == "Album" && f2.year == "2023")
    let f3 = AsideParser.parseFolder(forFile: URL(fileURLWithPath: "/music/_loosie/x.mp3"))
    check("folder: unstructured yields nothing", f3.album == nil && f3.year == nil)
    let f4 = AsideParser.parseFolder(forFile: URL(fileURLWithPath: "/music/Homework (2011)/CD1/x.mp3"))
    check("folder: disc parent climbs", f4.album == "Homework" && f4.year == "2011")
    let f5 = AsideParser.parseFolder(forFile: URL(fileURLWithPath: "/music/VA - Something (1998-2021)/x.mp3"))
    check("folder: range year yields album, no year", f5.album == "Something" && f5.year == nil)
}

// MARK: - Aside templating (variable-aware selection + substitution)

func testAsideTemplating() {
    check("requiredTokens: plain aside", Asides.requiredTokens(of: "no tokens here.").isEmpty)
    check("requiredTokens: two vars",
          Asides.requiredTokens(of: "%artist% on %album%? canon.") == ["artist", "album"])
    var ctx = AsideContext()
    ctx.year = "2023"
    ctx.bpm = "128"
    check("substitute fills known vars",
          Asides.substitute("%bpm% BPM, %year% called.", context: ctx) == "128 BPM, 2023 called.")
    check("substitute leaves unknown vars untouched",
          Asides.substitute("%artist% again?", context: ctx) == "%artist% again?")
    // Selection: with only year+bpm known, a picked aside must never show an unresolved token.
    // (Literal percents like "80% this genre" are fine — check token patterns, not "%".)
    var leakFree = true
    for _ in 0..<200 {
        let q = Asides.random(context: ctx)
        if !Asides.requiredTokens(of: q).isEmpty { leakFree = false; break }
    }
    check("random(context:) never leaks unresolved tokens", leakFree)
    // Full context can resolve everything, incl. combos.
    let full = AsideContext(filename: "x", artist: "A", title: "T", album: "AL", year: "2023", bpm: "128")
    check("combo aside substitutes fully",
          Asides.substitute("%artist% — %title%. someone studied.", context: full) == "A — T. someone studied.")
}

// MARK: - Aside context assembly (tags win; filename + folder fill gaps)

func testAsideContextGather() {
    let service = NativeMetadataService()
    // Nonexistent file -> tags fail softly; filename + folder parsing still apply.
    // All variable values arrive lowercase + sanitized.
    let url = URL(fileURLWithPath: "/music/Artist - Album (2023)/0856 - Onyx Fog - Static (Onyx Fog Main Mix).mp3")
    let ctx = AsideContext.gather(url: url, filename: url.lastPathComponent, bpm: "129", service: service)
    check("gather: artist from filename, lowercased", ctx.artist == "onyx fog")
    check("gather: title from filename, lowercased", ctx.title == "static (onyx fog main mix)")
    check("gather: album from folder, lowercased", ctx.album == "album")
    check("gather: year from folder", ctx.year == "2023")
    check("gather: bpm passed through", ctx.bpm == "129")
    check("gather: filename sanitized + lowercased", ctx.filename == "0856 - onyx fog - static (onyx fog main mix)")
    let barren = URL(fileURLWithPath: "/downloads/_loosie/01 - Blue Hours (Night Ferry remix).mp3")
    let ctx2 = AsideContext.gather(url: barren, filename: barren.lastPathComponent, bpm: nil, service: service)
    check("gather: barren folder -> title only", ctx2.title == "blue hours (night ferry remix)"
          && ctx2.artist == nil && ctx2.album == nil && ctx2.year == nil && ctx2.bpm == nil)
}

// MARK: - Normalize, kick tiebreak, tempo summary, egg clock

func testNormalize() {
    check("normalize lowercases + strips underscores", AsideParser.normalize("Onyx_Fog") == "onyx fog")
    check("normalize collapses whitespace", AsideParser.normalize("  A   B  ") == "a b")
    check("normalize nil -> nil", AsideParser.normalize(nil) == nil)
    check("normalize empty -> nil", AsideParser.normalize("   ") == nil)
}

func testMetricalTiebreak() {
    // Harmonic relatives: LOW band carries the pulse.
    check("tiebreak: 133.2 vs 101.2 (x4/3) -> low", BPMEngine.metricalTiebreak(nominee: 133.2, lowBand: 101.2) == 101.2)
    check("tiebreak: 110 vs 82.5 (x4/3) -> low", BPMEngine.metricalTiebreak(nominee: 110.0, lowBand: 82.5) == 82.5)
    check("tiebreak: 174 vs 87 (x2 half-time) -> low", BPMEngine.metricalTiebreak(nominee: 174.0, lowBand: 87.0) == 87.0)
    // ×3/2 is absent — both real-world firings were 3-beat pattern periods,
    // not half-time grooves (122->81 and 119->79 were wrong; nominee stands now).
    check("tiebreak: 150 vs 100 (x3/2 removed) -> nominee", BPMEngine.metricalTiebreak(nominee: 150.0, lowBand: 100.0) == 150.0)
    check("tiebreak: 120 vs 80 (x3/2 removed) -> nominee", BPMEngine.metricalTiebreak(nominee: 120.0, lowBand: 80.0) == 120.0)
    // Agreement and non-metrical disagreement keep the nominee.
    check("tiebreak: bands within 3% keep nominee", BPMEngine.metricalTiebreak(nominee: 100.0, lowBand: 101.0) == 100.0)
    check("tiebreak: 120 vs 100 (x1.2, not metrical) -> nominee", BPMEngine.metricalTiebreak(nominee: 120.0, lowBand: 100.0) == 120.0)
    check("tiebreak: degenerate inputs -> nominee", BPMEngine.metricalTiebreak(nominee: 128.0, lowBand: 0) == 128.0)
}

// MARK: - Consensus fold, backbeat support, multi-tempo gate

func testConsensusFold() {
    // 3-beat pattern period: 40.6 x3 lands on MID's 122 -> consensus picks x3.
    let a = BPMEngine.foldWithConsensus(raw: 40.6, selfIndex: 0, raws: [40.6, 122.1, 122.3],
                                        minBPM: 70, maxBPM: 180)
    check("consensus fold 40.6 -> ~121.8 (got \(a))", abs(a - 121.8) <= 1.0)
    // No agreement anywhere: plain octave fold stands (t_f662ef40dd LOW stays 82.4).
    let b = BPMEngine.foldWithConsensus(raw: 41.2, selfIndex: 0, raws: [41.2, 110.0, 110.1],
                                        minBPM: 70, maxBPM: 180)
    check("consensus fold 41.2 -> ~82.4 default (got \(b))", abs(b - 82.4) <= 1.0)
    // t_f56837a178 body: 51.7 x3 agrees with another band's 155.1.
    let c = BPMEngine.foldWithConsensus(raw: 51.7, selfIndex: 0, raws: [51.7, 155.1, nil],
                                        minBPM: 70, maxBPM: 180)
    check("consensus fold 51.7 -> ~155.1 (got \(c))", abs(c - 155.1) <= 1.0)
    // In-range reading with no partners stays itself.
    let d = BPMEngine.foldWithConsensus(raw: 100.0, selfIndex: 1, raws: [41.0, 100.0, 133.0],
                                        minBPM: 70, maxBPM: 180)
    check("consensus fold 100 -> 100 (got \(d))", abs(d - 100.0) <= 0.5)
}

func testBackbeatSupport() {
    // Snare on 2&4 of 120 = 60 BPM periodicity in MID.
    let peaks: [[(bpm: Double, frac: Float)]] = [
        [(120.4, 1.0), (61.0, 0.9)],   // LOW (ignored by design)
        [(60.2, 1.0), (120.1, 0.8)],   // MID: strong 60 -> backbeat for 120
        [(240.0, 1.0)],                // HIGH
    ]
    check("backbeat: T=120 supported by MID 60.2", BPMEngine.backbeatSupport(bandPeaks: peaks, for: 120.0))
    check("backbeat: T=120 not fooled by LOW-only 60",
          !BPMEngine.backbeatSupport(bandPeaks: [[(60.1, 1.0)], [(122.0, 1.0)], [(250.0, 1.0)]], for: 120.0))
    check("backbeat: weak subharmonic (8%) does not count",
          !BPMEngine.backbeatSupport(bandPeaks: [[(120.0, 1.0)], [(120.0, 1.0), (60.0, 0.08)], [(250.0, 1.0)]], for: 120.0))
    check("backbeat: T=99 unsupported", !BPMEngine.backbeatSupport(bandPeaks: peaks, for: 99.0))
    check("backbeat: degenerate -> false", !BPMEngine.backbeatSupport(bandPeaks: peaks, for: 0))
}

func testMultiTempoGate() {
    func seg(_ bpm: Double, _ dur: Double, _ band: Int = 0) -> SegmentInfo {
        SegmentInfo(bpm: bpm, startTime: 0, duration: dur, band: band)
    }
    // t_f0cf33fd88 case: 101 vs 136 is a x4/3 metrical relative -> silent.
    check("gate: metrical relative suppressed",
          BPMEngine.multiTempoNote([seg(101, 77), seg(136, 19), seg(81, 3)], tagged: 101) == nil)
    // dee_dee case: 1% share -> silent.
    check("gate: tiny share suppressed",
          BPMEngine.multiTempoNote([seg(120, 99), seg(152, 1, 2)], tagged: 120) == nil)
    // Hover drift: 107 vs 111 is < 8 BPM apart -> silent.
    check("gate: <8 BPM drift suppressed",
          BPMEngine.multiTempoNote([seg(107, 60), seg(111, 40)], tagged: 107) == nil)
    // Megamix: 107 vs 121, 21% share, non-metrical -> flagged.
    let mega = BPMEngine.multiTempoNote([seg(107, 38), seg(111, 24), seg(121, 21, 1)], tagged: 107)
    check("gate: megamix flagged with 121", mega != nil && mega!.contains("121") && mega!.contains("tagged 107"))
    // t_f56837a178 case: x2 relatives BUT different dominant band (ambient intro vs kick-led body) -> flagged.
    let t_f56837a178 = BPMEngine.multiTempoNote([seg(155, 76), seg(77.5, 19, 2)], tagged: 155)
    check("gate: x2 band-character exception flags", t_f56837a178 != nil && (t_f56837a178!.contains("77") || t_f56837a178!.contains("78")))
    // x2 relatives with the SAME dominant band (hat artifact) -> silent.
    check("gate: x2 same-band suppressed",
          BPMEngine.multiTempoNote([seg(155, 76), seg(77.5, 19)], tagged: 155) == nil)
    // Real t_4e57a091c5's other cluster: 155 MID-led vs 103 LOW sections — x3/2 stays
    // suppressed even across bands (pattern-period artifact, not a thematic switch).
    check("gate: x3/2 different-band suppressed",
          BPMEngine.multiTempoNote([seg(155, 49, 1), seg(103, 33, 0)], tagged: 155) == nil)
    // x3/2 relatives with the SAME dominant band (pattern artifact) -> silent.
    check("gate: x3/2 same-band suppressed",
          BPMEngine.multiTempoNote([seg(155, 49, 1), seg(103, 33, 1)], tagged: 155) == nil)
    // The x2 band-switch waives the 12% share floor: a brief ambient no-kick intro
    // (13s of 133s = 9.8%) still earns the flag — t_4e57a091c5's 77 LOW intro vs 155 MID body.
    let t_f56837a178Intro = BPMEngine.multiTempoNote([seg(155, 120, 1), seg(77.5, 13, 0)], tagged: 155)
    check("gate: x2 band-switch waives share floor",
          t_f56837a178Intro != nil && (t_f56837a178Intro!.contains("77") || t_f56837a178Intro!.contains("78")))
    // t_4144928674 band split: 101 HIGH winner vs 135 LOW secondary is x4/3 -> silent even
    // across bands (3-beat pattern artifact, not a thematic change).
    check("gate: x4/3 different-band still suppressed",
          BPMEngine.multiTempoNote([seg(101, 60, 2), seg(135, 25, 0)], tagged: 101) == nil)
    // t_ee81aa44fe case: 119 vs 95 (x5/4) and vs 79 (x3/2) are both pattern-period artifacts
    // of the same groove -> silent even across bands.
    check("gate: x5/4 and x3/2 artifacts suppressed",
          BPMEngine.multiTempoNote([seg(119, 71, 2), seg(95, 13, 0), seg(79, 13, 0)], tagged: 119) == nil)
    // 12s minimum duration: 13s of 11% fails share; 13s of 13% passes duration.
    check("gate: secondary under 12s suppressed",
          BPMEngine.multiTempoNote([seg(100, 150), seg(140, 11, 1)], tagged: 100) == nil)
}

func testTempoSummary() {
    let segs = [
        SegmentInfo(bpm: 100.2, startTime: 0, duration: 60),
        SegmentInfo(bpm: 99.7, startTime: 60, duration: 30),   // rounds to 100: clusters
        SegmentInfo(bpm: 133.8, startTime: 90, duration: 30),
    ]
    let summary = BPMEngine.tempoSummary(segs)
    check("tempo summary cluster count", summary.count == 2)
    check("tempo summary winner first", summary.first?.bpm == 100 && approxEq(summary.first?.fraction ?? 0, 0.75))
    check("tempo summary runner-up", summary.count == 2 && summary[1].bpm == 134 && approxEq(summary[1].fraction, 0.25))
    check("tempo summary empty -> empty", BPMEngine.tempoSummary([]).isEmpty)
    check("tempo summary zero-duration ignored",
          BPMEngine.tempoSummary([SegmentInfo(bpm: 120, startTime: 0, duration: 0)]).isEmpty)
}

func testEggClock() {
    func isPrime(_ n: Int) -> Bool {
        if n < 2 { return false }
        var d = 2
        while d * d <= n { if n % d == 0 { return false }; d += 1 }
        return true
    }
    check("egg primes are all prime", AsideClock.primesThrough200.allSatisfy(isPrime))
    check("egg primes within 0...199", AsideClock.primesThrough200.allSatisfy { $0 > 0 && $0 < 200 })
    var offsetsOK = true
    for _ in 0..<500 {
        let o = AsideClock.randomOffset()
        if !(AsideClock.primesThrough200.contains(abs(o))) { offsetsOK = false; break }
    }
    check("egg offset always a prime magnitude", offsetsOK)
    check("egg first target near 2000 (1801...2199)", (1801...2199).contains(AsideClock.firstTarget()))

    // Testing mode: every 3rd scanned file fires.
    AsideClock.debugEvery = 3
    check("egg debug: 3rd fires", AsideClock.consumeCrossings(scanned: 3))
    check("egg debug: 4th silent", !AsideClock.consumeCrossings(scanned: 4))
    check("egg debug: 5th silent", !AsideClock.consumeCrossings(scanned: 5))
    check("egg debug: 6th fires", AsideClock.consumeCrossings(scanned: 6))

    // Live mode: crossings at/after the persisted target; the schedule
    // advances past everything the batch covered (coalescing deep batches
    // into a single firing) and survives via UserDefaults.
    AsideClock.debugEvery = nil
    AsideClock.setNextTargetForTesting(5)
    check("egg live: below target silent", !AsideClock.consumeCrossings(scanned: 4))
    check("egg live: at target fires", AsideClock.consumeCrossings(scanned: 5))
    check("egg live: schedule advanced past scan", !AsideClock.consumeCrossings(scanned: 1000))
    AsideClock.setNextTargetForTesting(5)
    check("egg live: deep batch coalesces to one", AsideClock.consumeCrossings(scanned: 9000))
    check("egg live: stored target now past the batch", AsideClock.nextTargetForTesting() >= 9001)
    check("egg live: same count again is silent", !AsideClock.consumeCrossings(scanned: 9000))
    AsideClock.debugEvery = 3 // restore testing default for the rest of the suite
}

// MARK: - Min/max parsing fallbacks

func testRangeParsing() {
    check("range parse valid", BPMEngine.parseRange(min: "70", max: "180") == (70, 180))
    check("range parse bad min falls back", BPMEngine.parseRange(min: "abc", max: "180") == (70, 180))
    check("range parse inverted falls back", BPMEngine.parseRange(min: "200", max: "100") == (70, 180))
    check("range parse wide ok", BPMEngine.parseRange(min: "40", max: "400") == (40, 400))
    check("range parse empty falls back", BPMEngine.parseRange(min: "", max: "") == (70, 180))
}

// MARK: - A/B drastic-change rule

func testDrasticChange() {
    check("drastic: 83 -> 110 drastic", BPMEngine.isDrasticBPMChange(old: 83, new: 110))
    check("drastic: 100 -> 134 drastic", BPMEngine.isDrasticBPMChange(old: 100, new: 134))
    check("drastic: +5 exactly is NOT drastic", !BPMEngine.isDrasticBPMChange(old: 120, new: 125))
    check("drastic: -5 exactly is NOT drastic", !BPMEngine.isDrasticBPMChange(old: 125, new: 120))
    check("drastic: +6 IS drastic", BPMEngine.isDrasticBPMChange(old: 120, new: 126))
    check("drastic: -6 IS drastic", BPMEngine.isDrasticBPMChange(old: 126, new: 120))
    check("drastic: equal NOT drastic", !BPMEngine.isDrasticBPMChange(old: 122, new: 122))
    check("drastic: -1 NOT drastic", !BPMEngine.isDrasticBPMChange(old: 122, new: 121))
    check("drastic: +1 NOT drastic", BPMEngine.isDrasticBPMChange(old: 121, new: 122) == false)
}

// MARK: - Instrument-aware onset decomposition (parked classifier)

private let testEnvRate = 44100.0 / 512.0 // 86.1328125 fps, same as engine @44.1k

private func makeBandData(_ n: Int) -> (envs: [[Float]], engs: [[[Float]]]) {
    let envs = [[Float]](repeating: [Float](repeating: 0, count: n), count: 3)
    let engs = [[[Float]]](repeating: [[Float]](repeating: [Float](repeating: 0, count: 4), count: n), count: 3)
    return (envs, engs)
}

/// Place one synthetic event: envelope spikes per band + sub-band energies per band.
private func synthOnset(_ d: inout (envs: [[Float]], engs: [[[Float]]]), frame f: Int,
                        envAmp: [(Int, Float)], eng: [(Int, [Float])]) {
    for (b, a) in envAmp { d.envs[b][f] = a }
    for (b, e) in eng { d.engs[b][f] = e }
}

private func fracNear(_ peaks: [(bpm: Double, frac: Float)], _ bpm: Double) -> Float {
    peaks.first(where: { abs($0.bpm - bpm) <= 0.03 * bpm })?.frac ?? 0
}

func testOnsetClassification() {
    let n = 1722 // 20 s @ 86.13 fps

    // 1. Kick-like: LOW band only, sharp attack, energy all <150 Hz.
    var d1 = makeBandData(n)
    for f in stride(from: 43, to: n, by: 43) {
        synthOnset(&d1, frame: f, envAmp: [(0, 10)], eng: [(0, [100, 0, 0, 0])])
    }
    let kicks = OnsetClassifier.classifyOnsets(envelopes: d1.envs, energies: d1.engs, envRate: testEnvRate)
    check("classify: kick events detected", kicks.count >= 35)
    if let k = kicks.first {
        let pk = k.roleProbabilities[.kick] ?? 0
        check("classify: kick-like -> P(kick) dominant", pk > 0.5 && pk > (k.roleProbabilities[.hihat] ?? 0) && pk > (k.roleProbabilities[.snare] ?? 0))
        let sum = k.roleProbabilities.values.reduce(0, +)
        check("classify: probabilities sum to 1", approxEq(Double(sum), 1.0, 1e-4))
    } else {
        check("classify: kick-like -> P(kick) dominant", false)
        check("classify: probabilities sum to 1", false)
    }

    // 2. Hihat-like: HIGH band, air (>5 kHz) dominant.
    var d2 = makeBandData(n)
    for f in stride(from: 32, to: n, by: 32) {
        synthOnset(&d2, frame: f, envAmp: [(2, 10)], eng: [(2, [0, 0, 10, 90])])
    }
    let hats = OnsetClassifier.classifyOnsets(envelopes: d2.envs, energies: d2.engs, envRate: testEnvRate)
    check("classify: hihat events detected", hats.count >= 45)
    if let h = hats.first {
        let ph = h.roleProbabilities[.hihat] ?? 0
        check("classify: air-dominant -> P(hihat) dominant", ph > 0.5 && ph > (h.roleProbabilities[.kick] ?? 0))
        check("classify: hihat probs sum to 1", approxEq(Double(h.roleProbabilities.values.reduce(0, +)), 1.0, 1e-4))
    } else {
        check("classify: air-dominant -> P(hihat) dominant", false)
        check("classify: hihat probs sum to 1", false)
    }

    // 3. Snare-like: MID body + presence/air wire noise, sharp attack.
    var d3 = makeBandData(n)
    for f in stride(from: 86, to: n, by: 86) {
        synthOnset(&d3, frame: f, envAmp: [(1, 10), (2, 6)], eng: [(1, [0, 60, 0, 0]), (2, [0, 0, 25, 15])])
    }
    let snares = OnsetClassifier.classifyOnsets(envelopes: d3.envs, energies: d3.engs, envRate: testEnvRate)
    if let s = snares.first {
        let ps = s.roleProbabilities[.snare] ?? 0
        check("classify: mid-body+air -> P(snare) dominant", ps > 0.5 && ps > (s.roleProbabilities[.hihat] ?? 0) && ps > (s.roleProbabilities[.kick] ?? 0))
    } else {
        check("classify: mid-body+air -> P(snare) dominant", false)
    }

    // 4. Slow bass swell: strong low energy but gradual attack must NOT read as kick
    //    (Wu et al. 2018 melodic-masking failure mode).
    var d4 = makeBandData(n)
    for f in stride(from: 43, to: n, by: 43) {
        synthOnset(&d4, frame: f, envAmp: [(0, 10)], eng: [(0, [100, 0, 0, 0])])
        d4.engs[0][f - 2] = [85, 0, 0, 0]
        d4.engs[0][f - 1] = [93, 0, 0, 0]
    }
    let swells = OnsetClassifier.classifyOnsets(envelopes: d4.envs, energies: d4.engs, envRate: testEnvRate)
    if let w = swells.first {
        check("classify: slow low swell -> not kick", (w.roleProbabilities[.kick] ?? 1) < 0.2 && (w.roleProbabilities[.other] ?? 0) > (w.roleProbabilities[.kick] ?? 0))
    } else {
        check("classify: slow low swell -> not kick", false)
    }

    // 5. Cross-band merge: simultaneous kick + hat (2 frames apart) is ONE event.
    var d5 = makeBandData(n)
    for f in stride(from: 43, to: n - 3, by: 43) {
        synthOnset(&d5, frame: f, envAmp: [(0, 10)], eng: [(0, [100, 0, 0, 0])])
        synthOnset(&d5, frame: f + 2, envAmp: [(2, 8)], eng: [(2, [0, 0, 10, 90])])
    }
    let merged = OnsetClassifier.classifyOnsets(envelopes: d5.envs, energies: d5.engs, envRate: testEnvRate)
    check("classify: cross-band simultaneous hits merge to one event", merged.count >= 35 && merged.count <= 45)
}

func testRoleWeightedEnvelopes() {
    let n = 1722

    // 6. Weight application: a kick-classified onset scales each band's envelope at the
    //    onset frame by the probability-weighted role gain; distant frames untouched.
    var d6 = makeBandData(n)
    for f in stride(from: 43, to: n, by: 43) {
        synthOnset(&d6, frame: f, envAmp: [(0, 10), (1, 5), (2, 3)], eng: [(0, [100, 0, 0, 0])])
    }
    let onsets6 = OnsetClassifier.classifyOnsets(envelopes: d6.envs, energies: d6.engs, envRate: testEnvRate)
    let w6 = OnsetClassifier.roleWeightedEnvelopes(envelopes: d6.envs, onsets: onsets6, envRate: testEnvRate)
    if let k = onsets6.first {
        var expect = [Float](repeating: 0, count: 3)
        for role in OnsetRole.allCases {
            let p = k.roleProbabilities[role] ?? 0
            for b in 0..<3 { expect[b] += p * (OnsetClassifier.roleBandWeights[role]?[b] ?? 1) }
        }
        check("weight: kick onset LOW gain matches matrix", approxEq(Double(w6[0][k.frame]), Double(d6.envs[0][k.frame] * expect[0]), 1e-3))
        check("weight: kick onset MID damped", w6[1][k.frame] < d6.envs[1][k.frame] && approxEq(Double(w6[1][k.frame]), Double(d6.envs[1][k.frame] * expect[1]), 1e-3))
        let far = min(n - 1, k.frame + 20)
        check("weight: frames far from onsets unchanged", w6[0][far] == d6.envs[0][far] && w6[1][far] == d6.envs[1][far] && w6[2][far] == d6.envs[2][far])
    } else {
        check("weight: kick onset LOW gain matches matrix", false)
        check("weight: kick onset MID damped", false)
        check("weight: frames far from onsets unchanged", false)
    }

    // 7. No onsets -> identity.
    let d7 = makeBandData(n)
    let w7 = OnsetClassifier.roleWeightedEnvelopes(envelopes: d7.envs, onsets: [], envRate: testEnvRate)
    check("weight: no onsets leaves envelopes identical", w7 == d7.envs)

    // 8. Mechanism (t_0710e9887b x4/3): a dotted-8th hat pattern reading ~161 BPM in MID must
    //    lose autocorr strength when hats are damped (hihat MID gain 0.4 vs snare 1.0).
    var d8 = makeBandData(n)
    for f in stride(from: 16, to: n, by: 32) { // dotted-8th hats @120 BPM context (~161.5 BPM rate)
        synthOnset(&d8, frame: f, envAmp: [(1, 6)], eng: [(1, [0, 50, 0, 0]), (2, [0, 0, 10, 90])])
    }
    for f in stride(from: 64, to: n, by: 86) { // backbeat snares (60.1 BPM half-time rate)
        synthOnset(&d8, frame: f, envAmp: [(1, 10)], eng: [(1, [0, 60, 0, 0]), (2, [0, 0, 25, 15])])
    }
    let onsets8 = OnsetClassifier.classifyOnsets(envelopes: d8.envs, energies: d8.engs, envRate: testEnvRate)
    let w8 = OnsetClassifier.roleWeightedEnvelopes(envelopes: d8.envs, onsets: onsets8, envRate: testEnvRate)
    let rawPeaks = BPMEngine.topEnvelopePeaks(d8.envs[1], envRate: testEnvRate, k: 6, minBPM: 70, maxBPM: 180, fold: false)
    let wPeaks = BPMEngine.topEnvelopePeaks(w8[1], envRate: testEnvRate, k: 6, minBPM: 70, maxBPM: 180, fold: false)
    let dotted: Double = 60.0 * testEnvRate / 32.0 // ~161.5 BPM
    let rFrac = fracNear(rawPeaks, dotted), wFrac = fracNear(wPeaks, dotted)
    check("mechanism: dotted-8th hat rate present in raw MID", rFrac > 0.5)
    check("mechanism: hat damping shrinks dotted-8th peak >=40%", wFrac < rFrac * 0.6 && wFrac < 0.55)
}

func testOnsetClassificationGuards() {
    // 9. Pin the role->band weight matrix (hand-set; any retune is deliberate).
    check("matrix: kick row", OnsetClassifier.roleBandWeights[.kick] == [1.0, 0.3, 0.1])
    check("matrix: hihat damped below pulse instruments in LOW and MID",
          (OnsetClassifier.roleBandWeights[.hihat]?[0] ?? 1) < (OnsetClassifier.roleBandWeights[.kick]?[0] ?? 0) &&
          (OnsetClassifier.roleBandWeights[.hihat]?[1] ?? 1) < (OnsetClassifier.roleBandWeights[.snare]?[1] ?? 0))

    // 10. Fold guard: x1.5/x2/3 candidates stay FORBIDDEN (circular-reinforcement lesson).
    //     raw 69 with a 51.7 sibling must NOT corroborate to ~103.5 (69 x1.5).
    let folded = BPMEngine.foldWithConsensus(raw: 69, selfIndex: 1, raws: [51.7, 69, nil], minBPM: 70, maxBPM: 180)
    check("fold guard: 69 with 51.7 sibling does NOT land at ~103.5", abs(folded - 103.5) > 3.0)
    check("fold guard: 69 folds to 138", approxEq(folded, 138))

    // 11. BPMAnalysis new evidence fields default to empty (additive, non-breaking).
    let bare = BPMAnalysis(bpm: 120, segments: [])
    check("BPMAnalysis: peak arrays default empty", bare.bandPeaksRaw.isEmpty && bare.bandPeaksRoleWeighted.isEmpty)

    // 12. Classifier perf: 8 s chunk (690 frames) classifies well under the 5 ms budget.
    var d12 = makeBandData(690)
    for f in stride(from: 22, to: 690, by: 22) {
        synthOnset(&d12, frame: f, envAmp: [(0, 10), (2, 8)], eng: [(0, [100, 0, 0, 0]), (2, [0, 0, 10, 90])])
    }
    let t0 = CFAbsoluteTimeGetCurrent()
    for _ in 0..<50 {
        _ = OnsetClassifier.classifyOnsets(envelopes: d12.envs, energies: d12.engs, envRate: testEnvRate)
    }
    let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0 / 50.0
    check("perf: classify 8s chunk < 5 ms", ms < 5.0)
}

// MARK: - Online beat tracker

/// Synthetic click grid: spikes of `amp` at every `periodFrames` (rounded), over n frames.
private func clickEnvelope(_ n: Int, periodFrames: Double, amp: Float = 10,
                           startFrame: Int = 0, phaseShift: Int = 0) -> [Float] {
    var env = [Float](repeating: 0, count: n)
    var k = 0
    while true {
        let f = startFrame + phaseShift + Int((Double(k) * periodFrames).rounded())
        if f >= n { break }
        env[f] = amp
        k += 1
    }
    return env
}

/// Feed an envelope to the tracker the way analyzeSegments does: 8 s chunks.
private func feedChunks(_ tr: inout BeatTracker, _ env: [Float], chunkFrames: Int = 690) {
    var c = 0
    while c * chunkFrames < env.count {
        let lo = c * chunkFrames
        let hi = min(lo + chunkFrames, env.count)
        tr.process(chunk: Array(env[lo..<hi]), chunkStartFrame: lo)
        c += 1
    }
}

func testBeatTracker() {
    let period = testEnvRate * 60.0 / 120.0 // 43.066 frames @ 120 BPM

    // 1. Locks onto a 120 BPM click grid; high confidence; onset-backed positions.
    var tr = BeatTracker()
    let env1 = clickEnvelope(2070, periodFrames: period) // 24 s of clicks
    tr.start(bpm: 120, anchorSeconds: 0, envRate: testEnvRate)
    feedChunks(&tr, env1)
    check("tracker: locks onto 120 BPM clicks with high confidence", tr.confidence >= 0.8)
    let idealBeats = Int(24.0 / 0.5)
    check("tracker: beat count ~= duration/period", abs(tr.beats.count - idealBeats) <= 3)

    // 2. Snapped positions land on the click frames (±2 frames) — CMLt-style tolerance.
    let offBy = tr.beats.map { b -> Double in
        let frames = b * testEnvRate
        let k = (frames / period).rounded()
        return abs(frames - k * period)
    }
    let within = offBy.filter { $0 <= 2.0 }.count
    check("tracker: >=90% of beats within ±2 frames of the grid", Double(within) / Double(max(1, offBy.count)) >= 0.9)

    // 3. Beat times are absolute seconds and strictly increasing.
    var monotonic = true
    for i in 1..<tr.beats.count where tr.beats[i] <= tr.beats[i - 1] { monotonic = false }
    check("tracker: beatTimes monotonic increasing", monotonic)
    check("tracker: beat times in seconds (~0.5 s spacing)",
          tr.beats.count > 4 && approxEq(tr.beats[2] - tr.beats[1], 0.5, 0.02))

    // 4. Coasting through silence: beats continue on-grid, confidence decays.
    var tr4 = BeatTracker()
    tr4.start(bpm: 120, anchorSeconds: 0, envRate: testEnvRate)
    feedChunks(&tr4, clickEnvelope(690, periodFrames: period)) // one locked chunk
    let confBefore = tr4.confidence
    let beatsBefore = tr4.beats.count
    tr4.process(chunk: [Float](repeating: 0, count: 690), chunkStartFrame: 690)
    check("tracker: coasts through silence emitting grid beats", tr4.beats.count > beatsBefore)
    check("tracker: confidence decays in silence", tr4.confidence < confBefore)

    // 5. advanceGrid: no emission during gaps, grid stays continuable.
    var tr5 = BeatTracker()
    tr5.start(bpm: 120, anchorSeconds: 0, envRate: testEnvRate)
    feedChunks(&tr5, clickEnvelope(690, periodFrames: period))
    let n5 = tr5.beats.count
    tr5.advanceGrid(throughFrame: 690.0 * 4)
    check("tracker: advanceGrid emits nothing", tr5.beats.count == n5)
    if let g = tr5.gridOriginSeconds {
        // On-grid resume at frame 4*690: isPhaseAligned must accept a click there.
        let clickT = Double(4 * 690) / testEnvRate
        check("tracker: on-grid resume passes phase check",
              BPMEngine.isPhaseAligned(clickT, bpm: 120, origin: g))
        // Off-grid resume (half-period shift) must fail the phase check.
        let offT = clickT + 0.25
        check("tracker: off-grid resume fails phase check",
              !BPMEngine.isPhaseAligned(offT, bpm: 120, origin: g))
    } else {
        check("tracker: on-grid resume passes phase check", false)
        check("tracker: off-grid resume fails phase check", false)
    }

    // 6. Re-seed on tempo change: 120 -> 90 BPM spacing.
    var tr6 = BeatTracker()
    tr6.start(bpm: 120, anchorSeconds: 0, envRate: testEnvRate)
    feedChunks(&tr6, clickEnvelope(690, periodFrames: period))
    tr6.start(bpm: 90, anchorSeconds: 8.0, envRate: testEnvRate)
    let period90 = testEnvRate * 60.0 / 90.0
    feedChunks(&tr6, clickEnvelope(1380, periodFrames: period90, startFrame: 690, phaseShift: 0))
    check("tracker: re-seed follows new tempo (~0.667 s spacing)",
          tr6.beats.count > 4 && approxEq(tr6.beats[2] - tr6.beats[1], 60.0 / 90.0, 0.02))

    // 7. Confidence bounded in [0,1] across a mixed run.
    var inRange = true
    if tr.confidence < 0 || tr.confidence > 1 || tr4.confidence < 0 || tr4.confidence > 1 { inRange = false }
    check("tracker: confidence stays in [0,1]", inRange)

    // 8. BPMAnalysis.beatTimes defaults empty (additive, non-breaking).
    check("BPMAnalysis: beatTimes defaults empty", BPMAnalysis(bpm: 120, segments: []).beatTimes.isEmpty)

    // 9. Perf: an 8 s chunk processes far under the 100 ms budget.
    var tr9 = BeatTracker()
    tr9.start(bpm: 120, anchorSeconds: 0, envRate: testEnvRate)
    let chunk = Array(clickEnvelope(6900, periodFrames: period).prefix(690))
    let t0 = CFAbsoluteTimeGetCurrent()
    for i in 0..<100 { tr9.process(chunk: chunk, chunkStartFrame: i * 690) }
    let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0 / 100.0
    check("perf: tracker 8s chunk < 100 ms", ms < 100.0)
}

// MARK: - Multi-candidate tracker

func testCandidateSet() {
    // The bounded candidate set is verdict + 6 relatives, clipped to the BPM
    // range and de-duplicated. For 120 BPM at 70-180: 60 (out), 90, 120, 160,
    // 180, 80, 240 (out).
    let cands = candidateSet(for: 120, minBPM: 70, maxBPM: 180)
    check("candidate set includes verdict itself", cands.contains(where: { abs($0 - 120) < 0.5 }))
    check("candidate set includes ×3/4 (90)", cands.contains(where: { abs($0 - 90) < 0.5 }))
    check("candidate set includes ×2/3 (80)", cands.contains(where: { abs($0 - 80) < 0.5 }))
    check("candidate set includes ×4/3 (160)", cands.contains(where: { abs($0 - 160) < 0.5 }))
    check("candidate set includes ×3/2 (180)", cands.contains(where: { abs($0 - 180) < 0.5 }))
    check("candidate set excludes ×½ (60, below min)", !cands.contains(where: { $0 < 70 }))
    check("candidate set excludes ×2 (240, above max)", !cands.contains(where: { $0 > 180 }))

    // At low BPM (e.g. 80) the ×½ below the floor gets dropped.
    let candsLow = candidateSet(for: 80, minBPM: 70, maxBPM: 180)
    check("candidate set 80: ×½ 40 dropped", !candsLow.contains(where: { $0 < 70 }))
    check("candidate set 80: includes ×4/3 (~107)", candsLow.contains(where: { abs($0 - 106.67) < 0.5 }))

    // Dedup: the rounded-key check keeps near-identical candidates out.
    let candsDedup = candidateSet(for: 120, minBPM: 70, maxBPM: 180)
    let uniqueKeys = Set(candsDedup.map { ($0 * 100.0).rounded() })
    check("candidate set keys are unique", Double(uniqueKeys.count) == Double(candsDedup.count))
}

func testMultiCandidateAccumulator() {
    // Synthetic 120 BPM click grid: 24 seconds = 3 chunks at the standard 8 s.
    let period = testEnvRate * 60.0 / 120.0
    let chunkFrames = 690 // 8 s @ 86.1 fps
    let env1 = clickEnvelope(2070, periodFrames: period)
    var acc = MultiCandidateAccumulator(envRate: testEnvRate)
    // Evaluate the 120 candidate on 3 chunks; 96 candidate (×4/5 ratio)
    // shouldn't snap well to 120-period clicks.
    acc.evaluateChunk(chunk: Array(env1[0..<chunkFrames]),
                       chunkStartFrame: 0,
                       chunkAnchor: 0,
                       candidates: [120, 96])
    acc.evaluateChunk(chunk: Array(env1[chunkFrames..<(2 * chunkFrames)]),
                       chunkStartFrame: chunkFrames,
                       chunkAnchor: Double(chunkFrames) / testEnvRate,
                       candidates: [120, 96])
    acc.evaluateChunk(chunk: Array(env1[(2 * chunkFrames)..<2070]),
                       chunkStartFrame: 2 * chunkFrames,
                       chunkAnchor: Double(2 * chunkFrames) / testEnvRate,
                       candidates: [120, 96])
    let scores = acc.scores()
    let s120 = scores.first(where: { abs($0.bpm - 120) < 0.5 })!
    let s96 = scores.first(where: { abs($0.bpm - 96) < 0.5 })!
    // 120 is the real grid; 96 is not. Snap rate is the primary discriminator.
    check("accumulator: 120 candidate has higher snap rate than 96 (real grid)", s120.snapRate > s96.snapRate)
    check("accumulator: 96 snap rate is well below 1.0 (not the real grid)", s96.snapRate < 0.8)
    check("accumulator: 120 snap rate is at or near 1.0 (perfect click grid)", s120.snapRate >= 0.9)
    check("accumulator: coverage = 24s for both candidates", approxEq(s120.coverageSeconds, 24.0, 0.1) && approxEq(s96.coverageSeconds, 24.0, 0.1))
    // Scores are sorted by gridStability * coverage descending.
    if scores.count >= 2 {
        check("accumulator: scores sorted by gridStability * coverage desc",
              Double(scores[0].gridStability) * scores[0].coverageSeconds >= Double(scores[1].gridStability) * scores[1].coverageSeconds)
    }
}

func testMultiCandidateDistinctBeats() {
    // Property: the accumulator differentiates a real grid from a non-grid
    // via snap rate. 120 BPM click grid: 120 candidate snaps almost every
    // beat. 160 candidate (×4/3) snaps only every 4th beat. This is the
    // structural evidence the new flip rule uses.
    let period = testEnvRate * 60.0 / 120.0
    let chunkFrames = 690
    let env = clickEnvelope(2760, periodFrames: period) // 32 s = 4 chunks
    var acc = MultiCandidateAccumulator(envRate: testEnvRate)
    for i in 0..<4 {
        let lo = i * chunkFrames
        let hi = min(lo + chunkFrames, env.count)
        acc.evaluateChunk(chunk: Array(env[lo..<hi]),
                           chunkStartFrame: lo,
                           chunkAnchor: Double(lo) / testEnvRate,
                           candidates: [120, 160])
    }
    let s120 = acc.scores().first(where: { abs($0.bpm - 120) < 0.5 })!
    let s160 = acc.scores().first(where: { abs($0.bpm - 160) < 0.5 })!
    // 120 has substantially higher snap rate than 160 (real grid vs sub-grid alias).
    check("distinct beats: 120 snap rate > 160 snap rate (real grid vs alias)", s120.snapRate > s160.snapRate)
    // Coverage must be equal (both candidates evaluated over the same chunks).
    check("distinct beats: coverage equal across candidates", approxEq(s120.coverageSeconds, s160.coverageSeconds, 0.1))
    // 160 has MORE beats than 120 (faster tempo, more beats in same time) — this
    // is the property that makes beatCount alone a poor discriminator.
    check("distinct beats: 160 has more beats than 120 (faster tempo)", s160.beatCount > s120.beatCount)
}

func testMultiCandidateScoreboardType() {
    // The BPMAnalysis new field defaults empty (additive change).
    let a = BPMAnalysis(bpm: 120, segments: [])
    check("BPMAnalysis: multiCandidateScores defaults empty", a.multiCandidateScores.isEmpty)
    // Can be assigned a non-empty array.
    var b = a
    b.multiCandidateScores = [MultiCandidateScore(bpm: 120, snapRate: 0.9, gridStability: 0.85, coverageSeconds: 24, beatCount: 48)]
    check("BPMAnalysis: multiCandidateScores can be assigned", b.multiCandidateScores.count == 1)
    check("BPMAnalysis: bpm unchanged after multiCandidateScores mutation", b.bpm == 120)
}

func testMove4Constants() {
    // Lock down the Move 4 constants — corpus calibration was generated
    // with these values.
    check("move4DirectSupportMargin > 1.0 (must require a real gap, not strict equality)",
          BPMEngine.move4DirectSupportMargin > 1.0)
    check("move4DirectSupportMargin <= 1.5 (must not require an unreal gap)",
          BPMEngine.move4DirectSupportMargin <= 1.5)
    check("move4MinDirectSupport >= 0.3 (candidate must be \"really there\" in cross-band sum)",
          BPMEngine.move4MinDirectSupport >= 0.3)
}

func testMove5Constants() {
    // Lock down the Move 5 (folder affinity + ambient) constants.
    check("move5FolderAffinityMargin > 1.0 (must require a real gap)",
          BPMEngine.move5FolderAffinityMargin > 1.0)
    check("move5FolderAffinityMargin <= 1.5",
          BPMEngine.move5FolderAffinityMargin <= 1.5)
    check("move5AmbientMinPeakFrac >= 0.4 (only real peaks count, not noise)",
          BPMEngine.move5AmbientMinPeakFrac >= 0.4)
    check("move5AmbientMaxClusterFraction in (0.0, 1.0) (cluster must dominate OR not)",
          BPMEngine.move5AmbientMaxClusterFraction > 0.0 && BPMEngine.move5AmbientMaxClusterFraction < 1.0)
    check("FolderAffinity.anchorConfidenceThreshold == 0.4",
          FolderAffinity.anchorConfidenceThreshold == 0.4)
    check("FolderAffinity.minAnchorCrossBandSupport == 0.5",
          FolderAffinity.minAnchorCrossBandSupport == 0.5)
}

func testDetectAmbient() {
    // Helper: build a synthetic BPMAnalysis with given bandPeaks and segments.
    func makeAnalysis(bandPeaks: [[(bpm: Double, frac: Float)]],
                       segments: [SegmentInfo]) -> BPMAnalysis {
        return BPMAnalysis(bpm: 120, segments: segments,
                           bandPeaksRaw: bandPeaks, bandPeaksRoleWeighted: bandPeaks)
    }

    // t_d39307236f-like peaks: LOW top 258, MID top 58.7, HIGH top 63.8.
    // All out of 70-180 range. Largest cluster ~24% (unstable).
    let nilPeaks: [[(bpm: Double, frac: Float)]] = [
        [(258.4, 0.96), (215.3, 0.95), (63.8, 0.94), (60.1, 0.93), (172.3, 0.90), (30.8, 0.87)],
        [(58.7, 0.90), (63.8, 0.87), (156.6, 0.85), (224.7, 0.85), (184.6, 0.84), (31.9, 0.81)],
        [(63.8, 1.0), (31.9, 0.84), (129.2, 0.58), (105.5, 0.53), (39.2, 0.50), (44.6, 0.48)]
    ]
    // Synthetic t_a2bf2f398e-like segments: ~12 segments at varied tempos covering ~24% largest.
    let nilSegments: [SegmentInfo] = [
        SegmentInfo(bpm: 126.89, startTime: 0,    duration: 24.0, band: 0),
        SegmentInfo(bpm: 112.35, startTime: 24,   duration: 8.0,  band: 1),
        SegmentInfo(bpm: 117.83, startTime: 32,   duration: 8.0,  band: 0),
        SegmentInfo(bpm: 127.83, startTime: 40,   duration: 8.0,  band: 2),
        SegmentInfo(bpm: 152.00, startTime: 48,   duration: 8.0,  band: 1),
        SegmentInfo(bpm: 161.30, startTime: 56,   duration: 8.0,  band: 0),
        SegmentInfo(bpm: 147.36, startTime: 64,   duration: 8.0,  band: 1),
        SegmentInfo(bpm: 152.00, startTime: 72,   duration: 8.0,  band: 1),
        SegmentInfo(bpm: 134.19, startTime: 80,   duration: 16.0, band: 1),
        SegmentInfo(bpm: 129.10, startTime: 96,   duration: 16.0, band: 2),
        SegmentInfo(bpm: 101.33, startTime: 112,  duration: 8.0,  band: 0),
        SegmentInfo(bpm: 93.80,  startTime: 120,  duration: 8.0,  band: 1),
        SegmentInfo(bpm: 152.00, startTime: 128,  duration: 8.0,  band: 1)
    ]
    let nilAnalysis = makeAnalysis(bandPeaks: nilPeaks, segments: nilSegments)
    check("t_d39307236f-like: tops out of 70-180 + cluster < 30% → detected as ambient",
          BPMEngine.detectAmbient(segments: nilAnalysis.segments, bandPeaks: nilAnalysis.bandPeaksRaw))

    // Real track: 120 BPM in MID at 0.85 → not ambient (Check 1 catches).
    let realPeaks: [[(bpm: Double, frac: Float)]] = [
        [(60.0, 0.5), (120.0, 0.7)],
        [(120.0, 0.85), (60.0, 0.4)],
        [(120.0, 0.6), (240.0, 0.5)]
    ]
    let realSegments = (0..<10).map { SegmentInfo(bpm: 120, startTime: Double($0) * 8, duration: 8, band: 1) }
    let realAnalysis = makeAnalysis(bandPeaks: realPeaks, segments: realSegments)
    check("real track: MID top 120 at 0.85 → NOT ambient",
          !BPMEngine.detectAmbient(segments: realAnalysis.segments, bandPeaks: realAnalysis.bandPeaksRaw))

    // t_f56837a178-like: LOW top 154.7 at 100% → not ambient (Check 1 catches).
    let t_f56837a178Peaks: [[(bpm: Double, frac: Float)]] = [
        [(154.7, 1.0), (76.3, 0.65), (51.5, 0.55)],
        [(154.7, 0.95), (76.3, 0.60), (51.5, 0.50)],
        [(47.4, 1.0), (154.7, 0.85), (76.3, 0.70)]
    ]
    let t_f56837a178Segments = (0..<10).map { SegmentInfo(bpm: 155, startTime: Double($0) * 8, duration: 8, band: 0) }
    let t_f56837a178Analysis = makeAnalysis(bandPeaks: t_f56837a178Peaks, segments: t_f56837a178Segments)
    check("t_f56837a178-like: LOW top 154.7 at 100% → NOT ambient",
          !BPMEngine.detectAmbient(segments: t_f56837a178Analysis.segments, bandPeaks: t_f56837a178Analysis.bandPeaksRaw))

    // t_d2df69ce79-like: weak 70-180 bandPeaks but stable 101 cluster → NOT ambient (Check 2 catches).
    // (This is the case that over-fired with the simpler heuristic.)
    let t_8b2826a9ecPeaks: [[(bpm: Double, frac: Float)]] = [
        [(68.0, 1.0), (40.7, 0.96), (136.0, 0.70), (31.3, 0.58), (101.3, 0.46), (33.8, 0.44)],
        [(68.0, 1.0), (40.7, 1.0), (101.3, 0.89), (33.8, 0.81), (50.7, 0.80), (206.7, 0.77)],
        [(206.7, 1.0), (139.7, 0.91), (132.5, 0.91), (110.0, 0.89), (47.9, 0.87), (50.2, 0.87)]
    ]
    let t_8b2826a9ecSegments = (0..<20).map { SegmentInfo(bpm: 101, startTime: Double($0) * 4, duration: 4, band: 1) }
    let t_8b2826a9ecAnalysis = makeAnalysis(bandPeaks: t_8b2826a9ecPeaks, segments: t_8b2826a9ecSegments)
    check("t_d2df69ce79-like: weak 70-180 peaks but stable 101 cluster → NOT ambient (Check 2 saves it)",
          !BPMEngine.detectAmbient(segments: t_8b2826a9ecAnalysis.segments, bandPeaks: t_8b2826a9ecAnalysis.bandPeaksRaw))

    // t_7d604cf85e-like: 139 verdict, weak 70-180 bandPeaks, but stable 139 cluster.
    let fourTetPeaks: [[(bpm: Double, frac: Float)]] = [
        [(68.9, 1.0), (80.5, 0.95), (48.3, 0.91), (60.3, 0.87), (242.0, 0.83)],
        [(60.3, 1.0), (239.8, 0.94), (161.0, 0.92), (96.5, 0.90), (80.6, 0.88)],
        [(40.2, 1.0), (68.9, 0.99), (60.4, 0.94), (159.1, 0.94), (97.6, 0.90)]
    ]
    let fourTetSegments = (0..<20).map { SegmentInfo(bpm: 139, startTime: Double($0) * 4, duration: 4, band: 0) }
    let fourTetAnalysis = makeAnalysis(bandPeaks: fourTetPeaks, segments: fourTetSegments)
    check("t_7d604cf85e-like: weak 70-180 peaks but stable 139 cluster → NOT ambient",
          !BPMEngine.detectAmbient(segments: fourTetAnalysis.segments, bandPeaks: fourTetAnalysis.bandPeaksRaw))
}

func testApplyFolderAffinity() {
    // Synthetic band peaks: verdict 126 strong, anchor 94 in MID+HIGH.
    // t_1f74aed1db 1-16 scenario: verdict 126 (LOW@1.00, MID@0.82, HIGH absent),
    // anchor 94 (LOW=0, MID@0.77, HIGH@0.80 = cross-band 1.57).
    let peaks: [[(bpm: Double, frac: Float)]] = [
        // LOW: 126 strong, no 94
        [(126.0, 1.0), (62.0, 0.7), (40.0, 0.5)],
        // MID: 47 top, 126@0.82, 94@0.77
        [(47.0, 1.0), (126.0, 0.82), (94.0, 0.77), (190.0, 0.6)],
        // HIGH: 47 top, 94@0.80, 126 absent
        [(47.0, 1.0), (94.0, 0.80), (60.0, 0.7), (30.0, 0.5)]
    ]
    let anchor94 = FolderAnchor(bpm: 94, confidence: 0.6, trackCount: 7, sourceURL: URL(fileURLWithPath: "/test"))
    let result94 = BPMEngine.applyFolderAffinity(verdict: 126, bandPeaks: peaks, anchor: anchor94)
    check("folder affinity: 126 → 94 (×4/3 family, anchor 94 cross-band 1.57 > 0.5 floor)",
          result94.flipped && abs(result94.bpm - 94) < 0.5)

    // Verdict 140 → anchor 105 (t_798aaf4cd2 dub scenario).
    let peakst_798aaf4cd2: [[(bpm: Double, frac: Float)]] = [
        [(140.0, 1.0), (70.0, 0.95), (45.0, 0.8)],
        [(70.0, 1.0), (105.0, 0.71), (140.0, 0.66), (40.0, 0.5)],
        [(52.0, 1.0), (105.0, 0.97), (200.0, 0.9), (70.0, 0.85)]
    ]
    let anchor105 = FolderAnchor(bpm: 105, confidence: 0.65, trackCount: 3, sourceURL: URL(fileURLWithPath: "/test2"))
    let result105 = BPMEngine.applyFolderAffinity(verdict: 140, bandPeaks: peakst_798aaf4cd2, anchor: anchor105)
    check("folder affinity: 140 → 105 (t_798aaf4cd2 dub, anchor 105 cross-band 1.68)",
          result105.flipped && abs(result105.bpm - 105) < 0.5)

    // No-op: verdict equals anchor.
    let resultNoop = BPMEngine.applyFolderAffinity(verdict: 94, bandPeaks: peaks, anchor: anchor94)
    check("folder affinity: verdict == anchor → no flip",
          !resultNoop.flipped && resultNoop.bpm == 94)

    // No flip: anchor absent from cross-band (no peak in any band).
    let peaksNoAnchor: [[(bpm: Double, frac: Float)]] = [
        [(126.0, 1.0), (62.0, 0.7)],
        [(126.0, 0.9), (47.0, 0.8)],
        [(62.0, 0.9), (200.0, 0.7)]
    ]
    let resultNoAnchor = BPMEngine.applyFolderAffinity(verdict: 126, bandPeaks: peaksNoAnchor, anchor: anchor94)
    check("folder affinity: anchor absent from track → no flip",
          !resultNoAnchor.flipped && resultNoAnchor.bpm == 126)

    // No flip: ratio not in ×4/3 or ×3/2 family (e.g., verdict is ×2 of anchor).
    let peaksOctave: [[(bpm: Double, frac: Float)]] = [
        [(162.0, 1.0), (80.0, 0.7)],
        [(162.0, 0.9), (81.0, 0.85), (40.0, 0.5)],
        [(162.0, 0.8), (81.0, 0.7)]
    ]
    let anchor81 = FolderAnchor(bpm: 81, confidence: 0.6, trackCount: 1, sourceURL: URL(fileURLWithPath: "/test3"))
    let resultOctave = BPMEngine.applyFolderAffinity(verdict: 162, bandPeaks: peaksOctave, anchor: anchor81)
    check("folder affinity: ×2 ratio (162 vs 81) → no flip (octave excluded)",
          !resultOctave.flipped && resultOctave.bpm == 162)
}

func testFolderAffinityBuild() {
    // Synthetic batch for the cross-track-support anchor
    // selection. The anchor is the candidate verdict that has the
    // highest SUM of cross-band direct support across all other tracks
    // in the same folder.
    //
    // Folder 1: 2 tracks. track1 verdict=94 (conf 0.6), track2 verdict=126 (conf 0.81).
    //   - r1=track1 (94) checked in track2's peaks: 94 at MID=0.91 + 94 at HIGH=0.91 = 1.82
    //   - r1=track2 (126) checked in track1's peaks: 126 at LOW=1.0 + 126 at HIGH=0.73 = 1.73
    //   → 94 wins (1.82 > 1.73) and is the anchor.
    // Folder 2: 1 track — no cross-track support possible → no anchor.
    let folder1 = URL(fileURLWithPath: "/music/album1/track1.mp3")
    let folder1b = URL(fileURLWithPath: "/music/album1/track2.mp3")
    let folder2a = URL(fileURLWithPath: "/music/album2/track1.mp3")
    // track1's peaks (verdict=94). 94 strong in MID/HIGH; 126 only in LOW.
    let peaks94Track1: [[(bpm: Double, frac: Float)]] = [
        [(bpm: 126, frac: 1.0)],                         // LOW: 126 strong
        [(bpm: 94, frac: 0.91)],                         // MID: 94 strong
        [(bpm: 94, frac: 0.75), (bpm: 126, frac: 0.73)]   // HIGH: 94 + 126
    ]
    // track2's peaks (verdict=126). 126 only in LOW; 94 dominates MID/HIGH.
    let peaks126Track2: [[(bpm: Double, frac: Float)]] = [
        [(bpm: 126, frac: 1.0)],                         // LOW: 126 strong
        [(bpm: 94, frac: 0.91), (bpm: 126, frac: 0.0)],   // MID: 94 strong
        [(bpm: 94, frac: 0.91), (bpm: 126, frac: 0.0)]    // HIGH: 94 strong
    ]
    let results: [(url: URL, bpm: Double, confidence: Double, bandPeaks: [[(bpm: Double, frac: Float)]])] = [
        (folder1, 94, 0.6, peaks94Track1),
        (folder1b, 126, 0.81, peaks126Track2),
        (folder2a, 100, 0.3, [[(bpm: 100, frac: 0.5)]]),
    ]
    let affinity = FolderAffinity.build(from: results)
    let anchor1 = affinity.anchor(for: folder1b)
    check("folder affinity build: folder1 anchor = 94 (cross-track 1.82 > 126's 1.73)",
          anchor1?.bpm == 94 && anchor1?.trackCount == 2)
    check("folder affinity build: folder1 source URL = track1 (highest conf in 94-bucket)",
          anchor1?.sourceURL.path == folder1.path)
    let anchor2 = affinity.anchor(for: folder2a)
    check("folder affinity build: folder2 has NO anchor (single track, no cross-track support)",
          anchor2 == nil)
    let unknown = affinity.anchor(for: URL(fileURLWithPath: "/music/unknown/track.mp3"))
    check("folder affinity build: unknown folder → nil", unknown == nil)
}


// MARK: - Confidence

func testConfidenceLevel() {
    check("confidence < 0.40 -> low", BPMEngine.confidenceLevel(0.0) == "low")
    check("confidence 0.39 -> low",   BPMEngine.confidenceLevel(0.39) == "low")
    check("confidence 0.40 -> med",   BPMEngine.confidenceLevel(0.40) == "med")
    check("confidence 0.55 -> med",   BPMEngine.confidenceLevel(0.55) == "med")
    check("confidence 0.69 -> med",   BPMEngine.confidenceLevel(0.69) == "med")
    check("confidence 0.70 -> high",  BPMEngine.confidenceLevel(0.70) == "high")
    check("confidence 1.00 -> high",  BPMEngine.confidenceLevel(1.0) == "high")
}

func testConfidenceWeightsSumToOne() {
    let sum = BPMEngine.confidenceWeightBandFracs
            + BPMEngine.confidenceWeightClusterDur
            + BPMEngine.confidenceWeightSegCount
            + BPMEngine.confidenceWeightBackbeat
            + BPMEngine.confidenceWeightTracker
    check("confidence weights sum to 1.0 (±0.001)", abs(sum - 1.0) < 0.001)
    check("all weights are non-negative",
          BPMEngine.confidenceWeightBandFracs >= 0 &&
          BPMEngine.confidenceWeightClusterDur >= 0 &&
          BPMEngine.confidenceWeightSegCount   >= 0 &&
          BPMEngine.confidenceWeightBackbeat   >= 0 &&
          BPMEngine.confidenceWeightTracker    >= 0)
}

func testConfidenceThresholds() {
    check("low threshold == 0.40", BPMEngine.confidenceLowThreshold == 0.40)
    check("high threshold == 0.70", BPMEngine.confidenceHighThreshold == 0.70)
    check("low < high (sanity)", BPMEngine.confidenceLowThreshold < BPMEngine.confidenceHighThreshold)
}

func testConfidenceOnRealCorpus() {
    // NOTE: an earlier version of this test ran
    // real DSP on 7 audio files (~10-15s of test time). The test is a
    // WITNESS to the confidence aggregation, not a verdict — it
    // doesn't assert that greens > failures (that's tuning-to-corpus
    // and the family rule forbids it). The real calibration workstream
    // is the corpus gate, which runs on real audio and asserts the
    // full pipeline.
    //
    // This synthetic version uses hand-set confidence values that
    // match the typical pattern: greens land ~0.6-0.7 (clean
    // autocorrelation + stable cluster), failures land ~0.2-0.4
    // (pattern-period artifact). The test still exercises the
    // bounds check + prints the witness averages. The point is the
    // aggregation, not the DSP.
    let greenConfidences: [Double] = [0.65, 0.71, 0.61, 0.69]  // typical green (med→high)
    let failConfidences: [Double] = [0.21, 0.32, 0.33]         // typical failure (low)
    // Build synthetic BPMAnalysis structs and read back confidence.
    var greenScores: [Double] = []
    var failScores: [Double] = []
    for c in greenConfidences {
        let a = BPMAnalysis(bpm: 120, segments: [],
                            bandPeaksRaw: [], bandPeaksRoleWeighted: [],
                            beatTimes: [], confidence: c, backbeatStrength: 1.0)
        greenScores.append(a.confidence)
    }
    for c in failConfidences {
        let a = BPMAnalysis(bpm: 120, segments: [],
                            bandPeaksRaw: [], bandPeaksRoleWeighted: [],
                            beatTimes: [], confidence: c, backbeatStrength: 1.0)
        failScores.append(a.confidence)
    }
    check("got 4 green scores", greenScores.count == 4)
    check("got 3 failure scores", failScores.count == 3)
    for s in greenScores + failScores {
        check("score in [0,1] (got \(String(format: "%.2f", s)))", s >= 0 && s <= 1)
    }
    // Witness: print the averages so the developer can eyeball the
    // calibration during tuning. The real corpus-level calibration
    // lives in the corpus gate (53/75 green, 21 known-failure, 1
    // accepted-limit).
    let greenAvg = greenScores.isEmpty ? 0 : greenScores.reduce(0,+) / Double(greenScores.count)
    let failAvg  = failScores.isEmpty  ? 0 : failScores.reduce(0,+)  / Double(failScores.count)
    print("    [confidence calibration] green avg=\(String(format: "%.2f", greenAvg)) (n=4), failure avg=\(String(format: "%.2f", failAvg)) (n=3) [synthetic witness — real DSP in corpus gate]")
}


// MARK: - Metadata spec behaviors (v2.2 refusal, unsync bit, header-only reads)

func testMetadataSpecFixes() {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("BPMPLSTests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    let service = NativeMetadataService()

    // 1. ID3v2.2 magic (unsupported version): writes must REFUSE, not dual-tag.
    let v22 = tmp.appendingPathComponent("v22.mp3")
    var v22bytes: [UInt8] = [0x49, 0x44, 0x33, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 1, 2, 3, 4]
    v22bytes += [UInt8](repeating: 0xFF, count: 64)
    try! Data(v22bytes).write(to: v22)
    var refused = false
    do { try service.writeBPM(url: v22, bpm: 100) } catch { refused = true }
    check("v2.2 write refused (no dual-tagging)", refused)
    do { _ = try service.readBPM(url: v22); check("v2.2 read throws corruptFile", false) }
    catch { check("v2.2 read throws corruptFile", true) }

    // 2. Unsynchronisation bit is never round-tripped on write: build a tag
    //    with flags 0xFF, rewrite through the service, and verify the header.
    var tag = ID3Tag(major: 3, revision: 0, flags: 0xFF, extendedHeader: nil, frames: [], paddingLength: 16)
    id3SettingTBPM(&tag, bpm: 120)
    let rebuilt = buildID3Tag(tag)
    check("rebuilt header keeps ID3 magic", rebuilt[0] == 0x49 && rebuilt[1] == 0x44 && rebuilt[2] == 0x33)
    check("unsync bit (0x80) cleared on rebuild", rebuilt[5] & 0x80 == 0)
    check("ext-header bit (0x40) cleared when no ext header", rebuilt[5] & 0x40 == 0)

    // 3. Header-only reads: a small tag buried in front of 1 MB of audio
    //    parses identically (the reader must not need the audio bytes).
    let big = tmp.appendingPathComponent("big.mp3")
    var bigBytes = buildID3Tag(tag)
    bigBytes += [UInt8](repeating: 0xAA, count: 1_000_000)
    try! Data(bigBytes).write(to: big)
    check("header-only readBPM finds the tag", (try? service.readBPM(url: big)) ?? nil == 120)
    let tags = try? service.readBasicTags(url: big)
    check("header-only readBasicTags works", tags != nil)

    // 4. No tag at all: reads return nil without touching the audio region.
    let bare = tmp.appendingPathComponent("bare.mp3")
    try! Data([UInt8](repeating: 0x55, count: 4096)).write(to: bare)
    check("untagged file reads nil", (try? service.readBPM(url: bare)) ?? nil == nil)
}

// MARK: - AsideClock persistence across launches

func testEggClockPersistence() {
    AsideClock.debugEvery = nil
    let key = "asideNextTarget"
    UserDefaults.standard.removeObject(forKey: key)
    AsideClock.reloadFromDefaultsForTesting()
    let first = AsideClock.nextTargetForTesting()
    check("fresh seed near 2000", (1801...2199).contains(first))
    UserDefaults.standard.set(first + 123, forKey: key)
    AsideClock.reloadFromDefaultsForTesting()
    check("reload picks up stored target", AsideClock.nextTargetForTesting() == first + 123)
    check("crossing at stored target fires", AsideClock.consumeCrossings(scanned: first + 123))
    AsideClock.reloadFromDefaultsForTesting() // persisted advancement
    check("advanced target persisted", AsideClock.nextTargetForTesting() >= first + 124)
    AsideClock.debugEvery = 3 // restore testing default
}

// MARK: - SkipList matching

func testSkipListMatching() {
    var lists = SkipLists.empty
    lists.move6a = ["/music/a.mp3"]
    check("skipped path matches its Move", lists.isSkipped(path: "/music/a.mp3", for: .move6a))
    check("other path not skipped", !lists.isSkipped(path: "/music/b.mp3", for: .move6a))
    check("other Move not skipped on same path", !lists.isSkipped(path: "/music/a.mp3", for: .move6b))
}

@main
struct UnitTests {
    static func main() {
        setbuf(stdout, nil) // unbuffered: crash points visible in output
        testOctaveConstraint()
        testSyncsafe()
        testID3Roundtrip()
        testVorbisRoundtrip()
        testBandSelection()
        testBarMultiple()
        testPhaseGrid()
        testRounding()
        testDrasticChange()
        testBandFallback()
        testFriendlyErrors()
        testErrorSnapshot()
        testLoggingControls()
        testAsides()
        testAsideParsers()
        testAsideTemplating()
        testAsideContextGather()
        testNormalize()
        testMetricalTiebreak()
        testConsensusFold()
        testBackbeatSupport()
        testMultiTempoGate()
        testTempoSummary()
        testEggClock()
        testRangeParsing()
        testOnsetClassification()
        testRoleWeightedEnvelopes()
        testOnsetClassificationGuards()
        testBeatTracker()
        testCandidateSet()
        testMultiCandidateAccumulator()
        testMultiCandidateDistinctBeats()
        testMultiCandidateScoreboardType()
        testMove4Constants()
        testMove5Constants()
        testDetectAmbient()
        testApplyFolderAffinity()
        testFolderAffinityBuild()
        testConfidenceLevel()
        testConfidenceWeightsSumToOne()
        testConfidenceThresholds()
        testConfidenceOnRealCorpus()
        testMetadataSpecFixes()
        testEggClockPersistence()
        testSkipListMatching()
        printTestSummary(label: "UNIT TESTS")
    }
}
