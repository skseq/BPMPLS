import Foundation

// Occasional console asides with personal variables:
// %filename% %artist% %title% %album% %year% %bpm%. Variable-aware selection: an aside
// only fires when ALL of its variables are known for that track — no blank holes, ever.
// Variable values are normalized: sanitized (underscores -> spaces) and lowercased.
// Sources: ID3/Vorbis tags (authoritative) -> filename parse -> parent-folder parse.
// The pool is baked in at BUILD time from Resources/asides.md (build.sh re-bakes
// AsidesBuiltin.swift whenever the md changes) — no external file is read at runtime.

struct AsideContext: Equatable, Sendable {
    var filename: String? = nil
    var artist: String? = nil
    var title: String? = nil
    var album: String? = nil
    var year: String? = nil
    var bpm: String? = nil

    func value(for token: String) -> String? {
        switch token {
        case "filename": return filename
        case "artist": return artist
        case "title": return title
        case "album": return album
        case "year": return year
        case "bpm": return bpm
        default: return nil
        }
    }

    /// Assemble the context for one track: tags win, filename parse fills gaps,
    /// folder parse supplies album/year only. `bpm` arrives pre-rounded from the batch.
    static func gather(url: URL, filename: String, bpm: String?,
                       service: MetadataServiceProtocol) -> AsideContext {
        var ctx = AsideContext()
        let cleanName = AsideParser.normalize(AsideParser.sanitizeFilename(filename))
        ctx.filename = cleanName.map { AsideParser.truncate($0) }
        let tags = (try? service.readBasicTags(url: url)) ?? BasicTags()
        let parsed = AsideParser.parseFilename(filename)
        ctx.artist = AsideParser.normalize(tags.artist ?? parsed.artist)
        ctx.title = AsideParser.normalize(tags.title ?? parsed.title)
        let folder = AsideParser.parseFolder(forFile: url)
        ctx.album = AsideParser.normalize(tags.album ?? folder.album)
        let rawYear = tags.year ?? folder.year
        ctx.year = rawYear.flatMap { AsideParser.extractYear($0) }
        ctx.bpm = bpm
        return ctx
    }
}

enum AsideParser {

    /// Underscores -> spaces, whitespace collapsed, trimmed.
    static func sanitize(_ s: String) -> String {
        let spaced = s.replacingOccurrences(of: "_", with: " ")
        let collapsed = spaced.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return collapsed.trimmingCharacters(in: .whitespaces)
    }

    /// Variable values are presented lowercase + sanitized ("t_6872087338" -> "t_e9ba9a45b0").
    static func normalize(_ s: String?) -> String? {
        guard let s = s else { return nil }
        let n = sanitize(s).lowercased()
        return n.isEmpty ? nil : n
    }

    static func sanitizeFilename(_ name: String) -> String {
        sanitize((name as NSString).deletingPathExtension)
    }

    /// Long Beatport-style names get an ellipsis so the log line stays one line.
    static func truncate(_ s: String, max: Int = 60) -> String {
        guard s.count > max else { return s }
        return String(s.prefix(max - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// "0856 - Artist - Title (Mix).mp3" -> (Artist, Title (Mix)); "01 - Title.mp3" -> (nil, Title);
    /// "NoSeparators.mp3" -> (nil, NoSeparators). Ambiguity yields nothing rather than a wrong guess.
    static func parseFilename(_ raw: String) -> (artist: String?, title: String?) {
        let s = sanitizeFilename(raw)
        guard !s.isEmpty else { return (nil, nil) }
        var parts = s.components(separatedBy: " - ")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if let first = parts.first, first.allSatisfy({ $0.isNumber }), parts.count > 1 {
            parts.removeFirst()
        }
        switch parts.count {
        case 0: return (nil, nil)
        case 1: return parts[0].allSatisfy({ $0.isNumber }) ? (nil, nil) : (nil, parts[0])
        default: return (parts[0], parts.dropFirst().joined(separator: " - "))
        }
    }

    /// First standalone 4-digit year (1950...next year); year RANGES (1998-2021) yield nil.
    static func extractYear(_ s: String) -> String? {
        if s.range(of: #"(19|20)\d{2}\s*[-–—/]\s*(19|20)\d{2}"#, options: .regularExpression) != nil {
            return nil
        }
        guard let m = s.range(of: #"(19|20)\d{2}"#, options: .regularExpression) else { return nil }
        let y = String(s[m])
        guard let year = Int(y) else { return nil }
        let current = Calendar.current.component(.year, from: Date())
        return (1950...(current + 1)).contains(year) ? y : nil
    }

    /// Album/year from the file's parent folder. A bare-year ("1998") or disc ("CD1")
    /// parent climbs one level for the album while carrying the year with it.
    /// Folders with no structure ("_loosie", "Downloads") yield nothing.
    static func parseFolder(forFile url: URL) -> (album: String?, year: String?) {
        var dir = url.deletingLastPathComponent()
        var carriedYear: String? = nil
        for _ in 0..<2 {
            let name = sanitize(dir.lastPathComponent)
            if isBareYear(name) {
                carriedYear = carriedYear ?? name
                dir = dir.deletingLastPathComponent()
                continue
            }
            if isDiscFolder(name) {
                dir = dir.deletingLastPathComponent()
                continue
            }
            return (albumFromFolder(name), extractYear(name) ?? carriedYear)
        }
        return (nil, carriedYear)
    }

    static func isBareYear(_ s: String) -> Bool {
        s.range(of: #"^(19|20)\d{2}$"#, options: .regularExpression) != nil
    }

    static func isDiscFolder(_ s: String) -> Bool {
        s.range(of: #"(?i)^(cd|disc|disk)\s*\d+$"#, options: .regularExpression) != nil
    }

    /// "VA - t_75d06cd224 Records (1998-2021)" -> "t_75d06cd224 Records"; "Artist - Album (2023)"
    /// -> "Album"; "Homework (2011)" -> "Homework"; "loosie" -> nil.
    static func albumFromFolder(_ raw: String) -> String? {
        let stripped = raw.replacingOccurrences(
            of: #"[\(\[][^\)\]]*(19|20)\d{2}[^\)\]]*[\)\]]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        let hadYearGroup = stripped != raw.trimmingCharacters(in: .whitespaces)
        let parts = stripped.components(separatedBy: " - ")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if parts.count >= 2, let last = parts.last { return last }
        if parts.count == 1, hadYearGroup { return parts[0] }
        return nil
    }
}

// MARK: - Aside schedule

/// LIVE schedule: fire when the cumulative scanned count crosses a
/// target of 2000 ± a random prime in 0...199 (re-rolled after every firing,
/// so it never lands on a round number). The target is PERSISTED in
/// UserDefaults, so the cadence holds across app launches — roughly one aside
/// per 2000 lifetime scans, never once per session. A single deep batch that
/// blows through several targets consumes them all but earns ONE aside, fired
/// at that session's completion (see AnalysisCoordinator).
enum AsideClock {
    static let primesThrough200: [Int] = [
        2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37, 41, 43, 47, 53, 59, 61, 67, 71, 73, 79,
        83, 89, 97, 101, 103, 107, 109, 113, 127, 131, 137, 139, 149, 151, 157, 163, 167,
        173, 179, 181, 191, 193, 197, 199,
    ]

    static let interval = 2000
    private static let targetKey = "asideNextTarget"

    /// Testing override: fire every Nth scanned file. nil = live schedule.
    static var debugEvery: Int? = nil

    private static var nextTarget: Int = loadTarget()

    private static func loadTarget() -> Int {
        let defaults = UserDefaults.standard
        if let t = defaults.object(forKey: targetKey) as? Int, t > 0 { return t }
        let t = firstTarget()
        defaults.set(t, forKey: targetKey)
        return t
    }

    static func firstTarget() -> Int { max(1, interval + randomOffset()) }

    static func randomOffset() -> Int {
        (primesThrough200.randomElement() ?? 97) * (Bool.random() ? 1 : -1)
    }

    /// Consume every crossing at/below `scanned`, advancing (and persisting)
    /// the schedule past them. Returns true when at least one target was
    /// crossed — the caller fires ONE aside for the session, at completion.
    static func consumeCrossings(scanned: Int) -> Bool {
        if let d = debugEvery { return d > 0 && scanned % d == 0 }
        guard scanned >= nextTarget else { return false }
        while scanned >= nextTarget {
            nextTarget = max(scanned + 1, nextTarget + interval + randomOffset())
        }
        UserDefaults.standard.set(nextTarget, forKey: targetKey)
        return true
    }

    /// Tests only.
    static func setNextTargetForTesting(_ t: Int) {
        nextTarget = t
        UserDefaults.standard.set(t, forKey: targetKey)
    }

    /// Tests only.
    static func nextTargetForTesting() -> Int { nextTarget }

    /// Tests only: re-run the persisted-target load (simulates a relaunch).
    static func reloadFromDefaultsForTesting() { nextTarget = loadTarget() }
}

// MARK: - Asides

enum Asides {
    static let tokens = ["filename", "artist", "title", "album", "year", "bpm"]

    /// Compiled-in pool, baked from Resources/asides.md (see AsidesBuiltin.swift).
    static let builtin = asidesBuiltin

    static func load(from url: URL) -> [String]? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.isEmpty ? nil : lines
    }

    static func requiredTokens(of aside: String) -> Set<String> {
        var found = Set<String>()
        for token in tokens where aside.contains("%\(token)%") { found.insert(token) }
        return found
    }

    /// Pick a aside whose variables are ALL known for this track, then substitute.
    static func random(context: AsideContext = AsideContext()) -> String {
        let eligible = builtin.filter { aside in
            requiredTokens(of: aside).allSatisfy { context.value(for: $0) != nil }
        }
        let aside = (eligible.isEmpty ? builtin : eligible).randomElement() ?? "nice track."
        return substitute(aside, context: context)
    }

    static func substitute(_ aside: String, context: AsideContext) -> String {
        var out = aside
        for token in tokens {
            if let value = context.value(for: token) {
                out = out.replacingOccurrences(of: "%\(token)%", with: value)
            }
        }
        return out
    }
}
