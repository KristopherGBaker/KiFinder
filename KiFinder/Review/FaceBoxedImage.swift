import AppKit
import ImageIO
import SwiftUI

/// Shared image-with-face-boxes renderer used by BOTH the inspector
/// `LightboxView` and the center Quick Look preview, so the box mapping and
/// orientation correction live in a single place.
///
/// The candidate carries each detected face in the image's raw (un-oriented)
/// pixel space; this view loads the image's natural aspect and EXIF orientation,
/// maps every box onto the on-screen, orientation-corrected, aspect-fit photo,
/// and draws them — the selected/emphasized face solid amber, the others as
/// dimmer dashed outlines. When `onSelectFace` is non-nil the boxes are tappable
/// (the inspector's re-point behavior); when it is `nil` the outlines are
/// display-only. When the candidate has no detected face, only the image shows.
struct FaceBoxedImage: View {
    let candidate: Candidate
    /// Longest-edge ceiling for the downsampled image load.
    var maxPixel: CGFloat
    /// Called with the index of a tapped face. `nil` ⇒ display-only outlines
    /// (no buttons; faces are not tappable, e.g. the read-only preview).
    var onSelectFace: ((Int) -> Void)?
    /// a11y identifier of the emphasized (selected) face; the others use
    /// `"\(identifierPrefix)-<index>"`.
    var identifierPrefix: String
    /// Ceiling on the displayed image's height; `nil` fills the available height.
    var maxDisplayHeight: CGFloat?
    /// Height reserved for the loading / failed placeholder.
    var placeholderHeight: CGFloat = 280
    /// When non-nil, an "draw a face region" affordance (a11y id `drawRegionButton`)
    /// is shown; a drag over the fitted photo produces a normalized **raw top-left**
    /// rect (the inverse of `aspectFitRect`+`orient`, clamped to 0…1) handed here.
    var onDrawRegion: ((CGRect) -> Void)?
    /// The `faceBoxes` index of the manually-drawn box (item 19), styled distinctly
    /// and exposed via a stable a11y marker; `nil` when there is no manual box.
    var manualFaceIndex: Int?
    /// When non-nil with a `manualFaceIndex`, a remove affordance (a11y id
    /// `removeManualRegionButton`) clears the drawn box.
    var onRemoveManualRegion: (() -> Void)?
    /// Whether the item-21 resize handles (`manualResizeHandle-*`) are offered on the
    /// manual box (item 25). Defaults to `false` — when off, the manual box still
    /// draws/removes but exposes NO resize handles; the user removes and re-draws to
    /// change it. Drawing/removing are never gated by this flag.
    var manualResizeEnabled: Bool = false
    /// When supplied, an external owner controls whether draw mode is armed — e.g. the
    /// 'R' keyboard shortcut in the large center preview flips this, and the on-screen
    /// `drawRegionButton` toggles the SAME state. When `nil` (the inspector lightbox)
    /// the view owns the flag internally and only the button arms drawing.
    var isDrawingArmed: Binding<Bool>?


    @State private var image: NSImage?
    /// Every detected face's box, in display (orientation-corrected) space, index
    /// aligned with `candidate.faceBoxes`.
    @State private var displayBoxes: [CGRect] = []
    @State private var displayAspect: CGFloat?
    @State private var orientation: CGImagePropertyOrientation = .up
    @State private var failed = false
    /// Internal fallback for the draw-armed flag when no external `isDrawingArmed`
    /// binding is supplied (the inspector lightbox).
    @State private var internalIsDrawing = false
    /// Whether draw mode is armed (a drag will define a new region) — the external
    /// binding when present (the large preview, so the 'R' shortcut and the button
    /// share it), else the internal @State.
    private var isDrawing: Binding<Bool> { isDrawingArmed ?? $internalIsDrawing }
    /// The in-progress drag rectangle in container POINTS (live preview), or nil.
    @State private var liveDragRect: CGRect?
    /// The in-progress RESIZE rectangle in container POINTS (item 21). While a manual
    /// box's handle is being dragged this tracks the live geometry so the outline and
    /// handles follow the drag; the re-embed fires only on release.
    @State private var liveResizeRect: CGRect?

    // MARK: - Zoom / pan (item 38)

    /// Current magnification of the displayed photo, in `[1, maxZoom]`. `1` is fit.
    @State private var zoom: CGFloat = 1
    /// Current pan offset (container points) of the zoomed photo about the view center;
    /// bounded by the overscan so the image can't be dragged past its scaled edges.
    @State private var pan: CGSize = .zero
    /// The committed zoom at the START of a magnification gesture (the gesture reports a
    /// factor relative to its start, so we multiply by this base each frame).
    @State private var zoomBase: CGFloat = 1
    /// The committed pan at the START of a pan drag (each frame adds the drag translation).
    @State private var panBase: CGSize = .zero
    /// The measured size of the displayed photo's container, captured so the pan/zoom
    /// gestures and clamps have the geometry they need.
    @State private var containerSize: CGSize = .zero

    /// Hard ceiling on magnification — generous enough to inspect a small face, bounded
    /// so the bitmap never blurs into uselessness.
    static let maxZoom: CGFloat = 6

    var body: some View {
        content
            .task(id: candidate.id) { await load() }
            // A drawn/removed manual region mutates `faceBoxes` without changing the
            // photo id, so re-map the display boxes here (the load task won't re-fire).
            .onChange(of: candidate.faceBoxes) { _, boxes in
                guard displayAspect != nil else { return }
                displayBoxes = boxes.map { Self.orient($0, orientation) }
            }
    }

    @ViewBuilder
    private var content: some View {
        if let image, let displayAspect {
            // Size the frame to the photo's own aspect so it fills the available
            // width (no letterboxing); `maxDisplayHeight` only bites very tall
            // portraits. The boxes overlay the SAME rect, so they stay aligned to
            // the displayed image — not the surrounding (padded) container.
            //
            // Item 38: the image + boxes + draw/resize canvas are wrapped in a SINGLE
            // transformed layer (`scaleEffect`+`offset`) so the boxes/handles scale and
            // pan WITH the bitmap; the draw/resize gestures live inside that layer and so
            // read pre-transform (un-zoomed) coordinates — at zoom 1 / pan .zero the math
            // is byte-identical to before. The pan/zoom/reset gestures sit on the OUTER
            // (un-transformed) container.
            Color.clear
                .aspectRatio(displayAspect, contentMode: .fit)
                .overlay {
                    mediaStack(image: image, aspect: displayAspect)
                        .scaleEffect(zoom, anchor: .center)
                        .offset(pan)
                }
                .overlay(alignment: .topTrailing) { drawControls }
                .overlay(alignment: .topLeading) { zoomControls }
                .onGeometryChange(for: CGSize.self) { $0.size } action: { containerSize = $0 }
                .background {
                    // Scroll / two-finger-scroll to zoom (mouse + trackpad). scrollWheel is a
                    // distinct event from SwiftUI's tap/drag, so it never fights pan/draw.
                    ScrollZoomCatcher { delta in
                        setZoom(Self.scrollZoom(zoom, deltaY: delta, max: Self.maxZoom))
                    }
                }
                .contentShape(Rectangle())
                .gesture(zoomGesture)
                .gesture(panGesture)
                .onTapGesture(count: 2) { resetZoom() }
                .frame(maxWidth: .infinity, maxHeight: maxDisplayHeight ?? .infinity)
        } else if failed {
            placeholder.frame(height: placeholderHeight)
        } else {
            placeholder
                .redacted(reason: .placeholder)
                .frame(height: placeholderHeight)
        }
    }

    /// The transformed visual stack: the photo plus every face box, the draw canvas, and
    /// the resize handles. Wrapped by `content` in `.scaleEffect`/`.offset` so all of it
    /// scales/pans together (item 38, assertion 5 — boxes share the image's transform).
    private func mediaStack(image: NSImage, aspect: CGFloat) -> some View {
        Color.clear
            .overlay {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .accessibilityHidden(true)
            }
            .overlay {
                if !displayBoxes.isEmpty {
                    GeometryReader { proxy in
                        ForEach(displayBoxes.indices, id: \.self) { index in
                            faceBox(index: index, box: displayBoxes[index], aspect: aspect, in: proxy.size)
                        }
                    }
                }
            }
            .overlay {
                if onDrawRegion != nil {
                    drawLayer(aspect: aspect)
                }
            }
            .overlay {
                // Item 21: resize handles on the MANUAL box only, and only when
                // the user isn't mid-draw (the draw canvas owns the gestures then).
                // Item 25: gated behind the opt-in `manualResizeEnabled` preference
                // — off by default, so no `manualResizeHandle-*` handles are emitted.
                if manualResizeEnabled, onDrawRegion != nil, !isDrawing.wrappedValue,
                   let manualFaceIndex, displayBoxes.indices.contains(manualFaceIndex)
                {
                    resizeHandlesLayer(box: displayBoxes[manualFaceIndex], aspect: aspect)
                }
            }
    }

    // MARK: - Zoom / pan controls (item 38)

    /// Localized a11y label for the reset-zoom control.
    private static let resetZoomLabel: String = String(localized: "Reset zoom")

    /// Per-press zoom factor for the +/- buttons.
    static let zoomStep: CGFloat = 1.5

    /// Always-visible zoom cluster (−, +, reset-to-fit) so zoom is discoverable and works
    /// with a mouse (pinch + scroll-wheel still work too). Reset/− disable at fit; + at max.
    private var zoomControls: some View {
        HStack(spacing: 4) {
            Button { setZoom(Self.steppedZoom(zoom, by: 1 / Self.zoomStep, max: Self.maxZoom)) } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .accessibilityIdentifier("zoomOutButton")
            .accessibilityLabel("Zoom out")
            .disabled(zoom <= 1)

            Button { setZoom(Self.steppedZoom(zoom, by: Self.zoomStep, max: Self.maxZoom)) } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .accessibilityIdentifier("zoomInButton")
            .accessibilityLabel("Zoom in")
            .disabled(zoom >= Self.maxZoom)

            Button { resetZoom() } label: {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
            }
            .accessibilityIdentifier("resetZoomButton")
            .accessibilityLabel(Self.resetZoomLabel)
            .disabled(zoom <= 1)
        }
        .buttonStyle(.borderless)
        .labelStyle(.iconOnly)
        .font(.system(size: 14, weight: .semibold))
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        // Frosted backing + hairline so the controls stay legible over ANY photo (light or
        // dark) instead of sitting directly on the variable image.
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
        .padding(8)
    }

    /// Commits a new zoom level (buttons / scroll-wheel), re-clamping pan + the gesture bases.
    private func setZoom(_ newZoom: CGFloat) {
        zoom = Self.clampZoom(newZoom, max: Self.maxZoom)
        zoomBase = zoom
        clampPanToOverscan()
        panBase = pan
    }

    /// Multiplies `current` by `factor` (the +/- buttons), clamped to `[1, maxZoom]`. Pure.
    nonisolated static func steppedZoom(_ current: CGFloat, by factor: CGFloat, max maxZoom: CGFloat) -> CGFloat {
        clampZoom(current * factor, max: maxZoom)
    }

    /// Maps a scroll-wheel `deltaY` to a multiplicative zoom nudge (scroll up = zoom in),
    /// clamped to `[1, maxZoom]`. Pure. Sensitivity tuned for trackpad + mouse wheel.
    nonisolated static func scrollZoom(_ current: CGFloat, deltaY: CGFloat, max maxZoom: CGFloat) -> CGFloat {
        clampZoom(current * (1 + deltaY * 0.005), max: maxZoom)
    }

    /// Pinch-to-zoom. The gesture reports a factor relative to its start, so we scale the
    /// committed `zoomBase` and clamp to `[1, maxZoom]`, re-clamping the pan as the
    /// overscan shrinks. Commits on release.
    private var zoomGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                zoom = Self.clampZoom(zoomBase * value, max: Self.maxZoom)
                clampPanToOverscan()
            }
            .onEnded { value in
                zoom = Self.clampZoom(zoomBase * value, max: Self.maxZoom)
                zoomBase = zoom
                clampPanToOverscan()
                panBase = pan
            }
    }

    /// Drag-to-pan, active only while zoomed and NOT drawing (the draw canvas owns drags
    /// when armed). Each frame adds the drag translation to the committed `panBase`,
    /// bounded by the overscan. Commits on release.
    private var panGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                guard !isDrawing.wrappedValue, zoom > 1 else { return }
                let fitted = Self.aspectFitRect(aspect: displayAspect ?? 1, in: containerSize)
                pan = Self.clampPan(
                    CGSize(width: panBase.width + value.translation.width,
                           height: panBase.height + value.translation.height),
                    zoom: zoom, fitted: fitted, container: containerSize
                )
            }
            .onEnded { _ in
                guard !isDrawing.wrappedValue, zoom > 1 else { return }
                panBase = pan
            }
    }

    private func clampPanToOverscan() {
        let fitted = Self.aspectFitRect(aspect: displayAspect ?? 1, in: containerSize)
        pan = Self.clampPan(pan, zoom: zoom, fitted: fitted, container: containerSize)
    }

    /// Return to fit (zoom 1, pan .zero). Wired to `resetZoomButton` and double-click.
    private func resetZoom() {
        zoom = 1
        zoomBase = 1
        pan = .zero
        panBase = .zero
    }

    private var placeholder: some View {
        DesignColor.hairline.overlay {
            Image(systemName: "photo")
                .font(.largeTitle)
                .foregroundStyle(DesignColor.inkSecondary)
        }
    }

    /// Draws one face's box over the aspect-fit display rect of the photo. The
    /// selected face is solid amber; the others are dimmer and dashed. When
    /// `onSelectFace` is set, the non-selected boxes are tappable so the user can
    /// re-point the match (the inspector behavior). `box` is normalized (0…1,
    /// top-left) in the displayed (orientation-corrected) image space.
    ///
    /// A face is "selected"/emphasized only when its index equals the candidate's
    /// `selectedFaceIndex`; since we iterate `displayBoxes.indices`, a `nil` or
    /// out-of-range `selectedFaceIndex` simply matches nothing — every box renders
    /// as a secondary indexed outline and no emphasized box is emitted.
    @ViewBuilder
    private func faceBox(index: Int, box: CGRect, aspect: CGFloat, in container: CGSize) -> some View {
        let fitted = Self.aspectFitRect(aspect: aspect, in: container)
        let isManual = index == manualFaceIndex
        let selected = index == candidate.selectedFaceIndex
        // A manually-drawn box reads in its own accent (solid, distinct from the amber
        // auto-selected and the white secondary outlines).
        let strokeColor = isManual ? DesignColor.manualRegion : (selected ? DesignColor.maybe : Color.white.opacity(0.85))
        let outline = RoundedRectangle(cornerRadius: 8)
            .fill(isManual ? DesignColor.manualRegion.opacity(0.16) : (selected ? DesignColor.maybe.opacity(0.14) : .clear))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        strokeColor,
                        style: StrokeStyle(
                            lineWidth: (selected || isManual) ? 3 : 2,
                            dash: isManual ? [4, 3] : (selected ? [] : [5, 4])
                        )
                    )
            }
            .contentShape(Rectangle())
        // On-screen rect in container points. While THIS manual box is being resized
        // (item 21), follow the live rect so the outline tracks the handle drag; the
        // stored normalized box only updates on release (re-embed).
        let onScreen = (isManual ? liveResizeRect : nil) ?? CGRect(
            x: fitted.minX + box.minX * fitted.width,
            y: fitted.minY + box.minY * fitted.height,
            width: box.width * fitted.width,
            height: box.height * fitted.height
        )
        let width = onScreen.width
        let height = onScreen.height
        let x = onScreen.midX
        let y = onScreen.midY
        // Stable a11y marker: a manual box is `"\(identifierPrefix)-manual"`,
        // separating it from the auto boxes' selected/indexed identifiers.
        let identifier = isManual
            ? "\(identifierPrefix)-manual"
            : (selected ? identifierPrefix : "\(identifierPrefix)-\(index)")

        if let onSelectFace {
            Button {
                onSelectFace(index)
            } label: {
                outline
            }
            .buttonStyle(.plain)
            .disabled(selected || isManual)
            .frame(width: width, height: height)
            .position(x: x, y: y)
            .accessibilityAddTraits((selected || isManual) ? .isImage : .isButton)
            .accessibilityIdentifier(identifier)
            .accessibilityLabel(
                isManual
                    ? String(localized: "Drawn face")
                    : (selected
                        ? String(localized: "Detected face")
                        : String(localized: "Other face \(index + 1), tap to select"))
            )
        } else {
            // Display-only: a non-interactive outline that is still exposed to
            // assistive tech (and queryable by identifier). The non-localized
            // fallback label for secondary faces avoids adding catalog keys; the
            // meaningful description lives on the enclosing preview (fileName).
            let displayLabel: String = isManual
                ? String(localized: "Drawn face")
                : (selected ? String(localized: "Detected face") : "Face \(index + 1)")
            outline
                .frame(width: width, height: height)
                .position(x: x, y: y)
                .accessibilityElement()
                .accessibilityAddTraits(.isImage)
                .accessibilityIdentifier(identifier)
                .accessibilityLabel(displayLabel)
        }
    }

    private func load() async {
        image = nil
        displayBoxes = []
        displayAspect = nil
        failed = false

        if let url = candidate.sourceURL {
            let px = maxPixel
            let loaded = await Task.detached(priority: .userInitiated) {
                let image = CandidateImage.downsample(url: url, maxPixel: px)
                let geometry = Self.rawGeometry(url: url)
                return (image, geometry)
            }.value
            guard let nsImage = loaded.0 else { failed = true; return }
            image = nsImage
            apply(rawAspect: loaded.1?.aspect, orientation: loaded.1?.orientation ?? .up)
        } else if !candidate.imageResourceName.isEmpty,
                  let url = Bundle.main.url(forResource: candidate.imageResourceName, withExtension: "png"),
                  let nsImage = NSImage(contentsOf: url)
        {
            image = nsImage
            // Bundled sample PNGs carry no EXIF orientation.
            apply(rawAspect: Self.aspect(of: nsImage), orientation: .up)
        } else {
            failed = true
        }
    }

    /// Maps the raw-space face boxes and aspect into displayed (oriented) space.
    private func apply(rawAspect: CGFloat?, orientation: CGImagePropertyOrientation) {
        guard let rawAspect, rawAspect > 0 else { return }
        self.orientation = orientation
        displayAspect = Self.isQuarterTurn(orientation) ? 1 / rawAspect : rawAspect
        displayBoxes = candidate.faceBoxes.map { Self.orient($0, orientation) }
    }

    // MARK: - Draw region (item 19)

    /// Transparent drag-catching layer over the fitted photo, active only while draw
    /// mode is armed; renders the live rectangle as it's dragged. On end, converts the
    /// displayed-space drag to a normalized raw top-left rect and calls `onDrawRegion`.
    private func drawLayer(aspect: CGFloat) -> some View {
        GeometryReader { proxy in
            let fitted = Self.aspectFitRect(aspect: aspect, in: proxy.size)
            ZStack {
                if isDrawing.wrappedValue {
                    Rectangle()
                        .fill(Color.black.opacity(0.001))
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 2)
                                .onChanged { value in
                                    liveDragRect = Self.dragRect(from: value, clampedTo: fitted)
                                }
                                .onEnded { value in
                                    let rect = Self.dragRect(from: value, clampedTo: fitted)
                                    liveDragRect = nil
                                    isDrawing.wrappedValue = false
                                    let raw = Self.rawRegion(
                                        fromDisplayedRect: rect,
                                        aspect: aspect,
                                        orientation: orientation,
                                        in: proxy.size
                                    )
                                    if raw.width > 0, raw.height > 0 { onDrawRegion?(raw) }
                                }
                        )
                        .accessibilityIdentifier("drawRegionCanvas")
                }
                if let live = liveDragRect {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(DesignColor.manualRegion, style: StrokeStyle(lineWidth: 2, dash: [6, 3]))
                        .frame(width: live.width, height: live.height)
                        .position(x: live.midX, y: live.midY)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    /// Draw-mode toggle (a11y id `drawRegionButton`) plus, when a manual box exists,
    /// a remove control (a11y id `removeManualRegionButton`).
    @ViewBuilder
    private var drawControls: some View {
        if onDrawRegion != nil {
            HStack(spacing: 8) {
                if onRemoveManualRegion != nil, manualFaceIndex != nil {
                    Button {
                        onRemoveManualRegion?()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .accessibilityIdentifier("removeManualRegionButton")
                    .accessibilityLabel("Remove drawn face")
                }
                Button {
                    isDrawing.wrappedValue.toggle()
                    liveDragRect = nil
                } label: {
                    Image(systemName: isDrawing.wrappedValue ? "rectangle.dashed" : "rectangle.badge.plus")
                }
                .accessibilityIdentifier("drawRegionButton")
                .accessibilityLabel(isDrawing.wrappedValue ? "Cancel drawing a face" : "Draw a face")
            }
            .buttonStyle(.borderedProminent)
            .tint(DesignColor.manualRegion)
            .padding(8)
        }
    }

    // MARK: - Resize handles (item 21)

    /// Side length (container points) of a handle's transparent hit target; large
    /// enough to grab comfortably without overlapping neighbours on a small box.
    private static let resizeHitTarget: CGFloat = 30
    /// Visible diameter (container points) of a handle dot.
    private static let resizeDotSize: CGFloat = 14
    /// The smallest a resized box may get on either axis, in container points — keeps
    /// the box grabbable and guarantees the raw result stays non-degenerate so the
    /// engine never rejects it.
    static let resizeMinSize: CGFloat = 24
    /// Non-localized a11y label for the body/move target (no catalog key).
    private static let moveLabel: String = "Move drawn face"

    /// Overlay of 8 edge/corner handles plus a body/move target, drawn on the MANUAL
    /// box only. Each handle drives a live `@State` rect during the gesture and, on
    /// release, converts the final rect to a raw region and calls `onDrawRegion` ONCE
    /// (re-embed on release only) — routing through the same replace-in-place path as
    /// draw. `box` is the manual box in displayed (orientation-corrected) space.
    private func resizeHandlesLayer(box: CGRect, aspect: CGFloat) -> some View {
        GeometryReader { proxy in
            let fitted = Self.aspectFitRect(aspect: aspect, in: proxy.size)
            // The stored box's on-screen rect — the START for every gesture (the box
            // doesn't mutate mid-drag, so this stays the gesture's anchor).
            let base = CGRect(
                x: fitted.minX + box.minX * fitted.width,
                y: fitted.minY + box.minY * fitted.height,
                width: box.width * fitted.width,
                height: box.height * fitted.height
            )
            // What the handles render around: the live rect during a drag, else `base`.
            let shown = liveResizeRect ?? base
            ZStack {
                // Body/move target spanning the box interior.
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .frame(width: shown.width, height: shown.height)
                    .position(x: shown.midX, y: shown.midY)
                    .gesture(resizeGesture(handle: .body, start: base, fitted: fitted, aspect: aspect, in: proxy.size))
                    .accessibilityElement()
                    .accessibilityAddTraits(.allowsDirectInteraction)
                    .accessibilityLabel(Self.moveLabel)
                    .accessibilityIdentifier("manualResizeHandle-body")

                ForEach(Self.ResizeHandle.edges, id: \.self) { handle in
                    let point = Self.handlePosition(handle, in: shown)
                    // Plain (non-localized) label so no catalog key is added — mirrors
                    // the secondary-face fallback label.
                    let label = "Resize drawn face \(handle.rawValue)"
                    handleDot
                        .position(x: point.x, y: point.y)
                        .gesture(resizeGesture(handle: handle, start: base, fitted: fitted, aspect: aspect, in: proxy.size))
                        .accessibilityElement()
                        .accessibilityAddTraits(.allowsDirectInteraction)
                        .accessibilityLabel(label)
                        .accessibilityIdentifier("manualResizeHandle-\(handle.rawValue)")
                }
            }
        }
    }

    /// One handle dot: a small accent circle centered in a larger transparent hit area.
    private var handleDot: some View {
        ZStack {
            Color.black.opacity(0.001)
                .frame(width: Self.resizeHitTarget, height: Self.resizeHitTarget)
                .contentShape(Rectangle())
            Circle()
                .fill(DesignColor.manualRegion)
                .overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
                .frame(width: Self.resizeDotSize, height: Self.resizeDotSize)
        }
    }

    /// The drag gesture for one handle. `.onChanged` updates the live rect each frame;
    /// `.onEnded` commits exactly once — converting the final rect to a raw region and
    /// firing `onDrawRegion` (the embed/rescore trigger).
    private func resizeGesture(
        handle: ResizeHandle,
        start: CGRect,
        fitted: CGRect,
        aspect: CGFloat,
        in container: CGSize
    ) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                liveResizeRect = Self.resizedRect(
                    from: start,
                    handle: handle,
                    translation: value.translation,
                    clampedTo: fitted,
                    minSize: Self.resizeMinSize
                )
            }
            .onEnded { value in
                let finalRect = Self.resizedRect(
                    from: start,
                    handle: handle,
                    translation: value.translation,
                    clampedTo: fitted,
                    minSize: Self.resizeMinSize
                )
                liveResizeRect = nil
                let raw = Self.rawRegion(
                    fromDisplayedRect: finalRect,
                    aspect: aspect,
                    orientation: orientation,
                    in: container
                )
                if raw.width > 0, raw.height > 0 { onDrawRegion?(raw) }
            }
    }

    // MARK: - Geometry

    /// The largest rect of the given aspect (w/h) centered inside `size` — the
    /// rect a `scaledToFit` image occupies.
    nonisolated static func aspectFitRect(aspect: CGFloat, in size: CGSize) -> CGRect {
        guard aspect > 0, size.width > 0, size.height > 0 else {
            return CGRect(origin: .zero, size: size)
        }
        var fitted = size
        if aspect > size.width / size.height {
            fitted.height = size.width / aspect
        } else {
            fitted.width = size.height * aspect
        }
        return CGRect(
            x: (size.width - fitted.width) / 2,
            y: (size.height - fitted.height) / 2,
            width: fitted.width,
            height: fitted.height
        )
    }

    // MARK: - Zoom / pan transform (item 38)

    /// Maps a point from CONTAINER space back into the un-transformed fitted-image space,
    /// inverting `.scaleEffect(zoom, anchor: .center).offset(pan)`. The anchor is the view
    /// center, which — because `aspectFitRect` centers the photo in the container — is the
    /// fitted rect's center. At `zoom 1, pan .zero` this is the IDENTITY.
    nonisolated static func containerToFitted(
        _ point: CGPoint,
        fitted: CGRect,
        zoom: CGFloat,
        pan: CGSize
    ) -> CGPoint {
        let z = zoom == 0 ? 1 : zoom
        let cx = fitted.midX
        let cy = fitted.midY
        return CGPoint(
            x: cx + (point.x - pan.width - cx) / z,
            y: cy + (point.y - pan.height - cy) / z
        )
    }

    /// The forward of `containerToFitted`: maps a point from the un-transformed
    /// fitted-image space to where it lands on screen under `zoom`/`pan` about the view
    /// center. `fittedToContainer(containerToFitted(p)) == p` (round-trip inverse).
    nonisolated static func fittedToContainer(
        _ point: CGPoint,
        fitted: CGRect,
        zoom: CGFloat,
        pan: CGSize
    ) -> CGPoint {
        let cx = fitted.midX
        let cy = fitted.midY
        return CGPoint(
            x: cx + (point.x - cx) * zoom + pan.width,
            y: cy + (point.y - cy) * zoom + pan.height
        )
    }

    /// Inverts the zoom/pan transform for a whole rect by mapping its two opposite
    /// corners through `containerToFitted` (uniform scale + translation keeps it
    /// axis-aligned). Identity at `zoom 1 / pan .zero`.
    nonisolated static func containerToFittedRect(
        _ rect: CGRect,
        fitted: CGRect,
        zoom: CGFloat,
        pan: CGSize
    ) -> CGRect {
        let a = containerToFitted(CGPoint(x: rect.minX, y: rect.minY), fitted: fitted, zoom: zoom, pan: pan)
        let b = containerToFitted(CGPoint(x: rect.maxX, y: rect.maxY), fitted: fitted, zoom: zoom, pan: pan)
        return CGRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(a.x - b.x),
            height: abs(a.y - b.y)
        )
    }

    /// Clamps a magnification into `[1, maxZoom]` (never below fit, never past the ceiling).
    nonisolated static func clampZoom(_ zoom: CGFloat, max maxZoom: CGFloat) -> CGFloat {
        min(max(zoom, 1), maxZoom)
    }

    /// Bounds a pan to the overscan: each axis is limited to `max(0, (scaledSize −
    /// containerSize) / 2)`, where `scaledSize = fittedSize * zoom`. At `zoom 1` the scaled
    /// photo never exceeds the container, so the bound is `0` and the pan is `.zero`; a
    /// letterboxed axis whose scaled size still fits also stays pinned (bound `0`).
    nonisolated static func clampPan(
        _ pan: CGSize,
        zoom: CGFloat,
        fitted: CGRect,
        container: CGSize
    ) -> CGSize {
        let boundX = max(0, (fitted.width * zoom - container.width) / 2)
        let boundY = max(0, (fitted.height * zoom - container.height) / 2)
        return CGSize(
            width: min(max(pan.width, -boundX), boundX),
            height: min(max(pan.height, -boundY), boundY)
        )
    }

    nonisolated static func isQuarterTurn(_ orientation: CGImagePropertyOrientation) -> Bool {
        switch orientation {
        case .left, .right, .leftMirrored, .rightMirrored: true
        default: false
        }
    }

    /// Transforms a normalized top-left rect from raw image space into the
    /// displayed space produced by applying `orientation` (the same transform
    /// ImageIO bakes into the rendered thumbnail).
    nonisolated static func orient(_ rect: CGRect, _ orientation: CGImagePropertyOrientation) -> CGRect {
        func map(_ p: CGPoint) -> CGPoint {
            switch orientation {
            case .up: CGPoint(x: p.x, y: p.y)
            case .upMirrored: CGPoint(x: 1 - p.x, y: p.y)
            case .down: CGPoint(x: 1 - p.x, y: 1 - p.y)
            case .downMirrored: CGPoint(x: p.x, y: 1 - p.y)
            case .leftMirrored: CGPoint(x: p.y, y: p.x)
            case .right: CGPoint(x: 1 - p.y, y: p.x)
            case .rightMirrored: CGPoint(x: 1 - p.y, y: 1 - p.x)
            case .left: CGPoint(x: p.y, y: 1 - p.x)
            @unknown default: CGPoint(x: p.x, y: p.y)
            }
        }
        let a = map(CGPoint(x: rect.minX, y: rect.minY))
        let b = map(CGPoint(x: rect.maxX, y: rect.maxY))
        return CGRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(a.x - b.x),
            height: abs(a.y - b.y)
        )
    }

    /// The exact inverse of `orient`: maps a normalized rect from displayed
    /// (orientation-corrected) space back to raw top-left image space. A drag in
    /// displayed space round-trips raw → `orient` → displayed and back via this.
    nonisolated static func unorient(_ rect: CGRect, _ orientation: CGImagePropertyOrientation) -> CGRect {
        func inverseMap(_ p: CGPoint) -> CGPoint {
            switch orientation {
            case .up: CGPoint(x: p.x, y: p.y)
            case .upMirrored: CGPoint(x: 1 - p.x, y: p.y)
            case .down: CGPoint(x: 1 - p.x, y: 1 - p.y)
            case .downMirrored: CGPoint(x: p.x, y: 1 - p.y)
            case .leftMirrored: CGPoint(x: p.y, y: p.x)
            case .right: CGPoint(x: p.y, y: 1 - p.x)
            case .rightMirrored: CGPoint(x: 1 - p.y, y: 1 - p.x)
            case .left: CGPoint(x: 1 - p.y, y: p.x)
            @unknown default: CGPoint(x: p.x, y: p.y)
            }
        }
        let a = inverseMap(CGPoint(x: rect.minX, y: rect.minY))
        let b = inverseMap(CGPoint(x: rect.maxX, y: rect.maxY))
        return CGRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(a.x - b.x),
            height: abs(a.y - b.y)
        )
    }

    /// Converts a drag rectangle in container POINTS into a normalized **raw
    /// top-left** rect: first undoes the `zoom`/`pan` transform (item 38 — identity at
    /// `zoom 1 / pan .zero`, so the legacy un-zoomed result is reproduced exactly), then
    /// removes the aspect-fit letterbox (so coordinates are relative to the displayed
    /// photo, not the padded container), then inverts the EXIF orientation, then clamps
    /// to 0…1. Shared by the draw/resize gestures and their unit tests so the on-screen
    /// math is exactly the tested math.
    nonisolated static func rawRegion(
        fromDisplayedRect dragRect: CGRect,
        aspect: CGFloat,
        orientation: CGImagePropertyOrientation,
        in container: CGSize,
        zoom: CGFloat = 1,
        pan: CGSize = .zero
    ) -> CGRect {
        let fitted = aspectFitRect(aspect: aspect, in: container)
        guard fitted.width > 0, fitted.height > 0 else { return .zero }
        // Undo zoom/pan back into un-transformed fitted space BEFORE removing the
        // letterbox (the two steps must compose in this order).
        let unzoomed = containerToFittedRect(dragRect, fitted: fitted, zoom: zoom, pan: pan)
        let displayedNormalized = CGRect(
            x: (unzoomed.minX - fitted.minX) / fitted.width,
            y: (unzoomed.minY - fitted.minY) / fitted.height,
            width: unzoomed.width / fitted.width,
            height: unzoomed.height / fitted.height
        )
        return clampedUnitRect(unorient(displayedNormalized, orientation))
    }

    /// A drag's start→current rectangle in container points, clamped to the fitted
    /// photo rect so a region can't be drawn into the letterbox.
    nonisolated static func dragRect(from value: DragGesture.Value, clampedTo fitted: CGRect) -> CGRect {
        let minX = max(fitted.minX, min(value.startLocation.x, value.location.x))
        let maxX = min(fitted.maxX, max(value.startLocation.x, value.location.x))
        let minY = max(fitted.minY, min(value.startLocation.y, value.location.y))
        let maxY = min(fitted.maxY, max(value.startLocation.y, value.location.y))
        return CGRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
    }

    /// Clamps a normalized rect into the unit square, preserving non-negative size.
    nonisolated static func clampedUnitRect(_ rect: CGRect) -> CGRect {
        let minX = max(0, min(1, rect.minX))
        let minY = max(0, min(1, rect.minY))
        let maxX = max(0, min(1, rect.maxX))
        let maxY = max(0, min(1, rect.maxY))
        return CGRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
    }

    // MARK: - Resize geometry (item 21)

    /// The eight edge/corner resize handles plus a body/move handle. The `rawValue`
    /// is the stable a11y suffix (`manualResizeHandle-<rawValue>`).
    enum ResizeHandle: String, CaseIterable {
        case topLeft, top, topRight
        case left, right
        case bottomLeft, bottom, bottomRight
        case body

        /// The eight edge/corner handles (everything except `body`), in a stable order.
        static var edges: [ResizeHandle] {
            [.topLeft, .top, .topRight, .left, .right, .bottomLeft, .bottom, .bottomRight]
        }

        var movesLeft: Bool {
            self == .topLeft || self == .left || self == .bottomLeft
        }

        var movesRight: Bool {
            self == .topRight || self == .right || self == .bottomRight
        }

        var movesTop: Bool {
            self == .topLeft || self == .top || self == .topRight
        }

        var movesBottom: Bool {
            self == .bottomLeft || self == .bottom || self == .bottomRight
        }
    }

    /// The on-screen point (container points) where a handle is drawn for `rect`.
    nonisolated static func handlePosition(_ handle: ResizeHandle, in rect: CGRect) -> CGPoint {
        switch handle {
        case .topLeft: CGPoint(x: rect.minX, y: rect.minY)
        case .top: CGPoint(x: rect.midX, y: rect.minY)
        case .topRight: CGPoint(x: rect.maxX, y: rect.minY)
        case .left: CGPoint(x: rect.minX, y: rect.midY)
        case .right: CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomLeft: CGPoint(x: rect.minX, y: rect.maxY)
        case .bottom: CGPoint(x: rect.midX, y: rect.maxY)
        case .bottomRight: CGPoint(x: rect.maxX, y: rect.maxY)
        case .body: CGPoint(x: rect.midX, y: rect.midY)
        }
    }

    /// Applies a handle drag to `start` (container points) and returns the new rect:
    /// corner handles move two edges, edge handles one, the body handle translates the
    /// whole rect. The result is clamped INSIDE `fitted` (never into the letterbox) and
    /// never smaller than `minSize` on either axis — the dragged edge stops rather than
    /// inverting. Pure, so the on-screen math is exactly the unit-tested math.
    nonisolated static func resizedRect(
        from start: CGRect,
        handle: ResizeHandle,
        translation: CGSize,
        clampedTo fitted: CGRect,
        minSize: CGFloat
    ) -> CGRect {
        // A box can't be wider/taller than the photo it lives in.
        let minW = min(minSize, fitted.width)
        let minH = min(minSize, fitted.height)

        if handle == .body {
            // Translate without resizing; keep the whole rect inside `fitted`.
            let width = min(start.width, fitted.width)
            let height = min(start.height, fitted.height)
            let x = min(max(start.minX + translation.width, fitted.minX), fitted.maxX - width)
            let y = min(max(start.minY + translation.height, fitted.minY), fitted.maxY - height)
            return CGRect(x: x, y: y, width: width, height: height)
        }

        var minX = start.minX
        var maxX = start.maxX
        var minY = start.minY
        var maxY = start.maxY

        if handle.movesLeft {
            // Left edge moves, right edge fixed: clamp to [fitted.minX, maxX - minW].
            minX = min(max(start.minX + translation.width, fitted.minX), maxX - minW)
        }
        if handle.movesRight {
            // Right edge moves, left edge fixed: clamp to [minX + minW, fitted.maxX].
            maxX = max(min(start.maxX + translation.width, fitted.maxX), minX + minW)
        }
        if handle.movesTop {
            minY = min(max(start.minY + translation.height, fitted.minY), maxY - minH)
        }
        if handle.movesBottom {
            maxY = max(min(start.maxY + translation.height, fitted.maxY), minY + minH)
        }

        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    // MARK: - Image metadata

    private nonisolated static func rawGeometry(url: URL) -> (aspect: CGFloat, orientation: CGImagePropertyOrientation)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              width > 0, height > 0
        else { return nil }
        let raw = (props[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
        let orientation = CGImagePropertyOrientation(rawValue: raw) ?? .up
        return (CGFloat(width / height), orientation)
    }

    private static func aspect(of image: NSImage) -> CGFloat? {
        if let rep = image.representations.first, rep.pixelsHigh > 0 {
            return CGFloat(rep.pixelsWide) / CGFloat(rep.pixelsHigh)
        }
        guard image.size.height > 0 else { return nil }
        return image.size.width / image.size.height
    }
}

/// Captures `scrollWheel` (mouse wheel + trackpad two-finger scroll) over the image and
/// forwards the vertical delta so the photo can scroll-to-zoom. A plain NSView background:
/// scrollWheel is a distinct event from SwiftUI's tap/drag gestures, so it never competes
/// with pan/draw. Horizontal-only scrolls fall through.
private struct ScrollZoomCatcher: NSViewRepresentable {
    let onScroll: (CGFloat) -> Void

    func makeNSView(context _: Context) -> ScrollCatchView {
        let view = ScrollCatchView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ nsView: ScrollCatchView, context _: Context) {
        nsView.onScroll = onScroll
    }
}

private final class ScrollCatchView: NSView {
    var onScroll: ((CGFloat) -> Void)?

    override func scrollWheel(with event: NSEvent) {
        let dy = event.scrollingDeltaY
        if dy != 0 {
            onScroll?(dy)
        } else {
            super.scrollWheel(with: event)
        }
    }
}
