import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// First-run / re-enrollment sheet. Captures the person's name, collects 5–12
/// local reference photos, shows a real cropped preview per accepted photo, and
/// enrolls entirely on device. Presented over the Review surface; dismisses back
/// to it on success. Copy is name-parameterized (neutral when the name is blank).
struct EnrollmentSheet: View {
    @Bindable var model: EnrollmentModel
    /// When false the Cancel affordance is hidden — a MANDATORY enrollment (first
    /// run / delete-last-person) the user must complete rather than dismiss onto an
    /// empty Review. Defaults to true so re-enroll / add-person stay cancelable.
    var isCancelable: Bool = true
    let onCancel: () -> Void

    /// Drives the "Choose Photos…" file importer — the non-drag path into the
    /// enrollment sheet. Drag-and-drop is otherwise the only way to add references,
    /// which hard-blocks keyboard-only users inside a modal they can't cancel.
    @State private var isChoosingPhotos = false

    private var status: EnrollmentStatusCopy {
        EnrollmentStatusCopy(model.readiness, name: model.trimmedName)
    }

    /// The trimmed name, or `nil` when blank — switches the copy between the
    /// name-parameterized and the neutral phrasing.
    private var name: String? {
        let trimmed = model.trimmedName
        return trimmed.isEmpty ? nil : trimmed
    }

    var body: some View {
        VStack(spacing: 0) {
            // Scrollable content so the sheet never clips its footer as references
            // are added (the filmstrip + status grow the content past a fixed height).
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    nameField
                    steps
                    guidance
                    dropZone
                    filmstrip
                    statusRow
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            // Footer is pinned below the scroll area, so Cancel/Enroll stay visible
            // no matter how much content is above.
            footer
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
        }
        // Content-driven sizing (not a fixed 720): the scroll area already keeps the
        // footer pinned, and an ideal — rather than hard — height lets the sheet grow
        // to fit large accessibility text and shrink onto a small display instead of
        // clipping or overflowing the window's 480 pt minimum height.
        .frame(minWidth: 480, idealWidth: 560, minHeight: 420, idealHeight: 720)
        .background(DesignColor.canvas)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name.map { String(localized: "Enroll \($0)") } ?? String(localized: "Enroll a person"))
                    .kionFont(24, weight: .semibold, design: .rounded)
                    .accessibilityIdentifier("enroll-title")
                Text(name.map { String(localized: "Teach \($0)'s face to your Mac.") }
                    ?? String(localized: "Teach a face to your Mac."))
                    .kionFont(13)
                    .foregroundStyle(DesignColor.inkSecondary)
            }
            Spacer()
            LocalOnlyBadge()
        }
    }

    // MARK: - Name

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Name")
                .kionFont(12, weight: .medium)
                .foregroundStyle(DesignColor.inkSecondary)
            TextField(String(localized: "Name"), text: $model.displayName)
                .textFieldStyle(.roundedBorder)
                .kionFont(14)
                .disabled(model.isEnrolling)
                .accessibilityIdentifier("enroll-name-field")
                .accessibilityLabel(String(localized: "Name"))
        }
    }

    // MARK: - Steps

    private var steps: some View {
        VStack(alignment: .leading, spacing: 8) {
            EnrollmentStep(
                number: 1,
                text: name.map { String(localized: "Add 5–12 reference photos of \($0)") }
                    ?? String(localized: "Add 5–12 reference photos of this person"),
                identifier: "enrollment-step-1"
            )
            EnrollmentStep(
                number: 2,
                text: String(localized: "We crop to the face right here on your Mac"),
                identifier: "enrollment-step-2"
            )
            EnrollmentStep(
                number: 3,
                text: name.map { String(localized: "Enroll to start finding \($0) in your scans") }
                    ?? String(localized: "Enroll to start finding them in your scans"),
                identifier: "enrollment-step-3"
            )
        }
    }

    private var guidance: some View {
        Label {
            Text(guidanceText)
                .kionFont(12)
                .foregroundStyle(DesignColor.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "calendar.badge.clock")
                .foregroundStyle(DesignColor.maybe)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("enrollment-age-guidance")
        .accessibilityLabel(guidanceAccessibilityLabel)
    }

    private var guidanceText: String {
        if let name {
            String(localized: "Spread photos over the years — older and recent shots — so \(name) stays recognizable.")
        } else {
            String(localized: "Spread photos over the years — older and recent shots — so they stay recognizable.")
        }
    }

    private var guidanceAccessibilityLabel: String {
        if let name {
            String(localized: "Spread photos over the years so \(name) stays recognizable.")
        } else {
            String(localized: "Spread photos over the years so they stay recognizable.")
        }
    }

    // MARK: - Drop zone

    private var dropZone: some View {
        VStack(spacing: 8) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 30))
                .foregroundStyle(model.isDropEnabled ? DesignColor.keep : DesignColor.inkSecondary)
            Text("Drag 5–12 photos here")
                .kionFont(14, weight: .medium)
            Text("JPEG, PNG, or HEIC · they never leave this Mac")
                .kionFont(11)
                .foregroundStyle(DesignColor.inkSecondary)
            // A non-drag path so keyboard-only users (and anyone who doesn't think
            // to drag) can add references without leaving this uncancellable sheet.
            Button("Choose Photos…") {
                isChoosingPhotos = true
            }
            .buttonStyle(.bordered)
            .disabled(!model.isDropEnabled)
            .accessibilityIdentifier("choose-photos")
            .fileImporter(
                isPresented: $isChoosingPhotos,
                allowedContentTypes: [.jpeg, .png, .heic],
                allowsMultipleSelection: true
            ) { result in
                // Same in-session powerbox grant the drop path relies on — no explicit
                // security scoping needed for the later on-device enroll read.
                if case let .success(urls) = result {
                    _ = model.add(urls)
                }
            }
            if !model.testReferencePaths.isEmpty {
                Button("Add Sample References") {
                    model.addTestReferences()
                }
                .buttonStyle(.bordered)
                .disabled(!model.isDropEnabled)
                .accessibilityIdentifier("add-test-references")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(DesignColor.surface.opacity(model.isDropEnabled ? 1 : 0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                .foregroundStyle(DesignColor.hairline)
        )
        .opacity(model.isDropEnabled ? 1 : 0.6)
        .dropDestination(for: URL.self) { urls, _ in
            model.add(urls) > 0
        }
        .disabled(!model.isDropEnabled)
        // NOTE: do NOT put an .accessibilityIdentifier on this container — on macOS
        // a container identifier propagates down and CLOBBERS every descendant's own
        // identifier (the inner `add-test-references` button included), which makes
        // the test affordance unqueryable. Identify the leaf controls instead.
    }

    // MARK: - Filmstrip

    private var filmstrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(model.acceptedURLs, id: \.self) { url in
                    ReferencePreview(url: url) { model.remove(url) }
                }
            }
            .padding(.horizontal, 2)
        }
        .frame(height: model.acceptedURLs.isEmpty ? 0 : 104)
    }

    // MARK: - Status

    private var statusRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("References: \(model.referenceCount)")
                .kionFont(12, weight: .medium)
                .accessibilityIdentifier("reference-count")
            Text(status.detail)
                .kionFont(12)
                .foregroundStyle(status.tint)
                .accessibilityIdentifier("enrollment-status")
            if model.didHitLimit {
                Label(
                    "Only 12 references allowed — extra photos were skipped.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .kionFont(12)
                .foregroundStyle(DesignColor.maybe)
                .accessibilityIdentifier("reference-limit-feedback")
            }
            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .kionFont(12)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("enrollment-error")
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            if model.isEnrolling {
                ProgressView()
                    .controlSize(.small)
                Text(name.map { String(localized: "Enrolling \($0)…") } ?? String(localized: "Enrolling…"))
                    .kionFont(12)
                    .foregroundStyle(DesignColor.inkSecondary)
                    .accessibilityIdentifier("enrolling-indicator")
            }
            Spacer()
            if isCancelable {
                Button("Cancel", role: .cancel) {
                    onCancel()
                }
                .disabled(model.isEnrolling)
                .accessibilityIdentifier("Cancel")
            }

            Button("Enroll") {
                Task { await model.enroll() }
            }
            .buttonStyle(.borderedProminent)
            .tint(DesignColor.keep)
            .disabled(!model.canEnroll)
            .accessibilityIdentifier("Enroll")
        }
    }
}

private struct LocalOnlyBadge: View {
    var body: some View {
        Label("LOCAL-ONLY", systemImage: "lock.fill")
            .kionFont(11, weight: .semibold)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(DesignColor.keep.opacity(0.16), in: Capsule())
            .foregroundStyle(DesignColor.keep)
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier("LOCAL-ONLY")
            .accessibilityLabel("LOCAL-ONLY")
    }
}

private struct EnrollmentStep: View {
    let number: Int
    let text: String
    let identifier: String

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text("\(number)")
                .kionFont(12, weight: .bold)
                .frame(width: 22, height: 22)
                .background(DesignColor.keep.opacity(0.18), in: Circle())
                .foregroundStyle(DesignColor.keep)
            Text(text)
                .kionFont(13)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(String(localized: "Step \(number): \(text)"))
    }
}

/// One real downsampled preview per accepted reference URL, loaded off the main
/// thread via the shared ImageIO thumbnail path. Falls back to the generic
/// placeholder icon only while loading or when the image can't be decoded.
private struct ReferencePreview: View {
    let url: URL
    let onRemove: () -> Void

    @State private var image: NSImage?

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(DesignColor.surface)
                    .overlay(thumbnail)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(DesignColor.hairline)
                    )
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                Button {
                    onRemove()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(DesignColor.inkSecondary)
                }
                .buttonStyle(.plain)
                .padding(3)
                .accessibilityHidden(true)
            }
            Text(url.lastPathComponent)
                .kionFont(9, design: .monospaced)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 72)
                .foregroundStyle(DesignColor.inkSecondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("reference-preview")
        .accessibilityLabel(String(localized: "Reference \(url.lastPathComponent)"))
        .task(id: url) { await load() }
    }

    /// The real downsampled photo once decoded; the generic person glyph while
    /// loading or if the image can't be decoded.
    @ViewBuilder
    private var thumbnail: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 72, height: 72)
        } else {
            Image(systemName: "person.crop.square.fill")
                .font(.system(size: 34))
                .foregroundStyle(DesignColor.keep.opacity(0.85))
        }
    }

    private func load() async {
        let target = url
        let loaded = await Task.detached(priority: .userInitiated) {
            CandidateImage.downsample(url: target, maxPixel: 144)
        }.value
        if let loaded { image = loaded }
    }
}

/// Maps readiness onto the helper copy + tint shown under the drop zone.
private struct EnrollmentStatusCopy {
    let detail: String
    let tint: Color

    init(_ readiness: EnrollmentModel.Readiness, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        switch readiness {
        case .empty:
            detail = String(localized: "Add at least 5 photos to enroll.")
            tint = DesignColor.inkSecondary
        case .tooFew:
            detail = String(localized: "Add a few more — 5 photos minimum.")
            tint = DesignColor.maybe
        case .ready:
            detail = trimmed.isEmpty
                ? String(localized: "Ready to enroll.")
                : String(localized: "Ready to enroll \(trimmed).")
            tint = DesignColor.keep
        case .enrolling:
            detail = String(localized: "Enrolling…")
            tint = DesignColor.inkSecondary
        }
    }
}
