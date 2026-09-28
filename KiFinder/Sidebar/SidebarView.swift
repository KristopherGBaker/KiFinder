import AppKit
import SwiftUI

/// The sidebar: a **people list** (one row per enrolled/known person), the
/// always-on privacy note, and the current-scan summary. Selecting a row makes
/// that person active and filters Review to them; rows offer re-enroll, rename,
/// and delete, and a "+ Add person" affordance starts enrolling someone new.
struct SidebarView: View {
    let model: AppModel

    /// The person a pending delete is confirming. Deleting a person is strictly
    /// more destructive than removing one library photo (which already confirms),
    /// so the trash action stages the person here and the confirmation dialog —
    /// naming them and the consequences — is the only thing that actually deletes.
    @State private var pendingDeletePerson: Person?

    var body: some View {
        List {
            Section {
                ForEach(model.people) { person in
                    PersonRow(
                        person: person,
                        isActive: person.id == model.activePersonID,
                        referenceCount: model.referenceCount(for: person.id),
                        thumbnailURL: model.thumbnailURL(for: person.id),
                        onSelect: { model.selectPerson(id: person.id) },
                        onReEnroll: { model.presentEnrollment(personID: person.id) },
                        onRename: { model.renamePerson(id: person.id, to: $0) },
                        onDelete: { pendingDeletePerson = person }
                    )
                    .listRowSeparator(.hidden)
                }
                AddPersonButton(onAdd: { model.beginAddPerson() })
                    .listRowSeparator(.hidden)
            } header: {
                Text("People")
                    .kionFont(11, weight: .semibold)
                    .foregroundStyle(DesignColor.inkSecondary)
                    .accessibilityIdentifier("people-section")
            }
            Section {
                LibraryButton(
                    isActive: model.libraryBrowseActive,
                    onSelect: { model.showLibrary() }
                )
                .listRowSeparator(.hidden)
            }
            PrivacyNote()
                .listRowSeparator(.hidden)
            CurrentScanSummary(
                candidateCount: model.keepCount + model.maybeCount,
                totalPhotoCount: model.totalPhotoCount,
                scanLabel: model.currentScanLabel,
                hasScanned: model.hasCompletedScan,
                onScan: { model.presentScan() }
            )
            .listRowSeparator(.hidden)
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(DesignColor.sidebar)
        .liquidGlassChrome()
        // Deleting a person removes their profile, saved photos, and skip history
        // with no undo — gate it behind a confirmation that names them, mirroring
        // the library-photo remove confirm (LibraryBrowseView).
        .confirmationDialog(
            pendingDeletePerson.map { LocalizedStringKey("Delete \($0.displayName)?") } ?? "Delete this person?",
            isPresented: Binding(
                get: { pendingDeletePerson != nil },
                set: { if !$0 { pendingDeletePerson = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDeletePerson
        ) { person in
            Button("Delete", role: .destructive) {
                model.deletePerson(id: person.id)
            }
            .accessibilityIdentifier("confirm-delete-person")
            Button("Cancel", role: .cancel) {}
        } message: { person in
            Text("This permanently removes \(person.displayName)'s profile, saved photos, and skip history. This can't be undone.")
        }
    }
}

/// One person in the sidebar list: thumbnail (real crop, initials, or icon),
/// name, reference count, and the per-row re-enroll / rename / delete actions.
/// The whole row is tappable to make the person active. Accessibility ids are
/// stable English/`id` literals — never derived from the (user-data) name.
private struct PersonRow: View {
    let person: Person
    let isActive: Bool
    let referenceCount: Int?
    let thumbnailURL: URL?
    let onSelect: () -> Void
    let onReEnroll: () -> Void
    let onRename: (String) -> Void
    let onDelete: () -> Void

    @State private var isRenaming = false
    @State private var draftName = ""

    private var subtitle: String {
        if let referenceCount {
            return String(localized: "Enrolled · \(referenceCount) references")
        }
        return String(localized: "Not enrolled yet")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                PersonThumbnail(url: thumbnailURL, displayName: person.displayName)
                VStack(alignment: .leading, spacing: 2) {
                    Text(person.displayName)
                        .kionFont(15, weight: .semibold)
                        .lineLimit(1)
                        .accessibilityIdentifier("person-name")
                    Text(subtitle)
                        .kionFont(12)
                        .foregroundStyle(DesignColor.inkSecondary)
                        .lineLimit(1)
                        .accessibilityIdentifier(referenceCount == nil ? "profile-subtitle" : "enrolled-profile")
                }
                Spacer(minLength: 0)
            }

            if isRenaming {
                renameField
            }

            actions
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isActive ? DesignColor.keep.opacity(0.16) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isActive ? DesignColor.keep.opacity(0.5) : Color.clear, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture { onSelect() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("person-row-\(person.id)")
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
    }

    private var renameField: some View {
        TextField("Name", text: $draftName)
            .textFieldStyle(.roundedBorder)
            .kionFont(13)
            .onSubmit { commitRename() }
            .accessibilityIdentifier("rename-person-field")
            .onAppear { draftName = person.displayName }
    }

    private var actions: some View {
        HStack(spacing: 6) {
            Button(action: onReEnroll) {
                let title: LocalizedStringKey = referenceCount == nil ? "Enroll" : "Re-enroll"
                Label(title, systemImage: "person.crop.circle.badge.plus")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help(referenceCount == nil
                ? LocalizedStringKey("Enroll this person")
                : LocalizedStringKey("Re-enroll this person"))
            .accessibilityIdentifier("re-enroll-person")

            Button {
                draftName = person.displayName
                isRenaming.toggle()
            } label: {
                Label("Rename", systemImage: "pencil")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help(LocalizedStringKey("Rename this person"))
            .accessibilityIdentifier("rename-person")

            Button(role: .destructive, action: onDelete) {
                Label("Delete", systemImage: "trash")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help(LocalizedStringKey("Delete this person"))
            .accessibilityIdentifier("delete-person")

            Spacer(minLength: 0)
        }
        .kionFont(12)
        .foregroundStyle(DesignColor.inkSecondary)
    }

    private func commitRename() {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            onRename(trimmed)
        }
        isRenaming = false
    }
}

/// A person's avatar: their real cropped-face thumbnail when one is cached,
/// otherwise initials drawn from the display name, otherwise a generic icon.
private struct PersonThumbnail: View {
    let url: URL?
    let displayName: String

    @State private var image: NSImage?

    private var initials: String? {
        let letters = displayName
            .split(separator: " ")
            .compactMap(\.first)
            .prefix(2)
        let value = String(letters).uppercased()
        return value.isEmpty ? nil : value
    }

    var body: some View {
        ZStack {
            Circle().fill(DesignColor.keep.opacity(0.18))
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else if let initials {
                Text(initials)
                    .kionFont(15, weight: .semibold)
                    .foregroundStyle(DesignColor.keep)
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .font(.title)
                    .foregroundStyle(DesignColor.keep)
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(Circle())
        .accessibilityHidden(true)
        .task(id: url) { await load() }
    }

    private func load() async {
        guard let url else {
            image = nil
            return
        }
        let loaded = await Task.detached(priority: .userInitiated) {
            CandidateImage.downsample(url: url, maxPixel: 88)
        }.value
        image = loaded
    }
}

/// The "+ Add person" affordance that starts enrolling a brand-new person.
private struct AddPersonButton: View {
    let onAdd: () -> Void

    var body: some View {
        Button(action: onAdd) {
            Label("Add person", systemImage: "plus.circle.fill")
                .kionFont(13, weight: .medium)
        }
        .buttonStyle(.borderless)
        .padding(.vertical, 4)
        .accessibilityIdentifier("add-person")
    }
}

/// The sidebar's **Library** destination: swaps the detail pane to the kept-photo
/// library browser (item 18b). Distinct from the people list; selecting a person
/// returns to Review.
private struct LibraryButton: View {
    let isActive: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                Image(systemName: "photo.stack")
                    .foregroundStyle(DesignColor.keep)
                    .frame(width: 24)
                Text("Library")
                    .kionFont(15, weight: .semibold)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isActive ? DesignColor.keep.opacity(0.16) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isActive ? DesignColor.keep.opacity(0.5) : Color.clear, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("librarySidebarButton")
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
    }
}

private struct PrivacyNote: View {
    var body: some View {
        Label {
            Text("Everything stays on your Mac")
                .kionFont(13)
        } icon: {
            Image(systemName: "lock.fill")
                .foregroundStyle(DesignColor.keep)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("Everything stays on your Mac")
        .accessibilityLabel("Everything stays on your Mac")
    }
}

private struct CurrentScanSummary: View {
    let candidateCount: Int
    let totalPhotoCount: Int
    let scanLabel: String?
    let hasScanned: Bool
    let onScan: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("CURRENT SCAN")
                .kionFont(11)
                .foregroundStyle(DesignColor.inkSecondary)
                .accessibilityIdentifier("CURRENT SCAN")
            Text(scanLabel ?? String(localized: "No album scanned yet"))
                .kionFont(15, weight: .semibold)
            if hasScanned {
                Text("\(candidateCount) candidates out of \(totalPhotoCount)")
                    .kionFont(12)
                    .foregroundStyle(DesignColor.inkSecondary)
            }
            Button {
                onScan()
            } label: {
                let title: LocalizedStringKey = hasScanned ? "New scan" : "Scan an album"
                Label(title, systemImage: "sparkle.magnifyingglass")
                    .kionFont(12, weight: .medium)
            }
            .buttonStyle(.bordered)
            .padding(.top, 2)
            .accessibilityIdentifier("New scan")
        }
        .padding(.vertical, 8)
    }
}
