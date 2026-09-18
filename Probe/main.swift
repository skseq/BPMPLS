import Foundation
import AVFoundation
import Accelerate

// Diagnostic probe: why did BPMPLS pick X when the better musically-fit BPM is Y?
// Read-only: never writes tags. Run: probe <file.mp3> [...]

func fmt(_ xs: [(bpm: Double, frac: Float)]) -> String {
    if xs.isEmpty { return "(none)" }
    return xs.map { String(format: "%.1f@%d%%", $0.bpm, Int(($0.frac * 100).rounded())) }.joined(separator: "  ")
}

let bandNames = ["LOW<150", "MID150-2k", "HIGH>2k"]
let args = Array(CommandLine.arguments.dropFirst())
guard !args.isEmpty else {
    print("usage: probe <audio files...>")
    exit(1)
}

let metadata = NativeMetadataService()
for path in args {
    let url = URL(fileURLWithPath: path)
    print("\n================================================================")
    print("FILE: \(url.lastPathComponent)")
    if let tagged = try? metadata.readBPM(url: url) {
        print(String(format: "existing tag BPM: %.2f", tagged))
    } else {
        print("existing tag BPM: (none)")
    }
    do {
        let (samples, sampleRate) = try BPMEngine.readMonoSamples(url: url)
        let seconds = Double(samples.count) / sampleRate
        print(String(format: "pcm: %d samples @ %d Hz (%.1fs)", samples.count, Int(sampleRate), seconds))
        let bands = BPMEngine.splitBands(samples: samples, sampleRate: sampleRate)
        let envelopes = bands.map { BPMEngine.onsetEnvelope(samples: $0, sampleRate: sampleRate) }
        let envRate = sampleRate / Double(BPMEngine.hopSize)
        let envCount = envelopes.map { $0.count }.max() ?? 0

        print("\n-- whole-track per-band autocorrelation (BPM @ % of band best) --")
        for (i, env) in envelopes.enumerated() {
            let varStr = BPMEngine.normalizedIOIVariance(peaks: BPMEngine.pickPeaks(envelope: env, envRate: envRate))
                .map { String(format: "%.4f", $0) } ?? "n/a"
            print("  \(bandNames[i])  ioiVar=\(varStr)")
            print("    top5: \(fmt(BPMEngine.topEnvelopePeaks(env, envRate: envRate, k: 5, minBPM: 40, maxBPM: 400, fold: false)))")
        }

        // Chunk walk, mirroring analyzeSegments energy/floor logic.
        let chunkEnv = max(8, Int(BPMEngine.chunkSeconds * envRate))
        let totalChunks = max(1, (envCount + chunkEnv - 1) / chunkEnv)
        func rangeFor(_ c: Int, count: Int) -> Range<Int> {
            let lo = min(c * chunkEnv, count)
            return lo..<min((c + 1) * chunkEnv, count)
        }
        var energies = [Float](repeating: 0, count: totalChunks)
        for c in 0..<totalChunks {
            energies[c] = envelopes.map { env -> Float in
                let r = rangeFor(c, count: env.count)
                return r.isEmpty ? 0 : vDSP.mean(env[r])
            }.max() ?? 0
        }
        let maxEnergy = energies.max() ?? 0
        let floorE = maxEnergy * BPMEngine.energyFloorRatio

        print("\n-- chunk walk (8s chunks above energy floor) --")
        print("   #   t(s)  eng%  | LOW top3 | MID top3 | HIGH top3 | engine pick")
        for c in 0..<totalChunks where energies[c] >= floorE {
            let chunks = envelopes.map { env -> [Float] in
                let r = rangeFor(c, count: env.count)
                return r.isEmpty ? [] : Array(env[r])
            }
            var cols: [String] = []
            for b in 0..<3 {
                cols.append(fmt(Array(BPMEngine.topEnvelopePeaks(chunks[b], envRate: envRate, minBPM: 40, maxBPM: 400, fold: false).prefix(3))))
            }
            let pick = BPMEngine.bpmFromBandChunks(chunks, envRate: envRate,
                                                   minBPM: 70, maxBPM: 180)
            let order = BPMEngine.bandVarianceOrder(chunks: chunks, envRate: envRate)
            let pickStr = pick.map { String(format: "%.1f (%@ first, src %@)", $0.bpm, bandNames[order.first ?? -1], bandNames[$0.band]) } ?? "nil"
            print(String(format: "  %2d %6.0f %4.0f%% | %@ | %@ | %@ | %@",
                         c, Double(c) * BPMEngine.chunkSeconds, 100 * energies[c] / maxEnergy,
                         cols[0], cols[1], cols[2], pickStr))
        }

        print("\n-- engine verdict --")
        // analyzeSegments also returns role-weighted whole-track peaks
        // (instrument-aware decomposition evidence; verdict rules still read
        // raw) and multi-candidate grid-stability scores. The probe is the
        // one caller that opts into the (parked) classifier compute.
        let segAnalysis = try BPMEngine.analyzeSegments(samples: samples, sampleRate: sampleRate,
                                                          minBPM: 70, maxBPM: 180, computeRoleEvidence: true)
        let segments = segAnalysis.segments
        let rawPeaks = segAnalysis.bandPeaks
        let rolePeaks = segAnalysis.roleBandPeaks
        let beatTimes = segAnalysis.beatTimes
        let multiScores = segAnalysis.multiCandidateScores
        for s in segments {
            print(String(format: "  segment: %.2f BPM  start %.0fs  dur %.1fs  band %@", s.bpm, s.startTime, s.duration, bandNames[s.band]))
        }
        // Online beat tracker output (evidence only).
        print(String(format: "  tracked beats: %d", beatTimes.count))
        if !beatTimes.isEmpty {
            let head = beatTimes.prefix(6).map { String(format: "%.2f", $0) }.joined(separator: ", ")
            let tail = beatTimes.suffix(3).map { String(format: "%.2f", $0) }.joined(separator: ", ")
            print("    first: \(head)  ...  last: \(tail)")
        }
        // Multi-candidate grid-stability diagnostic table: one row per
        // bounded candidate tempo. The per-track inspection surface for the
        // verdict pipeline's candidate evaluation.
        if !multiScores.isEmpty {
            print("\n-- multi-candidate grid-stability --")
            print("  bpm    snap   grid   cov(s)  beats  | family-to-verdict")
            let finalVerdictBPM = segments.isEmpty ? 0 : (BPMEngine.tempoClusters(segments).first?.bpm ?? 0)
            for s in multiScores {
                let ratio = finalVerdictBPM > 0 ? s.bpm / finalVerdictBPM : 0
                let fam: String
                if finalVerdictBPM > 0, abs(s.bpm - finalVerdictBPM) > 0.5 {
                    if abs(ratio - 1.333) <= 0.04 { fam = "×4/3-high" }
                    else if abs(ratio - 1.5) <= 0.045 { fam = "×3/2-low" }
                    else if abs(ratio - 0.667) <= 0.02 { fam = "×2/3-high" }
                    else if abs(ratio - 0.75) <= 0.0225 { fam = "×3/4-low" }
                    else if abs(ratio - 2.0) <= 0.06 { fam = "×2 (octave)" }
                    else if abs(ratio - 0.5) <= 0.015 { fam = "×½ (octave)" }
                    else { fam = "(other)" }
                } else {
                    fam = "verdict"
                }
                print(String(format: "  %5.1f  %5.2f %5.2f  %6.0f  %5d  | %@",
                             s.bpm, s.snapRate, s.gridStability, s.coverageSeconds, s.beatCount, fam))
            }
        }
        func fmtPeaks(_ xs: [(bpm: Double, frac: Float)]) -> String {
            xs.isEmpty ? "(none)" : xs.map { String(format: "%.1f@%d%%", $0.bpm, Int(($0.frac * 100).rounded())) }.joined(separator: "  ")
        }
        print("\n-- whole-track engine peaks: RAW vs ROLE-WEIGHTED (top6, unfolded) --")
        for i in 0..<3 {
            print("  \(bandNames[i])")
            print("    raw : \(fmtPeaks(rawPeaks[i]))")
            print("    role: \(fmtPeaks(rolePeaks[i]))")
        }
        let final = try BPMEngine.analyzeSync(url: url, minBPM: 70, maxBPM: 180)
        print(String(format: "  FINAL: %.2f BPM -> tagged %d", final, BPMEngine.roundedBPM(final)))
        // Show noBeatFound status from the detailed analysis.
        if let detailed = try? BPMEngine.analyzeDetailedSync(url: url, minBPM: 70, maxBPM: 180) {
            if detailed.noBeatFound {
                print("  AMBIENT: (no beat found) — engine detected no clear beat in 70-180 range")
            }
        }
    } catch {
        print("  ERROR: \(error.localizedDescription)")
    }
}
