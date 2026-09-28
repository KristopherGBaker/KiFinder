import SwiftUI

/// The live, mutable review decision for a candidate.
///
/// Distinct from `Candidate.bucket` (the engine's *initial* classification) so a
/// decision stays reversible until export: a kept photo can be skipped and a
/// skipped photo re-kept without losing the original candidate metadata.
enum ReviewState: String, Equatable {
    case keep
    case maybe
    /// Scanned but didn't match — shown so nothing is hidden; can still be kept.
    case other
    case skipped

    init(bucket: ReviewBucket) {
        switch bucket {
        case .keep: self = .keep
        case .maybe: self = .maybe
        case .other: self = .other
        }
    }

    /// Human-facing section/bucket name shown in the grid, tiles, and lightbox.
    var displayName: String {
        switch self {
        case .keep: String(localized: "Found matches")
        case .maybe: String(localized: "Worth a look")
        case .other: String(localized: "The rest")
        case .skipped: String(localized: "Skipped")
        }
    }

    var symbolName: String {
        switch self {
        case .keep: "checkmark.circle.fill"
        case .maybe: "smallcircle.filled.circle"
        case .other: "circle"
        case .skipped: "minus.circle"
        }
    }

    var tint: Color {
        switch self {
        case .keep: DesignColor.keep
        case .maybe: DesignColor.maybe
        case .other: DesignColor.inkSecondary
        case .skipped: DesignColor.inkSecondary
        }
    }

    /// Per-section hint copy shown next to the header count.
    var sectionHint: String {
        switch self {
        case .keep: String(localized: "Auto-selected · quick confirm")
        case .maybe: String(localized: "Never hidden · press Return to keep")
        case .other: String(localized: "Didn't match · press Return to keep")
        case .skipped: String(localized: "Reversible · press Return to re-keep")
        }
    }
}
