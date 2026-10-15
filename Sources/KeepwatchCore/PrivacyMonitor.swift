import CoreAudio
import CoreMediaIO
import Foundation

/// A process that is currently recording from a microphone.
public struct MicUser: Equatable, Hashable, Sendable {
    public var pid: Int32
    public var bundleID: String?
}

/// A point-in-time view of mic and camera use. Reading this needs no mic or
/// camera permission: Keepwatch never captures anything, it only asks the
/// system whether a device is running.
public struct PrivacySnapshot: Equatable, Sendable {
    public var micInUse: Bool
    public var cameraInUse: Bool
    /// Who is recording, from the CoreAudio process list (macOS 14+).
    /// Empty when the mic is in use but the system didn't say by whom.
    public var micUsers: [MicUser]
    /// Whether the default input device is muted; nil if it has no mute control.
    public var micMuted: Bool?

    public static let idle = PrivacySnapshot(micInUse: false, cameraInUse: false, micUsers: [], micMuted: nil)
}

/// Reads mic and camera state from CoreAudio and CoreMediaIO.
public enum PrivacyMonitor {
    /// Cap on how many audio objects or camera devices we read, so a
    /// misreporting driver can't make us allocate without limit.
    static let maxObjects = 512

    public static func snapshot() -> PrivacySnapshot {
        let inputs = audioInputDevices()
        let micInUse = inputs.contains { audioDeviceIsRunningSomewhere($0) }
        return PrivacySnapshot(
            micInUse: micInUse,
            cameraInUse: cameraDevices().contains { cameraIsRunningSomewhere($0) },
            micUsers: micInUse ? processesRecording() : [],
            micMuted: defaultInputDevice().flatMap(inputMute)
        )
    }

    // MARK: Microphone

    static func audioObjectIDs(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr else { return [] }
        let count = min(Int(size) / MemoryLayout<AudioObjectID>.size, maxObjects)
        guard count > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: count)
        size = UInt32(count * MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    static func audioInputDevices() -> [AudioObjectID] {
        audioObjectIDs(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices).filter { device in
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                     mScope: kAudioObjectPropertyScopeInput,
                                                     mElement: kAudioObjectPropertyElementMain)
            var size: UInt32 = 0
            return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
        }
    }

    static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(object, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    static func audioDeviceIsRunningSomewhere(_ device: AudioObjectID) -> Bool {
        (uint32(device, kAudioDevicePropertyDeviceIsRunningSomewhere) ?? 0) != 0
    }

    static func defaultInputDevice() -> AudioObjectID? {
        guard let id = uint32(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice),
              id != kAudioObjectUnknown else { return nil }
        return AudioObjectID(id)
    }

    static func inputMute(_ device: AudioObjectID) -> Bool? {
        uint32(device, kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeInput).map { $0 != 0 }
    }

    /// Processes with input running, from the macOS 14 process objects.
    static func processesRecording() -> [MicUser] {
        audioObjectIDs(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList)
            .compactMap { process -> MicUser? in
                guard (uint32(process, kAudioProcessPropertyIsRunningInput) ?? 0) != 0 else { return nil }
                let pid = uint32(process, kAudioProcessPropertyPID).map { Int32(bitPattern: $0) } ?? -1
                return MicUser(pid: pid, bundleID: string(process, kAudioProcessPropertyBundleID))
            }
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(object, &address) else { return nil }
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr,
              let cf = value?.takeRetainedValue() else { return nil }
        let s = cf as String
        return s.isEmpty ? nil : s
    }

    /// Mute or unmute the default input device. Returns false if the device has
    /// no settable mute. This is a soft mute: another app can unmute it.
    @discardableResult
    public static func setMicMuted(_ muted: Bool) -> Bool {
        guard let device = defaultInputDevice() else { return false }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioObjectPropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(device, &address),
              AudioObjectIsPropertySettable(device, &address, &settable) == noErr, settable.boolValue else { return false }
        var value: UInt32 = muted ? 1 : 0
        return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }

    /// Whether the default input device offers a mute control at all.
    public static var canMuteMic: Bool {
        guard let device = defaultInputDevice() else { return false }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioObjectPropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var settable: DarwinBoolean = false
        return AudioObjectHasProperty(device, &address)
            && AudioObjectIsPropertySettable(device, &address, &settable) == noErr && settable.boolValue
    }

    // MARK: Camera

    static func cameraDevices() -> [CMIOObjectID] {
        var address = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
                                                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var size: UInt32 = 0
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        guard CMIOObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        let count = min(Int(size) / MemoryLayout<CMIOObjectID>.size, maxObjects)
        guard count > 0 else { return [] }
        var ids = [CMIOObjectID](repeating: 0, count: count)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(system, &address, 0, nil, UInt32(count * MemoryLayout<CMIOObjectID>.size),
                                        &used, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(used) / MemoryLayout<CMIOObjectID>.size))
    }

    static func cameraIsRunningSomewhere(_ device: CMIOObjectID) -> Bool {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeWildcard),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementWildcard))
        guard CMIOObjectHasProperty(device, &address) else { return false }
        var value: UInt32 = 0
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &used, &value) == noErr
        else { return false }
        return value != 0
    }
}
