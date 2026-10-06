import Foundation
import CoreAudio
import AVFoundation

/// A system audio input device the user can pick in Preferences.
struct AudioInputDevice: Identifiable, Hashable, Sendable {
    static let autoUID = "auto"

    let id: AudioDeviceID
    let uid: String
    let name: String
    let isBluetooth: Bool
    let isBuiltIn: Bool

    var displayName: String {
        if isBluetooth { return "\(name) (Bluetooth)" }
        if isBuiltIn { return "\(name) (Built-in)" }
        return name
    }
}

/// Enumerates macOS input devices and classifies Bluetooth vs built-in.
enum AudioDeviceManager {
    static func listInputDevices() -> [AudioInputDevice] {
        let deviceIDs = allDeviceIDs()
        var devices: [AudioInputDevice] = []
        for deviceID in deviceIDs {
            guard inputChannelCount(deviceID) > 0 else { continue }
            guard let uid = stringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID) else { continue }
            let name = stringProperty(deviceID, selector: kAudioDevicePropertyDeviceNameCFString) ?? "Microphone \(deviceID)"
            let transport = transportType(deviceID)
            let isBluetooth = transport == kAudioDeviceTransportTypeBluetooth
                || transport == kAudioDeviceTransportTypeBluetoothLE
            let isBuiltIn = transport == kAudioDeviceTransportTypeBuiltIn
            devices.append(AudioInputDevice(
                id: deviceID,
                uid: uid,
                name: name,
                isBluetooth: isBluetooth,
                isBuiltIn: isBuiltIn
            ))
        }
        return devices.sorted { lhs, rhs in
            if lhs.isBuiltIn != rhs.isBuiltIn { return lhs.isBuiltIn }
            if lhs.isBluetooth != rhs.isBluetooth { return !lhs.isBluetooth }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    /// Auto follows the system input. Explicit choices are applied once when the
    /// preference changes instead of switching devices during every recording.
    static func resolvedDevice(savedUID: String?) -> AudioInputDevice? {
        let devices = listInputDevices()
        if let savedUID, savedUID != AudioInputDevice.autoUID,
           let match = devices.first(where: { $0.uid == savedUID }) {
            return match
        }
        return defaultInputDevice() ?? devices.first
    }

    static func defaultInputDevice() -> AudioInputDevice? {
        guard let id = defaultInputDeviceID() else { return nil }
        return listInputDevices().first { $0.id == id }
    }

    static func defaultInputDeviceID() -> AudioDeviceID? {
        hardwareDefaultDevice(selector: kAudioHardwarePropertyDefaultInputDevice)
    }

    @discardableResult
    static func setDefaultInputDevice(_ deviceID: AudioDeviceID) -> Bool {
        var id = deviceID
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &id
        )
        if status != noErr {
            print("⚠️ Failed to set default input device: \(status)")
            return false
        }
        return true
    }

    private static func hardwareDefaultDevice(selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        var deviceID = AudioDeviceID()
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr, deviceID != 0 else { return nil }
        return deviceID
    }

    static func device(uid: String) -> AudioInputDevice? {
        listInputDevices().first { $0.uid == uid }
    }

    static func isBluetoothUID(_ uid: String?) -> Bool {
        guard let uid, uid != AudioInputDevice.autoUID else {
            return resolvedDevice(savedUID: uid)?.isBluetooth ?? false
        }
        return device(uid: uid)?.isBluetooth ?? false
    }

    static func defaultOutputIsBluetooth() -> Bool {
        guard let deviceID = hardwareDefaultDevice(selector: kAudioHardwarePropertyDefaultOutputDevice) else {
            return false
        }
        let transport = transportType(deviceID)
        return transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    // MARK: - CoreAudio helpers

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        )
        guard status == noErr else { return [] }
        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var ids = Array(repeating: AudioDeviceID(), count: count)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &ids
        )
        guard status == noErr else { return [] }
        return ids
    }

    private static func inputChannelCount(_ deviceID: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize)
        guard sizeStatus == noErr, dataSize > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(dataSize), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, raw)
        guard status == noErr else { return 0 }
        let bufferList = raw.assumingMemoryBound(to: AudioBufferList.self)
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func transportType(_ deviceID: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transport)
        return status == noErr ? transport : 0
    }

    private static func stringProperty(_ deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfName: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &cfName)
        guard status == noErr else { return nil }
        return cfName?.takeUnretainedValue() as String?
    }
}
