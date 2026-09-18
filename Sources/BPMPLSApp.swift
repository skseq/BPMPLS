import SwiftUI
import AppKit

@main
struct BPMPLSApp: App {
    @Environment(\.openWindow) private var openWindow
    @NSApplicationDelegateAdaptor(BPMPLSAppDelegate.self) private var appDelegate

    init() {
        // One-time cleanup of settings removed from the UI (incl. the old
        // 60-160 test mode, which could otherwise silently re-activate).
        let stale = ["bpmTestMode60to160", "clearQueueOnNewDrop",
                     "writeNullBpmForAmbient", "useFolderAffinity"]
        for key in stale {
            UserDefaults.standard.removeObject(forKey: key)
        }
        LogService.shared.log("--- BPMPLS \(BPMPLSVersion.current) launched ---")
    }

    var body: some Scene {
        WindowGroup("BPMPLS") {
            BPMCalculatorView()
        }
        .defaultSize(width: 760, height: 540)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About BPMPLS") { openWindow(id: "about") }
            }
            // Standard macOS intake + file actions.
            CommandGroup(after: .newItem) {
                Button("Open…") { AppCommandsBridge.current?.openPanel() }
                    .keyboardShortcut("o")
                Divider()
                Button("Reveal in Finder") { AppCommandsBridge.current?.revealSelection() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(AppCommandsBridge.current?.selectedURL == nil)
            }
            // No Help menu: the app has no help book, and macOS would
            // otherwise insert an empty stub with just a search field.
            CommandGroup(replacing: .help) { }
            // The app's core actions, mirrored in the menu bar.
            CommandMenu("Queue") {
                Button("Analyze") { AppCommandsBridge.current?.analyze() }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(!(AppCommandsBridge.current?.canAnalyze ?? false))
                Button("Retry Errors") { AppCommandsBridge.current?.retryErrors() }
                    .keyboardShortcut("r")
                    .disabled(!(AppCommandsBridge.current?.canRetryErrors ?? false))
                Divider()
                Button("Clear Queue") { AppCommandsBridge.current?.clearQueue() }
                    .disabled(!(AppCommandsBridge.current?.hasQueue ?? false))
                Button("Clear BPM Tags…") { AppCommandsBridge.current?.clearBPMs() }
                    .disabled(!(AppCommandsBridge.current?.hasQueue ?? false))
                Divider()
                if AppCommandsBridge.current?.canShowDiscrepancies == true {
                    Button("Show Discrepancies Only") { AppCommandsBridge.current?.toggleDiscrepancies() }
                        .keyboardShortcut("d")
                }
            }
        }

        Window("About BPMPLS", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Settings {
            SettingsView()
        }
    }
}

/// AppDelegate shim: SwiftUI's @main doesn't expose a clean place to hook
/// AppKit termination, so we use a NSApplicationDelegateAdaptor.
final class BPMPLSAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
    /// Pending tag writes are flushed by a background task that outlives the
    /// "batch complete" chime. Answer .terminateLater, wait (bounded) for the
    /// writes, then allow termination — otherwise quitting right after a
    /// batch silently loses whatever writes are still in flight.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let coordinator = AnalysisCoordinator.active, coordinator.hasPendingWrites else {
            return .terminateNow
        }
        Task { @MainActor in
            await coordinator.flushPendingWrites(timeout: 10.0)
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

struct SettingsView: View {
    @AppStorage("completionSound") private var completionSound = "Glass"
    @AppStorage("errorSound") private var errorSound = "Tink"
    @AppStorage("loggingEnabled") private var loggingEnabled = false

    var body: some View {
        Form {
            Section("Notification Sounds") {
                Picker("Completion sound", selection: $completionSound) {
                    Text("None").tag("None")
                    ForEach(SoundService.stockSounds, id: \.self) { Text($0).tag($0) }
                }
                .onChange(of: completionSound) { _, new in SoundService.preview(new) }
                .help("Played when a batch finishes with zero errors")

                Picker("With-errors sound", selection: $errorSound) {
                    Text("None").tag("None")
                    ForEach(SoundService.stockSounds, id: \.self) { Text($0).tag($0) }
                }
                .onChange(of: errorSound) { _, new in SoundService.preview(new) }
                .help("Played when a batch finishes with at least one error")
            }

            Section("Logging") {
                Toggle("Enable logging", isOn: $loggingEnabled)
                    .help("Off by default. Writes per-session logs to ~/Library/Logs/BPMPLS (keeps newest 10)")
                HStack(spacing: 10) {
                    Button("Open Log") { LogService.shared.reveal() }
                    Button("Clear Logs") { LogService.shared.clearLogs() }
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct AboutView: View {
    @State private var scanned = Stats.totalScanned

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform.badge.plus")
                .font(.system(size: 38))
                .foregroundStyle(Theme.mint)
                .padding(.bottom, 2)
            Text("BPMPLS").font(.title2).bold()
            Text(BPMPLSVersion.current).font(.caption).foregroundStyle(.secondary)
            Text("LLM development by SKSoft.")
                .font(.callout)
            Text("Licensed under the MIT License")
                .font(.caption).foregroundStyle(.secondary)
            Text("Total tracks scanned: \(scanned)")
                .font(.callout).monospacedDigit()
                .padding(.top, 2)
        }
        .padding(24)
        .frame(width: 340)
        .onAppear { scanned = Stats.totalScanned }
    }
}
