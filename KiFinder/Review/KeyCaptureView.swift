import AppKit
import SwiftUI

/// A single keyboard command for the review grid, derived from a raw key code so
/// it is independent of character/modifier mapping quirks.
enum KeyCommand: Equatable {
    case left, right, up, down
    case keep // Return / keypad enter — keeps the focused tile (Finder ergonomics)
    case keepWithoutMatch // Shift-Return / Shift-keypad enter — keep with no face teach (item 37)
    case skip // Delete / Backspace / Forward-delete
    case preview // Space — toggles the full-size Quick Look-style center preview
    case close // Esc — closes the preview (and any open lightbox)
    case drawRegion // R — arms drawing a manual face region in the large preview
    case removeRegion // Shift-R — removes the current manual face region

    init?(keyCode: UInt16, shift: Bool = false) {
        switch keyCode {
        case 123: self = .left
        case 124: self = .right
        case 125: self = .down
        case 126: self = .up
        // return / keypad enter: Shift keeps WITHOUT teaching (item 37), plain keeps.
        case 36, 76: self = shift ? .keepWithoutMatch : .keep
        case 49: self = .preview // space
        case 53: self = .close // escape
        case 51, 117: self = .skip // delete (backspace) / forward delete
        // R: arm drawing a manual face region; Shift-R removes the current one.
        case 15: self = shift ? .removeRegion : .drawRegion
        default: return nil
        }
    }
}

/// Window-level keyboard capture for the review grid.
///
/// The previous SwiftUI `@FocusState` + per-tile `.onKeyPress` path did not
/// deliver `typeKey` events reliably inside a `LazyVGrid` of focusable tiles
/// under XCUITest, so arrow navigation never moved. A real AppKit first
/// responder receives `keyDown` dependably; we translate it to a `KeyCommand`
/// and let the model own focus/selection. This decouples "what is focused"
/// (model state, mirrored to the accessibility value) from "who receives keys"
/// (this view).
struct KeyCaptureView: NSViewRepresentable {
    let onCommand: (KeyCommand) -> Void

    func makeNSView(context _: Context) -> KeyCaptureNSView {
        let view = KeyCaptureNSView()
        view.onCommand = onCommand
        return view
    }

    func updateNSView(_ nsView: KeyCaptureNSView, context _: Context) {
        nsView.onCommand = onCommand
        nsView.ensureFirstResponder()
    }
}

/// Invisible NSView that claims (and re-claims) first responder and forwards
/// recognized key codes as `KeyCommand`s.
final class KeyCaptureNSView: NSView {
    var onCommand: ((KeyCommand) -> Void)?
    private var grabTimer: Timer?

    override var acceptsFirstResponder: Bool {
        true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            grabTimer?.invalidate()
            grabTimer = nil
            return
        }
        ensureFirstResponder()
        // Self-healing: the window may not be key yet, and SwiftUI scene setup and
        // the inspector (lightbox) can transiently steal first responder. A short
        // repeating timer re-claims it so every keypress — including the very first
        // arrow under a UI test — lands here. Target-action (not a closure) keeps
        // this strict-concurrency clean.
        grabTimer?.invalidate()
        let timer = Timer(
            timeInterval: 0.1,
            target: self,
            selector: #selector(grabTick),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .common)
        grabTimer = timer
    }

    @objc private func grabTick() {
        ensureFirstResponder()
    }

    /// Claims first responder for the culling keys — but ONLY when focus is
    /// *unset* (the window itself, its content view, or nil). If the user has
    /// moved focus to a real control via Tab / Full Keyboard Access (a toolbar
    /// button, the Hide-reviewed toggle, a sidebar row, an inspector button) or is
    /// editing text, this leaves it alone. Perpetually re-grabbing regardless —
    /// the previous behavior — made every other control keyboard-unreachable,
    /// defeating system-wide keyboard access. Culling self-heals: whenever focus
    /// returns to the unset state (scene setup, an inspector dismiss), the next
    /// tick reclaims it so keys still land on the grid by default.
    func ensureFirstResponder() {
        guard let window else { return }
        let current = window.firstResponder
        guard current !== self else { return }
        let focusIsUnset = current == nil
            || current === window
            || current === window.contentView
        guard focusIsUnset else { return }
        window.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        let shift = event.modifierFlags.contains(.shift)
        if let command = KeyCommand(keyCode: event.keyCode, shift: shift) {
            onCommand?(command)
        } else {
            super.keyDown(with: event)
        }
    }
}
