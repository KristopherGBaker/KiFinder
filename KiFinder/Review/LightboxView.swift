import AppKit
import SwiftUI

/// Trailing inspector lightbox for a single candidate: large preview with an
/// amber detected-face overlay, a confidence chip, and Skip / Keep actions.
/// Content scrolls while the actions stay pinned, so the controls remain
/// reachable even at the largest Dynamic Type sizes.
struct LightboxView: View {
    let candidate: Candidate
    let state: ReviewState
    let position: Int
    let total: Int
    let onSkip: () -> Void
    let onKeep: () -> Void
    /// Keeps the focused photo into the library WITHOUT teaching the engine (item 37),
    /// for a photo whose face can't be selected. No-op default keeps call sites terse.
    var onKeepWithoutMatch: () -> Void = {}
    /// Called with the index of a face the user tapped in the preview.
    var onSelectFace: (Int) -> Void = { _ in }
    /// Called with a normalized raw top-left rect when the user draws a region (item
    /// 19); `nil` disables the draw affordance.
    var onDrawRegion: ((CGRect) -> Void)?
    /// The `faceBoxes` index of the active person's manual box, if any.
    var manualFaceIndex: Int?
    /// Removes the active person's manual box.
    var onRemoveManualRegion: (() -> Void)?
    /// Whether this photo's source is already in the active person's library (item
    /// 18a) — drives the inspector's "already saved" marker.
    var isInLibrary = false
    /// Whether the item-21 resize handles are offered on the manual box (item 25);
    /// off by default. Passed straight through to the shared `FaceBoxedImage`.
    var manualResizeEnabled = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                preview
                if candidate.faceBoxes.count > 1 {
                    faceHint
                }
                HStack(spacing: 10) {
                    ConfidenceChip(state: state, score: candidate.score)
                    if isInLibrary {
                        alreadySavedChip
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(DesignColor.surface)
        // The header + actions are pinned to the TOP of the inspector (which is
        // always within the window's visible frame, unlike the bottom edge on
        // small/off-screen windows) so Skip/Keep stay hittable at every Dynamic
        // Type size while the preview and chip scroll beneath.
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                header
                actions
                keyboardHint
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
        }
    }

    private var positionText: String {
        String(localized: "\(position) of \(total)")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(candidate.fileName)
                .kionFont(17, weight: .semibold, design: .monospaced)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .accessibilityIdentifier(candidate.fileName)
            Text(positionText)
                .kionFont(13)
                .foregroundStyle(DesignColor.inkSecondary)
                .accessibilityIdentifier("lightbox-position")
        }
    }

    private var preview: some View {
        // The shared renderer carries the load → EXIF-orient → aspect-fit → draw
        // path; the inspector keeps its tappable, re-pointable boxes and the
        // `lightboxFaceBox` / `lightboxFaceBox-<index>` identifiers.
        FaceBoxedImage(
            candidate: candidate,
            maxPixel: Self.previewMaxHeight * 2,
            onSelectFace: onSelectFace,
            identifierPrefix: "lightboxFaceBox",
            maxDisplayHeight: Self.previewMaxHeight,
            onDrawRegion: onDrawRegion,
            manualFaceIndex: manualFaceIndex,
            onRemoveManualRegion: onRemoveManualRegion,
            manualResizeEnabled: manualResizeEnabled
        )
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    /// Ceiling so a very tall portrait can't dominate the inspector; normal and
    /// landscape photos fill the pane width well below this.
    private static let previewMaxHeight: CGFloat = 560

    /// Inspector marker shown when this photo is already in the active person's
    /// library. Exposes the stable a11y id `alreadySavedMarker`.
    private var alreadySavedChip: some View {
        Label("Saved to library", systemImage: "tray.and.arrow.down.fill")
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(DesignColor.keep.opacity(0.16), in: Capsule())
            .foregroundStyle(DesignColor.keep)
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier("alreadySavedMarker")
            .accessibilityLabel("Already saved to library")
    }

    private var faceHint: some View {
        Label("Multiple faces — tap the correct one, then Keep", systemImage: "hand.tap")
            .font(.caption)
            .foregroundStyle(DesignColor.inkSecondary)
            .accessibilityIdentifier("lightboxFaceHint")
    }

    private var actions: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Button(action: onSkip) {
                    Label("Skip", systemImage: "xmark")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("Skip")

                Button(action: onKeep) {
                    Label("Keep", systemImage: "checkmark")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(DesignColor.keep)
                .accessibilityIdentifier("Keep")
            }
            // Item 37: keep into the library/export WITHOUT teaching the engine — for a
            // photo whose face is occluded/undetected and can't be selected or drawn.
            Button(action: onKeepWithoutMatch) {
                Label("Keep without a match", systemImage: "person.crop.circle.badge.questionmark")
                    .frame(maxWidth: .infinity, minHeight: 36)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("keepWithoutMatchButton")
            .help(LocalizedStringKey("Keep this photo without selecting a face — the engine won't learn from it"))
        }
    }

    private var keyboardHint: some View {
        Label {
            Text("Left/right to move · Return to keep · Delete to skip")
        } icon: {
            Image(systemName: "keyboard")
        }
        .font(.caption)
        .foregroundStyle(DesignColor.inkSecondary)
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("lightboxKeyboardHint")
        .accessibilityLabel("Left/right to move · Return to keep · Delete to skip")
    }
}

/// Shown in the always-open inspector when no photo is selected: a quiet,
/// centered prompt that also teaches the keyboard model, so the pane reads as
/// intentional rather than empty.
struct InspectorEmptyState: View {
    var body: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 0)

            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(DesignColor.inkSecondary)
                .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text("No photo selected")
                    .kionFont(17, weight: .semibold)
                    .foregroundStyle(DesignColor.ink)
                Text("Pick a photo from the grid to review it up close.")
                    .kionFont(13)
                    .foregroundStyle(DesignColor.inkSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            keyboardHint
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .background(DesignColor.surface)
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("inspectorEmptyState")
        .accessibilityLabel("No photo selected. Pick a photo from the grid to review it.")
    }

    private var keyboardHint: some View {
        Label {
            Text("Return keeps · Left/right to move · Space previews · Delete skips")
        } icon: {
            Image(systemName: "keyboard")
        }
        .font(.caption)
        .foregroundStyle(DesignColor.inkSecondary)
        .multilineTextAlignment(.center)
        .accessibilityHidden(true)
    }
}

/// Confidence chip exposing both the visible bucket name and the numeric score
/// to assistive tech without requiring hover.
private struct ConfidenceChip: View {
    let state: ReviewState
    let score: Double

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: state.symbolName)
            Text(state.displayName)
                .fontWeight(.medium)
            Text(formattedScore(score))
                .monospacedDigit()
                .foregroundStyle(DesignColor.inkSecondary)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(state.tint.opacity(0.16), in: Capsule())
        .foregroundStyle(state.tint)
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("confidenceChip")
        // macOS does not reliably surface accessibilityValue separately, so the
        // visible bucket and numeric score are both encoded in the label.
        .accessibilityLabel(String(localized: "Confidence \(state.displayName), score \(formattedScore(score))"))
        .accessibilityValue(formattedScore(score))
    }
}
