# Future Work

Deferred, non-blocking improvements, recorded so they aren't lost. Most come from a
pre-release review. These are the items we chose to defer rather than do.

## §4 UI/UX & accessibility: Medium (deferred)

These four remain after the other five §4-Medium items were done (menu-bar commands, real
Liquid Glass adoption, content-driven sheet sizing, face-box design tokens, album drop on the
populated grid). Each is a risk or a product/design judgment call. Also, the UITest host is
environmentally degraded, so automated tests can't guard keyboard or visual behavior.

### Adaptive grid columns (currently hardcoded to 3)
- **What:** `AppModel.swift` (~713 to 730) fixes `columnCount = 3`, and `ReviewSurface.swift`
  renders the grid with it. DESIGN.md specifies adaptive ~236 pt tiles. On large displays the
  tiles balloon, and big albums become a very long scroll.
- **Approach:** derive the column count from the container width (for example,
  `onGeometryChange`) and pass it through.
- **Risk (why deferred):** `columnCount` also drives **arrow-key row math** in BOTH `AppModel`
  and `LibraryModel` (`moveLibraryFocus(by: ±columnCount)` and the review equivalent). A dynamic
  count must keep keyboard row navigation consistent, and no working UITest would catch a
  regression. Do it carefully and verify the keyboard by hand.

### WCAG contrast for `maybe` / `keep` as small text (light mode)
- **What:** measured contrast is ≈ 2.84:1 for `maybe` on `canvas` and ≈ 3.97:1 for `keep` on
  `surface` (AA needs 4.5:1). Both colors are used for 11 to 12 pt status text
  (`EnrollmentSheet`, sidebar badges). Dark-mode values pass.
- **Approach:** darken the light-mode variants of the `keep`/`maybe` color assets, or add
  text-only tokens (for example, `keepText`/`maybeText`) so the accent color for icons and fills
  stays the same while text meets AA. A third option: use `maybe`/`keep` only for icons paired
  with `ink` text.
- **Why deferred:** it changes brand accent colors, so the exact values need a designer's eye.

### Keyboard-operable sidebar rows + context menu
- **What:** person rows in `Sidebar/SidebarView.swift` use `onTapGesture` (not a `Button` or
  `List(selection:)`), so the keyboard can't operate them. Each row also shows three permanent
  icon-only actions (re-enroll / rename / delete), with the destructive Delete one icon away from
  Rename. Delete now asks for confirmation (see the shipped a11y fixes), but the layout still
  invites misclicks.
- **Approach:** use a real `List(selection:)` for row selection and move the row actions into a
  context menu (and/or reveal them on hover), per the HIG.
- **Why deferred:** it's a moderate rework of the interaction model, and degraded UITests can't
  guard it.

### First-run double gate
- **What:** `KiFinderRootView.swift` makes a new user download the model **and** finish a
  5-photo enrollment before they see the main surface. The model gate is necessary. The
  uncancellable enrollment arguably isn't, since the empty Review already has a good invitation
  state.
- **Approach:** let first-run enrollment cancel onto Review with a prominent "Enroll someone"
  CTA. Optionally keep the mandatory re-open when the last person is deleted.
- **Why deferred:** it's a product-flow decision, not a clear-cut fix (the review itself says
  "consider").

## macOS 27 migration notes

macOS 27 / Xcode 27 broke the app at launch: a window-level min frame around the split view and
inspector looped AppKit's constraint pass. It also shifted Vision's face detection enough to
break bit-exact embedding fixtures. Both are fixed. The unit (519) and engine (129) suites pass.
The UI-test fixes are below; one item (dark-mode rendering) is still open:

- **Sample-mode tests saw an empty people list. FIXED (item 76).** Probing found the real
  cause: on macOS 27 BOTH processes are App-Sandboxed to their own containers. The XCUITest
  runner (`KiFinderUITests-Runner.app`) can write ONLY to its own container. Writes to `/tmp`,
  `/var/folders/…/T`, `/Users/Shared`, and the APP's container all fail
  (`NSCocoaErrorDomain 513`). The app can write ONLY to *its* container
  (`~/Library/Containers/com.krisbaker.KiFinder/Data/tmp/…` and its Application Support). So a
  `KION_PROFILE_STORE` under `/tmp` (or the runner's temp) wrote nothing, `bootstrapRoster`'s
  `try?` seeding silently produced no people, and the mandatory "Enroll a person" sheet covered
  Review. That one cause was behind 25 of the 26 failures. The app already created the store's
  parent dir; the app's OWN sandbox was denying `/tmp`. The fix:
  - All app-written harness files now go through `HarnessPaths.appWritable` into the app's own
    container (the app creates the parents).
  - Runner-authored fixtures the app only READS (`KION_LIBRARY_PICK`) stay in the runner's temp
    (`HarnessPaths.runnerWritable`).
  - A library fixture the app must READ *and WRITE* is staged in the runner's temp, then copied
    into the app's container by the new `KION_LIBRARY_SEED_DIR` hook (`stageLibrarySeed`).

  No entitlement or sandbox changes.
- **Review header now lives in the window toolbar. FIXED (item 78).** Native window chrome
  replaced the in-content `ReviewToolbar` capsule. The title and subtitle are
  `navigationTitle`/`navigationSubtitle`, and the five review actions are `.toolbar` items
  (`.primaryAction`). macOS lays them out across the full window width and handles overflow
  itself. At the 1000 × 640 default size nothing wraps, truncates, or spills a glass ellipse over
  the sidebar. `ReviewToolbarLayoutTests` guards the layout at the unzoomed default size.
- **Dynamic Type header does not grow. FIXED (item 77).** macOS 27 stopped scaling
  `@ScaledMetric` (and semantic fonts) from a `dynamicTypeSize` environment override. So
  `kionFont` now also derives a size from the environment via a ratio table
  (`DynamicTypeSize.kionScale`) and uses the larger of the two.
- **`-AppleInterfaceStyle Dark` no longer switches the app on macOS 27 (open).**
  `LaunchTests.testDarkLaunch` still runs its element assertions, but the app renders in the
  system appearance, so the test no longer proves dark rendering. A `KION_APPEARANCE` hook
  (`NSApp.appearance`) would restore a real dark-mode check.
- **Harness window size.** `KION_*` launches use an isolated defaults suite with no saved window
  frame, so the window opens at the modest default size. `LazyVStack` sections below the fold then
  never enter the accessibility tree. Every UI-test `launch` helper now zooms the window first
  (`XCUIApplication.zoomMainWindow()`). Tests that move a tile to the top scroll back before
  counting it.
- **UI tests no longer overwrite the user's saved window frame.** `NSWindow` frame autosave
  writes to `UserDefaults.standard`, which the isolated `KION_*` harness suite doesn't cover. A
  zoomed UI test used to leave a 1728-pt-wide frame behind for the next real launch. Harness
  launches now detach every window from frame autosave
  (`KionEnvironment.applyHarnessWindowPolicy`). The app is never resized programmatically
  (macOS 27's split-view constraint pass makes that risky), so `ReviewToolbarLayoutTests`
  restores the default size by dragging the resize corner.
- **Stale sample expectations** in `LaunchTests` ("1 confident + 1 worth a look", lightbox
  "1 of 2") predated items 6/7, after which the primary sample person sees 5 photos. They now
  match the current sample data.

## Related follow-ups noted elsewhere

- **Undo for bulk decisions.** The §4-Medium menu-bar work added a "Review" `CommandMenu` but no
  `UndoManager` wiring. One misclick on "Skip all" (`ReviewSurface`) can skip hundreds of photos
  with no ⌘Z. Add undo for the bulk operations alongside the menu commands.
- **AdaFace calibration is an untuned placeholder** (`FaceModelDescriptor.adaface`,
  0.40/0.08/0.0). It needs tuning against a labeled evaluation set. The Vision FeaturePrint
  calibration has the same caveat.
- **§1 repo hygiene:** done for the public release (items 79 to 81). LICENSE
  (GPL-3.0-or-later), `THIRD-PARTY-NOTICES.md`, fork-friendly ad-hoc signing, CONTRIBUTING + CI,
  and fixture provenance.
