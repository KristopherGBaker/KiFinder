import AppKit
import SwiftUI

/// Formats a confidence score deterministically (locale-independent) for both
/// the visible chip and its accessibility value, e.g. `0.68`.
func formattedScore(_ score: Double) -> String {
    String(format: "%.2f", score)
}

/// Keyboard-first review grid. Focus and preview/lightbox selection live on
/// `AppModel`; an AppKit `KeyCaptureView` is the window's first responder and
/// forwards raw key codes as `KeyCommand`s. Arrow keys move focus, Return keeps,
/// Delete/Backspace skips, Space opens a full-size Quick Look-style preview over
/// the center grid (Space again or Esc closes it). The right inspector stays
/// mounted throughout. Counts/export update immediately and decisions animate.
struct ReviewSurface: View {
    let model: AppModel

    /// The real System Settings → Accessibility → Reduce Motion state. `model.reduceMotion`
    /// is the `KION_REDUCE_MOTION` test hook; a real user who turns Reduce Motion on must
    /// also get instant (unanimated) bucket moves, so the two are OR'd in `commitDecision`.
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    /// Whether a folder/zip is being dragged over the POPULATED grid. The empty
    /// state already accepts album drops; once candidates exist the same drop
    /// should still start a scan (previously it silently did nothing).
    @State private var isGridDropTargeted = false

    @Namespace private var tileNamespace

    /// The review actions now live in the native window toolbar (item 78), so their
    /// popover/confirmation-dialog presentation state moves onto the surface.
    @State private var showExportOptions = false
    @State private var showShortcuts = false

    private var columns: Int {
        max(1, model.columnCount)
    }

    /// Person-aware window title, with a neutral fallback when no one is active.
    /// Byte-identical to the copy the removed in-content `ReviewToolbar` computed,
    /// so `Localizable.xcstrings` needs no new keys.
    private var title: String {
        guard let personName = model.activePersonName else { return String(localized: "Review candidates") }
        return String(localized: "Review \(personName) candidates")
    }

    /// Window subtitle: the confident/worth-a-look/total summary when there are
    /// candidates, otherwise the person-aware scan prompt. Same localized strings
    /// the old toolbar used.
    private var subtitle: String {
        let personName = model.activePersonName
        guard model.hasCandidates else {
            guard let personName else { return String(localized: "Scan an album to find your people") }
            return String(localized: "Scan an album to find \(personName)")
        }
        let keepCount = model.keepCount
        let maybeCount = model.maybeCount
        let totalPhotoCount = model.totalPhotoCount
        return String(localized: "\(keepCount) confident + \(maybeCount) worth a look from \(totalPhotoCount) photos")
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.hasSelection {
                SelectionBar(
                    count: model.selectionCount,
                    onKeep: { commitDecision { model.keepSelected() } },
                    onSkip: { commitDecision { model.skipSelected() } },
                    onExportFolder: exportSelectedToFolder,
                    onExportPhotos: { model.exportSelectedToPhotos() },
                    onClear: { model.clearSelection() }
                )
                Divider()
            }
            if model.hasCandidates {
                if model.pendingPromotionCount > 0 {
                    PromotionBanner(count: model.pendingPromotionCount) {
                        withAnimation(.easeInOut(duration: 0.25)) { model.applyPendingPromotions() }
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        grid
                            .padding()
                    }
                    .background(DesignColor.canvas)
                    // While the full-size preview overlays the grid, the covered tiles
                    // must leave the accessibility tree too — VoiceOver (and XCUITest)
                    // should see only the preview, not the grid it hides.
                    .accessibilityHidden(model.isPreviewPresented)
                    // Dropping a folder/zip onto the populated grid starts a scan, just
                    // like the empty state — the affordance shouldn't vanish the moment
                    // candidates exist (that's exactly when users reach for it).
                    .overlay {
                        if isGridDropTargeted {
                            RoundedRectangle(cornerRadius: 16)
                                .strokeBorder(DesignColor.keep, style: StrokeStyle(lineWidth: 2, dash: [8, 5]))
                                .padding(12)
                                .allowsHitTesting(false)
                        }
                    }
                    .dropDestination(for: URL.self) { urls, _ in
                        guard !urls.isEmpty else { return false }
                        model.scanDroppedAlbums(urls)
                        return true
                    } isTargeted: { isGridDropTargeted = $0 }
                    // Keep the keyboard-focused tile visible: arrow navigation and the
                    // keep-advance both move focusedID, and this scrolls it into view.
                    .onChange(of: model.focusedID) { _, id in
                        guard let id else { return }
                        withAnimation(.easeInOut(duration: 0.2)) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
                // The full-size preview OVERLAYS the grid rather than replacing it, so
                // the ScrollView stays mounted and keeps its exact native scroll offset.
                // Closing the preview (Space/Esc) simply reveals the grid right where the
                // user left it — no scroll reset, no re-centering approximation (item 46,
                // bug 1). photoPreview is opaque (its own canvas background), so it fully
                // covers the grid and captures taps (face selection) while presented.
                .overlay {
                    if model.isPreviewPresented,
                       let id = model.focusedID,
                       let candidate = model.candidate(for: id)
                    {
                        photoPreview(candidate)
                    }
                }
            } else {
                ReviewEmptyState(
                    personName: model.activePersonName,
                    onScan: { model.presentScan() },
                    onDropAlbums: { model.scanDroppedAlbums($0) }
                )
            }
        }
        .animation(.easeInOut(duration: 0.25), value: model.pendingPromotionCount)
        // Window-level key capture so arrow/Space/Delete/Return/Esc always land,
        // regardless of which SwiftUI element nominally holds focus.
        .background(KeyCaptureView(onCommand: handle))
        // The inspector stays open at all times; it shows the lightbox for the
        // selected photo, or a calm empty state when nothing is selected.
        .inspector(isPresented: .constant(true)) { inspector }
        // Title/subtitle are the native window chrome (item 78): macOS renders them
        // in the titlebar/toolbar and clamps them itself, so they never clip or
        // wrap the way the old in-content capsule did at the 1000×640 default size.
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        // The review actions are native toolbar items — macOS lays them out, groups
        // them under Liquid Glass, and overflows to a menu when the window is narrow.
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if model.hasCandidates {
                    // A toolbar toggle button (not a `.switch`, which macOS won't
                    // render in a toolbar) for hiding already-reviewed photos.
                    Toggle("Hide reviewed", systemImage: "eye.slash", isOn: Binding(
                        get: { model.hideAlreadyReviewed },
                        set: { model.hideAlreadyReviewed = $0 }
                    ))
                    .toggleStyle(.button)
                    .help("Hide photos you've already kept or skipped, even from earlier scans")
                    .accessibilityIdentifier("hideReviewedToggle")

                    Button("Keyboard", systemImage: "keyboard") { showShortcuts.toggle() }
                        .accessibilityIdentifier("Keyboard")
                        .popover(isPresented: $showShortcuts, arrowEdge: .bottom) {
                            KeyboardShortcutsPopover()
                        }

                    // Item 50: re-run the (item-49 scoped) match re-score on demand —
                    // distinct from "Re-scan", which re-reads the album from disk.
                    // Enabled once the user has kept/skipped; surfaces the promotion
                    // banner when new matches appear.
                    Button("Find new matches", systemImage: "sparkles") { model.rescoreNow() }
                        .disabled(!model.hasUnscoredDecisions)
                        .help(model.hasUnscoredDecisions
                            ? LocalizedStringKey("Re-score undecided photos for new matches")
                            : LocalizedStringKey("Keep or skip a photo to find new matches"))
                        .accessibilityIdentifier("findNewMatches")

                    Button("Re-scan", systemImage: "arrow.clockwise") { model.presentScan() }
                        .accessibilityIdentifier("Re-scan")

                    // A plain Button (queryable as `app.buttons["Export N Kept"]`) that
                    // opens a destination chooser — a Menu does not surface as a button.
                    // Stays visible but disabled until at least one photo is kept.
                    Button("Export \(model.keepCount) Kept", systemImage: "square.and.arrow.up") {
                        showExportOptions = true
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.keepCount == 0)
                    .help(model.keepCount == 0
                        ? LocalizedStringKey("Keep at least one photo to export")
                        : LocalizedStringKey("Export the kept photos"))
                    .accessibilityIdentifier("Export \(model.keepCount) Kept")
                    .confirmationDialog(
                        "Export \(model.keepCount) kept photos",
                        isPresented: $showExportOptions,
                        titleVisibility: .visible
                    ) {
                        Button("Export to Folder…") { exportToFolder() }
                            .accessibilityIdentifier("Export to Folder…")
                        Button("Add to Photos") { model.exportKeptToPhotos() }
                            .accessibilityIdentifier("Add to Photos")
                        Button("Cancel", role: .cancel) {}
                    }
                }
            }
        }
    }

    private var grid: some View {
        LazyVStack(alignment: .leading, spacing: 24) {
            CandidateSection(
                model: model,
                state: .keep,
                count: model.keepCount,
                candidates: model.keepCandidateDetails,
                focusedID: model.focusedID,
                columns: columns,
                namespace: tileNamespace,
                onActivate: activate
            )
            // "Worth a look" is rendered unconditionally so it is never auto-hidden.
            CandidateSection(
                model: model,
                state: .maybe,
                count: model.maybeCount,
                candidates: model.maybeCandidateDetails,
                focusedID: model.focusedID,
                columns: columns,
                namespace: tileNamespace,
                onActivate: activate
            )
            // "The rest" — every other scanned photo, so nothing is hidden.
            if !model.otherCandidateDetails.isEmpty {
                CandidateSection(
                    model: model,
                    state: .other,
                    count: model.otherCandidateDetails.count,
                    candidates: model.otherCandidateDetails,
                    focusedID: model.focusedID,
                    columns: columns,
                    namespace: tileNamespace,
                    onActivate: activate
                )
            }
            if !model.skippedCandidateDetails.isEmpty {
                CandidateSection(
                    model: model,
                    state: .skipped,
                    count: model.skippedCandidateDetails.count,
                    candidates: model.skippedCandidateDetails,
                    focusedID: model.focusedID,
                    columns: columns,
                    namespace: tileNamespace,
                    onActivate: activate
                )
            }
        }
    }

    /// Full-size Quick Look-style preview of the focused photo, occupying the
    /// center content area in place of the grid. It reuses the shared
    /// `FaceBoxedImage` so every detected face is outlined over the aspect-fit,
    /// EXIF-corrected displayed image (boxes track the displayed image rect, not
    /// the padded container) — the active person's matched face emphasized and the
    /// rest shown as secondary outlines. Tapping a non-selected outline selects
    /// that face (item 46). The candidate is already personalized to the active
    /// person (its `selectedFaceIndex`), so each person sees their own face boxed.
    /// Tapping a non-selected face box selects it as the active person's match —
    /// the same wiring as the inspector `LightboxView` (item 46).
    private func photoPreview(_ candidate: Candidate) -> some View {
        FaceBoxedImage(
            candidate: candidate,
            maxPixel: 2000,
            onSelectFace: { faceIndex in model.selectFace(candidate, faceIndex: faceIndex) },
            identifierPrefix: "previewFaceBox",
            maxDisplayHeight: nil,
            onDrawRegion: { model.addManualRegion(to: candidate, normalizedRect: $0) },
            manualFaceIndex: model.manualFaceIndex(for: candidate),
            onRemoveManualRegion: { model.removeManualRegion(from: candidate) },
            manualResizeEnabled: model.manualRegionResizeEnabled,
            // The 'R' shortcut and the on-screen drawRegionButton share this arm state.
            isDrawingArmed: Binding(
                get: { model.isDrawingManualRegion },
                set: { model.isDrawingManualRegion = $0 }
            )
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .background(DesignColor.canvas)
        .clipped()
        // `.contain` (not `.ignore`) so the per-face outlines remain queryable by
        // their `previewFaceBox` / `previewFaceBox-<index>` identifiers while the
        // preview itself keeps its id and the fileName label.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("photoPreview")
        .accessibilityLabel(candidate.fileName)
    }

    private var inspector: some View {
        Group {
            if let id = model.selectedCandidateID,
               let candidate = model.candidate(for: id),
               let position = model.position(of: id)
            {
                LightboxView(
                    candidate: candidate,
                    state: model.state(for: id),
                    position: position,
                    total: model.orderedCount,
                    onSkip: { commitDecision { model.skip(candidate) } },
                    onKeep: { commitDecision { model.keep(candidate) } },
                    onKeepWithoutMatch: { commitDecision { model.keepWithoutMatchFocused() } },
                    onSelectFace: { faceIndex in model.selectFace(candidate, faceIndex: faceIndex) },
                    onDrawRegion: { model.addManualRegion(to: candidate, normalizedRect: $0) },
                    manualFaceIndex: model.manualFaceIndex(for: candidate),
                    onRemoveManualRegion: { model.removeManualRegion(from: candidate) },
                    isInLibrary: model.isInLibrary(id),
                    manualResizeEnabled: model.manualRegionResizeEnabled
                )
                // Backup Esc handler in case focus is ever pulled into the inspector.
                .onExitCommand { model.closeLightbox() }
            } else {
                InspectorEmptyState()
            }
        }
        .inspectorColumnWidth(min: 340, ideal: 400, max: 560)
    }

    // MARK: - Keyboard

    private func handle(_ command: KeyCommand) {
        switch command {
        case .left: model.moveLeft()
        case .right: model.moveRight()
        case .up: model.moveUp()
        case .down: model.moveDown()
        case .keep: commitDecision { model.keepFocused() }
        case .keepWithoutMatch: commitDecision { model.keepWithoutMatchFocused() }
        case .skip: commitDecision { model.skipFocused() }
        case .preview: model.togglePreview()
        case .close: model.escape()
        case .drawRegion: model.toggleManualRegionDrawing()
        case .removeRegion: model.removeFocusedManualRegion()
        }
    }

    // MARK: - Pointer

    private func activate(_ candidate: Candidate) {
        model.open(candidate.id)
    }

    // MARK: - Export

    /// Exports the kept files to a folder: straight to the test-named directory
    /// when `KION_EXPORT_DEST` is set, otherwise via the system folder picker.
    private func exportToFolder() {
        if let dest = model.testExportDest {
            model.exportKept(toFolder: dest)
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Export")
        if panel.runModal() == .OK, let url = panel.url {
            model.exportKept(toFolder: url)
        }
    }

    /// Exports the multi-selected files to a folder: straight to the test-named
    /// directory when `KION_EXPORT_DEST` is set, otherwise via the system picker.
    private func exportSelectedToFolder() {
        if let dest = model.testExportDest {
            model.exportSelected(toFolder: dest)
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Export")
        if panel.runModal() == .OK, let url = panel.url {
            model.exportSelected(toFolder: url)
        }
    }

    /// Applies a state mutation with an animated bucket move, falling back to an
    /// instant (but still complete) change under Reduce Motion.
    private func commitDecision(_ action: () -> Void) {
        if model.reduceMotion || systemReduceMotion {
            action()
        } else {
            withAnimation(.snappy) { action() }
        }
    }
}

/// Bulk-action bar shown only while the grid has a multi-selection (item 17):
/// Skip Selected + Export Selected, plus a count and a clear affordance. Absent
/// when nothing is selected (the body gates on `model.hasSelection`).
private struct SelectionBar: View {
    let count: Int
    let onKeep: () -> Void
    let onSkip: () -> Void
    let onExportFolder: () -> Void
    let onExportPhotos: () -> Void
    let onClear: () -> Void

    @State private var showExportOptions = false

    var body: some View {
        HStack(spacing: 12) {
            Button("Clear", systemImage: "xmark.circle") { onClear() }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("clearSelectionButton")
            Text("\(count) selected")
                .kionFont(13, weight: .medium)
                .accessibilityIdentifier("selectionCount")
            Spacer()
            Button("Keep Selected", systemImage: "checkmark.circle") { onKeep() }
                .accessibilityIdentifier("keepSelectedButton")
            Button("Skip Selected", systemImage: "minus.circle") { onSkip() }
                .accessibilityIdentifier("skipSelectedButton")
            Button("Export Selected", systemImage: "square.and.arrow.up") {
                showExportOptions = true
            }
            .buttonStyle(.borderedProminent)
            .tint(DesignColor.ink)
            .foregroundStyle(DesignColor.inkInverse)
            .accessibilityIdentifier("exportSelectedButton")
            .confirmationDialog(
                "Export \(count) selected photos",
                isPresented: $showExportOptions,
                titleVisibility: .visible
            ) {
                Button("Export to Folder…") { onExportFolder() }
                    .accessibilityIdentifier("Export Selected to Folder…")
                Button("Add to Photos") { onExportPhotos() }
                    .accessibilityIdentifier("Add Selected to Photos")
                Button("Cancel", role: .cancel) {}
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(DesignColor.keep.opacity(0.08))
        // Expose child button ids (skipSelectedButton/exportSelectedButton/…) to
        // XCUITest; a bare container identifier otherwise shadows them.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("selectionBar")
    }
}

/// Single source of truth for the Review grid tile's image-box layout. The
/// aspect ratio is a compile-time constant (it does NOT depend on any
/// `Candidate`), so every tile's image area is laid out to the same uniform
/// footprint regardless of the source photo's dimensions.
enum ReviewGridLayout {
    /// Width : height of every tile's image box.
    static let imageAspectRatio: CGFloat = 1.25

    /// The image box's height for a given (grid-uniform) width. Pure and
    /// candidate-independent.
    static func cellImageHeight(forWidth width: CGFloat) -> CGFloat {
        width / imageAspectRatio
    }
}

private struct CandidateSection: View {
    let model: AppModel
    let state: ReviewState
    let count: Int
    let candidates: [Candidate]
    let focusedID: String?
    let columns: Int
    let namespace: Namespace.ID
    let onActivate: (Candidate) -> Void

    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 12), count: columns)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CandidateSectionHeader(
                state: state,
                count: count,
                onSelectAll: { model.selectSection(state) },
                onSkipAll: { model.skipSection(state) }
            )
            LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 12) {
                ForEach(candidates) { candidate in
                    PhotoTile(
                        candidate: candidate,
                        state: state,
                        isFocused: focusedID == candidate.id,
                        isSelected: model.selectedPhotoIDs.contains(candidate.id),
                        isInLibrary: model.isInLibrary(candidate.id),
                        isKeptWithoutMatch: model.isKeptWithoutMatch(candidate.id),
                        namespace: namespace,
                        onActivate: { onActivate(candidate) },
                        onToggle: { model.toggleSelection(candidate.id) },
                        onExtend: { model.extendSelection(to: candidate.id) }
                    )
                    // Addressable by ScrollViewReader so keyboard focus scrolls
                    // the tile into view (even when lazily off-screen).
                    .id(candidate.id)
                }
            }
        }
    }
}

private struct CandidateSectionHeader: View {
    let state: ReviewState
    let count: Int
    let onSelectAll: () -> Void
    let onSkipAll: () -> Void

    /// Only the actionable engine sections ("Worth a look" / "The rest") get bulk
    /// header buttons; "Found matches" and "Skipped" don't.
    private var showsBulkActions: Bool {
        state == .maybe || state == .other
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: state.symbolName)
                .foregroundStyle(state.tint)
            Text(state.displayName)
                .kionFont(17, weight: .semibold)
                .accessibilityIdentifier("section-\(state.rawValue)")
            Text("\(count)")
                .kionFont(13)
                .foregroundStyle(DesignColor.inkSecondary)
            Text(state.sectionHint)
                .kionFont(13)
                .foregroundStyle(DesignColor.inkSecondary)
                .lineLimit(2)
            if showsBulkActions {
                Spacer(minLength: 8)
                Button("Select all", action: onSelectAll)
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("selectAllButton-\(state.rawValue)")
                Button("Skip all", action: onSkipAll)
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("skipAllButton-\(state.rawValue)")
            }
        }
    }
}

/// Shown before any scan (or when an album yielded nothing): an inviting prompt
/// to scan, doubling as a drop target for albums.
private struct ReviewEmptyState: View {
    /// Active person's display name (user data), or `nil` for neutral fallback copy.
    let personName: String?
    let onScan: () -> Void
    let onDropAlbums: ([URL]) -> Void

    @State private var isTargeted = false

    private var prompt: String {
        guard let personName else { return String(localized: "Scan an album to find your people") }
        return String(localized: "Scan an album to find \(personName)")
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 48, weight: .regular))
                .foregroundStyle(DesignColor.inkSecondary)
            VStack(spacing: 6) {
                Text("No photos to review yet")
                    .kionFont(20, weight: .semibold, design: .rounded)
                Text(prompt)
                    .kionFont(13)
                    .foregroundStyle(DesignColor.inkSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
            Button(action: onScan) {
                Label("Scan an album…", systemImage: "sparkle.magnifyingglass")
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(DesignColor.keep)
            .controlSize(.large)
            .accessibilityIdentifier("scanAnAlbum")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
        .background(DesignColor.canvas)
        .overlay {
            if isTargeted {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(DesignColor.keep, style: StrokeStyle(lineWidth: 2, dash: [8, 5]))
                    .padding(12)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard !urls.isEmpty else { return false }
            onDropAlbums(urls)
            return true
        } isTargeted: { isTargeted = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reviewEmptyState")
    }
}

/// Popover listing the keyboard-first culling shortcuts.
private struct KeyboardShortcutsPopover: View {
    private let shortcuts: [(key: String, action: LocalizedStringKey)] = [
        ("← →", "Move between photos"),
        ("Return", "Keep"),
        ("Space", "Open preview"),
        ("Esc", "Close preview"),
        ("Delete", "Skip"),
        ("R", "Draw a face region (in preview)"),
        ("⇧R", "Remove drawn face region"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Keyboard shortcuts")
                .kionFont(13, weight: .semibold)
            ForEach(shortcuts, id: \.key) { shortcut in
                HStack(spacing: 12) {
                    Text(shortcut.key)
                        .kionFont(12, weight: .medium, design: .monospaced)
                        .frame(width: 64, alignment: .leading)
                    Text(shortcut.action)
                        .kionFont(12)
                        .foregroundStyle(DesignColor.inkSecondary)
                }
            }
        }
        .padding(16)
        .accessibilityIdentifier("keyboardShortcuts")
    }
}

/// Quiet, keep-tinted banner that surfaces photos which now match after teaching
/// the profile — without moving anything until the user asks.
private struct PromotionBanner: View {
    let count: Int
    let onShow: () -> Void

    private var message: String {
        String(localized: "\(count) more photos now match")
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .foregroundStyle(DesignColor.keep)
            Text(message)
                .kionFont(13, weight: .medium)
            Spacer()
            Button("Show", action: onShow)
                .buttonStyle(.borderless)
                .foregroundStyle(DesignColor.keep)
                .fontWeight(.semibold)
                .accessibilityIdentifier("showPromotions")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(DesignColor.keep.opacity(0.12))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("promotionBanner")
    }
}

private struct PhotoTile: View {
    let candidate: Candidate
    let state: ReviewState
    let isFocused: Bool
    /// Whether this tile is part of the grid's multi-selection (item 17).
    let isSelected: Bool
    /// Whether this photo's source is already in the active person's library (item
    /// 18a) — drives the "already saved" marker.
    let isInLibrary: Bool
    /// Whether this photo was kept WITHOUT a face match for the active person (item
    /// 37) — drives the "kept without a match" badge.
    let isKeptWithoutMatch: Bool
    let namespace: Namespace.ID
    /// Plain click: replace the selection with this tile AND open it in the
    /// inspector (today's behavior).
    let onActivate: () -> Void
    /// ⌘-click: toggle this tile in/out of the selection (no inspector change).
    let onToggle: () -> Void
    /// ⇧-click: extend the selection from the anchor to this tile.
    let onExtend: () -> Void

    /// Bucket name plus focus/selection markers. The markers are the test-observable
    /// signals for keyboard focus and multi-selection; they survive a tile
    /// re-parenting between sections because they are plain strings, not AX traits on
    /// a button role. They are written into both label and value so whichever macOS
    /// surfaces carries them.
    private var accessibilityLabel: String {
        var base = "\(candidate.fileName), \(state.displayName)"
        // The "focused"/"selected" markers are VoiceOver-read, so they localize; en
        // stays exact, which the UI tests (run in en) match.
        if isFocused { base = String(localized: "\(base), focused") }
        if isSelected { base = String(localized: "\(base), selected") }
        return base
    }

    private var accessibilityValue: String {
        var value = state.displayName
        if isFocused { value = String(localized: "\(value), focused") }
        if isSelected { value = String(localized: "\(value), selected") }
        return value
    }

    var body: some View {
        tileContent
            .matchedGeometryEffect(id: candidate.id, in: namespace)
            .overlay { selectionRing }
            .overlay { focusRing }
            .overlay(alignment: .topLeading) { selectionCheck }
            .contentShape(RoundedRectangle(cornerRadius: 8))
            // Modifier-aware clicks: ⌘ toggles, ⇧ extends, plain click selects +
            // opens. The modified gestures take priority; the plain tap is the
            // fallback.
            .gesture(TapGesture().modifiers(.command).onEnded { _ in onToggle() })
            .gesture(TapGesture().modifiers(.shift).onEnded { _ in onExtend() })
            .onTapGesture(perform: onActivate)
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier(candidate.fileName)
            .accessibilityAddTraits(.isButton)
            // Keyboard focus + multi-selection are model state, not SwiftUI focus.
            // AXSelected is not a standard attribute of an AXButton role and surfaces
            // inconsistently across SwiftUI re-parenting (e.g. when a tile moves into
            // the Skipped section), so they are mirrored as plain "focused"/"selected"
            // markers in both the accessibility label and value — strings macOS
            // exposes dependably to XCUITest on the tile queried by identifier.
            .accessibilityLabel(accessibilityLabel)
            .accessibilityValue(accessibilityValue)
            .accessibilityHint("Return keeps · Space opens preview · Delete skips")
    }

    /// A keep-tinted ring drawn around the whole tile when it is multi-selected.
    @ViewBuilder
    private var selectionRing: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: 10)
                .stroke(DesignColor.keep, lineWidth: 3)
                .padding(-1)
        }
    }

    /// A small "already saved to library" badge (item 18a), shown when this photo's
    /// source is already in the active person's library. Exposes the stable a11y id
    /// `alreadySavedMarker`.
    @ViewBuilder
    private var alreadySavedMarker: some View {
        if isInLibrary {
            Image(systemName: "tray.and.arrow.down.fill")
                .font(.caption)
                .foregroundStyle(DesignColor.keep)
                .padding(5)
                .background(.regularMaterial, in: Circle())
                .padding(6)
                .accessibilityIdentifier("alreadySavedMarker")
                .accessibilityLabel("Already saved to library")
        }
    }

    /// A small "kept without a match" badge (item 37), shown when this photo was kept
    /// for the active person without a face match (no engine teaching). Exposes the
    /// stable a11y id `keptWithoutMatchBadge`.
    @ViewBuilder
    private var keptWithoutMatchMarker: some View {
        if isKeptWithoutMatch {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.caption)
                .foregroundStyle(DesignColor.keep)
                .padding(5)
                .background(.regularMaterial, in: Circle())
                .padding(6)
                .accessibilityIdentifier("keptWithoutMatchBadge")
                .accessibilityLabel("Kept without a match")
        }
    }

    /// A filled checkmark badge in the top-leading corner of a selected tile.
    @ViewBuilder
    private var selectionCheck: some View {
        if isSelected {
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(DesignColor.keep)
                .background(Circle().fill(.white))
                .padding(6)
                .accessibilityHidden(true)
        }
    }

    private var tileContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                // Fixed-ratio image box: a transparent spacer drives a uniform
                // `width × width/ratio` footprint for every tile (independent of
                // the source photo), and the candidate image is shown to FIT
                // inside it (whole photo visible, letterboxed) — never cropped.
                Color.clear
                    .aspectRatio(ReviewGridLayout.imageAspectRatio, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .overlay { CandidateImage(candidate: candidate, maxPixel: 600) }
                    .background(DesignColor.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .opacity(state == .skipped ? 0.5 : 1)
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(state.tint, lineWidth: 2)
                    }
                    // The "already saved" marker floats over the photo's
                    // bottom-right corner (symmetric with the top-right Keep
                    // badge) so it never overlaps the fileName + score text row.
                    .overlay(alignment: .bottomTrailing) { alreadySavedMarker }
                    // The "kept without a match" badge floats over the bottom-left
                    // corner so it never collides with the saved/keep markers.
                    .overlay(alignment: .bottomLeading) { keptWithoutMatchMarker }

                StateBadge(state: state)
                    .padding(8)
            }

            HStack {
                Text(candidate.fileName)
                    .kionFont(13, design: .monospaced)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Spacer()
                Text(formattedScore(candidate.score))
                    .kionFont(11)
                    .foregroundStyle(DesignColor.inkSecondary)
            }
        }
        .padding(8)
        .frame(minWidth: 44, minHeight: 44)
        .background(DesignColor.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(DesignColor.hairline)
        }
    }

    /// Visible keyboard focus ring drawn around the whole tile.
    @ViewBuilder
    private var focusRing: some View {
        if isFocused {
            RoundedRectangle(cornerRadius: 10)
                .stroke(DesignColor.keep, lineWidth: 3)
                .padding(-3)
        }
    }
}

private struct StateBadge: View {
    let state: ReviewState

    private var title: String {
        switch state {
        case .keep: String(localized: "Keep")
        case .maybe: String(localized: "Maybe")
        case .other: String(localized: "Other")
        case .skipped: String(localized: "Skipped")
        }
    }

    var body: some View {
        Label(title, systemImage: state.symbolName)
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.regularMaterial, in: Capsule())
            .foregroundStyle(state.tint)
    }
}

struct ResourceImage: View {
    let resourceName: String
    /// How the bundled asset is fit into its container. Defaults to `.fill` so
    /// existing call sites keep their behavior; the Review tile path passes
    /// `.fit` so sample photos are shown whole (letterboxed), never cropped.
    var contentMode: ContentMode = .fill

    var body: some View {
        if let url = Bundle.main.url(forResource: resourceName, withExtension: "png"),
           let image = NSImage(contentsOf: url)
        {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: contentMode)
        } else {
            DesignColor.hairline
                .overlay {
                    Image(systemName: "photo")
                        .font(.largeTitle)
                        .foregroundStyle(DesignColor.inkSecondary)
                }
        }
    }
}
