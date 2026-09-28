# KiFinder: Design

> Design source of truth. Derived from the Pencil mockup (`~/Downloads/photo-triage`, the
> KiFinder app frame) and a `/swiftui-design` (HIG) pass. **This file is authoritative.** The .pen
> file is only for a human to eyeball.

## Subject and platform

A quiet, **privacy-first macOS app** that helps one person sort photos of a specific subject (the
person you enroll) out of large mixed albums. The posture is *local and calm*: "Teach it once.
Sort privately after." / "Everything stays on your Mac." It is the review and culling front end
for an on-device face matcher (see PRODUCT.md and docs/ARCHITECTURE.md). macOS 26 (Tahoe),
SwiftUI, Apple silicon. A single-window, document-style app.

## Design principles (from the HIG pass)

- **Lead with the photos, not chrome.** The candidate grid and the lightbox are the product.
  Everything else is quiet. One accent (Keep green), used sparingly.
- **Native Mac structure.** `NavigationSplitView` (sidebar + detail) with a trailing `.inspector`
  for the lightbox. A real toolbar, a real `List` for history, and a real `LazyVGrid` for tiles,
  not hand-positioned cards.
- **Keyboard-first culling is the signature.** ←/→ move through candidates, **Return = Keep**,
  **Delete = Skip**, and **Space** previews. The mouse is optional. This makes it feel like a tool, not a web page.
- **Restraint.** Hairline separators and system materials/Liquid Glass for layering. No
  drop-shadow card grid, and no gradients except the subtle profile avatar.

## Tokens

Define tokens in an **asset catalog** with light/dark pairs. Reference them by semantic role, not
by hex in code. The mock is a warm-neutral *light* look. The dark variants below keep it calm,
not inverted.

### Color (role: light / dark)
- `canvas` (window/content bg): `#F6F6F3` / `#1C1C1A`
- `sidebar` (source list bg): `#ECEDEA` / `#232422`. Prefer the system sidebar material; this is
  the fallback tint.
- `surface` (cards/tiles/panels): `#FFFFFF` / `#2A2B28`
- `ink` (primary text): `#1B1C1E` / `#F3F3F0`
- `inkSecondary` (secondary text/labels): `#6B6D70` / `#A6A8A4`
- `hairline` (borders/separators): `#D7D8D4` / `#3A3B38`
- `keep` (**the one accent**: confirm/keep, privacy lock): `#3B8F61` (dark: `#4FA374`). Wire it
  through `.tint(_:)`.
- `maybe` (borderline / face box / "worth a look"): `#C9842C` (dark: `#D9A050`)
- `inkInverse` (dark surfaces: scan card, Export button): `#1B1C1E` bg, `#F6F6F3` text.

Color is **never the only signal**. Pair the keep green and maybe amber with an icon and label
(checkmark/"Keep", dot/"Worth a look").

### Type: SF Pro, system text styles (Dynamic Type), with `.rounded` for display
- **Display / titles** ("Teach it once.", "Review <name> candidates"): `.largeTitle`/`.title`
  with `.fontDesign(.rounded)`, weight `.semibold`. Friendly and approachable; the chosen voice
  in place of the mock's Geist.
- **Section headers** ("Found matches", "Worth a look"): `.headline`, default SF Pro.
- **Body / labels / button text**: `.body` / `.callout`, default SF Pro.
- **Secondary / hints / counts** ("5 confident + 8 worth a look", "7 of 13"): `.subheadline`/
  `.caption`, `inkSecondary`.
- **Data/filenames** ("IMG_1861.HEIC"): `.callout` `.monospaced` is acceptable for filenames.
- No `.font(.system(size:))`. Everything scales with Dynamic Type.

### Spacing, shape, material
- Spacing: system default stack spacing + `.padding()`; tile grid gap ~12. Avoid magic numbers.
- Radius: tiles/cards 8, buttons ~7 (use `.buttonStyle` defaults where possible), panels 10 to 18.
- **Elevation via material, not shadow**: `.regularMaterial`/`.thinMaterial`. On macOS 26, adopt
  **Liquid Glass** for the toolbar, sidebar, and the inspector/lightbox floating layer via the
  system treatments (`.glassEffect`, grouped in a `GlassEffectContainer`). Glass is for the
  floating control layer, **not** the photo content. Respect **Reduce Transparency** (solid
  `surface` fallback).

## Navigation & layout

`NavigationSplitView`:
- **Sidebar** (`List`, sidebar style): a **People** section (one row per enrolled person:
  avatar, name, and reference count; selecting a row makes that person active; rows offer
  re-enroll, rename, and delete) with an "Add person" button, a **Library** row for browsing
  kept photos, a privacy note row ("Everything stays on your Mac", lock in `keep`), and a
  "Current scan" card (album name + "N candidates out of M").
- **Detail**: the Review surface (toolbar + candidate grid).
- **Inspector** (`.inspector`, trailing): the **Lightbox** for the selected candidate.

The Enroll and Scan surfaces are **sheets/first-run flows** over the main window. The mock shows
them as standalone "moments".

```
┌──────────── KiFinder ───────────────────────────────────────────────────────┐
│ [Keyboard] [Re-scan]                                          [ Export 6 kept]│  ← toolbar
├───────────┬───────────────────────────────────────────────┬─────────────────┤
│ Name ◑    │  Review <name> candidates                      │ IMG_1861.HEIC   │
│ 7 photos  │  5 confident + 8 worth a look from 312 photos  │ 7 of 13         │
│           │                                                 │ ┌─────────────┐ │
│ 🔒 stays  │  ● Found matches  Auto-selected · quick confirm │ │   ▢ face    │ │ ← amber
│   on Mac  │  ┌────┐┌────┐┌────┐                             │ │   (preview) │ │   box
│           │  │ ✓  ││ ✓  ││ ✓  │   …                         │ └─────────────┘ │
│ Current   │  └────┘└────┘└────┘                             │ [ Skip ][ Keep ]│ ← Del/Return
│ scan      │  ● Worth a look   Never hidden · Return to keep │ ←/→ move · Ret. │
│ June…zip  │  ┌────┐┌────┐┌────┐                             │   keeps · Del   │
│ 13 of 312 │  │ ◐  ││ ◐  ││ ◌  │   …                         │   skips         │
│           │  └────┘└────┘└────┘                             │                 │
│           │                                                 │                 │
└───────────┴───────────────────────────────────────────────┴─────────────────┘
```

## Surfaces

### 1. Enrollment: "Teach it once. Sort privately after."
A focused first-run sheet.
- **Left:** a large **drop zone** ("Add 5 to 12 reference photos of this person") for reference photos. It
  shows a thumbnail filmstrip of what's added and a small **cropped-face preview** per photo (the
  Vision detection result).
- **Age spread:** when the subject is a young child whose face changes fast, **references should
  span their age range**. Guide the user toward a spread of ages (for example, a few per age
  band), not 5 to 12 shots of one look. Feedback then keeps growing the exemplar set per album.
- **Right:** three quiet steps ("Add 5 to 12 clear photos", "Review cropped faces", "Save local
  profile"), a `LOCAL ONLY` badge, and the privacy line.
- The primary action saves the local profile and dismisses to Review.

### 2. Album scan moment (dark surface)
A dark card (`inkInverse`): **"Drop album"** accepts **a folder OR a .zip**. Zips may contain
nested folders; traverse them recursively. On drop, a local scan runs with live progress: the
album name, a progress bar + %, and three stats (**matches so far**, **on device 100%** as privacy
reassurance, and **time left**), plus a **Stop** button. Copy: "One gesture starts a local scan.
This archive is unzipped, matched against the subject, then forgotten."

### 3. Review window (the core)
- **Toolbar**: title "Review <name> candidates" + subtitle "N confident + M worth a look from K
  photos". Trailing buttons: **Keyboard** (shortcuts cheat-sheet popover), **Re-scan**, and a
  filled dark **"Export N kept"**. Export is a menu that picks the destination: **a folder** or
  **the Photos app**. It is always a straight copy of the source (no conversion).
- **Candidate grid** (`LazyVGrid`, adaptive ~236pt tiles, gap 12), in two sections:
  - **"Found matches"**: the keep/confident bucket. Header hint "Auto-selected · quick confirm".
    Each tile is pre-marked kept (green check), but every decision stays reversible.
  - **"Worth a look"**: the maybe bucket. Header hint "Never hidden · press Return to keep".
    Borderline matches are **never auto-hidden**.
- **Lightbox inspector**: the selected photo's filename + an "i of N" counter; a large preview
  with an **amber face bounding box** and a confidence chip ("Worth a look · score on hover");
  **Skip** (neutral) and **Keep** (`keep` green) controls; and a keyboard hint line.

## Components
- **PhotoTile**: square-ish image (radius 8, hairline border), a bucket affordance (green check
  for kept, amber dot for maybe), filename on hover. Selected state = `keep`/`maybe` ring.
- **CandidateSection**: header (label + count + hint) over a `LazyVGrid`.
- **Lightbox**: large `AsyncImage`/`NSImage` preview with an overlaid face box and confidence
  chip; Skip/Keep buttons; keyboard hint.
- **SidebarProfile / PrivacyNote / CurrentScan / ScanHistoryRow**.
- **ScanProgress**: dark card with progress + matches/on-device/time-left stats + Stop.
- **DropZone**: reusable drag-and-drop target (reference photos; album folder/zip).

## Interactions
- **Keyboard culling** (signature): `←`/`→` (and `↑`/`↓` across grid rows) move selection;
  **Return** = Keep; **Delete**/`Backspace` = Skip; **Space** opens the full-size preview; `Esc`
  closes it. Selection always has a visible focus ring. Every key action animates the
  tile's bucket change.
- **Confirm/Skip → feedback**: Keep or Skip on a candidate records a confirm or reject that feeds
  the engine's profile, improving future scans. Idempotent, and reversible until export.
- **Drag-and-drop**: reference photos (enroll), album folder/zip (scan).
- **Export**: **straight-copies** the kept source files (byte for byte, original format and
  metadata preserved, no re-encode) to a **user-chosen folder** or the **Photos app** (add-only).
  Format conversion is a deferred option, not in v1.

## Signature moment
The **matched-geometry transition** from a grid tile into the lightbox preview, paired with
keyboard Keep/Skip animating the tile's bucket state. The result is a tactile, fast culling
rhythm. Honor **Reduce Motion** (cross-fade instead).

## Voice / copy
Calm, plain, privacy-forward, second person. Title case for buttons and menus ("Export 6 Kept",
"Re-scan"); sentence case for body text and hints. Empty states are invitations ("Enroll to start finding them
in your scans"). Never apologize. Errors say what happened and how to fix it.

## Accessibility floor
- Dynamic Type up to accessibility sizes without clipping.
- VoiceOver labels on every tile ("Candidate, IMG_1861, worth a look") and control.
- Color is never the sole signal (icon + label with keep/maybe).
- ≥44pt targets.
- Reduce Motion and Reduce Transparency respected.
- Intentional Dark Mode.
- Full keyboard operability (it's the primary input).
