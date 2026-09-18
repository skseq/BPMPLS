import Foundation
import AppKit

// Shared services: per-session opt-in file logging with error snapshots,
// selectable stock-sound chimes (regular volume, mutable), cumulative stats,
// per-track timeout.

/// Single source of truth for the user-facing version string (About view,
/// footer, launch log). Keep in sync with Info.plist CFBundleShortVersionString.
enum BPMPLSVersion {
    static let current = "v0.8.906b"
}

enum AnalysisConfig {
    static let perTrackTimeout: Double = 60 // seconds; hung files get retried once, then skipped
}

enum AnalysisError: Error {
    case timeout
}

extension AnalysisError: LocalizedError {
    var errorDescription: String? {
        "analysis timed out (\(Int(AnalysisConfig.perTrackTimeout))s)"
    }
}

/// Races an operation against a clock; cancellation propagates into the operation.
func withTimeout<T: Sendable>(seconds: Double,
                              _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            try Task.checkCancellation()
            throw AnalysisError.timeout
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

// MARK: - Per-session verbose log + error snapshots (opt-in via Settings)

final class LogService: @unchecked Sendable {
    static let shared = LogService(directory: LogService.defaultDirectory)

    private static var defaultDirectory: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/BPMPLS", isDirectory: true)
    }

    private static var sessionStamp: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return f.string(from: Date())
    }

    let directory: URL
    let logURL: URL
    let errorLogURL: URL

    /// Tests only; nil = follow the "Enable logging" setting (default OFF).
    var enabledOverride: Bool?
    private var enabled: Bool {
        enabledOverride ?? UserDefaults.standard.bool(forKey: "loggingEnabled")
    }

    private let lock = NSLock()
    private let formatter: DateFormatter
    private let maxBytes: UInt64 = 5_000_000
    private let keepBytes: Int = 2_500_000

    // Error snapshot: ring of recent lines; an error dumps context around itself.
    private var ring: [String] = []
    private let ringCapacity = 200
    private let contextLines = 5
    private var teeRemaining = 0

    init(directory: URL, stamp: String? = nil) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
        let s = stamp ?? LogService.sessionStamp
        logURL = directory.appendingPathComponent("BPMPLS \(s).log")
        errorLogURL = directory.appendingPathComponent("BPMPLS-errors \(s).log")
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        formatter = f
        LogService.prune(directory: directory)
    }

    func log(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        let line = "[\(formatter.string(from: Date()))] \(message)"
        pushToRing(line)
        guard enabled else { return }
        append(line, to: logURL, trimming: true)
        if teeRemaining > 0 {
            append(line, to: errorLogURL, trimming: false)
            teeRemaining -= 1
            if teeRemaining == 0 {
                append("===== end of error snapshot =====", to: errorLogURL, trimming: false)
            }
        }
    }

    /// Error snapshot: 5 lines of context before the error, the error itself, then the
    /// next 5 lines — a self-contained block in the errors log.
    func error(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        let stamp = formatter.string(from: Date())
        let line = "[\(stamp)] ERROR \(message)"
        pushToRing(line)
        guard enabled else { return }
        var block = "\n===== ERROR SNAPSHOT @ \(stamp): \(message) =====\n"
        block += "--- \(min(contextLines, ring.count)) lines of context before ---\n"
        block += ring.suffix(contextLines).joined(separator: "\n")
        block += "\n>>> \(line)\n--- next \(contextLines) lines follow ---"
        append(block, to: errorLogURL, trimming: false)
        append(line, to: logURL, trimming: true)
        teeRemaining = contextLines
    }

    private func pushToRing(_ line: String) {
        ring.append(line)
        if ring.count > ringCapacity { ring.removeFirst(ring.count - ringCapacity) }
    }

    private func append(_ text: String, to url: URL, trimming: Bool) {
        if trimming { trimIfNeeded(url) }
        let data = Data((text + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }

    private func trimIfNeeded(_ url: URL) {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              UInt64(size) > maxBytes,
              let data = try? Data(contentsOf: url) else { return }
        let tail = data.suffix(keepBytes)
        try? Data("[log trimmed — kept last \(keepBytes) bytes]\n".utf8).write(to: url)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(tail)
            try? handle.close()
        }
    }

    /// Keeps only the newest `keep` session logs (main and errors groups separately).
    static func prune(directory: URL, keep: Int = 10) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.creationDateKey]) else { return }
        func created(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
        }
        for isErrors in [false, true] {
            let group = files
                .filter { $0.pathExtension == "log" && $0.lastPathComponent.contains("-errors") == isErrors }
                .sorted { created($0) > created($1) }
            for url in group.dropFirst(keep) { try? FileManager.default.removeItem(at: url) }
        }
    }

    func clearLogs() {
        lock.lock()
        defer { lock.unlock() }
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory,
                                                                       includingPropertiesForKeys: nil) else { return }
        for url in files where url.pathExtension == "log" {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Open Log: select this session's log if it exists, otherwise open the folder.
    func reveal() {
        if FileManager.default.fileExists(atPath: logURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([logURL])
        } else {
            revealFolder()
        }
    }

    func revealFolder() {
        NSWorkspace.shared.open(directory)
    }
}

// MARK: - Completion chime (ad-hoc DIY: stock sound, NOT a trackable notification)

enum SoundService {
    private static var current: NSSound?

    /// Stock sounds present in /System/Library/Sounds on modern macOS.
    static let stockSounds = ["Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero",
                              "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink"]

    /// Plays the user's chosen sound at regular system volume (Settings):
    /// completionSound for a clean batch, errorSound when the batch had errors.
    /// "None" or the Mute checkbox = silent.
    static func playCompletion(errors: Bool) {
        guard !UserDefaults.standard.bool(forKey: "muteSounds") else {
            LogService.shared.log("chime skipped (muted)")
            return
        }
        let key = errors ? "errorSound" : "completionSound"
        let name = UserDefaults.standard.string(forKey: key) ?? (errors ? "Tink" : "Glass")
        guard name != "None", let sound = NSSound(named: NSSound.Name(name)) else { return }
        sound.volume = 1.0
        current = sound // keep alive while playing
        sound.play()
        LogService.shared.log("chime played: \(name)")
    }

    /// Settings preview — always plays (explicit user action).
    static func preview(_ name: String) {
        guard name != "None", let sound = NSSound(named: NSSound.Name(name)) else { return }
        sound.volume = 1.0
        current = sound
        sound.play()
    }
}

// MARK: - Cumulative stats

enum Stats {
    private static let key = "totalTracksScanned"

    static var totalScanned: Int {
        UserDefaults.standard.integer(forKey: key)
    }

    /// Every track that finished processing (done OR error) counts as scanned.
    static func addScanned(_ n: Int) {
        UserDefaults.standard.set(totalScanned + n, forKey: key)
    }
}
