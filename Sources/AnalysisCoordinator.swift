import Foundation
import SwiftUI

// Component 5: Swift Concurrency orchestration.
// @MainActor owns ALL UI-state mutations; DSP/tag work hops off the main actor inside
// task-group child tasks. Concurrency is capped at activeProcessorCount - 1.
// Two-pass design: the first pass analyzes every track and updates the table in
// real time; the second pass applies the folder-affinity prior, overrides any
// flipped verdicts, and dispatches the tag writes (in a background task so the
// completion chime never waits on file I/O — see the write task below).

struct UIMessage: Identifiable, Equatable {
    enum Kind: Equatable { case info, warn, error, success, multiTempo, aside }
    let id = UUID()
    let text: String
    let kind: Kind
}

@MainActor
final class AnalysisCoordinator: ObservableObject {
    /// The most recently created coordinator, so the app delegate can flush
    /// pending tag writes on quit. Weak: the view owns the coordinator.
    @MainActor static weak var active: AnalysisCoordinator?

    @Published var messages: [UIMessage] = []
    @Published private(set) var isRunning = false
    private var batchTask: Task<Void, Never>?
    /// Background tag-write task for the current/last batch. Held so app
    /// termination can wait for it instead of silently dropping writes.
    private var writeTask: Task<Void, Never>?
    /// Increments on every analyze()/cancel() call. A stale batch task
    /// compares its captured generation against the current one and skips
    /// its UI cleanup if a newer batch has taken over.
    private var batchGeneration = 0

    init() {
        AnalysisCoordinator.active = self
    }

    func post(_ text: String, _ kind: UIMessage.Kind = .info) {
        messages.append(UIMessage(text: text, kind: kind))
        if messages.count > 200 { messages.removeFirst(messages.count - 200) }
    }

    func cancel() {
        batchGeneration += 1
        batchTask?.cancel()
        batchTask = nil
    }

    /// True while the background tag-write task is in flight (quit-flush gate).
    var hasPendingWrites: Bool { writeTask != nil }

    /// Wait (up to `timeout` seconds) for the background tag-write task to
    /// finish. Called by the app delegate during quit so pending writes are
    /// not silently lost. Safe to call with nothing pending.
    func flushPendingWrites(timeout: Double) async {
        guard let task = writeTask else { return }
        _ = await withTaskGroup(of: Void.self) { group in
            group.addTask { await task.value }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            }
            await group.next()
            group.cancelAll()
        }
        writeTask = nil
    }

    /// Retry the errored tracks. Tag-write failures retry only the write
    /// (the analysis verdict is still good); analysis failures re-analyze.
    func retry(tracks: Binding<[AudioTrack]>, minBPM: Double, maxBPM: Double,
               batchProgress: Binding<Double>, service: MetadataServiceProtocol,
               errorIDs: Set<UUID>) {
        let writeFailed = tracks.wrappedValue.filter {
            errorIDs.contains($0.id) && $0.errorInfo?.hasPrefix("tag write failed") == true
        }
        let analysisIDs = Set(errorIDs.subtracting(writeFailed.map { $0.id }))
        if !analysisIDs.isEmpty {
            analyze(tracks: tracks, minBPM: minBPM, maxBPM: maxBPM,
                    batchProgress: batchProgress, service: service, only: analysisIDs)
        }
        guard !writeFailed.isEmpty else { return }
        post("Retrying \(writeFailed.count) tag write\(writeFailed.count == 1 ? "" : "s")…")
        LogService.shared.log("=== retry: \(writeFailed.count) tag write(s) ===")
        Task.detached(priority: .userInitiated) { [weak self] in
            var fixed = 0
            for track in writeFailed {
                guard let bpm = track.calculatedBPM else { continue }
                do {
                    try service.writeBPM(url: track.url, bpm: bpm)
                    fixed += 1
                    LogService.shared.log("  retry write OK '\(track.filename)'")
                    let id = track.id
                    await MainActor.run {
                        if let idx = tracks.wrappedValue.firstIndex(where: { $0.id == id }) {
                            tracks.wrappedValue[idx].analysisState = .done
                            tracks.wrappedValue[idx].errorInfo = nil
                        }
                    }
                } catch {
                    LogService.shared.log("  retry write FAILED '\(track.filename)': \(error.localizedDescription)")
                    let id = track.id
                    let msg = "tag write failed: \(error.localizedDescription)"
                    await MainActor.run {
                        if let idx = tracks.wrappedValue.firstIndex(where: { $0.id == id }) {
                            tracks.wrappedValue[idx].errorInfo = msg
                        }
                    }
                }
            }
            if let self = self {
                let n = fixed
                let total = writeFailed.count
                await MainActor.run {
                    self.post(n == total
                              ? "✓ \(n) tag\(n == 1 ? "" : "s") re-written"
                              : "⚠ \(n)/\(total) re-writes succeeded (see log)",
                              n == total ? .success : .warn)
                }
            }
        }
    }

    /// Pass `only` to analyze just a subset (e.g. retry of errored tracks).
    func analyze(tracks: Binding<[AudioTrack]>, minBPM: Double, maxBPM: Double,
                 batchProgress: Binding<Double>, service: MetadataServiceProtocol,
                 only: Set<UUID>? = nil) {
        cancel()
        batchGeneration += 1
        let generation = batchGeneration
        let items = tracks.wrappedValue.compactMap { track -> (id: UUID, url: URL, name: String)? in
            if let only, !only.contains(track.id) { return nil }
            return (track.id, track.url, track.filename)
        }
        let total = items.count
        guard total > 0 else { return }
        let cap = max(1, ProcessInfo.processInfo.activeProcessorCount - 1)
        batchProgress.wrappedValue = 0.0
        let itemIDs = Set(items.map { $0.id })
        for idx in tracks.wrappedValue.indices where itemIDs.contains(tracks.wrappedValue[idx].id) {
            // A/B evidence: remember the value we're about to supersede (tag or prior run).
            if let current = tracks.wrappedValue[idx].calculatedBPM {
                tracks.wrappedValue[idx].previousBPM = current
            }
            tracks.wrappedValue[idx].analysisState = .analyzing
            tracks.wrappedValue[idx].errorInfo = nil
        }
        isRunning = true
        let isRetry = only != nil
        LogService.shared.log("=== batch start: \(total) tracks\(isRetry ? " (retry of errors)" : ""), range \(Int(minBPM))–\(Int(maxBPM)) BPM, concurrency \(cap) ===")
        post("\(isRetry ? "Retrying" : "Analyzing") \(total) tracks · range \(Int(minBPM))–\(Int(maxBPM)) BPM")

        batchTask = Task {
            let batchStart = Date()
            var okCount = 0
            var errCount = 0
            // Index map for the per-completion row lookups below — a linear
            // firstIndex(where:) per completed track is O(n²) on
            // thousand-file batches. Falls back to a scan when the map goes
            // stale (tracks appended/removed mid-batch).
            var indexByID: [UUID: Int] = [:]
            func rowIndex(for id: UUID) -> Int? {
                if let i = indexByID[id] {
                    guard i < tracks.wrappedValue.count, tracks.wrappedValue[i].id == id else {
                        return tracks.wrappedValue.firstIndex(where: { $0.id == id })
                    }
                    return i
                }
                let i = tracks.wrappedValue.firstIndex(where: { $0.id == id })
                if let i { indexByID[id] = i }
                return i
            }
            // Cache first-pass BPMAnalysis per item so the folder-affinity
            // prior can apply after the whole batch is analyzed. Each child
            // task returns its raw analysis (no writeBPM yet); the
            // coordinator decides verdicts + writes after the affinity pass.
            var firstPass: [(id: UUID, url: URL, name: String, analysis: BPMAnalysis)] = []
            await withThrowingTaskGroup(of: (UUID, String, Result<BPMAnalysis, Error>).self) { group in
                var submitted = 0
                var completed = 0
                while completed < total {
                    if Task.isCancelled { break }
                    // Only add a child task while below the concurrency cap.
                    while submitted < total && submitted - completed < cap {
                        let item = items[submitted]
                        submitted += 1
                        group.addTask {
                            do {
                                try Task.checkCancellation()
                                let t0 = Date()
                                LogService.shared.log("START '\(item.name)'")
                                let analysis = try await Self.analyzeWithRetry(url: item.url, name: item.name,
                                                                               minBPM: minBPM, maxBPM: maxBPM)
                                let dt = String(format: "%.2f", Date().timeIntervalSince(t0))
                                LogService.shared.log("DONE  '\(item.name)' -> \(Int(analysis.bpm)) BPM (raw, \(dt)s)")
                                return (item.id, item.name, .success(analysis))
                            } catch {
                                if error is CancellationError || Task.isCancelled { throw error }
                                return (item.id, item.name, .failure(error))
                            }
                        }
                    }
                    do {
                        guard let (id, name, result) = try await group.next() else { break }
                        completed += 1
                        Stats.addScanned(1) // done or error: the track was scanned
                        switch result {
                        case .success(let analysis):
                            // Cache for the second pass (folder affinity) and
                            // update the table in real time as DSP completes.
                            // The folder-affinity prior (second pass) only ever
                            // OVERRIDES the verdict for a ×4/3 or ×3/2 flip, so
                            // the provisional verdict is honest.
                            if let url = items.first(where: { $0.id == id })?.url {
                                firstPass.append((id, url, name, analysis))
                            }
                            if let idx = rowIndex(for: id) {
                                let provisionalClean = Double(BPMEngine.roundedBPM(analysis.bpm))
                                tracks.wrappedValue[idx].calculatedBPM = provisionalClean
                                tracks.wrappedValue[idx].analysisState = .done
                                tracks.wrappedValue[idx].errorInfo = nil
                                tracks.wrappedValue[idx].confidence = analysis.confidence
                                tracks.wrappedValue[idx].noBeatFound = analysis.noBeatFound
                                okCount += 1  // count successful first-pass analyses
                                // Per-track findings (not folder-context findings) fire here.
                                let tempoNote = BPMEngine.multiTempoNote(analysis.segments, tagged: Int(provisionalClean))
                                if let note = tempoNote {
                                    LogService.shared.log("  \(note)")
                                    post("≈ \(name): \(note)", .multiTempo)
                                }
                                if analysis.noBeatFound {
                                    post("◇ \(name): no beat found", .info)
                                }
                            }
                        case .failure(let error):
                            if error is CancellationError || Task.isCancelled { break }
                            errCount += 1
                            if let idx = rowIndex(for: id) {
                                tracks.wrappedValue[idx].analysisState = .error
                                tracks.wrappedValue[idx].errorInfo = error.localizedDescription
                                post("✗ \(name): \(error.localizedDescription)", .error)
                            }
                        }
                        batchProgress.wrappedValue = Double(completed) / Double(total) * 0.9
                    } catch {
                        break // group threw (cancellation propagates from children)
                    }
                }
                group.cancelAll()
            }

            // ─── Second pass — folder-affinity prior ───
            // Build the folder context from first-pass results, then for each
            // cached analysis apply BPMEngine.applyFolderAffinity. A flipped
            // verdict wins over the raw verdict. writeBPM happens here too
            // (so we don't write a value we're about to override).
            let firstPassSummary: [(url: URL, bpm: Double, confidence: Double, bandPeaks: [[(bpm: Double, frac: Float)]])] = firstPass.map {
                ($0.url, $0.analysis.bpm, $0.analysis.confidence, $0.analysis.bandPeaksRaw)
            }
            let folderAffinity = FolderAffinity.build(from: firstPassSummary)
            var folderFlips: [String] = [] // log lines for the batch summary

            // Collect (url, name, final-bpm, noBeatFound) tuples here and
            // dispatch the file writes to a detached task. Running the writes
            // inline would synchronously block the main batch task on file
            // I/O — for a 173-file drop on an external drive that's ~45s of
            // beachball AFTER all analysis was done, before "batch complete"
            // + chime fire. The detached task does the I/O in the background
            // and the UI stays responsive.
            var pendingWrites: [(id: UUID, name: String, url: URL, bpm: Double, noBeatFound: Bool)] = []

            for entry in firstPass {
                var verdict = entry.analysis.bpm
                var folderFlipped = false
                if let anchor = folderAffinity.anchor(for: entry.url),
                   anchor.sourceURL != entry.url {
                    let result = BPMEngine.applyFolderAffinity(
                        verdict: verdict,
                        bandPeaks: entry.analysis.bandPeaksRaw,
                        anchor: anchor
                    )
                    if result.flipped {
                        verdict = result.bpm
                        folderFlipped = true
                        folderFlips.append("\(entry.name): \(Int(entry.analysis.bpm))→\(Int(result.bpm))")
                        LogService.shared.log("  FOLDER '\(entry.name)': \(Int(entry.analysis.bpm))→\(Int(result.bpm)) BPM (\(result.reason))")
                    }
                }
                // If folder affinity flipped the verdict, update the
                // provisional UI write so the table re-renders the cell with
                // the corrected value — a structural override, not a re-run
                // of DSP.
                if folderFlipped, let idx = tracks.wrappedValue.firstIndex(where: { $0.id == entry.id }) {
                    let flippedClean = Double(BPMEngine.roundedBPM(verdict))
                    tracks.wrappedValue[idx].calculatedBPM = flippedClean
                }
                let clean = Double(BPMEngine.roundedBPM(verdict))
                pendingWrites.append((id: entry.id, name: entry.name, url: entry.url, bpm: clean, noBeatFound: entry.analysis.noBeatFound))
            }
            // Consume any schedule crossings now (the counter already
            // includes this batch), but hold the aside until natural
            // batch completion — it fires as the console's closing line so a
            // fast deep scan can't scroll it past.
            let asideEarned = AsideClock.consumeCrossings(scanned: Stats.totalScanned)
            // Kick off the background tag-write task. The batch marks
            // "complete" and plays the chime WITHOUT waiting for this to
            // finish — the UI gets responsive immediately.
            //
            // Tag-write gating: the noBeatFound flag is a diagnostic (UI
            // shows a gray "no beat" badge) but is NOT a hard block on
            // writing the tag. If the engine's final verdict is in 70-180,
            // we trust the verdict and write the tag — even if
            // detectAmbient() flagged the track. This fixes the Bunny
            // t_ea734c5da5 "t_3522c21bc9" case (noBeatFound=true but verdict=114 via
            // a ×4/3 fold from 152: the bandPeaks tops are outside 70-180 at
            // 184.6/234.9, but the verdict is in range and the user's ear
            // confirmed 114). Without this override, the noBeatFound flag
            // would silently skip the write and leave the user's
            // pre-existing (often wrong) tag in place.
            if !pendingWrites.isEmpty {
                let writes = pendingWrites
                writeTask = Task.detached(priority: .background) { [weak self] in
                    var written = 0
                    var failed = 0
                    var ambientSkipped = 0
                    var ambientButVerdictInRange = 0
                    var failureLines: [String] = []
                    func handleWriteFailure(_ w: (id: UUID, name: String, url: URL, bpm: Double, noBeatFound: Bool), _ error: Error) async {
                        failed += 1
                        let line = "\(w.name): tag write failed — \(error.localizedDescription)"
                        failureLines.append(line)
                        LogService.shared.log("  WRITE FAILED '\(w.name)': \(error.localizedDescription)")
                        // Surface on the row (and thus in Retry Errors) + console.
                        if let self = self {
                            let id = w.id
                            await MainActor.run {
                                if let idx = tracks.wrappedValue.firstIndex(where: { $0.id == id }) {
                                    tracks.wrappedValue[idx].analysisState = .error
                                    tracks.wrappedValue[idx].errorInfo = "tag write failed: \(error.localizedDescription)"
                                }
                                self.post("✗ \(line)", .error)
                            }
                        }
                    }
                    for w in writes {
                        if w.noBeatFound, w.bpm >= 70, w.bpm <= 180 {
                            // Trust the verdict even when the ambient
                            // heuristic fired. The ambient badge still shows
                            // in the UI (noBeatFound flag on the analysis
                            // object), but the tag gets the engine's decision.
                            do {
                                try service.writeBPM(url: w.url, bpm: w.bpm)
                                LogService.shared.log("  AMBIENT-but-verdict-in-range '\(w.name)': verdict=\(Int(w.bpm)) BPM, tag written (t_3522c21bc9 case)")
                                ambientButVerdictInRange += 1
                            } catch { await handleWriteFailure(w, error) }
                        } else if w.noBeatFound {
                            // Ambient outside the musical range: no tag write.
                            LogService.shared.log("  AMBIENT '\(w.name)': no beat found, tag write skipped (verdict outside 70-180)")
                            ambientSkipped += 1
                        } else {
                            do {
                                try service.writeBPM(url: w.url, bpm: w.bpm)
                                written += 1
                            } catch { await handleWriteFailure(w, error) }
                        }
                    }
                    LogService.shared.log("=== tag writes complete: \(written) written, \(failed) failed, \(ambientSkipped) skipped, \(ambientButVerdictInRange) ambient-but-verdict-in-range ===")
                    let landed = written + ambientButVerdictInRange
                    if failed > 0, let self = self {
                        let failedCount = failed
                        await MainActor.run {
                            self.post("⚠ \(failedCount) tag write\(failedCount == 1 ? "" : "s") failed — see error tray", .warn)
                        }
                    } else if landed > 0, let self = self {
                        await MainActor.run {
                            self.post("✓ \(landed) tag\(landed == 1 ? "" : "s") written", .success)
                        }
                    }
                    if let self = self {
                        await MainActor.run { self.writeTask = nil }
                    }
                }
            }
            // v0.8.903: post a single summary line if any folder flips fired.
            if !folderFlips.isEmpty {
                let summary = "Folder affinity: \(folderFlips.count) flip\(folderFlips.count == 1 ? "" : "s") (\(folderFlips.joined(separator: ", ")))"
                LogService.shared.log("=== \(summary) ===")
                post(summary, .info)
            }

            // A newer batch (or a cancel + new analyze) took over while this
            // task was finishing — its cleanup would clobber the new batch's
            // state (isRunning, .analyzing rows), so stop here.
            guard generation == batchGeneration else { return }
            batchProgress.wrappedValue = 1.0
            // After cancellation, anything left mid-flight returns to pending.
            var cancelledCount = 0
            for idx in tracks.wrappedValue.indices where tracks.wrappedValue[idx].analysisState == .analyzing {
                tracks.wrappedValue[idx].analysisState = .pending
                cancelledCount += 1
            }
            let dt = String(format: "%.1f", Date().timeIntervalSince(batchStart))
            if Task.isCancelled {
                LogService.shared.log("=== batch cancelled: \(okCount) ok, \(errCount) errors, \(cancelledCount) aborted (\(dt)s) ===")
                post("Cancelled — \(okCount) kept, \(cancelledCount) back to pending", .warn)
            } else {
                LogService.shared.log("=== batch complete: \(okCount) ok, \(errCount) errors (\(dt)s) ===")
                post(errCount == 0
                     ? "✓ Done — \(okCount) analyzed in \(dt)s\(asideEarned || !pendingWrites.isEmpty ? " · writing tags…" : "")"
                     : "✓ Done — \(okCount) analyzed · \(errCount) error\(errCount == 1 ? "" : "s") in \(dt)s (see error tray / log)",
                     errCount == 0 ? .success : .warn)
                SoundService.playCompletion(errors: errCount > 0)
                // A beat after the chime, one aside from a random track in
                // the batch types on as the console's last line. Cancelled
                // batches spend their crossing silently — the aside belongs
                // to a FINISHED session.
                if asideEarned, let pick = firstPass.randomElement() {
                    let name = pick.name
                    let trackURL = pick.url
                    let bpmString: String? = pick.analysis.noBeatFound ? nil : String(BPMEngine.roundedBPM(pick.analysis.bpm))
                    Task.detached { [weak self] in
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        let ctx = AsideContext.gather(url: trackURL, filename: name,
                                                     bpm: bpmString, service: service)
                        let line = "\(name): \(Asides.random(context: ctx))"
                        LogService.shared.log(line)
                        // If a new batch took over during the beat, skip the
                        // console cameo — never a mid-batch aside.
                        await MainActor.run { [weak self] in
                            guard let self, generation == self.batchGeneration else { return }
                            self.post("✳ \(line)", .aside)
                        }
                    }
                }
            }
            isRunning = false
        }
    }

    /// One analysis attempt, then exactly one retry, then give up (move on to next track).
    nonisolated private static func analyzeWithRetry(url: URL, name: String,
                                                     minBPM: Double, maxBPM: Double) async throws -> BPMAnalysis {
        do {
            return try await withTimeout(seconds: AnalysisConfig.perTrackTimeout) {
                try await BPMEngine.analyzeDetailed(url: url, minBPM: minBPM, maxBPM: maxBPM)
            }
        } catch {
            if error is CancellationError || Task.isCancelled { throw error }
            LogService.shared.log("WARN  '\(name)': \(error.localizedDescription) — retrying once")
            try await Task.sleep(nanoseconds: 300_000_000)
            do {
                return try await withTimeout(seconds: AnalysisConfig.perTrackTimeout) {
                    try await BPMEngine.analyzeDetailed(url: url, minBPM: minBPM, maxBPM: maxBPM)
                }
            } catch {
                if error is CancellationError || Task.isCancelled { throw error }
                LogService.shared.error("'\(name)': \(error.localizedDescription) — skipped after retry")
                throw error
            }
        }
    }
}
