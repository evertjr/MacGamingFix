import CoreAudio

class AudioSampleRate {
    private var originalRate: Float64?

    static let targetRate: Float64 = 44_100

    func activate() {
        guard let deviceID = defaultOutputDevice() else { return }
        guard let currentRate = sampleRate(of: deviceID) else { return }

        if currentRate == Self.targetRate {
            // Already at target — nothing to change, nothing to restore.
            return
        }

        originalRate = currentRate
        setSampleRate(Self.targetRate, on: deviceID)
    }

    func deactivate() {
        guard let rate = originalRate else { return }
        originalRate = nil

        guard let deviceID = defaultOutputDevice() else { return }
        setSampleRate(rate, on: deviceID)
    }

    deinit {
        deactivate()
    }

    // MARK: - CoreAudio Helpers

    private func defaultOutputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var deviceID: AudioDeviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0, nil,
            &size, &deviceID
        )

        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    private func sampleRate(of deviceID: AudioDeviceID) -> Float64? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)

        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0, nil,
            &size, &rate
        )

        guard status == noErr else { return nil }
        return rate
    }

    private func setSampleRate(_ rate: Float64, on deviceID: AudioDeviceID) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var newRate = rate
        AudioObjectSetPropertyData(
            deviceID,
            &address,
            0, nil,
            UInt32(MemoryLayout<Float64>.size), &newRate
        )
    }
}
