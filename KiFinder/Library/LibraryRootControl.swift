import SwiftUI

/// Reusable library-root chooser used in both onboarding and Settings (items 18a + 44):
/// shows the current root path (pre-filled with the app-container default) and a
/// "Choose…" button that stores a user-picked folder as a security-scoped bookmark.
/// When a custom folder is in use, a "Use Default" button clears the bookmark and
/// returns to the container. The field is read-only (the root is changed via the picker,
/// honoring the `KION_LIBRARY_PICK` test override). Purely additive and NON-gating — the
/// root always has a default, so it never blocks model-download readiness.
struct LibraryRootControl: View {
    @Bindable var model: AppModel

    var body: some View {
        // `libraryRoot` is resolved once and re-set by the picker/reset, so observe
        // `libraryRevision` — bumped on every change — to refresh the field.
        let _ = model.libraryRevision
        return VStack(alignment: .leading, spacing: 8) {
            Text("Saved photo library")
                .kionFont(13, weight: .semibold)
                .foregroundStyle(DesignColor.ink)
            Text("Kept photos are copied here, organized by person and month.")
                .kionFont(12)
                .foregroundStyle(DesignColor.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Text(model.libraryRoot.path)
                    .kionFont(12, design: .monospaced)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(DesignColor.surface, in: RoundedRectangle(cornerRadius: 6))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6).stroke(DesignColor.hairline)
                    }
                    .accessibilityIdentifier("libraryRootField")
                    .accessibilityLabel("Library folder")
                    .accessibilityValue(model.libraryRoot.path)
                Button("Choose…") { model.chooseLibraryRoot() }
                    .accessibilityIdentifier("libraryRootChooseButton")
                if !model.isUsingDefaultLibraryRoot {
                    Button("Use Default") { model.resetLibraryRootToDefault() }
                        .accessibilityIdentifier("libraryRootUseDefaultButton")
                }
            }
            if model.libraryRootNeedsReselection {
                Text("The saved library folder is no longer available. Choose it again to keep saving there.")
                    .kionFont(12)
                    .foregroundStyle(DesignColor.maybe)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("libraryRootReselectNotice")
            }
        }
    }
}

/// The macOS Settings scene body (item 18a): lets the user change the library root
/// after onboarding. Wrapped in a `Form` so it reads as a standard preferences pane.
struct LibrarySettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            LibraryRootControl(model: model)
            // Item 25: opt-in resize handles for drawn manual face regions (off by
            // default; drawing/removing a region are always available regardless).
            Toggle("Resize drawn face regions", isOn: $model.manualRegionResizeEnabled)
                .accessibilityIdentifier("manualResizeToggle")
            FaceBackendPicker(model: model)
            ScanWorkersPicker(model: model)
        }
        .padding(20)
        .frame(width: 460)
        // Item 76: NO container-level `.accessibilityIdentifier` here. On macOS 27 an
        // identifier on the `Form` cascades onto EVERY descendant, shadowing the child
        // identifiers (`scanWorkersPicker`, `scanWorkersCaption`, `manualResizeToggle`,
        // `faceBackendPicker`, `libraryRootField`, …) so none is queryable by its own id.
        // Nothing references the container id, so it is simply dropped.
    }
}

/// The face-matching backend picker (item 72): lets the user choose ArcFace
/// (ONNX, today's default) or Apple's built-in Vision FeaturePrint. Bound to
/// `model.faceBackend` — which only PERSISTS the preference (see its doc on
/// `AppModel`) — so the caption is explicit that the change needs a relaunch to
/// take effect; this never re-aims the already-running session.
struct FaceBackendPicker: View {
    @Bindable var model: AppModel

    var body: some View {
        Section {
            Picker("Face matching", selection: $model.faceBackend) {
                ForEach(FaceBackend.allCases, id: \.self) { backend in
                    Text(backend.displayName).tag(backend)
                }
            }
            .accessibilityIdentifier("faceBackendPicker")
            Text("Changes take effect after you quit and reopen KiFinder.")
                .kionFont(12)
                .foregroundStyle(DesignColor.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if !model.faceBackend.needsModelDownload {
                Text("Vision FeaturePrint is built into macOS — no model download needed.")
                    .kionFont(12)
                    .foregroundStyle(DesignColor.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("faceBackendNoDownloadNote")
            }
        } header: {
            Text("Face Matching")
        }
    }
}

/// The scan-concurrency picker (item 75): how many photos a scan embeds at once.
/// Bound to `model.scanWorkerCount`, which stores the PICKED value (Automatic stays
/// "automatic" rather than freezing today's core count); the caption reports what
/// Automatic resolves to on this machine. Unlike the backend picker this needs no
/// relaunch — the engine re-reads the preference at the start of every scan.
struct ScanWorkersPicker: View {
    @Bindable var model: AppModel

    var body: some View {
        Section {
            Picker("Photos at a time", selection: $model.scanWorkerCount) {
                ForEach(ScanWorkersPreference.selectableCounts, id: \.self) { count in
                    Text(count == ScanWorkersPreference.automatic
                        ? String(localized: "Automatic")
                        : "\(count)")
                        .tag(count)
                }
            }
            .accessibilityIdentifier("scanWorkersPicker")
            Text("Scanning \(model.effectiveScanWorkerCount) photos at a time. Higher is faster on big albums but uses more memory and keeps the fans up; it applies to your next scan.")
                .kionFont(12)
                .foregroundStyle(DesignColor.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("scanWorkersCaption")
        } header: {
            Text("Scanning")
        }
    }
}
