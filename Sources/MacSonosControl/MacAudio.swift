import CoreAudio

/// Decides whether the Mac itself should keep the volume keys.
/// The Mac keeps them when sound goes somewhere other than the built-in speakers
/// (headphones, AirPods, HDMI, AirPlay, USB…), or when something is using the microphone (a call).
enum MacAudio {
    static func macShouldHandleVolume() -> Bool {
        guard let output = defaultDevice(kAudioHardwarePropertyDefaultOutputDevice) else { return false }

        if let transport = value(output, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal),
           transport != kAudioDeviceTransportTypeBuiltIn {
            return true
        }
        // Built-in output, but with headphones plugged into the jack.
        if let source = value(output, kAudioDevicePropertyDataSource, kAudioObjectPropertyScopeOutput),
           source == 0x6864_706E { // 'hdpn'
            return true
        }
        if let input = defaultDevice(kAudioHardwarePropertyDefaultInputDevice),
           let running = value(input, kAudioDevicePropertyDeviceIsRunningSomewhere, kAudioObjectPropertyScopeGlobal),
           running != 0 {
            return true
        }
        return false
    }

    private static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioObjectID? {
        guard let id = value(AudioObjectID(kAudioObjectSystemObject), selector, kAudioObjectPropertyScopeGlobal),
              id != kAudioObjectUnknown else { return nil }
        return id
    }

    private static func value(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                              _ scope: AudioObjectPropertyScope) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                                 mElement: kAudioObjectPropertyElementMain)
        var result: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &result) == noErr else { return nil }
        return result
    }
}
