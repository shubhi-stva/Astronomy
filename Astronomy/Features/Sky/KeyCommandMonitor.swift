//
//  KeyCommandMonitor.swift
//  Astronomy
//
//  Window-local keyboard shortcuts for the sky.
//
//  Why not `.keyboardShortcut` on a hidden `Button`: SwiftUI implements those
//  as AppKit *key equivalents*, and `performKeyEquivalent(with:)` is dispatched
//  before `keyDown(with:)` reaches the first responder. A bare-letter shortcut
//  declared that way therefore fires while the user is typing a letter into the
//  search field or the command palette, which is exactly the shortcut the
//  founding brief asks for (`N` for night vision). A local `keyDown` monitor
//  can ask what the first responder is before deciding, which is the one thing
//  the declarative form cannot do.
//
//  Modified shortcuts (⌘K) are unambiguous and are handled here too, purely so
//  there is one place that knows the app's key map.
//

import AppKit
import SwiftUI

/// A zero-size view that installs a window-local `keyDown` monitor for as long
/// as it is on screen.
struct KeyCommandMonitor: NSViewRepresentable {

    /// Returns true when the event was consumed; false passes it on.
    let handler: (KeyCommand) -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.handler = handler
        context.coordinator.install()
        return NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.handler = handler
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.remove()
    }

    @MainActor
    final class Coordinator {
        var handler: ((KeyCommand) -> Bool)?
        private var monitor: Any?

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let handler = self.handler else { return event }
                guard let command = KeyCommand(event: event, isEditing: Self.isEditingText())
                else { return event }
                return handler(command) ? nil : event
            }
        }

        func remove() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        /// True when a text field owns the keyboard. SwiftUI's `TextField` is
        /// backed by the window's shared field editor, an `NSTextView`, so this
        /// is the check that keeps a bare letter from being stolen mid-word.
        private static func isEditingText() -> Bool {
            let responder = NSApp.keyWindow?.firstResponder
            if responder is NSTextView { return true }
            if let view = responder as? NSView, view is NSTextField { return true }
            return false
        }
    }
}

/// The app's key map, as a value.
///
/// Modelled rather than matched inline so `KeyCommandTests` can assert the
/// routing without an event loop, and so the palette's own help text and this
/// list cannot drift apart.
enum KeyCommand: Equatable {
    /// ⌘K — open the command palette.
    case openCommandPalette
    /// N — toggle night vision. Suppressed while text is being edited.
    case toggleNightVision
    /// M — start (or clear) the angular-measurement tool.
    case measure
    /// G — the equatorial grid. The one reference layer common enough to earn
    /// a bare letter.
    case toggleGrid
    /// P — the satellite passes panel.
    case togglePasses
    /// Esc — dismiss whatever transient surface is open.
    case dismiss

    /// Escape's key code. Matched by code rather than by character because
    /// Escape has no character on every keyboard layout.
    static let escapeKeyCode: UInt16 = 53

    init?(event: NSEvent, isEditing: Bool) {
        self.init(
            characters: event.charactersIgnoringModifiers ?? "",
            modifiers: event.modifierFlags.intersection(.deviceIndependentFlagsMask),
            keyCode: event.keyCode,
            isEditing: isEditing
        )
    }

    /// The routing itself, as a pure function of the four things an event
    /// contributes. This is the form the tests exercise.
    init?(
        characters rawCharacters: String,
        modifiers: NSEvent.ModifierFlags,
        keyCode: UInt16,
        isEditing: Bool
    ) {
        let command = modifiers.contains(.command)
        let onlyCommand = modifiers.subtracting([.command, .function, .numericPad]).isEmpty
        let characters = rawCharacters.lowercased()

        if command, onlyCommand, characters == "k" {
            self = .openCommandPalette
            return
        }
        if keyCode == Self.escapeKeyCode {
            self = .dismiss
            return
        }
        // Bare letters only, and never while something is being typed into.
        let bare = modifiers.subtracting([.function, .numericPad]).isEmpty
        guard !isEditing, bare else { return nil }
        switch characters {
        case "n": self = .toggleNightVision
        case "m": self = .measure
        case "g": self = .toggleGrid
        case "p": self = .togglePasses
        default: return nil
        }
    }
}
