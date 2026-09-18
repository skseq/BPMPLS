import Foundation
import Accelerate

// Instrument-aware onset decomposition (PARKED: built and calibrated, but it
// failed its effectiveness criteria on real polyphonic mixes and was never
// allowed to touch verdicts — see the probe-only call sites in BPMEngine).
//
// A soft drum-role classification stage between onsetEnvelope and bpmFromEnvelope.
// It does NOT replace splitBands and does NOT touch the verdict pipeline: each
// detected onset gets a probability distribution over {kick, snare, hihat, other},
// and the three existing band envelopes are reweighted per-onset BEFORE the same
// autocorrelation runs. The intent:
//   - kick-class onsets dominate the LOW band contribution
//   - snare-class onsets dominate the MID band contribution
//   - hihat-class onsets are DAMPED — hats are subdivisions, not the pulse.
//     Dotted-8th hat patterns are exactly the x4/3 pattern-period adversary
//     (t_0710e9887b 06/07/08), so hat-frame flux is weighted down in the tempo vote.
// Feature set per the research phase (Herrera 2002 / Dittmar 2014 / Wu 2018):
// sub-band energy ratios + attack slope, all from the STFT frames the engine
// already computes. No ML model, no corpus-learned parameters: the thresholds
// below are hand-set and documented, same discipline as §2 constants.

enum OnsetRole: String, CaseIterable, Sendable {
    case kick, snare, hihat, other
}

/// One detected onset event (merged across the three time-aligned band envelopes).
struct ClassifiedOnset: Sendable, Equatable {
    /// Seconds from track start.
    let time: Double
    /// Envelope frame index of the event (max-amplitude band member).
    let frame: Int
    /// Full-spectrum sub-band energies at the onset frame:
    /// [low <150 Hz, mid 150 Hz–2 kHz, presence 2–5 kHz, air >5 kHz].
    let bandEnergies: [Float]
    /// Soft role distribution; sums to 1.0.
    let roleProbabilities: [OnsetRole: Float]
}

struct OnsetClassifier {

    /// Role -> per-band envelope weight [LOW, MID, HIGH]. Hand-set.
    /// Kick reads keep LOW intact; snare keeps MID; hats are damped everywhere
    /// (least in HIGH, where they legitimately live) so subdivision periodicity
    /// loses weight against the pulse. `other` is neutral-ish across bands.
    static let roleBandWeights: [OnsetRole: [Float]] = [
        .kick:  [1.0, 0.3, 0.1],
        .snare: [0.3, 1.0, 0.4],
        .hihat: [0.1, 0.4, 0.6],
        .other: [0.5, 0.5, 0.5],
    ]

    /// Onsets closer than this many envelope frames (~35 ms @ 86.1 fps) across
    /// bands are one physical event (a kick + hat hit on the same eighth note).
    static let mergeWindowFrames = 3
    /// Per-onset weight smear: frames [f-smear, f+smear] get the event's weight.
    static let weightSmearFrames = 1

    /// Denser peak picker for classification only. The engine's pickPeaks enforces
    /// a 0.25 s minimum distance for IOI-regularity scoring — far too coarse for
    /// hihats (16th notes at 120 BPM arrive every ~0.125 s), and undetected spikes
    /// keep full weight, which would defeat hat damping. Classification instead
    /// wants every significant onset: threshold mean + 1.0·sd, min distance 0.08 s.
    private static func densePeaks(envelope: [Float], envRate: Double) -> [(index: Int, amp: Float)] {
        let count = envelope.count
        guard count > 4, envRate > 0 else { return [] }
        let mean = vDSP.mean(envelope)
        var meanSquare: Float = 0
        vDSP_measqv(envelope, 1, &meanSquare, vDSP_Length(count))
        let sd = max(0, meanSquare - mean * mean).squareRoot()
        guard sd > 1e-9 else { return [] }
        let threshold = mean + 1.0 * sd
        let minDist = max(1, Int(0.08 * envRate))
        var peaks: [(index: Int, amp: Float)] = []
        var i = 1
        while i < count - 1 {
            let v = envelope[i]
            if v > threshold && v >= envelope[i - 1] && v >= envelope[i + 1] {
                if let last = peaks.last, i - last.index < minDist {
                    if v > last.amp { peaks[peaks.count - 1] = (i, v) }
                } else {
                    peaks.append((i, v))
                }
            }
            i += 1
        }
        return peaks
    }

    private static func clamp01(_ x: Float) -> Float { min(1, max(0, x)) }

    /// Detect onsets per band (densePeaks — finer than the engine's IOI picker),
    /// merge cross-band events, and classify each event from its sub-band
    /// energy signature.
    /// - Parameter energies: per band, per frame, [low, mid, presence, air] sums
    ///   from onsetEnvelopeAndEnergies (band-filtered, so only the passband is hot).
    static func classifyOnsets(envelopes: [[Float]], energies: [[[Float]]],
                               envRate: Double) -> [ClassifiedOnset] {
        guard envelopes.count == 3, energies.count == 3, envRate > 0 else { return [] }
        // Full-spectrum energy per frame = component-wise sum across band-filtered STFTs.
        let frameCount = envelopes.map { $0.count }.max() ?? 0
        guard frameCount > 0 else { return [] }
        var total = [Float](repeating: 0, count: frameCount)
        for b in 0..<3 {
            for (f, e) in energies[b].enumerated() where f < frameCount {
                total[f] += e[0] + e[1] + e[2] + e[3]
            }
        }
        // Gather per-band peaks as (frame, band, amplitude).
        var hits: [(frame: Int, band: Int, amp: Float)] = []
        for b in 0..<3 {
            let env = envelopes[b]
            guard !env.isEmpty else { continue }
            for p in densePeaks(envelope: env, envRate: envRate) {
                hits.append((p.index, b, p.amp))
            }
        }
        hits.sort { $0.frame < $1.frame }
        // Merge hits within the merge window into single events.
        var events: [(frame: Int, amp: Float)] = []
        for h in hits {
            if let last = events.last, h.frame - last.frame <= mergeWindowFrames {
                if h.amp > last.amp { events[events.count - 1] = (h.frame, h.amp) }
            } else {
                events.append((h.frame, h.amp))
            }
        }
        return events.compactMap { classifyEvent(frame: $0.frame, energies: energies,
                                                 total: total, envRate: envRate) }
    }

    /// Classify one event. Soft scores per role, gated by percussiveness (a slow
    /// bass swell with strong low energy must NOT read as kick — Wu et al. 2018's
    /// melodic-masking failure mode), then normalized to sum 1.
    private static func classifyEvent(frame f: Int, energies: [[[Float]]],
                                      total: [Float], envRate: Double) -> ClassifiedOnset? {
        var e = [Float](repeating: 0, count: 4)
        for b in 0..<3 where f < energies[b].count {
            for k in 0..<4 { e[k] += energies[b][f][k] }
        }
        let sum = e[0] + e[1] + e[2] + e[3]
        guard sum > 1e-6 else { return nil }
        let lowShare = e[0] / sum, midShare = e[1] / sum
        let presShare = e[2] / sum, airShare = e[3] / sum
        // Attack slope: fraction of onset-frame energy that arrived within the
        // last ~23 ms. Sharp percussive attacks -> near 1; swells -> near 0.
        let back = max(0, f - 2)
        let attack = clamp01((total[f] - total[back]) / (total[f] + 1e-9))
        let percussive = clamp01((attack - 0.3) / 0.3)

        var kickScore = clamp01((lowShare - 0.35) / 0.25) * percussive
        if airShare > 0.35 { kickScore *= 0.3 } // bright transients aren't kicks
        var hihatScore = clamp01((airShare - 0.40) / 0.25) * percussive
        if lowShare > 0.25 { hihatScore *= 0.3 } // kicks under hats pull air share down
        var snareScore = clamp01((midShare - 0.25) / 0.25) * percussive
        snareScore *= clamp01((presShare + 0.5 * airShare) / 0.30) // body + wire noise
        if lowShare > 0.45 { snareScore *= 0.5 }

        let best = max(kickScore, max(snareScore, hihatScore))
        let otherScore = max(0.15, 1.0 - best)
        let norm = kickScore + snareScore + hihatScore + otherScore
        let probs: [OnsetRole: Float] = [
            .kick: kickScore / norm,
            .snare: snareScore / norm,
            .hihat: hihatScore / norm,
            .other: otherScore / norm,
        ]
        return ClassifiedOnset(time: Double(f) / envRate, frame: f,
                               bandEnergies: e, roleProbabilities: probs)
    }

    /// Reweight each band's envelope per onset: frames near an event are scaled by
    /// the event's role-weighted band gain; frames far from any event keep weight 1.0
    /// (unclassified evidence is left alone). The autocorrelation downstream is the
    /// unchanged autocorrelation math — only the envelope values differ.
    static func roleWeightedEnvelopes(envelopes: [[Float]], onsets: [ClassifiedOnset],
                                      envRate: Double) -> [[Float]] {
        guard !onsets.isEmpty else { return envelopes }
        var out = envelopes
        for b in 0..<envelopes.count {
            let count = envelopes[b].count
            guard count > 0 else { continue }
            var bestDist = [Int](repeating: .max, count: count)
            for onset in onsets {
                var w: Float = 0
                for role in OnsetRole.allCases {
                    w += (onset.roleProbabilities[role] ?? 0) * (roleBandWeights[role]?[b] ?? 1)
                }
                let lo = max(0, onset.frame - weightSmearFrames)
                let hi = min(count - 1, onset.frame + weightSmearFrames)
                guard lo <= hi else { continue }
                for i in lo...hi {
                    let d = abs(i - onset.frame)
                    if d < bestDist[i] {
                        bestDist[i] = d
                        out[b][i] = envelopes[b][i] * w
                    }
                }
            }
        }
        return out
    }
}
