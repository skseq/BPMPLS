import Foundation
import AVFoundation
import Accelerate

// BPMPLS Corpus Gate
// Reads Tests/corpus_manifest.json, runs the engine on every row, applies
// the folder-affinity prior, and asserts the result
// matches each row's `engine_verdict`. Prints a summary and exits non-zero
// on any UNEXPECTED deviation.
//
//   swiftc Sources/*.swift Tools/corpus_gate.swift <flags> -o /tmp/corpus_gate
//   /tmp/corpus_gate Tests/corpus_manifest.json
//
// Two-pass design:
//   1. First pass: call analyzeDetailedSync on every row. Cache the
//      BPMAnalysis (verdict, bandPeaks, confidence, noBeatFound).
//   2. Build folder affinity from the cached verdicts + confidences.
//   3. Second pass: apply BPMEngine.applyFolderAffinity to each row.
//      Compare the (possibly corrected) verdict to expected.
//
// Locked contract:
//   - Rows with `engine_verdict: <number>`: corrected verdict must match.
//   - Rows with `engine_verdict: null` (multi-tempo or ambient): no numeric
//     compare. For `family == "ambient"`, the engine must report
//     `noBeatFound == true` (the ambient family asserts a heuristic flag).
//   - For other null-verdict rows (multi-tempo): no numeric compare; just
//     verify the file decodes and analysis completes.
//   - The summary line format is part of the contract.

struct Row: Decodable {
    let id: String
    var file: String
    let tag_bpm: Double?            // null OK (ambient rows have no tag)
    let engine_verdict: Double?    // null OK (multi-tempo or ambient)
    let truth_bpm: Double?
    let family: String
    let status: String
    let note: String?
}

struct Manifest: Decodable {
    let manifest_version: String
    let engine_version: String
    let rows: [Row]
}

enum GateError: Error, CustomStringConvertible {
    case missingArg
    case manifestUnreadable(String)
    case manifestMalformed(String)
    case fileMissing(String, String)        // (id, path)
    case decodeFailed(String, String)       // (id, msg)
    case verdictMismatch(String, Int, Int)  // (id, expected, got)
    case ambientExpectedButNotFound(String)  // id — family=ambient but noBeatFound=false

    var description: String {
        switch self {
        case .missingArg:
            return "usage: corpus_gate <manifest.json>"
        case .manifestUnreadable(let p):
            return "manifest unreadable: \(p)"
        case .manifestMalformed(let m):
            return "manifest malformed: \(m)"
        case .fileMissing(let id, let p):
            return "[\(id)] FILE MISSING: \(p)"
        case .decodeFailed(let id, let m):
            return "[\(id)] DECODE FAILED: \(m)"
        case .verdictMismatch(let id, let expected, let got):
            return "[\(id)] UNEXPECTED VERDICT: expected=\(expected) got=\(got)"
        case .ambientExpectedButNotFound(let id):
            return "[\(id)] EXPECTED AMBIENT but engine noBeatFound=false"
        }
    }
}

@main
struct CorpusGate {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
guard let manifestPath = args.first else {
    FileHandle.standardError.write(Data("usage: corpus_gate <manifest.json>\n".utf8))
    exit(2)
}

let url = URL(fileURLWithPath: manifestPath)
let data: Data
do {
    data = try Data(contentsOf: url)
} catch {
    FileHandle.standardError.write(Data("manifest unreadable: \(url.path) (\(error.localizedDescription))\n".utf8))
    exit(2)
}

let manifest: Manifest
do {
    let dec = JSONDecoder()
    manifest = try dec.decode(Manifest.self, from: data)
} catch {
    FileHandle.standardError.write(Data("manifest malformed: \(error.localizedDescription)\n".utf8))
    exit(2)
}

// Relative row paths (e.g. "Corpus/t_e6feadf81c/x.mp3") resolve against the
// project root — the manifest's directory's parent (Tests/../).
let projectRoot = url.deletingLastPathComponent().deletingLastPathComponent()
let rows: [Row] = manifest.rows.map { row in
    var r = row
    if !r.file.hasPrefix("/") {
        r.file = projectRoot.appendingPathComponent(r.file).path
    }
    return r
}

print("BPMPLS Corpus Gate — manifest \(manifest.manifest_version), engine \(manifest.engine_version), rows=\(rows.count)")
print(String(repeating: "-", count: 72))

var green = 0
var knownFailure = 0
var acceptedLimit = 0
var unexpected = 0
var skipped = 0
var failures: [String] = []
/// Count a row's status once; warn on unknown statuses.
func tally(_ status: String, id: String) {
    switch status {
    case "green": green += 1
    case "known-failure": knownFailure += 1
    case "accepted-limit": acceptedLimit += 1
    default:
        print("    WARN  unknown status '\(status)' on row \(id) — counting as skipped")
        skipped += 1
    }
}

// ─── Pass 1: analyze all rows, cache BPMAnalysis ────────────────────────────
var analyses: [String: BPMAnalysis] = [:]
for row in rows {
    guard FileManager.default.fileExists(atPath: row.file) else {
        let msg = GateError.fileMissing(row.id, row.file).description
        print("  FAIL  \(msg)")
        failures.append(msg)
        unexpected += 1
        continue
    }
    let fileURL = URL(fileURLWithPath: row.file)
    do {
        let analysis = try BPMEngine.analyzeDetailedSync(url: fileURL, minBPM: 70, maxBPM: 180)
        analyses[row.id] = analysis
    } catch {
        let msg = GateError.decodeFailed(row.id, error.localizedDescription).description
        print("  FAIL  \(msg)")
        failures.append(msg)
        unexpected += 1
    }
}

// ─── Build folder affinity from cached first-pass results ──────────────────
let firstPassResults: [(url: URL, bpm: Double, confidence: Double, bandPeaks: [[(bpm: Double, frac: Float)]])] = rows.compactMap { row in
    guard let analysis = analyses[row.id] else { return nil }
    return (URL(fileURLWithPath: row.file), analysis.bpm, analysis.confidence, analysis.bandPeaksRaw)
}
let folderAffinity = FolderAffinity.build(from: firstPassResults)
print("Folder affinity anchors: \(folderAffinity.anchors.count)")
for (folder, anchor) in folderAffinity.anchors {
    print("  → \(folder): anchor=\(Int(anchor.bpm)) conf=\(String(format: "%.2f", anchor.confidence)) from \(anchor.sourceURL.lastPathComponent)")
}

// ─── Pass 2: apply folder affinity, compare to expected ─────────────────────
for row in rows {
    guard let analysis = analyses[row.id] else { continue }  // first pass failed
    let fileURL = URL(fileURLWithPath: row.file)

    // Apply folder affinity if an anchor exists for this folder.
    var verdict = analysis.bpm
    var folderNote = ""
    if let anchor = folderAffinity.anchor(for: fileURL) {
        if anchor.sourceURL != fileURL {
            let result = BPMEngine.applyFolderAffinity(
                verdict: verdict,
                bandPeaks: analysis.bandPeaksRaw,
                anchor: anchor
            )
            if result.flipped {
                folderNote = " [folder: \(Int(verdict))→\(Int(result.bpm)) anchor=\(Int(anchor.bpm))]"
                verdict = result.bpm
            } else {
                folderNote = " [no-flip: \(result.reason)]"
            }
        }
    }

    let actualInt = BPMEngine.roundedBPM(verdict)
    let noBeat = analysis.noBeatFound
    let confLine = String(format: " conf=%.2f(%@)", analysis.confidence, BPMEngine.confidenceLevel(analysis.confidence))
    let ambientLine = noBeat ? " (no beat found)" : ""

    // Compare to expected.
    if let expectedDouble = row.engine_verdict {
        // Numeric compare.
        let expectedInt = Int(expectedDouble.rounded())
        if actualInt == expectedInt {
            print("  OK    [\(row.id)] status=\(row.status) family=\(row.family) expected=\(expectedInt) got=\(actualInt)\(confLine)\(folderNote)\(ambientLine)")
            tally(row.status, id: row.id)
        } else {
            let msg = GateError.verdictMismatch(row.id, expectedInt, actualInt).description
            print("  FAIL  \(msg) status=\(row.status) family=\(row.family)\(folderNote)")
            failures.append(msg)
            unexpected += 1
        }
    } else {
        // Null engine_verdict: multi-tempo or ambient.
        if row.family == "ambient" {
            if noBeat {
                print("  OK    [\(row.id)] status=\(row.status) family=\(row.family) actual=\(actualInt) (no verdict assert; ambient — engine confirmed noBeatFound)\(confLine)\(folderNote)")
                tally(row.status, id: row.id)
            } else {
                let msg = GateError.ambientExpectedButNotFound(row.id).description
                print("  FAIL  \(msg) status=\(row.status) family=\(row.family) actual=\(actualInt)\(confLine)\(folderNote)")
                failures.append(msg)
                unexpected += 1
            }
        } else {
            // Multi-tempo or other null-verdict row.
            print("  OK    [\(row.id)] status=\(row.status) family=\(row.family) actual=\(actualInt) (no verdict assert; multi-tempo)\(confLine)\(folderNote)\(ambientLine)")
            tally(row.status, id: row.id)
        }
    }
}

print(String(repeating: "-", count: 72))
let total = rows.count
let summary = "\(green)/\(total) green, \(knownFailure) known-failure, \(acceptedLimit) accepted-limit, \(unexpected) unexpected"
if skipped > 0 {
    print("SUMMARY: \(summary), \(skipped) skipped")
} else {
    print("SUMMARY: \(summary)")
}

if unexpected > 0 {
    print("\nGATE FAILED — \(unexpected) unexpected verdict(s):")
    for f in failures { print("  - \(f)") }
    exit(1)
}
print("GATE PASSED")
exit(0)
    } // main
} // CorpusGate
