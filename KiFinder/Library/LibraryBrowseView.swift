import AppKit
import SwiftUI

/// Browses the persistent kept-photo library (item 18b), restyled in item 26a to look
/// and behave like the scanned/review grid: review-style cells grouped **by person →
/// month**, keyboard **focus + arrow navigation**, **click selects** a cell (it does NOT
/// auto-open a viewer), and **Space opens the full photo IN-PLACE** (replacing the grid)
/// with **Esc/Back** to return. The grouped data, the library focus/preview state, and
/// every store op live on `AppModel`; this view is the on-device presentation.
struct LibraryBrowseView: View {
    let model: AppModel

    /// What a pending remove-confirmation will act on, if any. Cells + the preview remove
    /// a SPECIFIC photo; the Delete key removes the keyboard-focused cell and re-seats the
    /// cursor to the next entry (item 26b).
    private enum PendingRemoval {
        /// A specific cell's / the preview's photo.
        case item(LibraryPhotoItem)
        /// The keyboard-focused cell (Delete key) — re-seats focus to the NEXT entry.
        case focused
    }

    /// The pending remove confirmation, if any (item-18b affordance retained + item-26b
    /// Delete key).
    @State private var pendingRemoval: PendingRemoval?

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 12), count: max(1, model.columnCount))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.hasLibrarySelection {
                LibrarySelectionBar(
                    count: model.librarySelectionCount,
                    onExportPhotos: { model.exportSelectedLibraryToPhotos() },
                    onClear: { model.clearLibrarySelection() }
                )
                Divider()
            }
            content
        }
        .background(DesignColor.canvas)
        // NOTE: do NOT put `.accessibilityIdentifier("libraryBrowseView")` here — on this
        // container it PROPAGATES down and overrides child ids (libraryFullSizePreview,
        // libraryEmptyState, libraryPersonFilter all became "libraryBrowseView"). The id
        // lives on the header title (a leaf) instead; child ids then survive.
        // Window-level key capture (the SAME view ReviewSurface uses) so arrow / Space /
        // Esc always land on the library handle regardless of SwiftUI focus.
        .background(KeyCaptureView(onCommand: handle))
        .confirmationDialog(
            "Remove this photo from your library?",
            isPresented: removalBinding,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                switch pendingRemoval {
                case let .item(item):
                    // A specific cell / the preview: remove that photo and (if open) return
                    // the preview to the grid.
                    model.removeFromLibrary(item.entry)
                    model.closeLibraryPreview()
                case .focused:
                    // The Delete key OR the in-place preview's Remove (the previewed entry IS
                    // the focused one): remove it, re-seat focus to the NEXT entry, and return
                    // the preview to the grid (a no-op when the preview isn't open).
                    model.removeFocusedFromLibrary()
                    model.closeLibraryPreview()
                case nil:
                    break
                }
                pendingRemoval = nil
            }
            .accessibilityIdentifier("confirmRemoveFromLibraryButton")
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
                .accessibilityIdentifier("cancelRemoveFromLibraryButton")
        } message: {
            Text("The saved copy is deleted from disk. You can keep it again later.")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Library")
                    .kionFont(20, weight: .semibold, design: .rounded)
                    // The library-open marker, on a LEAF (no propagation to child ids).
                    .accessibilityIdentifier("libraryBrowseView")
                Text("Saved photos, grouped by person and month")
                    .kionFont(12)
                    .foregroundStyle(DesignColor.inkSecondary)
            }
            Spacer(minLength: 0)
            filterPicker
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var filterPicker: some View {
        Picker("Person", selection: filterBinding) {
            Text("All people").tag(String?.none)
            ForEach(model.people) { person in
                Text(person.displayName).tag(String?.some(person.id))
            }
        }
        .pickerStyle(.menu)
        .frame(maxWidth: 220)
        .accessibilityIdentifier("libraryPersonFilter")
    }

    @ViewBuilder
    private var content: some View {
        if model.libraryPreviewActive, let focused = model.libraryFocusedItem {
            // Center takeover: the focused photo fills the grid region (review-style),
            // returning to the grid on Esc or the Back control.
            LibraryInPlacePreview(
                item: focused,
                onBack: { model.closeLibraryPreview() },
                onReveal: { reveal(focused) },
                // The previewed entry IS the focused one — use the next-entry re-seat path
                // (and close the preview), matching the Delete key rather than the generic
                // first-entry re-seat of a cell removal.
                onRemove: { pendingRemoval = .focused }
            )
        } else if model.libraryGroups.isEmpty {
            emptyState
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        ForEach(model.libraryGroups) { person in
                            personSection(person)
                        }
                    }
                    .padding(20)
                }
                // Keep the keyboard-focused cell visible as arrow nav moves it.
                .onChange(of: model.libraryFocusedID) { _, id in
                    guard let id else { return }
                    withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
    }

    private func personSection(_ person: LibraryPersonGroup) -> some View {
        // Sections by person, sub-sections by month — built from PLAIN VStacks + header
        // VIEWS (not SwiftUI `Section`s) and a non-pinned LazyVStack, exactly like the
        // review grid's CandidateSection. Wrapping nested LazyVGrids in pinned
        // `Section` headers mis-measures on macOS and blanks/overlaps later sections.
        VStack(alignment: .leading, spacing: 16) {
            Text(person.personName)
                .kionFont(15, weight: .semibold)
                .foregroundStyle(DesignColor.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(person.months) { month in
                VStack(alignment: .leading, spacing: 8) {
                    Text(month.month)
                        .kionFont(13, weight: .semibold)
                        .foregroundStyle(DesignColor.inkSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                        ForEach(month.items) { item in
                            LibraryPhotoCell(
                                item: item,
                                isFocused: model.libraryFocusedID == item.entry.id,
                                isSelected: model.selectedLibraryIDs.contains(item.entry.id),
                                onSelect: { model.selectLibrary(item.entry.id) },
                                onToggle: { model.toggleLibrarySelection(item.entry.id) },
                                onExtend: { model.extendLibrarySelection(to: item.entry.id) },
                                onReveal: { reveal(item) },
                                onRemove: { pendingRemoval = .item(item) }
                            )
                            // Addressable so the ScrollViewReader can scroll focus into view.
                            .id(item.entry.id)
                        }
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 44))
                .foregroundStyle(DesignColor.inkSecondary)
            Text("Your library is empty")
                .kionFont(17, weight: .semibold)
            Text("Keep a photo while reviewing a person to save it here.")
                .kionFont(13)
                .foregroundStyle(DesignColor.inkSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
        // Contain the child Text/Image so the container id is itself queryable
        // (otherwise the children shadow it, like the item-17 SelectionBar fix).
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("libraryEmptyState")
    }

    private var removalBinding: Binding<Bool> {
        Binding(
            get: { pendingRemoval != nil },
            set: { if !$0 { pendingRemoval = nil } }
        )
    }

    private var filterBinding: Binding<String?> {
        Binding(
            get: { model.libraryFilterSubjectID },
            set: { model.setLibraryFilter($0) }
        )
    }

    private func reveal(_ item: LibraryPhotoItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    // MARK: - Keyboard

    /// Routes window-level key commands to the LIBRARY focus/preview ops (kept separate
    /// from the review handle). Keep (Return) is a no-op here; Skip (Delete) removes the
    /// focused cell behind a confirmation (item 26b) — it never maps to the review grid's
    /// `skipFocused`.
    private func handle(_ command: KeyCommand) {
        switch command {
        case .left: model.moveLibraryLeft()
        case .right: model.moveLibraryRight()
        case .up: model.moveLibraryUp()
        case .down: model.moveLibraryDown()
        case .preview: model.toggleLibraryPreview()
        case .close: model.closeLibraryPreview()
        // Manual-region drawing is a review-only affordance; the library grid ignores it.
        case .keep, .keepWithoutMatch, .drawRegion, .removeRegion: break
        case .skip:
            // Delete removes the focused library cell behind the existing confirmation;
            // a no-op when nothing is focused.
            if model.libraryFocusedID != nil { pendingRemoval = .focused }
        }
    }
}

/// The library bulk-action bar, shown only while the grid has a multi-selection (item
/// 28): a Clear, the selected count, and a single **Export Selected to Photos** button.
/// Library export is Photos only (the saved copies already live on disk), so there is NO
/// folder option and NO skip — the leaner mirror of the review grid's `SelectionBar`.
private struct LibrarySelectionBar: View {
    let count: Int
    let onExportPhotos: () -> Void
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button("Clear", systemImage: "xmark.circle") { onClear() }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("clearLibrarySelectionButton")
            Text("\(count) selected")
                .kionFont(13, weight: .medium)
                .accessibilityIdentifier("librarySelectionCount")
            Spacer()
            Button("Export Selected to Photos", systemImage: "photo.badge.plus") {
                onExportPhotos()
            }
            .buttonStyle(.borderedProminent)
            .tint(DesignColor.ink)
            .foregroundStyle(DesignColor.inkInverse)
            .accessibilityIdentifier("exportSelectedLibraryButton")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(DesignColor.keep.opacity(0.08))
        // Expose the child button/count ids to XCUITest; a bare container id otherwise
        // shadows them.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("librarySelectionBar")
    }
}

/// One saved photo in the grid, styled like the review `PhotoTile`: a downsampled
/// thumbnail (reusing `CandidateImage.downsample`), the filename, the card/border
/// treatment, and a keyboard focus ring on the focused cell. Clicking the cell FOCUSES
/// it (it does NOT auto-open the preview — Space does that). The item-18b reveal / remove
/// affordances are retained (their review-style relocation is item 26b). A stale entry
/// (file gone) shows a missing-file placeholder but is still removable.
private struct LibraryPhotoCell: View {
    let item: LibraryPhotoItem
    let isFocused: Bool
    let isSelected: Bool
    let onSelect: () -> Void
    let onToggle: () -> Void
    let onExtend: () -> Void
    let onReveal: () -> Void
    let onRemove: () -> Void

    @State private var thumbnail: NSImage?

    private var photoIdentifier: String {
        "libraryPhoto-\(item.entry.id)"
    }

    /// Stable a11y marker that distinguishes a selected cell from an unselected one,
    /// present only while the cell is selected (item 28).
    private var selectionMarkerIdentifier: String {
        "librarySelected-\(item.entry.id)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                Color.clear
                    .aspectRatio(ReviewGridLayout.imageAspectRatio, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .overlay { thumbnailBody }
                    .background(DesignColor.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(DesignColor.hairline, lineWidth: 1)
                    }
                    .overlay(alignment: .topTrailing) { selectionBadge }
            }

            HStack {
                Text(item.entry.fileName)
                    .kionFont(13, design: .monospaced)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                Button(action: onReveal) {
                    Label("Reveal in Finder", systemImage: "magnifyingglass")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help("Reveal in Finder")
                .accessibilityIdentifier("libraryRevealButton")

                Button(role: .destructive, action: onRemove) {
                    Label("Remove", systemImage: "trash")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help("Remove from library")
                .accessibilityIdentifier("removeFromLibraryButton")
            }
            .kionFont(12)
            .foregroundStyle(DesignColor.inkSecondary)
        }
        .padding(8)
        .frame(minWidth: 44, minHeight: 44)
        .background(DesignColor.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(DesignColor.hairline)
        }
        .overlay { selectionRing }
        .overlay { focusRing }
        .contentShape(RoundedRectangle(cornerRadius: 8))
        // Modifier clicks mirror the review grid (item 17): ⌘ toggles, ⇧ extends from
        // the anchor. The plain tap is the fallback — it selects + focuses the cell (it
        // does NOT open the preview; Space does).
        .gesture(TapGesture().modifiers(.command).onEnded { onToggle() })
        .gesture(TapGesture().modifiers(.shift).onEnded { onExtend() })
        .onTapGesture(perform: onSelect)
        .contextMenu {
            Button("Reveal in Finder", action: onReveal)
            Button("Remove from Library", role: .destructive, action: onRemove)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(photoIdentifier)
        .task(id: item.url) { await loadThumbnail() }
    }

    /// A filled checkmark in the top-trailing corner when the cell is selected, carrying
    /// the stable selection marker id so a UI test can tell selected from unselected.
    @ViewBuilder
    private var selectionBadge: some View {
        if isSelected {
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .symbolRenderingMode(.palette)
                .foregroundStyle(DesignColor.inkInverse, DesignColor.keep)
                .padding(6)
                .accessibilityIdentifier(selectionMarkerIdentifier)
        }
    }

    /// A keep-tinted ring around the whole cell while it is selected (distinct from the
    /// keyboard focus ring).
    @ViewBuilder
    private var selectionRing: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: 10)
                .stroke(DesignColor.keep, lineWidth: 2)
                .padding(-1)
        }
    }

    private var thumbnailBody: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(DesignColor.hairline)
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .scaledToFit()
            } else if !item.fileExists {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title2)
                    .foregroundStyle(DesignColor.inkSecondary)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// Visible keyboard focus ring, drawn like a review tile's.
    @ViewBuilder
    private var focusRing: some View {
        if isFocused {
            RoundedRectangle(cornerRadius: 10)
                .stroke(DesignColor.keep, lineWidth: 3)
                .padding(-3)
        }
    }

    private func loadThumbnail() async {
        guard item.fileExists else {
            thumbnail = nil
            return
        }
        let url = item.url
        thumbnail = await Task.detached(priority: .userInitiated) {
            CandidateImage.downsample(url: url, maxPixel: 320)
        }.value
    }
}

/// The in-place full-size preview (item 26a): a plain image of the saved file (NO face
/// boxes — library entries carry none) that takes over the grid region, with a Back
/// control that returns to the grid. Esc closes it too (via the window key capture).
private struct LibraryInPlacePreview: View {
    let item: LibraryPhotoItem
    let onBack: () -> Void
    let onReveal: () -> Void
    let onRemove: () -> Void

    @State private var image: NSImage?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    onBack()
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("libraryBackButton")
                Spacer(minLength: 0)
                Text(item.entry.fileName)
                    .kionFont(13, weight: .semibold)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Button(action: onReveal) {
                    Label("Reveal in Finder", systemImage: "magnifyingglass")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help("Reveal in Finder")
                .accessibilityIdentifier("libraryRevealButton")
                Button(role: .destructive, action: onRemove) {
                    Label("Remove", systemImage: "trash")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help("Remove from library")
                .accessibilityIdentifier("removeFromLibraryButton")
            }
            .padding(12)
            Divider()
            ZStack {
                DesignColor.canvas
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(16)
                } else if !item.fileExists {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 44))
                        .foregroundStyle(DesignColor.inkSecondary)
                } else {
                    ProgressView()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DesignColor.canvas)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("libraryFullSizePreview")
        .accessibilityLabel(item.entry.fileName)
        .task(id: item.url) { await load() }
    }

    private func load() async {
        guard item.fileExists else {
            image = nil
            return
        }
        let url = item.url
        image = await Task.detached(priority: .userInitiated) {
            CandidateImage.downsample(url: url, maxPixel: 2000)
        }.value
    }
}
