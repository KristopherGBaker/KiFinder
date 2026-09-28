# Future Work

Deferred, non-blocking improvements captured so they aren't lost. Most of these are drawn from a pre-release review; the
items below are the ones consciously deferred rather than done.

## §4 UI/UX & accessibility — Medium (deferred)

These four remained after the other five §4-Medium items were addressed (menu-bar commands,
real Liquid Glass adoption, content-driven sheet sizing, face-box design tokens, album drop on
the populated grid). They were deferred because each is a risk or product/design judgment call,
and the UITest host is environmentally degraded (so keyboard/visual behavior can't be regression-
gated automatically).

### Adaptive grid columns (currently hardcoded to 3)
- **What:** `AppModel.swift` (~713–730) fixes `columnCount = 3`; `ReviewSurface.swift` renders the
  grid with it. DESIGN.md specifies adaptive ~236 pt tiles. On large displays tiles balloon; big
  albums become a very long scroll.
- **Approach:** derive the column count from container width (e.g. `onGeometryChange`) and thread
  it through.
- **Risk (why deferred):** `columnCount` also drives **arrow-key row math** in BOTH `AppModel` and
  `LibraryModel` (`moveLibraryFocus(by: ±columnCount)` and the review equivalent). Making it
  dynamic must keep keyboard row navigation consistent, and there is no working UITest to catch a
  regression. Do this with care and manual keyboard verification.

### WCAG contrast for `maybe` / `keep` as small text (light mode)
- **What:** measured `maybe` on `canvas` ≈ 2.84:1 and `keep` on `surface` ≈ 3.97:1 (AA needs 4.5:1),
  yet both are used for 11–12 pt status text (`EnrollmentSheet`, sidebar badges). Dark-mode values
  pass.
- **Approach:** either darken the light-mode variants of the `keep`/`maybe` color assets, OR
  introduce separate text-only tokens (e.g. `keepText`/`maybeText`) so the accent color used for
  icons/fills stays as-is while text meets AA. Restricting `maybe`/`keep` to icons paired with
  `ink` text is a third option.
- **Why deferred:** changes brand accent colors — wants a designer's eye on the exact values.

### Keyboard-operable sidebar rows + context menu
- **What:** `Sidebar/SidebarView.swift` person rows use `onTapGesture` (not a `Button` or
  `List(selection:)`), so they aren't keyboard-operable, and they expose three permanent icon-only
  actions (re-enroll / rename / delete) with destructive Delete one icon from Rename. (Delete now
  at least confirms — see the shipped a11y fixes — but the layout still invites misclicks.)
- **Approach:** use real `List(selection:)` for row selection and move the row actions into a
  context menu (and/or hover-reveal), per HIG.
- **Why deferred:** a moderate interaction-model rework; degraded UITests can't gate it.

### First-run double gate
- **What:** `KiFinderRootView.swift` requires a new user to download the model **and** complete a
  5-photo enrollment before ever seeing the main surface. The model gate is necessary; the
  uncancellable enrollment arguably isn't — the empty Review already has a good invitation state.
- **Approach:** let first-run enrollment cancel onto Review with a prominent "Enroll someone" CTA,
  while keeping the mandatory re-open for the delete-last-person case if desired.
- **Why deferred:** a product-flow decision, not a clear-cut fix (the review itself frames it as
  "consider").

## macOS 27 — UI tests red (26/30)

macOS 27 / Xcode 27 broke the app at launch (a window-level min frame around the split view +
inspector looped AppKit's constraint pass) and shifted Vision's face detection enough to break
bit-exact embedding fixtures. Both are fixed (`fix(macos27)`); unit (508) and engine (129) suites
are green. The **XCUITest suite is not**:

- **Sample-mode tests saw an empty people list — FIXED (item 76).** Probing confirmed the
  real cause: on macOS 27 BOTH processes are App-Sandboxed to their own containers. The XCUITest
  runner (`KiFinderUITests-Runner.app`) can write ONLY its own container — writes to `/tmp`,
  `/var/folders/…/T`, `/Users/Shared`, and the APP's container all fail (`NSCocoaErrorDomain 513`).
  The app can write ONLY *its* container (`~/Library/Containers/com.krisbaker.KiFinder/Data/tmp/…`
  and its Application Support). So a `KION_PROFILE_STORE` under `/tmp` (or the runner's temp) wrote
  nothing, `bootstrapRoster`'s `try?` seeding silently yielded no people, and the mandatory
  "Enroll a person" sheet covered Review — the one cause behind 25 of the 26 failures. The app
  already created the store's parent dir; it was the app's OWN sandbox denying `/tmp`. Fix: all
  app-written harness files now route through `HarnessPaths.appWritable` into the app's own
  container (the app creates the parents); runner-authored fixtures the app only READS
  (`KION_LIBRARY_PICK`) stay in the runner's temp (`HarnessPaths.runnerWritable`), and a library
  fixture the app must READ *and WRITE* is staged in the runner's temp then copied into the app's
  container by the new `KION_LIBRARY_SEED_DIR` hook (`stageLibrarySeed`). No entitlement/sandbox
  changes.
- **Review header now lives in the window toolbar — FIXED (item 78).** The in-content `ReviewToolbar`
  capsule was replaced with native window chrome: the title/subtitle are `navigationTitle`/
  `navigationSubtitle` and the five review actions are `.toolbar` items (`.primaryAction`) that macOS
  lays out across the full window width and overflows itself — so at the 1000 × 640 default size
  nothing wraps, truncates, or spills a glass ellipse over the sidebar. `ReviewToolbarLayoutTests`
  guards the layout at the unzoomed default size.
- **Dynamic Type header does not grow — FIXED (item 77).** macOS 27 stopped scaling `@ScaledMetric`
  (and semantic fonts) from a `dynamicTypeSize` environment override, so `kionFont` now also derives
  a size from the environment via a ratio table (`DynamicTypeSize.kionScale`) and takes the larger
  of the two.
- **`-AppleInterfaceStyle Dark` no longer switches the app on macOS 27 (open).** `LaunchTests.
  testDarkLaunch` still runs its element assertions but the app renders in the system appearance;
  it no longer proves dark rendering. A `KION_APPEARANCE` hook (`NSApp.appearance`) would restore
  a real dark-mode check.
- **Harness window size.** Since `KION_*` launches use an isolated defaults suite (no saved window
  frame), the window opens at the modest default and `LazyVStack` sections below the fold never
  enter the accessibility tree. Every UI-test `launch` helper now zooms the window first
  (`XCUIApplication.zoomMainWindow()`), and tests that re-parent a tile to the top scroll back
  before counting it.
- **UI tests no longer overwrite the user's saved window frame.** `NSWindow` frame autosave writes to
  `UserDefaults.standard`, which the isolated `KION_*` harness suite does not cover, so a zoomed UI
  test used to leave a 1728-pt-wide frame behind for the next real launch. Harness launches now
  detach every window from frame autosave (`KionEnvironment.applyHarnessWindowPolicy`); the app is
  never resized programmatically (macOS 27's split-view constraint pass makes that risky), so
  `ReviewToolbarLayoutTests` restores the default size by dragging the resize corner.
- **Stale sample expectations** (`LaunchTests`: "1 confident + 1 worth a look", lightbox "1 of 2")
  predated items 6/7 (the primary sample person now sees 5 photos); updated to the
  current sample data.

## Related follow-ups noted elsewhere

- **Undo for bulk decisions.** The §4-Medium menu-bar work added a "Review" `CommandMenu` but not
  `UndoManager` wiring. "Skip all" (`ReviewSurface`) can flush hundreds of photos in one misclick
  with no ⌘Z. Wiring undo for the bulk operations is worth doing alongside the menu commands.
- **AdaFace calibration is an untuned placeholder** (`FaceModelDescriptor.adaface`,
  0.40/0.08/0.0) — needs tuning against a labeled evaluation set. Same honesty caveat as the Vision
  FeaturePrint calibration.
- **§1 repo hygiene** — done for the public release (items 79–81): LICENSE (GPL-3.0-or-later),
  `THIRD-PARTY-NOTICES.md`, fork-friendly ad-hoc signing, CONTRIBUTING + CI, and fixture provenance.
