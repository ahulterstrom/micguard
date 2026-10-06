// MicGuard — keeps Bluetooth headphone mics from becoming the default input,
// so headphones stay in high-quality (A2DP) mode instead of dropping to
// phone-call quality (HFP) whenever an app starts recording.

import AppKit
import CoreAudio

// MARK: - CoreAudio helpers

enum Audio {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func allDevices() -> [AudioDeviceID] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func defaultInput() -> AudioDeviceID? {
        var addr = address(kAudioHardwarePropertyDefaultInputDevice)
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &id) == noErr,
              id != kAudioObjectUnknown else { return nil }
        return id
    }

    @discardableResult
    static func setDefaultInput(_ device: AudioDeviceID) -> Bool {
        var addr = address(kAudioHardwarePropertyDefaultInputDevice)
        var id = device
        return AudioObjectSetPropertyData(system, &addr, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &id) == noErr
    }

    static func name(_ device: AudioDeviceID) -> String {
        var addr = address(kAudioObjectPropertyName)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &name) == noErr,
              let name else { return "Unknown device" }
        return name.takeRetainedValue() as String
    }

    static func transportType(_ device: AudioDeviceID) -> UInt32 {
        var addr = address(kAudioDevicePropertyTransportType)
        var type: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &type)
        return type
    }

    static func hasInput(_ device: AudioDeviceID) -> Bool {
        var addr = address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr && size > 0
    }

    static func isBluetooth(_ device: AudioDeviceID) -> Bool {
        let type = transportType(device)
        return type == kAudioDeviceTransportTypeBluetooth || type == kAudioDeviceTransportTypeBluetoothLE
    }

    /// The Mac's own microphone, found by transport type so it works regardless of name or language.
    static func builtInMic() -> AudioDeviceID? {
        allDevices().first { transportType($0) == kAudioDeviceTransportTypeBuiltIn && hasInput($0) }
    }

    static func onChange(_ selector: AudioObjectPropertySelector, _ handler: @escaping () -> Void) {
        var addr = address(selector)
        AudioObjectAddPropertyListenerBlock(system, &addr, DispatchQueue.main) { _, _ in handler() }
    }
}

// MARK: - Open at login (a per-user LaunchAgent)

enum LoginItem {
    static let label = "local.micguard"
    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool { FileManager.default.fileExists(atPath: plistURL.path) }

    static func setEnabled(_ on: Bool) {
        if on, let exe = Bundle.main.executablePath {
            let plist: NSDictionary = [
                "Label": label,
                "ProgramArguments": [exe],
                "RunAtLoad": true,
                "ProcessType": "Interactive",
            ]
            try? FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            plist.write(to: plistURL, atomically: true)
        } else {
            try? FileManager.default.removeItem(at: plistURL)
        }
    }
}

// MARK: - Menu-bar app

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let defaults = UserDefaults.standard
    private var lastAction: String?

    private var isActive: Bool {
        get { defaults.object(forKey: "active") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "active") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Only one copy should run (e.g. launched at login and again from Finder).
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).count > 1 {
            NSApp.terminate(nil)
            return
        }

        if !defaults.bool(forKey: "didFirstRun") {
            defaults.set(true, forKey: "didFirstRun")
            LoginItem.setEnabled(true)
        }

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()

        Audio.onChange(kAudioHardwarePropertyDefaultInputDevice) { [weak self] in self?.enforce() }
        Audio.onChange(kAudioHardwarePropertyDevices) { [weak self] in self?.enforce() }
        enforce()
    }

    /// If the default input is a Bluetooth mic, switch it back to the built-in mic.
    private func enforce(retriesLeft: Int = 3) {
        guard isActive,
              let current = Audio.defaultInput(), Audio.isBluetooth(current),
              let builtIn = Audio.builtInMic() else { return }

        let from = Audio.name(current)
        if Audio.setDefaultInput(builtIn) {
            let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)
            lastAction = "Switched away from \(from) at \(time)"
        }

        // macOS can re-select the headphones right after they connect, so check again shortly.
        if retriesLeft > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.enforce(retriesLeft: retriesLeft - 1)
            }
        }
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: "headphones", accessibilityDescription: "MicGuard")
        button.appearsDisabled = !isActive
        button.toolTip = isActive ? "MicGuard: keeping Bluetooth mics off" : "MicGuard: paused"
    }

    // Rebuild the menu each time it opens so the status is current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let current = Audio.defaultInput().map(Audio.name) ?? "None"
        menu.addItem(withTitle: "Microphone: \(current)", action: nil, keyEquivalent: "")
        if let lastAction {
            menu.addItem(withTitle: lastAction, action: nil, keyEquivalent: "")
        }
        menu.addItem(.separator())

        let toggle = menu.addItem(withTitle: "Keep Bluetooth Mics Off", action: #selector(toggleActive), keyEquivalent: "")
        toggle.target = self
        toggle.state = isActive ? .on : .off

        let login = menu.addItem(withTitle: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = LoginItem.isEnabled ? .on : .off

        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit MicGuard", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @objc private func toggleActive() {
        isActive.toggle()
        updateIcon()
        enforce()
    }

    @objc private func toggleLogin() {
        LoginItem.setEnabled(!LoginItem.isEnabled)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
