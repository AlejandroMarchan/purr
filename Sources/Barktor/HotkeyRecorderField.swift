import AppKit
import SwiftUI

// WisprFlow-style hotkey field: shows the current key and, on click, listens
// for the next keypress to rebind it. Captures both real combinations
// (⌃⌥ + key) and bare right-side modifiers (hold Right Option), which is the
// shape HotkeyManager actually watches for. `fn` and multi-modifier bare
// chords aren't supported at runtime, so they're not captured here either.
struct HotkeyRecorderField: View {
    let hotkey: Hotkey
    let onChange: (Hotkey) -> Void
    // Fired true when this field starts listening and false when it stops (by
    // any path: commit, Esc-cancel, tapping away, or the view disappearing).
    // The owner uses it to mute the global hotkey tap during capture.
    var onCapturingChange: (Bool) -> Void = { _ in }

    @State private var listening = false
    @State private var recorder = HotkeyRecorder()

    var body: some View {
        HStack(spacing: 6) {
            Text(listening ? "Press a key…" : hotkey.displayName)
                .foregroundStyle(listening ? Color.accentColor : .primary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Image(systemName: "pencil")
                .foregroundStyle(.secondary)
                .font(.system(size: 11))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(width: 190, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    listening ? Color.accentColor : Color(nsColor: .separatorColor),
                    lineWidth: listening ? 2 : 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { toggle() }
        .help("Click, then press the key or combination to use.")
        .onDisappear { stop() }
    }

    private func toggle() {
        if listening {
            stop()
        } else {
            listening = true
            // Mute the global tap *before* arming the monitor so no keypress
            // slips through and fires dictation mid-capture.
            onCapturingChange(true)
            recorder.start { captured in
                finishListening()
                onChange(captured)
            } onCancel: {
                finishListening()
            }
        }
    }

    private func stop() {
        recorder.stop()
        if listening { finishListening() }
    }

    private func finishListening() {
        listening = false
        onCapturingChange(false)
    }
}

// Owns the local event monitor for one recording session. A reference type so
// the monitor closure and the field's @State don't fight over value copies.
final class HotkeyRecorder {
    private var monitor: Any?
    private var onCapture: ((Hotkey) -> Void)?
    private var onCancel: (() -> Void)?
    // Highest modifier combination seen while no normal key was pressed; a
    // bare-modifier hotkey is committed from it once every key is released.
    private var candidateBareModifiers: CGEventFlags = []

    func start(onCapture: @escaping (Hotkey) -> Void, onCancel: @escaping () -> Void) {
        stop()
        self.onCapture = onCapture
        self.onCancel = onCancel
        candidateBareModifiers = []
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) {
            [weak self] event in
            // Swallow events we consume so the keys don't leak into the app.
            (self?.handle(event) ?? false) ? nil : event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        onCapture = nil
        onCancel = nil
        candidateBareModifiers = []
    }

    private func handle(_ event: NSEvent) -> Bool {
        let mods = Self.cgFlags(from: event.modifierFlags)
        switch event.type {
        case .keyDown:
            // Esc alone cancels the recording without changing the binding.
            if event.keyCode == 53 && mods.isEmpty {
                let cancel = onCancel
                stop()
                cancel?()
                return true
            }
            let key = Hotkey(keyCode: Int64(event.keyCode), modifiers: mods)
            commit(key)
            return true
        case .flagsChanged:
            if mods.isEmpty {
                // Everything released: a lone right-modifier tap becomes a
                // bare-modifier hotkey; a multi-modifier chord is dropped
                // (HotkeyManager can't watch those) and recording continues.
                if Self.isSingleModifier(candidateBareModifiers) {
                    commit(Hotkey(keyCode: nil, modifiers: candidateBareModifiers))
                }
                candidateBareModifiers = []
            } else {
                candidateBareModifiers = mods
            }
            return true
        default:
            return false
        }
    }

    private func commit(_ hotkey: Hotkey) {
        let capture = onCapture
        stop()
        capture?(hotkey)
    }

    private static func cgFlags(from flags: NSEvent.ModifierFlags) -> CGEventFlags {
        var result: CGEventFlags = []
        if flags.contains(.command) { result.insert(.maskCommand) }
        if flags.contains(.option) { result.insert(.maskAlternate) }
        if flags.contains(.shift) { result.insert(.maskShift) }
        if flags.contains(.control) { result.insert(.maskControl) }
        return result
    }

    private static func isSingleModifier(_ flags: CGEventFlags) -> Bool {
        let bits: [CGEventFlags] = [.maskCommand, .maskAlternate, .maskShift, .maskControl]
        return bits.filter { flags.contains($0) }.count == 1
    }
}
