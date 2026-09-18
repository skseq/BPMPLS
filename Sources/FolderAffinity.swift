import Foundation

// Folder-affinity prior.
//
// When a batch of files is analyzed, the files in the same parent folder
// (album / CD-single / EP) are often related. A CD single has multiple
// remixes of the same song; an album of a single artist usually shares a
// tempo. The folder-affinity prior uses the most confident verdict in each
// folder as an "anchor" tempo, then checks whether other tracks in the
// same folder are in a pattern-period family (×4/3, ×3/2) with that
// anchor. If so AND the anchor has any cross-band presence in the track,
// the verdict is corrected to the anchor. This is the structural answer to
// remix-single families whose truth is visible in MID/HIGH cross-band
// peaks but blocked by Move 4's LOW-floor (truth has LOW=0): the folder
// prior lifts the truth's effective cross-band for sibling tracks.
//
// Family-gated (×4/3 or ×3/2 only), direction-constrained (×4/3 artifacts
// only flip DOWN to the anchor, ×3/2 only flip UP). Album anchor must
// have confidence ≥ 0.4 to qualify. Anchor must have cross-band support
// ≥ 0.5 in the target track. Octave (×2/×½) and the subdominant-truth
// family are deliberately excluded (genuine album-level tempo variety
// or the t_cd80bde8b5-style no-pattern-period cases stay as-is).
//
// User-facing name: "Folder affinity". Setting key: `useFolderAffinity`,
// default true.

/// One folder's anchor — the most confident verdict in a folder.
struct FolderAnchor: Sendable, Equatable {
    /// The anchor tempo (the most confident verdict in the folder).
    var bpm: Double
    /// Confidence of the anchor verdict (used to gate the prior).
    var confidence: Double
    /// Number of tracks in the folder that contributed to finding this anchor.
    var trackCount: Int
    /// The source file (the track whose verdict became the anchor).
    var sourceURL: URL
}

/// Folder-affinity context — a map of parent-directory paths to anchors.
/// Built after the first analysis pass; applied as a second pass.
struct FolderAffinity: Sendable, Equatable {
    /// Per-folder anchors, keyed by parent directory path (deletingLastPathComponent).
    var anchors: [String: FolderAnchor]

    /// Look up the anchor for a given file's parent folder.
    func anchor(for url: URL) -> FolderAnchor? {
        let parent = url.deletingLastPathComponent().path
        return anchors[parent]
    }

    /// Build folder affinity from a batch of (URL, verdict, confidence,
    /// bandPeaks) tuples. For each parent folder, the anchor is picked
    /// by CROSS-TRACK SUPPORT: the verdict with the highest sum of
    /// cross-band direct support across other tracks in the folder
    /// wins. "Highest single confidence" is wrong for remix singles
    /// (several sibling variants can all return high-confidence
    /// dominant verdicts while the one correct variant is
    /// low-confidence), and "count of tracks with a peak" fails
    /// because peaks are dense (every track's bandPeaks have many
    /// entries at every other candidate's BPM within ±3%). The SUM of
    /// cross-band peak strengths discriminates: the truth tempo is
    /// present in all variants' cross-band peaks, while the artifacts
    /// are only strongly present where they're dominant.
    static func build(from results: [(url: URL, bpm: Double, confidence: Double, bandPeaks: [[(bpm: Double, frac: Float)]])]) -> FolderAffinity {
        var byFolder: [String: [(bpm: Double, confidence: Double, url: URL, bandPeaks: [[(bpm: Double, frac: Float)]])]] = [:]
        for r in results {
            let parent = r.url.deletingLastPathComponent().path
            byFolder[parent, default: []].append((r.bpm, r.confidence, r.url, r.bandPeaks))
        }
        var anchors: [String: FolderAnchor] = [:]
        let tol = BPMEngine.bpmMatchTolerance
        for (folder, results) in byFolder {
            // Bail on VAs / large collections per-folder. Folder affinity
            // is calibrated on real albums (< 20 tracks) and over-flips on
            // 100+ track drops where the cross-track support winner is just
            // the most-common verdict, not a real album-tempo prior. The
            // check is PER-FOLDER (not on the total results count) so a
            // batch that mixes folders still forms anchors for
            // small-album folders.
            if results.count > maxFolderSizeForPrior {
                continue
            }
            // For each candidate verdict, compute the SUM of cross-band
            // direct support across all OTHER tracks in the folder. The
            // candidate with the highest total is the anchor. The SUM (not
            // a count of tracks with a peak) discriminates: peaks are dense
            // (every track's bandPeaks have entries at every other
            // candidate's BPM within ±tol), so a count ties across
            // candidates. The truth tempo's cross-band peaks are stronger
            // (present in multiple bands with higher fracs) while the
            // artifact tempo is concentrated in one band (LOW usually).
            func directSupport(of candidate: Double, in peaks: [[(bpm: Double, frac: Float)]]) -> Float {
                BPMEngine.directSupport(candidate, bandPeaks: peaks)
            }
            var totalSupport: [Double: Float] = [:]
            for r1 in results {
                for r2 in results where r2.url != r1.url {
                    let s = directSupport(of: r1.bpm, in: r2.bandPeaks)
                    if s > 0 {
                        totalSupport[r1.bpm, default: 0] += s
                    }
                }
            }
            // The candidate with the most total support is the anchor.
            guard let (anchorBPM, _) = totalSupport.max(by: { $0.value < $1.value }) else { continue }
            // The anchor must be supported by at least 1 other track
            // (count of tracks where support > 0). A singleton folder
            // has 0 supporting tracks and no folder signal — skip.
            // A 2-track folder has 1 supporting track — that's enough
            // to form the anchor (e.g. t_798aaf4cd2 final+dub).
            let sourceURL = results.first(where: { abs($0.bpm - anchorBPM) <= tol * anchorBPM })?.url
            let supportingTracks = results.filter { r in
                r.url != sourceURL && directSupport(of: anchorBPM, in: r.bandPeaks) > 0
            }.count
            guard supportingTracks >= 1 else { continue }
            // Pick the most confident verdict that matches anchorBPM as
            // the source.
            let matchingVerdicts = results.filter { abs($0.bpm - anchorBPM) <= tol * anchorBPM }
            guard let best = matchingVerdicts.max(by: { $0.confidence < $1.confidence }) else { continue }
            let avgConf = matchingVerdicts.reduce(0.0) { $0 + $1.confidence } / Double(matchingVerdicts.count)
            guard avgConf >= anchorConfidenceThreshold else { continue }
            anchors[folder] = FolderAnchor(
                bpm: best.bpm,
                confidence: avgConf,
                trackCount: results.count,
                sourceURL: best.url
            )
        }
        return FolderAffinity(anchors: anchors)
    }

    /// Minimum confidence for a verdict to qualify as a folder anchor.
    /// Below this, the track isn't reliable enough to anchor the folder.
    /// 0.4, not 0.5: the confidence aggregation gives some clean verdicts
    /// (e.g. a truth-carrying singleton in a remix single) ~0.45 — a 0.5
    /// floor would block the anchor from forming and the sibling variants
    /// would have no anchor to flip to. The 0.4 floor is safe because
    /// applyFolderAffinity's cross-band check
    /// (minAnchorCrossBandSupport=0.5) is the real guard against
    /// coincidence — a low-confidence anchor only fires when the target
    /// track has strong cross-band evidence of the anchor's tempo.
    static let anchorConfidenceThreshold: Double = 0.4
    /// Minimum cross-band support the anchor must have in a target track
    /// for the flip to fire. Below this, the anchor isn't "really there"
    /// in the track (might be coincidence).
    static let minAnchorCrossBandSupport: Float = 0.5
    /// Maximum folder size for the anchor prior. Folders larger than this
    /// (VAs, large collections) skip the prior entirely: with size
    /// unlimited, the cross-track support winner of a 173-file batch
    /// becomes a generic "common" tempo and ×4/3-flips distinct tracks
    /// that are actually half-speed feels. Real albums are < 20 tracks;
    /// VAs and large collections are > 20. Users can split VAs into
    /// sub-folders if they want per-album priors.
    static let maxFolderSizeForPrior: Int = 20
}
