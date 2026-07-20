import CoreGraphics
import Foundation
import Testing

@testable import Barktor

struct DictationTriggerTests {
    // MARK: migrate

    @Test func cleanInstallSeedsRightOptionHold() {
        let trigger = DictationTrigger.migrate(
            legacyKeyCode: nil, legacyModifiers: nil, legacyMode: nil)
        #expect(trigger.hotkey == .defaultRightOption)
        #expect(trigger.gesture == .hold)
    }

    @Test func legacyToggleModeBecomesTapToggle() {
        let trigger = DictationTrigger.migrate(
            legacyKeyCode: nil,
            legacyModifiers: CGEventFlags.maskAlternate.rawValue,
            legacyMode: "toggle")
        #expect(trigger.gesture == .tapToggle)
        #expect(trigger.hotkey == .defaultRightOption)
    }

    @Test func legacyKeyComboIsPreserved() {
        // ⌃⌥ Space stored under the old scalars survives the fold.
        let mods: CGEventFlags = [.maskControl, .maskAlternate]
        let trigger = DictationTrigger.migrate(
            legacyKeyCode: 49, legacyModifiers: mods.rawValue, legacyMode: "holdToTalk")
        #expect(trigger.hotkey == Hotkey(keyCode: 49, modifiers: mods))
        #expect(trigger.gesture == .hold)
    }

    // MARK: Codable

    @Test func hotkeyCodableRoundTripsBothShapes() throws {
        let cases: [Hotkey] = [
            .defaultRightOption,  // bare modifier: keyCode nil
            Hotkey(keyCode: 96, modifiers: []),  // bare key
            Hotkey(keyCode: 49, modifiers: [.maskControl, .maskAlternate]),  // combo
        ]
        for hotkey in cases {
            let data = try JSONEncoder().encode(hotkey)
            let decoded = try JSONDecoder().decode(Hotkey.self, from: data)
            #expect(decoded == hotkey)
        }
    }

    @Test func triggerCodableRoundTrips() throws {
        let trigger = DictationTrigger(
            hotkey: Hotkey(keyCode: nil, modifiers: .maskCommand), gesture: .doubleTapToggle)
        let data = try JSONEncoder().encode(trigger)
        let decoded = try JSONDecoder().decode(DictationTrigger.self, from: data)
        #expect(decoded == trigger)
    }
}
