// Self-test for MicGuard. It changes the default input the way macOS does, then checks that
// the running MicGuard reacts correctly. Your original mic is restored at the end.
//
//   swift scripts/selftest.swift
//
// Which checks run depends on the lid, so for full coverage run it once with the lid open and
// once with it closed (on an external display). Most checks need Bluetooth headphones connected.
//
// The CoreAudio helpers here are deliberately separate from main.swift, so a bug there
// can't also hide in the test.

import CoreAudio
import Foundation
import IOKit

// MARK: - CoreAudio

let system = AudioObjectID(kAudioObjectSystemObject)

func address(_ selector: AudioObjectPropertySelector,
             _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func allDevices() -> [AudioDeviceID] {
    var addr = address(kAudioHardwarePropertyDevices)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

func transport(_ device: AudioDeviceID) -> UInt32 {
    var addr = address(kAudioDevicePropertyTransportType)
    var type: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    _ = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &type)
    return type
}

func hasInput(_ device: AudioDeviceID) -> Bool {
    var addr = address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput)
    var size: UInt32 = 0
    return AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr && size > 0
}

func name(_ device: AudioDeviceID) -> String {
    var addr = address(kAudioObjectPropertyName)
    var name: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &name) == noErr,
          let name else { return "none" }
    return name.takeRetainedValue() as String
}

func defaultInput() -> AudioDeviceID {
    var addr = address(kAudioHardwarePropertyDefaultInputDevice)
    var id = AudioDeviceID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    _ = AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &id)
    return id
}

func setDefaultInput(_ device: AudioDeviceID) {
    var addr = address(kAudioHardwarePropertyDefaultInputDevice)
    var id = device
    _ = AudioObjectSetPropertyData(system, &addr, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &id)
}

func isBluetooth(_ device: AudioDeviceID) -> Bool {
    [kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE].contains(transport(device))
}

func isBuiltIn(_ device: AudioDeviceID) -> Bool {
    transport(device) == kAudioDeviceTransportTypeBuiltIn
}

func isLidClosed() -> Bool {
    let rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    guard rootDomain != 0 else { return false }
    defer { IOObjectRelease(rootDomain) }
    let state = IORegistryEntryCreateCFProperty(rootDomain, "AppleClamshellState" as CFString,
                                                kCFAllocatorDefault, 0)?.takeRetainedValue()
    return state as? Bool ?? false
}

// MARK: - Test harness

enum Outcome { case pass, fail, skip }

/// Sets `device` as the default input, then checks the result both right away (MicGuard reacts
/// instantly) and after its retries have settled (to catch it switching back and forth).
func check(_ title: String, force device: AudioDeviceID?, expected: String,
           _ isExpected: (AudioDeviceID) -> Bool) -> Outcome {
    guard let device else {
        print("SKIP  \(title) (needed device isn't connected)")
        return .skip
    }
    setDefaultInput(device)
    Thread.sleep(forTimeInterval: 0.5)
    let early = defaultInput()
    Thread.sleep(forTimeInterval: 3.5)
    let settled = defaultInput()

    if isExpected(early) && isExpected(settled) {
        print("PASS  \(title)")
        return .pass
    }
    print("FAIL  \(title)")
    print("      expected \(expected); got \(name(early)) after 0.5s, \(name(settled)) after 4s")
    return .fail
}

// MARK: - Preconditions

let pgrep = Process()
pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
pgrep.arguments = ["-x", "MicGuard"]
pgrep.standardOutput = FileHandle.nullDevice
try pgrep.run()
pgrep.waitUntilExit()
guard pgrep.terminationStatus == 0 else {
    print("MicGuard isn't running. Start it with: open /Applications/MicGuard.app")
    exit(2)
}
guard UserDefaults(suiteName: "local.micguard")?.object(forKey: "active") as? Bool ?? true else {
    print("MicGuard is paused. Turn on \"Keep Bluetooth Mics Off\" in its menu first.")
    exit(2)
}

let skippedTransports: Set<UInt32> = [kAudioDeviceTransportTypeVirtual,
                                      kAudioDeviceTransportTypeAggregate,
                                      kAudioDeviceTransportTypeAutoAggregate]
let mics = allDevices().filter { hasInput($0) && !skippedTransports.contains(transport($0)) }
let bluetooth = mics.first(where: isBluetooth)
let builtIn = mics.first(where: isBuiltIn)
let otherWired = mics.first { !isBluetooth($0) && !isBuiltIn($0) }
let original = defaultInput()
let lidClosed = isLidClosed()

print("Lid: \(lidClosed ? "closed" : "open")")
print("Mics: " + mics.map(name).joined(separator: ", "))
print("")

// MARK: - Tests

var outcomes: [Outcome] = []

if !lidClosed {
    outcomes.append(check("Lid open: Bluetooth mic is switched to the built-in mic",
                          force: bluetooth, expected: "the built-in mic", isBuiltIn))
    outcomes.append(check("Lid open: built-in mic is left alone",
                          force: builtIn, expected: "the built-in mic", isBuiltIn))
} else {
    // With the lid shut the built-in mic records silence. Another wired mic is best;
    // without one, the Bluetooth mic is the only mic that works.
    let usable: (AudioDeviceID) -> Bool = otherWired != nil
        ? { !isBluetooth($0) && !isBuiltIn($0) }
        : { isBluetooth($0) }
    let usableName = otherWired.map(name) ?? bluetooth.map(name) ?? "a working mic"

    outcomes.append(check("Lid closed: dead built-in mic is switched to \(usableName)",
                          force: builtIn, expected: usableName, usable))
    outcomes.append(check("Lid closed: Bluetooth mic \(otherWired == nil ? "is left alone (no other mic)" : "is switched to \(usableName)")",
                          force: bluetooth, expected: usableName, usable))
}
if let otherWired {
    outcomes.append(check("\(name(otherWired)) (wired, chosen on purpose) is left alone",
                          force: otherWired, expected: name(otherWired)) { $0 == otherWired })
}

setDefaultInput(original)

// MARK: - Summary

let passed = outcomes.filter { $0 == .pass }.count
let failed = outcomes.filter { $0 == .fail }.count
let skipped = outcomes.filter { $0 == .skip }.count
print("")
print("\(passed) passed, \(failed) failed, \(skipped) skipped")
print("For full coverage, also run with the lid \(lidClosed ? "open" : "closed").")
exit(failed > 0 ? 1 : 0)
