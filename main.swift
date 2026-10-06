// MicGuard — keeps Bluetooth headphone mics from becoming the default input,
// so headphones stay in high-quality (A2DP) mode instead of dropping to
// phone-call quality (HFP) whenever an app starts recording.

import AppKit
import CoreAudio
import IOKit

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

    /// The Mac's own microphone, identified by transport type so it works regardless of name or language.
    static func isBuiltIn(_ device: AudioDeviceID) -> Bool {
        transportType(device) == kAudioDeviceTransportTypeBuiltIn
    }

    /// Input devices backed by a real microphone. Virtual and aggregate devices (BlackHole, Zoom, etc.)
    /// are skipped because switching to one would capture silence or something other than your voice.
    static func microphones() -> [AudioDeviceID] {
        let skipped: Set<UInt32> = [kAudioDeviceTransportTypeVirtual,
                                    kAudioDeviceTransportTypeAggregate,
                                    kAudioDeviceTransportTypeAutoAggregate]
        return allDevices().filter { hasInput($0) && !skipped.contains(transportType($0)) }
    }

    static func onChange(_ selector: AudioObjectPropertySelector, _ handler: @escaping () -> Void) {
        var addr = address(selector)
        AudioObjectAddPropertyListenerBlock(system, &addr, DispatchQueue.main) { _, _ in handler() }
    }
}

// MARK: - Lid state

enum Lid {
    /// True when a MacBook's lid is closed (e.g. running on an external display). Macs disconnect
    /// the built-in mic in hardware while the lid is shut, so it still shows up but records silence.
    static var isClosed: Bool {
        let rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard rootDomain != 0 else { return false }
        defer { IOObjectRelease(rootDomain) }
        let state = IORegistryEntryCreateCFProperty(rootDomain, "AppleClamshellState" as CFString,
                                                    kCFAllocatorDefault, 0)?.takeRetainedValue()
        return state as? Bool ?? false
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

        // Opening or closing the lid on an external display changes the screen setup;
        // waking from sleep can too. Either way the right mic may have changed.
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.recheckSoon() }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in self?.recheckSoon() }
        enforce()
    }

    /// The lid state can update slightly after the screen change, so check a few times.
    private func recheckSoon() {
        for delay in [0.0, 1.0, 3.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.enforce() }
        }
    }

    /// The mic that should replace `current`, or nil to leave it alone.
    /// - Lid open: switch away from Bluetooth mics, preferring the built-in mic.
    /// - Lid closed: the built-in mic records silence, so use another wired mic if there is one;
    ///   otherwise fall back to the Bluetooth mic, because call-quality audio beats a dead mic.
    private func replacement(for current: AudioDeviceID, lidClosed: Bool) -> AudioDeviceID? {
        let currentIsDeadBuiltIn = lidClosed && Audio.isBuiltIn(current)
        guard Audio.isBluetooth(current) || currentIsDeadBuiltIn else { return nil }

        let mics = Audio.microphones()
        let wired = mics.filter { !Audio.isBluetooth($0) && !(lidClosed && Audio.isBuiltIn($0)) }
        if let mic = wired.first(where: Audio.isBuiltIn) ?? wired.first {
            return mic
        }
        return currentIsDeadBuiltIn ? mics.first(where: Audio.isBluetooth) : nil
    }

    private func enforce(retriesLeft: Int = 3) {
        let lidClosed = Lid.isClosed
        guard isActive,
              let current = Audio.defaultInput(),
              let target = replacement(for: current, lidClosed: lidClosed) else { return }

        if Audio.setDefaultInput(target) {
            let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)
            lastAction = "Switched to \(Audio.name(target)) at \(time)" + (lidClosed ? " (lid closed)" : "")
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
        if Lid.isClosed {
            menu.addItem(withTitle: "Lid closed: built-in mic is off", action: nil, keyEquivalent: "")
        }
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
