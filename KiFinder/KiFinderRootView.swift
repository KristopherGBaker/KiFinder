import SwiftUI

struct KiFinderRootView: View {
    /// `@Bindable` so `$model.isEnrollmentPresented` is a properly observed
    /// binding — the sheet presents/dismisses when the model flips the flag from
    /// `.task` (first run) or a Review re-enroll action.
    @Bindable var model: AppModel

    /// Reports the user's first-run backend pick upward (item 73). The App owns
    /// the `AppModel` `@State`, so it's the one that reconstructs it when Vision
    /// requires a rebuild — this view never persists or reconstructs anything
    /// itself.
    let onFirstRunBackendChoice: (FaceBackend) -> Void

    var body: some View {
        if model.needsBackendChoice {
            // First run, backend undecided: ask BEFORE the onboarding download
            // gate below — picking Vision skips the download entirely.
            BackendChoiceView(model: model, onChoose: onFirstRunBackendChoice)
                .modifier(FirstRunFrame())
        } else if model.needsOnboarding {
            // First run with no model yet: gate the whole app on the download.
            OnboardingView(model: model)
                .modifier(FirstRunFrame())
        } else {
            reviewUI
        }
    }

    private var reviewUI: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } detail: {
            if model.libraryBrowseActive {
                LibraryBrowseView(model: model)
            } else {
                ReviewSurface(model: model)
            }
        }
        .tint(DesignColor.keep)
        .sheet(isPresented: $model.isEnrollmentPresented, onDismiss: model.dismissEnrollment) {
            if let enrollmentModel = model.enrollmentModel {
                EnrollmentSheet(model: enrollmentModel, isCancelable: !model.isEnrollmentMandatory) {
                    model.dismissEnrollment()
                }
                // A mandatory (first-run / delete-last) enrollment can't be escaped or
                // click-dismissed onto an empty Review — only completing it dismisses.
                .interactiveDismissDisabled(model.isEnrollmentMandatory)
            }
        }
        .sheet(isPresented: $model.isScanPresented, onDismiss: model.dismissScan) {
            ScanSheet(model: model)
        }
        .sheet(isPresented: $model.isExportSummaryPresented) {
            ExportSummaryView(model: model)
        }
        // A failed export surfaces a recoverable error instead of an "Exported 0"
        // summary: Try Again repeats the export, Dismiss clears it.
        .alert(
            "Export failed",
            isPresented: Binding(
                get: { model.exportError != nil },
                set: { if !$0 { model.clearExportError() } }
            ),
            presenting: model.exportError
        ) { _ in
            Button("Try Again") { model.retryExport() }
                .accessibilityIdentifier("exportErrorRetryButton")
            Button("Dismiss", role: .cancel) { model.clearExportError() }
                .accessibilityIdentifier("exportErrorDismissButton")
        } message: { message in
            Text(message)
        }
        // Item 53: an add/rename/delete roster-write failure surfaces the same
        // way — Try Again re-attempts exactly that operation, Dismiss clears it.
        .alert(
            "Couldn't save",
            isPresented: Binding(
                get: { model.rosterError != nil },
                set: { if !$0 { model.clearRosterError() } }
            ),
            presenting: model.rosterError
        ) { _ in
            Button("Try Again") { model.retryRoster() }
                .accessibilityIdentifier("rosterErrorRetryButton")
            Button("Dismiss", role: .cancel) { model.clearRosterError() }
                .accessibilityIdentifier("rosterErrorDismissButton")
        } message: { message in
            Text(message)
        }
        // A data file (people list / saved-photo index / skipped-photo history) that
        // couldn't be read was set aside instead of silently discarded (item 57).
        // Root-level, same wiring shape as the export-failure alert above — NOT
        // scoped to the scan sheet, since this can fire before any scan runs.
        // There's no retry (the quarantine already happened at construction); Dismiss
        // is the only action, and it never re-shows on its own.
        .alert(
            "Data file set aside",
            isPresented: Binding(
                get: { model.dataIntegrityNotice != nil },
                set: { if !$0 { model.clearDataIntegrityNotice() } }
            ),
            presenting: model.dataIntegrityNotice
        ) { _ in
            Button("Dismiss", role: .cancel) { model.clearDataIntegrityNotice() }
                .accessibilityIdentifier("dataIntegrityNoticeDismissButton")
        } message: { message in
            Text(message)
        }
        .task {
            // Harness launches only: stop frame autosave from overwriting the user's
            // saved window frame (see `KionEnvironment.applyHarnessWindowPolicy`).
            KionEnvironment.applyHarnessWindowPolicy()
            model.presentEnrollmentIfNeeded()
            await model.refreshCandidatesIfNeeded()
        }
    }
}

/// Anchors the first-run screens to a bounded ideal size. Onboarding fills its window
/// greedily (maxHeight: .infinity + Spacers) and so proposes no finite ideal height on
/// its own; with .contentMinSize resizability the window then sizes to that unbounded
/// vertical fitting size and opens absurdly tall (~3576pt), ignoring .defaultSize. An
/// explicit ideal gives the window a sane height to adopt, while maxWidth/maxHeight
/// .infinity still lets the user resize and maximize. Scoped to the first-run screens
/// only: the same frame around the review UI's split view + inspector crashes macOS 27
/// (see KiFinderApp).
private struct FirstRunFrame: ViewModifier {
    func body(content: Content) -> some View {
        content.frame(
            minWidth: 720, idealWidth: 1000, maxWidth: .infinity,
            minHeight: 480, idealHeight: 640, maxHeight: .infinity
        )
    }
}
