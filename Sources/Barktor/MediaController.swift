import CoreAudio

// Mute other apps' audio while a dictation records, restoring the prior state
// when it stops - the "don't make me talk over my own music" affordance.
// Public CoreAudio only: mute the default output device and put its previous
// mute flag back. Stateless, like SoundCues; the coordinator remembers the
// prior flag so it restores exactly that.
//
// (An earlier version also offered a "pause playback" mode via the system
// Play/Pause key, but that key is a directionless toggle and macOS exposes no
// reliable play-state to third-party apps since MediaRemote was gated behind a
// private entitlement in 15.4+ - so it would *start* music that was merely
// paused-but-warm. Mute is deterministic, which is why it's the only mode.)
@MainActor
enum MediaController {
    // Mute the default output device, returning its prior mute flag so the
    // caller can restore it. Returns nil (caller does nothing) when the device
    // has no settable master mute.
    // ponytail: master element only. Built-in output and most DACs support it;
    // an exotic device without it is a silent no-op. Upgrade to per-channel
    // mute only if that ever bites.
    static func mute() -> Bool? {
        guard let device = defaultOutputDevice() else { return nil }
        var addr = muteAddress()
        guard AudioObjectHasProperty(device, &addr) else { return nil }
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(device, &addr, &settable) == noErr, settable.boolValue
        else { return nil }
        let wasMuted = readMute(device)
        setMuted(device, true)
        return wasMuted
    }

    static func setMuted(_ muted: Bool) {
        guard let device = defaultOutputDevice() else { return }
        setMuted(device, muted)
    }

    // ---- CoreAudio helpers ----------------------------------------------

    private static func defaultOutputDevice() -> AudioObjectID? {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device) == noErr,
            device != kAudioObjectUnknown
        else { return nil }
        return device
    }

    private static func muteAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
    }

    private static func readMute(_ device: AudioObjectID) -> Bool {
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = muteAddress()
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &muted) == noErr
        else { return false }
        return muted != 0
    }

    private static func setMuted(_ device: AudioObjectID, _ muted: Bool) {
        var value: UInt32 = muted ? 1 : 0
        var addr = muteAddress()
        AudioObjectSetPropertyData(
            device, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }
}
