import SwiftUI
import AppKit
import UniformTypeIdentifiers

// Component 1: UI & state. Owns the queue table, the dual-thumb BPM range
// slider, the resizable log/error trays, the off-main ingest pipeline, and the
// optimistic Clear-BPMs flow. Analysis itself is delegated to
// AnalysisCoordinator; the view never touches the engine directly.

private let audioExtensions: Set<String> = ["mp3", "flac"]

/// App-wide theme colors (referenced from BPMPLSApp and the controls).
enum Theme {
    /// Success / completion color (also the aside line's color).
    static let mint = Color(red: 0.42, green: 0.87, blue: 0.68)
    /// Multi-tempo console notes — a shade darker in light mode so it stays legible.
    static let multiTempoBlue = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.45, green: 0.76, blue: 1.0, alpha: 1)
            : NSColor(srgbRed: 0.05, green: 0.50, blue: 0.88, alpha: 1)
    })
}

struct AudioTrack: Identifiable, Equatable, Sendable {
    enum AnalysisState: Equatable {
        case pending, analyzing, done, error
    }
    let id: UUID
    let url: URL
    let filename: String
    var calculatedBPM: Double?
    var analysisState: AnalysisState
    var errorInfo: String? = nil
    var previousBPM: Double? = nil
    /// Engine confidence score in [0,1]. Set on successful analysis; never
    /// overrides the verdict — displayed as a colored badge next to the BPM.
    var confidence: Double? = nil
    /// True when the engine detected an ambient/no-beat track. Surfaced as a
    /// gray "no beat" badge in the UI; the write gate may still write the tag.
    var noBeatFound: Bool = false
}

/// Bridge between the App-scope menu commands and the main window's actions
/// (the canonical FocusedValue pattern for SwiftUI menus).
@MainActor
final class AppActions: ObservableObject {
    @Published var canAnalyze = false
    @Published var canRetryErrors = false
    @Published var canShowDiscrepancies = false
    @Published var hasQueue = false
    @Published var selectedURL: URL?
    var openPanel: () -> Void = {}
    var revealSelection: () -> Void = {}
    var analyze: () -> Void = {}
    var retryErrors: () -> Void = {}
    var clearQueue: () -> Void = {}
    var clearBPMs: () -> Void = {}
    var toggleDiscrepancies: () -> Void = {}
}

/// Tiny non-actor bridge so menu commands can key their `disabled` state off
/// the main window's AppActions without capturing the observable object
/// directly in the scene body (which would re-evaluate the whole scene on
/// every change). The main window keeps the authoritative AppActions.
@MainActor
enum AppCommandsBridge {
    static weak var current: AppActions?
}

struct AppActionsFocusedKey: FocusedValueKey {
    typealias Value = AppActions
}

extension FocusedValues {
    var appActions: AppActions? {
        get { self[AppActionsFocusedKey.self] }
        set { self[AppActionsFocusedKey.self] = newValue }
    }
}

struct BPMCalculatorView: View {
    @State private var tracks: [AudioTrack] = []
    @State private var minVal: Double = 70
    @State private var maxVal: Double = 180
    @State private var batchProgress: Double = 0.0
    @State private var errorTrayHeight: CGFloat = 150
    @State private var trayDismissed = false
    @State private var consoleHeight: CGFloat = 130
    /// Discrepancies-only filter (⌘D): the main table shows only rows whose
    /// verdict differs from the original tag by > 5 BPM — the things worth
    /// reviewing after a scan.
    @State private var discrepanciesOnly = false
    @State private var selectedTrackID: AudioTrack.ID? = nil
    /// Tag-read progress (read/total) while the ingest prefill reads existing
    /// tags in batches of 100; nil when not pre-filling.
    @State private var tagReadProgress: (read: Int, total: Int)? = nil
    // Live-drag state for the divider drags: the visual position updates on
    // every mouse-move tick; the layout-driving heights commit on .onEnded.
    // The ghost-overlay divider drawn at the cursor's projected position
    // keeps the real layout (and the table) from reflowing during the drag.
    @State private var liveConsoleDrag: CGFloat = 0
    @State private var liveErrorTrayDrag: CGFloat = 0
    @State private var draggingConsole: Bool = false
    @State private var draggingErrorTray: Bool = false
    @State private var isIngesting = false
    @State private var isDropTargeted = false
    @StateObject private var coordinator = AnalysisCoordinator()
    @StateObject private var actions = AppActions()

    private let service: MetadataServiceProtocol = NativeMetadataService()

    static func confidenceColor(_ score: Double) -> Color {
        if score >= BPMEngine.confidenceHighThreshold { return Theme.mint }
        if score >= BPMEngine.confidenceLowThreshold { return .orange }
        return .secondary
    }

    var body: some View {
        decorated(windowLayout)
    }

    private var windowLayout: some View {
        GeometryReader { geo in
            // Row-level derivatives computed ONCE per body evaluation (the
            // per-render filter scans were O(n²) over a big batch).
            let errorTracks: [AudioTrack] = tracks.filter { $0.analysisState == .error }
            let hasDiscrepancies: Bool = tracks.contains { track in
                guard track.analysisState == .done,
                      let verdict = track.calculatedBPM,
                      let prev = track.previousBPM else { return false }
                return abs(BPMEngine.roundedBPM(verdict) - BPMEngine.roundedBPM(prev)) > 5
            }
            let finishedStates: Set<AudioTrack.AnalysisState> = [.done, .error]
            let completedCount: Int = tracks.filter { finishedStates.contains($0.analysisState) }.count
            mainStack(windowHeight: geo.size.height,
                      errorTracks: errorTracks,
                      completedCount: completedCount,
                      hasDiscrepancies: hasDiscrepancies)
        }
    }

    private func decorated(_ content: some View) -> some View {
        trackingDecorations(
            appearanceDecorations(
                content.frame(minWidth: 720, minHeight: 480)
            )
        )
    }

    private func appearanceDecorations(_ content: some View) -> some View {
        content
            .focusedSceneValue(\.appActions, actions)
            .onAppear {
                AppCommandsBridge.current = actions
                actions.openPanel = openPanel
                actions.analyze = analyze
                actions.retryErrors = retryErrors
                actions.clearQueue = clearQueue
                actions.clearBPMs = clearBPMs
                actions.revealSelection = {
                    if let id = selectedTrackID, let track = tracks.first(where: { $0.id == id }) {
                        NSWorkspace.shared.activateFileViewerSelecting([track.url])
                    }
                }
                actions.toggleDiscrepancies = { discrepanciesOnly.toggle() }
            }
    }

    private func trackingDecorations(_ content: some View) -> some View {
        content
            .onChange(of: tracks) { _, newTracks in
                actions.canAnalyze = !newTracks.isEmpty && !coordinator.isRunning
                actions.hasQueue = !newTracks.isEmpty
                actions.canRetryErrors = newTracks.contains { $0.analysisState == .error }
                actions.canShowDiscrepancies = newTracks.contains { track in
                    guard track.analysisState == .done,
                          let verdict = track.calculatedBPM,
                          let prev = track.previousBPM else { return false }
                    return abs(BPMEngine.roundedBPM(verdict) - BPMEngine.roundedBPM(prev)) > 5
                }
                if !actions.canShowDiscrepancies && discrepanciesOnly {
                    discrepanciesOnly = false
                }
            }
            .onChange(of: coordinator.isRunning) { _, running in
                actions.canAnalyze = !tracks.isEmpty && !running
            }
            .onChange(of: selectedTrackID) { _, id in
                actions.selectedURL = tracks.first { $0.id == id }?.url
            }
            .onChange(of: discrepanciesOnly) { _, _ in
                selectedTrackID = nil
            }
    }

    private func mainStack(windowHeight: CGFloat, errorTracks: [AudioTrack], completedCount: Int,
                           hasDiscrepancies: Bool) -> some View {
        VStack(spacing: 0) {
            controlBar(errorCount: errorTracks.count, hasDiscrepancies: hasDiscrepancies)
            Divider()
            middleArea(boundsHeight: windowHeight, errorTracks: errorTracks)
            ResizableDivider(visualHeight: 6, hitPadding: 7,
                             minHeight: 64, maxFraction: 0.3,
                             totalHeight: windowHeight,
                             committedHeight: $consoleHeight,
                             liveDelta: $liveConsoleDrag,
                             isDragging: $draggingConsole,
                             helpText: "Drag to resize the log console (up to 30% of the window)",
                             a11yLabel: "Resize log console")
            statusArea(completedCount: completedCount)
                .frame(height: consoleHeight)
        }
    }

    // MARK: - Control bar

    private func controlBar(errorCount: Int, hasDiscrepancies: Bool) -> some View {
        HStack(spacing: 10) {
            Button { analyze() } label: { Label("Analyze", systemImage: "bolt.fill") }
                .buttonStyle(.bordered)
                .tint(Theme.mint)
                .help("Analyze queue")
                .disabled(tracks.isEmpty || coordinator.isRunning)
            Button { clearQueue() } label: { Label("Clear Queue", systemImage: "trash") }
                .buttonStyle(.bordered)
                .help("Clear queue (cancels running analysis)")
                .disabled(tracks.isEmpty)
            // Appears only once a scan has produced a discrepancy, and
            // disappears again when the queue no longer has one.
            if hasDiscrepancies {
                Toggle("Discrepancies", isOn: $discrepanciesOnly)
                    .toggleStyle(.button)
                    .controlSize(.small)
                    .help("Show only tracks where the engine verdict differs from the original tag by more than 5 BPM")
            }
            Spacer()
            DualRangeSlider(lower: $minVal, upper: $maxVal, lowerBound: 50, upperBound: 200)
                .frame(width: 170)
            Button { clearBPMs() } label: { Image(systemName: "tag.slash") }
                .buttonStyle(.borderless)
                .help("Clear BPM tags from all files (other tags untouched)")
                .accessibilityLabel("Clear BPM tags")
                .disabled(tracks.isEmpty || coordinator.isRunning)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Middle: queue panel + error tray (appears only when errors exist)

    private func middleArea(boundsHeight: CGFloat, errorTracks: [AudioTrack]) -> some View {
        GeometryReader { geo in
            let showTray = !errorTracks.isEmpty && !trayDismissed
            let dividerH: CGFloat = showTray ? 20 : 0
            let available = max(0, geo.size.height - dividerH)
            let trayH = showTray ? errorTrayHeight : 0
            ZStack(alignment: .top) {
                VStack(spacing: 0) {
                    dropArea
                        .frame(height: max(0, available - trayH))
                    if showTray {
                        ResizableDivider(visualHeight: 8, hitPadding: 6,
                                         minHeight: 80, maxFraction: 0.5,
                                         totalHeight: available,
                                         committedHeight: $errorTrayHeight,
                                         liveDelta: $liveErrorTrayDrag,
                                         isDragging: $draggingErrorTray,
                                         helpText: "Drag to resize error tray",
                                         a11yLabel: "Resize error tray")
                            .frame(height: dividerH)
                        errorTray(errorTracks: errorTracks)
                            .frame(height: trayH)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.easeInOut(duration: 0.25), value: errorTracks.isEmpty)
                // Ghost overlay during a divider drag: the real layout above
                // stays committed; the ghost slides with the cursor and the
                // table doesn't reflow until release.
                if draggingConsole || draggingErrorTray {
                    Rectangle()
                        .fill(Theme.mint.opacity(0.45))
                        .frame(height: 6)
                        .offset(y: ghostYOffset(boundsHeight: geo.size.height,
                                                trayDividerTop: available - trayH))
                        .allowsHitTesting(false)
                }
            }
        }
        .onChange(of: errorTracks.isEmpty) { _, isEmpty in
            if !isEmpty { trayDismissed = false } // new errors re-open the tray
        }
    }

    /// Where the ghost divider should sit: the divider's committed top-edge
    /// MINUS the live drag magnitude — an up-drag moves the ghost UP,
    /// tracking the cursor one-to-one.
    private func ghostYOffset(boundsHeight: CGFloat, trayDividerTop: CGFloat) -> CGFloat {
        if draggingConsole {
            return boundsHeight - 6 - liveConsoleDrag
        } else if draggingErrorTray {
            return trayDividerTop - liveErrorTrayDrag
        }
        return 0
    }

    private func errorTray(errorTracks: [AudioTrack]) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Errors (\(errorTracks.count))")
                    .font(.callout).bold()
                Spacer()
                Button { retryErrors() } label: { Label("Retry Errors", systemImage: "arrow.clockwise") }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(coordinator.isRunning)
                    .help("Re-run the errored tracks (write failures retry the write, not the analysis)")
                Button { trayDismissed = true } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Hide error tray (re-opens on the next error)")
                    .accessibilityLabel("Hide error tray")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(errorTracks) { track in
                        RevealRow(filename: track.filename, subtitle: track.errorInfo ?? "unknown error",
                                  url: track.url, tint: .red, icon: "xmark.octagon")
                    }
                }
            }
        }
        .background(Color.red.opacity(0.04))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Errors, \(errorTracks.count) items")
    }

    // MARK: - Drop zone / table / ingest progress

    private var dropArea: some View {
        ZStack {
            if isIngesting {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Scanning folder…")
                        .foregroundStyle(.secondary)
                }
            } else if tracks.isEmpty {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                    .foregroundStyle(.tertiary)
                    .padding(14)
                Text("Drop audio files or folders — or choose File ▸ Open (⌘O)")
                    .foregroundStyle(.secondary)
            } else {
                table
                    .padding(8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            // Standard drag-over feedback for a valid drop target.
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Theme.mint.opacity(0.8), lineWidth: 2)
                    .padding(4)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted, perform: handleDrop)
    }

    private var displayedTracks: [AudioTrack] {
        guard discrepanciesOnly else { return tracks }
        return tracks.filter { track in
            guard track.analysisState == .done,
                  let verdict = track.calculatedBPM,
                  let prev = track.previousBPM else { return false }
            return abs(BPMEngine.roundedBPM(verdict) - BPMEngine.roundedBPM(prev)) > 5
        }
    }

    private var table: some View {
        Table(displayedTracks, selection: $selectedTrackID) {
            TableColumn("File") { track in
                Text(track.filename)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .contextMenu {
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([track.url])
                        }
                    }
            }
            TableColumn("BPM") { track in
                bpmCell(for: track)
            }
            .width(min: 90, ideal: 120, max: 160)
            TableColumn("Tag Δ") { track in
                deltaCell(for: track)
            }
            .width(min: 60, ideal: 80, max: 110)
        }
    }

    /// Old-tag → verdict delta, the discrepancies signal folded into the main
    /// table. Only meaningful when this session superseded a previous value.
    @ViewBuilder
    private func deltaCell(for track: AudioTrack) -> some View {
        if track.analysisState == .done,
           let previous = track.previousBPM,
           let current = track.calculatedBPM {
            let prevInt = BPMEngine.roundedBPM(previous)
            let newInt = BPMEngine.roundedBPM(current)
            let delta = newInt - prevInt
            let drastic = BPMEngine.isDrasticBPMChange(old: prevInt, new: newInt)
            Text("\(prevInt) → \(newInt) (\(delta > 0 ? "+" : "")\(delta))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(drastic ? Theme.mint : Color.secondary)
                .help(drastic
                      ? "Previously tagged \(prevInt) — changed by \(abs(newInt - prevInt)) BPM"
                      : "Previously tagged \(prevInt) — within ±5 BPM")
        } else {
            Text("").font(.caption)
        }
    }

    @ViewBuilder
    private func bpmCell(for track: AudioTrack) -> some View {
        switch track.analysisState {
        case .analyzing:
            ProgressView()
                .controlSize(.small)
        case .done:
            HStack(spacing: 4) {
                Text("\(BPMEngine.roundedBPM(track.calculatedBPM ?? 0)) BPM")
                    .monospacedDigit()
                // "no beat" badge — gray, replaces the confidence dot when
                // the engine flagged the track as ambient.
                if track.noBeatFound {
                    HStack(spacing: 3) {
                        Circle()
                            .fill(Color.secondary)
                            .frame(width: 6, height: 6)
                        Text("no beat")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .help("Engine found no clear beat. A verdict within 70–180 is still tagged; outside that range the tag write is skipped.")
                    .accessibilityLabel("no beat found")
                } else if let conf = track.confidence {
                    // Confidence badge — colored dot + small label.
                    // Never overrides the verdict; display only.
                    HStack(spacing: 3) {
                        Circle()
                            .fill(Self.confidenceColor(conf))
                            .frame(width: 6, height: 6)
                        Text(BPMEngine.confidenceLevel(conf))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .help(String(format: "engine confidence: %.2f (low <%.2f, med <%.2f, high ≥%.2f)",
                                 conf,
                                 BPMEngine.confidenceLowThreshold,
                                 BPMEngine.confidenceHighThreshold,
                                 BPMEngine.confidenceHighThreshold))
                    .accessibilityLabel("confidence \(BPMEngine.confidenceLevel(conf))")
                }
            }
        case .error:
            // Keep the verdict visible next to the error note — the engine's
            // reading is still informative when the tag write failed.
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.red)
                Text(track.errorInfo ?? "Analysis failed")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(track.errorInfo ?? "Analysis failed")
            }
            .accessibilityLabel("error: \(track.errorInfo ?? "analysis failed")")
        case .pending:
            Text("--")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Bottom status area (progress + console)

    private func statusArea(completedCount: Int) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                ProgressView(value: batchProgress)
                    .help("Batch progress")
                Text("\(completedCount)/\(tracks.count)")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    .help("Tracks finished")
                if let p = tagReadProgress {
                    HStack(spacing: 4) {
                        Image(systemName: "tag").font(.caption2).foregroundStyle(.secondary)
                        Text("Reading tags… \(p.read)/\(p.total)")
                            .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .help("Reading existing BPM tags from dropped files")
                }
                Spacer()
                Text("SKSoft™ 2026 · \(BPMPLSVersion.current)")
                    .font(.caption2).foregroundStyle(.quaternary)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(coordinator.messages) { message in
                            messageRow(message)
                                .id(message.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
                .background(Color.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
                .onChange(of: coordinator.messages.count) { _, _ in
                    if let last = coordinator.messages.last?.id {
                        withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func messageRow(_ message: UIMessage) -> some View {
        if message.kind == .aside {
            AsideText(text: message.text)
        } else {
            Text(message.text)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(color(for: message.kind))
        }
    }

    private func color(for kind: UIMessage.Kind) -> Color {
        switch kind {
        case .info: return .secondary
        case .warn: return .orange
        case .error: return .red
        case .success: return Theme.mint
        case .multiTempo: return Theme.multiTempoBlue
        case .aside: return .secondary // unreachable — asides render via AsideText
        }
    }

    // MARK: - Actions

    private func openPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        let flacType = UTType(filenameExtension: "flac") ?? .mp3
        panel.allowedContentTypes = [.mp3, flacType, .folder]
        panel.message = "Choose audio files or folders to analyze"
        if panel.runModal() == .OK {
            for url in panel.urls {
                ingest(url)
            }
        }
    }

    private func analyze() {
        coordinator.analyze(tracks: $tracks, minBPM: minVal, maxBPM: maxVal,
                            batchProgress: $batchProgress, service: service)
    }

    private func retryErrors() {
        // Write failures retry just the write (handled in the coordinator);
        // analysis failures re-analyze.
        let ids = Set(tracks.filter { $0.analysisState == .error }.map { $0.id })
        guard !ids.isEmpty else { return }
        coordinator.retry(tracks: $tracks, minBPM: minVal, maxBPM: maxVal,
                          batchProgress: $batchProgress, service: service, errorIDs: ids)
    }

    private func clearBPMs() {
        let urls = tracks.map { $0.url }
        // Guard rail for big batches: confirm before mass tag edits. The
        // alert's own "Don't show again" is the single suppression path.
        if urls.count > 50 && !UserDefaults.standard.bool(forKey: "clearBPMsWithoutConfirmation") {
            let alert = NSAlert()
            alert.messageText = "Clear BPM tags on \(urls.count) files?"
            alert.informativeText = "This erases the BPM tag in place on every queued file. Other tags are untouched."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Clear BPMs")
            alert.addButton(withTitle: "Cancel")
            alert.buttons.first?.hasDestructiveAction = true
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Don't show again"
            let response = alert.runModal()
            guard response == .alertFirstButtonReturn else {
                LogService.shared.log("clear BPMs cancelled by user (\(urls.count) files)")
                return
            }
            // Persist the suppression only when the action was confirmed.
            if alert.suppressionButton?.state == .on {
                UserDefaults.standard.set(true, forKey: "clearBPMsWithoutConfirmation")
            }
        }
        let service = self.service
        LogService.shared.log("clear BPMs requested for \(urls.count) files")
        // Optimistic UI reset; snapshot the erased value for the A/B display.
        for idx in tracks.indices {
            if let current = tracks[idx].calculatedBPM {
                tracks[idx].previousBPM = current
            }
            tracks[idx].calculatedBPM = nil
            tracks[idx].analysisState = .pending
            tracks[idx].errorInfo = nil
        }
        batchProgress = 0.0
        coordinator.post("Erasing BPM tags on \(urls.count) files…")
        Task {
            let total = urls.count
            var completed = 0
            var erased = 0
            var failed = 0
            var hadNone = 0
            // -1 = no tag present, 0 = erase failed, 1 = erased.
            await withTaskGroup(of: Int.self) { group in
                var submitted = 0
                while completed < total {
                    while submitted < total && submitted - completed < 4 {
                        let url = urls[submitted]
                        submitted += 1
                        group.addTask {
                            do {
                                // Flatten the double optional: a successful
                                // read returning nil means no BPM tag.
                                guard try service.readBPM(url: url) != nil else { return -1 }
                            } catch {
                                return 0 // unreadable file: count as failure
                            }
                            do {
                                try service.eraseBPM(url: url)
                                return 1
                            } catch {
                                LogService.shared.log("  ERASE FAILED '\(url.lastPathComponent)': \(error.localizedDescription)")
                                return 0
                            }
                        }
                    }
                    if let outcome = await group.next() {
                        completed += 1
                        switch outcome {
                        case 1: erased += 1
                        case -1: hadNone += 1
                        default: failed += 1
                        }
                        if completed % 100 == 0 || completed == total {
                            batchProgress = Double(completed) / Double(total)
                        }
                    }
                }
            }
            if failed > 0 {
                coordinator.post("BPM tags cleared — \(erased) erased, \(hadNone) had none, \(failed) FAILED (see log)", .warn)
            } else {
                coordinator.post("BPM tags cleared — \(erased) erased, \(hadNone) had none")
            }
            LogService.shared.log("clear BPMs finished: \(erased)/\(total) erased, \(hadNone) had none, \(failed) failed")
        }
    }

    private func clearQueue() {
        coordinator.cancel()
        tracks.removeAll()
        batchProgress = 0.0
        LogService.shared.log("queue cleared by user")
    }

    // MARK: - Drop handling (off-main ingest pipeline)

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            accepted = true
            _ = provider.loadObject(ofClass: URL.self) { url, error in
                guard let url = url else {
                    LogService.shared.log("drop: provider load failed: \(error?.localizedDescription ?? "unknown error")")
                    return
                }
                DispatchQueue.main.async { ingest(url) }
            }
        }
        return accepted
    }

    /// Enumerate + dedupe off-main, single batched insert, then lazy background
    /// pre-read of existing BPM tags in batches. No main-thread I/O, no pinwheel.
    private func ingest(_ url: URL) {
        let existing = Set(tracks.map { $0.url.standardizedFileURL.path })
        let service = self.service
        isIngesting = true
        Task.detached(priority: .userInitiated) {
            let (found, skipped) = await Self.collectAudioFiles(from: url, excluding: existing)
            guard !found.isEmpty else {
                await MainActor.run {
                    isIngesting = false
                    if !skipped.isEmpty {
                        let summary = Self.skipSummary(skipped)
                        coordinator.post("Nothing to analyze — \(summary)", .info)
                        LogService.shared.log("drop: nothing queued, \(summary)")
                    }
                }
                return
            }
            let newTracks = found.map {
                AudioTrack(id: UUID(), url: $0, filename: $0.lastPathComponent,
                           calculatedBPM: nil, analysisState: .pending)
            }
            let idByPath = Dictionary(uniqueKeysWithValues: newTracks.map {
                ($0.url.standardizedFileURL.path, $0.id)
            })
            let foundCount = found.count
            let droppedName = url.lastPathComponent
            await MainActor.run {
                tracks.append(contentsOf: newTracks)
                isIngesting = false
                LogService.shared.log("drop: '\(droppedName)' -> \(foundCount) files queued\(skipped.isEmpty ? "" : ", \(Self.skipSummary(skipped))")")
                if !skipped.isEmpty {
                    coordinator.post("\(foundCount) queued · \(Self.skipSummary(skipped))", .info)
                }
            }
            // Lazy pre-read of existing tags; batched main-actor updates.
            let totalToRead = foundCount
            var pending: [(UUID, Double)] = []
            var readSoFar = 0
            var unreadable = 0
            for fileURL in found {
                do {
                    if let bpm = try service.readBPM(url: fileURL),
                       let id = idByPath[fileURL.standardizedFileURL.path] {
                        pending.append((id, bpm))
                    }
                } catch {
                    unreadable += 1
                    LogService.shared.log("  prefill read failed '\(fileURL.lastPathComponent)': \(error.localizedDescription)")
                }
                readSoFar += 1
                if pending.count >= 100 {
                    let batch = pending
                    pending.removeAll()
                    let progress = readSoFar
                    await MainActor.run {
                        tagReadProgress = (progress, totalToRead)
                        applyPrefill(batch)
                    }
                }
            }
            if !pending.isEmpty {
                let batch = pending
                await MainActor.run {
                    applyPrefill(batch)
                }
            }
            let unreadableCount = unreadable
            await MainActor.run {
                tagReadProgress = nil
                if unreadableCount > 0 {
                    coordinator.post("⚠ \(unreadableCount) file\(unreadableCount == 1 ? "" : "s") unreadable at prefill — will fail on analyze", .warn)
                }
            }
        }
    }

    /// Off-main directory walk: recursive .mp3/.flac enumeration, Set-based dedupe.
    /// nonisolated so it never hops back to the main actor from the detached task.
    /// Also tallies skipped non-audio regular files by extension for the ingest report.
    private nonisolated static func collectAudioFiles(from url: URL, excluding existing: Set<String>) async -> (found: [URL], skipped: [String: Int]) {
        var found: [URL] = []
        var skipped: [String: Int] = [:]
        var seen = existing
        func skipTally(_ fileURL: URL) {
            let ext = fileURL.pathExtension.lowercased()
            skipped[ext.isEmpty ? "(no ext)" : ".\(ext)", default: 0] += 1
        }
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        if exists, isDirectory.boolValue,
           let enumerator = FileManager.default.enumerator(
               at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
           ) {
            while let fileURL = enumerator.nextObject() as? URL {
                guard (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
                if audioExtensions.contains(fileURL.pathExtension.lowercased()) {
                    if seen.insert(fileURL.standardizedFileURL.path).inserted {
                        found.append(fileURL)
                    }
                } else {
                    skipTally(fileURL)
                }
            }
        } else if exists {
            if audioExtensions.contains(url.pathExtension.lowercased()) {
                if seen.insert(url.standardizedFileURL.path).inserted {
                    found.append(url)
                }
            } else {
                skipTally(url)
            }
        }
        return (found.sorted { $0.path < $1.path }, skipped)
    }

    /// "3 skipped (.jpg ×2, .nfo ×1)" — top 4 extensions by count.
    private nonisolated static func skipSummary(_ skipped: [String: Int]) -> String {
        let total = skipped.values.reduce(0, +)
        let exts = skipped.sorted { $0.value > $1.value }.prefix(4)
            .map { "\($0.key) ×\($0.value)" }
            .joined(separator: ", ")
        return "\(total) skipped (\(exts))"
    }

    /// Batched prefill application, id → index map (the linear per-track
    /// firstIndex scan was O(n²) across a large ingest).
    private func applyPrefill(_ batch: [(UUID, Double)]) {
        var indexByID = Dictionary(uniqueKeysWithValues: tracks.enumerated().map { ($1.id, $0) })
        for (id, bpm) in batch {
            let idx: Int?
            if let i = indexByID[id], i < tracks.count, tracks[i].id == id {
                idx = i
            } else {
                idx = tracks.firstIndex(where: { $0.id == id })
                if let idx { indexByID[id] = idx }
            }
            if let idx, tracks[idx].analysisState == .pending {
                tracks[idx].calculatedBPM = bpm
                tracks[idx].analysisState = .done
            }
        }
    }
}

// MARK: - Reveal-in-Finder row (shared by the error tray)

/// A console-style row that reveals its file in Finder when clicked —
/// a real Button so it's keyboard-activatable.
private struct RevealRow: View {
    let filename: String
    let subtitle: String
    let url: URL
    let tint: Color
    let icon: String

    var body: some View {
        Button {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(filename)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .help("Reveal in Finder")
        .accessibilityLabel("\(filename), \(subtitle)")
    }
}

// MARK: - Unified resizable divider (console + error tray)

/// A hairline divider with a generous hover/drag zone. The layout-driving
/// height only commits on drag end; while dragging, the caller's ghost
/// overlay tracks the cursor instead (see BPMCalculatorView.middleArea).
private struct ResizableDivider: View {
    let visualHeight: CGFloat
    let hitPadding: CGFloat
    let minHeight: CGFloat
    let maxFraction: CGFloat
    let totalHeight: CGFloat
    @Binding var committedHeight: CGFloat
    @Binding var liveDelta: CGFloat
    @Binding var isDragging: Bool
    let helpText: String
    let a11yLabel: String

    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.06))
            .overlay(Rectangle().fill(Color.primary.opacity(0.2)).frame(height: 1))
            .frame(height: visualHeight)
            .padding(.vertical, hitPadding)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture()
                    .onChanged { value in
                        isDragging = true
                        liveDelta = -value.translation.height
                    }
                    .onEnded { value in
                        let target = committedHeight - value.translation.height
                        committedHeight = min(max(minHeight, target), max(minHeight, totalHeight * maxFraction))
                        isDragging = false
                        liveDelta = 0
                    }
            )
            .help(helpText)
            .accessibilityLabel(a11yLabel)
    }
}

// MARK: - Aside line

/// The aside line: arrives in the completion color (mint) so it reads
/// as a status line until the words give it away. Letters type on over ~1.5
/// s, then the line freezes as static text.
struct AsideText: View {
    let text: String
    @State private var revealed = 0

    private let color = Theme.mint

    var body: some View {
        Text(String(text.prefix(revealed)))
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(color)
            .accessibilityLabel(text)
            .task {
                // ~75 ticks × 20 ms ≈ 1.5 s for the whole line, any length —
                // slow enough to catch mid-type.
                let step = max(1, (text.count + 74) / 75)
                while revealed < text.count {
                    try? await Task.sleep(nanoseconds: 20_000_000)
                    if Task.isCancelled { return }
                    revealed = min(text.count, revealed + step)
                }
            }
    }
}

// MARK: - Dual-thumb BPM range slider

/// Custom dual-thumb slider (AppKit has no native two-thumb equivalent).
/// Thumb positions map proportionally to [lowerBound, upperBound]; keyboard
/// arrows nudge the most-recently-dragged thumb; VoiceOver treats it as one
/// adjustable control over the whole range.
struct DualRangeSlider: View {
    @Binding var lower: Double
    @Binding var upper: Double
    var lowerBound: Double
    var upperBound: Double
    @State private var activeThumb: Int? // nil = none, 0 = lower, 1 = upper
    @FocusState private var focused: Bool

    private let thumb: CGFloat = 12

    /// Midpoint of the bounded range — thumbs never cross it.
    private var midPoint: Double { (lowerBound + upperBound) / 2 }

    private func clamp(_ value: Double, isLower: Bool) -> Double {
        let stepped = value.rounded()
        if isLower {
            return min(max(lowerBound, stepped), min(midPoint, upper))
        } else {
            return max(min(upperBound, stepped), max(midPoint, lower))
        }
    }

    var body: some View {
        GeometryReader { geo in
            let usable = max(1, geo.size.width - thumb)
            let span = max(1, upperBound - lowerBound)
            let position: (Double) -> CGFloat = { value in
                thumb / 2 + CGFloat((value - lowerBound) / span) * usable
            }
            let lowerX = position(lower)
            let upperX = position(upper)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.15))
                    .frame(height: 3)
                    .padding(.horizontal, thumb / 2)
                Capsule()
                    .fill(Theme.mint.opacity(0.7))
                    .frame(width: max(0, upperX - lowerX), height: 3)
                    .offset(x: lowerX)
                Circle()
                    .fill(Color.primary.opacity(0.85))
                    .frame(width: thumb, height: thumb)
                    .offset(x: lowerX - thumb / 2)
                Circle()
                    .fill(Color.primary.opacity(0.85))
                    .frame(width: thumb, height: thumb)
                    .offset(x: upperX - thumb / 2)
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, 2)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if activeThumb == nil {
                            activeThumb = abs(value.startLocation.x - lowerX) <= abs(value.startLocation.x - upperX) ? 0 : 1
                        }
                        let raw = lowerBound + Double((value.location.x - thumb / 2) / usable) * span
                        if activeThumb == 0 {
                            lower = clamp(raw, isLower: true)
                        } else {
                            upper = clamp(raw, isLower: false)
                        }
                    }
                    .onEnded { _ in activeThumb = nil }
            )
        }
        .frame(height: 28)
        .overlay(alignment: .topLeading) {
            Text("\(Int(lower))")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(Theme.mint)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .topTrailing) {
            Text("\(Int(upper))")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(Theme.mint)
                .allowsHitTesting(false)
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled(true)
        .onMoveCommand { direction in
            // Nudge the last-dragged thumb (default: the lower one).
            let step: Double = (direction == .up || direction == .right) ? 1.0 : -1.0
            if activeThumb == 1 {
                upper = clamp(upper + step, isLower: false)
            } else {
                lower = clamp(lower + step, isLower: true)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("BPM range")
        .accessibilityValue("\(Int(lower)) to \(Int(upper)) BPM")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: upper = clamp(upper + 1, isLower: false)
            case .decrement: lower = clamp(lower - 1, isLower: true)
            @unknown default: break
            }
        }
        .help("BPM range — left thumb: min (\(Int(lowerBound))–\(Int(upperBound))), right thumb: max. Arrow keys nudge.")
    }
}
