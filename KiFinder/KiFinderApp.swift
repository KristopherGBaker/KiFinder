import Foundation
import SwiftUI

@main
@MainActor
struct KiFinderApp: App {
    // A real launch persists user prefs to the standard defaults; a `KION_*`-driven
    // harness launch (UI tests) gets an isolated suite, so a test can never write app
    // state — notably the library-root bookmark — into the real preference domain
    // (see `KionEnvironment.defaultsSuiteName`). Unit tests inject their own defaults
    // and otherwise fall back to a per-instance isolated suite (see AppModel.init).
    @State private var model = AppModel(libraryDefaults: KionEnvironment.appDefaults)
    @Environment(\.scenePhase) private var scenePhase
    private let dynamicTypeRaw = KionEnvironment.process["KION_DYNAMIC_TYPE"]

    var body: some Scene {
        WindowGroup {
            KiFinderRootView(model: model, onFirstRunBackendChoice: { backend in
                // `chooseFirstRunBackend` persists the choice and answers the
                // chooser for this session; only when it reports the choice
                // DIFFERS from the already-running backend (Vision, picked over
                // the default ArcFace) do we reconstruct `@State` — item72's
                // "no live re-aim" applies here too: we never re-aim in place,
                // we rebuild via the same `AppModel(libraryDefaults:)` init path
                // item72 already proved resolves Vision correctly.
                if model.chooseFirstRunBackend(backend) {
                    model = AppModel(libraryDefaults: KionEnvironment.appDefaults)
                }
            })
                .environment(model)
                // `kionFont` now scales via `@ScaledMetric`/`dynamicTypeSize` (real
                // accessibility text size); the `KION_DYNAMIC_TYPE` UI-test hook drives
                // that same environment through `dynamicTypeSizeOverride` below.
                .dynamicTypeSizeOverride(DynamicTypeSize.override(from: dynamicTypeRaw))
                // No window-level .frame here: the review UI's NavigationSplitView +
                // inspector derive the window's minimum size from their own column
                // minimums. Wrapping them in a fixed min frame made macOS 27's
                // split-view controller loop on "Update Constraints in Window" and
                // abort at launch. The first-run screens anchor their own size
                // instead (see KiFinderRootView.firstRunFrame).
                // On normal teardown (window backgrounded/inactive) complete any
                // pending coalesced feedback write so taught keep/skips aren't
                // dropped. (No claim about crash/force-quit durability.)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background || phase == .inactive {
                        Task { await model.flushPendingWrites() }
                    }
                }
        }
        // A modest default size keeps the whole window — including the inspector's
        // pinned bottom Skip/Keep bar — within the display's visible frame (menu bar
        // + Dock excluded) even on small/headless screens; contentMinSize lets it
        // shrink to the ScrollView-backed content.
        .defaultSize(width: 1000, height: 640)
        .windowResizability(.contentMinSize)
        .windowStyle(.titleBar)
        .commands {
            SidebarCommands()
            // Core actions in the menu bar so they're discoverable (Help search) and
            // usable by menu-reliant users, not only via the grid's keyboard capture.
            // Keep/Skip intentionally carry NO key equivalent: Return / Delete belong
            // to the review grid's KeyCaptureView, and claiming them here would hijack
            // culling. The ⌘-shortcuts below don't collide with the culling keys.
            CommandMenu("Review") {
                Button("Keep Focused Photo") { model.keepFocused() }
                    .disabled(model.focusedID == nil)
                Button("Skip Focused Photo") { model.skipFocused() }
                    .disabled(model.focusedID == nil)
                Divider()
                Button("New Scan…") { model.presentScan() }
                    .keyboardShortcut("n", modifiers: .command)
                Button("Add Person…") { model.beginAddPerson() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Divider()
                Button("Add Kept Photos to Photos") { model.exportSelectedToPhotos() }
                    .keyboardShortcut("e", modifiers: .command)
                    .disabled(model.keepCount == 0)
            }
        }

        // Settings scene (item 18a): change the saved-photo library root later.
        Settings {
            LibrarySettingsView(model: model)
        }
    }
}

extension DynamicTypeSize {
    /// Maps the `KION_DYNAMIC_TYPE` launch hook to a concrete size so UI tests
    /// can exercise large accessibility text without changing system settings.
    static func override(from raw: String?) -> DynamicTypeSize? {
        switch raw {
        case "xSmall": .xSmall
        case "small": .small
        case "medium": .medium
        case "large": .large
        case "xLarge": .xLarge
        case "xxLarge": .xxLarge
        case "xxxLarge": .xxxLarge
        case "accessibility1": .accessibility1
        case "accessibility2": .accessibility2
        case "accessibility3": .accessibility3
        case "accessibility4": .accessibility4
        case "accessibility5": .accessibility5
        default: nil
        }
    }
}

private extension View {
    @ViewBuilder
    func dynamicTypeSizeOverride(_ size: DynamicTypeSize?) -> some View {
        if let size {
            dynamicTypeSize(size)
        } else {
            self
        }
    }
}
