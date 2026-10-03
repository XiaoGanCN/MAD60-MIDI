// KeyboardCapture.swift
//
// The MAD60 is a normal USB keyboard, so without help every key you play also
// types into whatever has focus — including your DAW.
//
// MagMIDI silences it by taking **exclusive ownership (seize)** of the HID
// collection that carries the keystrokes.  This is deliberately the most
// contained mechanism available:
//
//   * it lives entirely inside this process — no system-wide HID state is
//     written, so nothing outlives MagMIDI;
//   * the grab is released automatically when the app quits, crashes or is
//     force-quit, and immediately when the switch is turned off;
//   * the worst case if it is refused is simply that keys keep typing.
//
// macOS gates seizing a keyboard collection behind the Input Monitoring
// permission, so the feature is **off by default** and every failure path is
// reported explicitly in the UI.
//
// Note: an earlier revision silenced the keyboard by installing a per-device
// `UserKeyMapping` through the HID event system.  That writes shared system
// state, and a bulk write destabilised the HID event stack, so it has been
// removed.  `tools/keyrestore.swift` clears any such mapping left behind by
// another app.

import Foundation
import AppKit
import IOKit.hid

final class KeyboardCapture {
    enum State: Equatable {
        case off
        case captured
        case permissionNeeded
        case deviceMissing
        case failed(String)

        var isCapturing: Bool { self == .captured }

        var description: String {
            switch self {
            case .off:
                return "Keyboard types normally"
            case .captured:
                return "Captured — the MAD60 no longer types"
            case .permissionNeeded:
                return "Needs Input Monitoring permission"
            case .deviceMissing:
                return "Waiting for the MAD60"
            case .failed(let why):
                return why
            }
        }
    }

    private(set) var state: State = .off {
        didSet {
            guard state != oldValue else { return }
            let value = state
            DispatchQueue.main.async { [weak self] in self?.onStateChange?(value) }
        }
    }

    var onStateChange: ((State) -> Void)?

    /// Human-readable log of what each seize attempt returned, for diagnostics.
    private(set) var lastResults: [String] = []

    private var thread: Thread?
    private var running = false
    private var enabled = false
    private var manager: IOHIDManager?
    private var startupLog: [String] = []
    /// Seized devices keyed by registry ID, which stays stable across the
    /// wrapper objects `IOHIDManagerCopyDevices` hands back on each call.
    private var seized: [UInt64: IOHIDDevice] = [:]
    private let lock = NSLock()

    // MARK: public API

    func activate() {
        enabled = true
        guard thread == nil else { return }
        running = true
        let t = Thread { [weak self] in self?.run() }
        t.name = "MagMIDI.KeyboardCapture"
        t.qualityOfService = .userInitiated
        thread = t
        t.start()
    }

    func deactivate() {
        enabled = false
        releaseAll()
        state = .off
    }

    func shutdown() {
        enabled = false
        running = false
        releaseAll()
        state = .off
    }

    /// Opens the Input Monitoring pane and puts this app's path on the
    /// clipboard, because adding an app there means finding it in a file
    /// picker and the build path is long.
    static func openInputMonitoringSettings() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(Bundle.main.bundlePath, forType: .string)
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
        NSWorkspace.shared.open(url)
    }

    static var hasInputMonitoring: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    // MARK: worker

    private func run() {
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        // Match on vendor/product only.  Filtering by the keyboard usage page in
        // the *matching* dictionary makes enumeration itself gated by Input
        // Monitoring, so without the permission the manager would silently see
        // no devices and we could never report why.  The usage filter is applied
        // per device below instead.
        IOHIDManagerSetDeviceMatching(m, [
            kIOHIDVendorIDKey: MAD60.vendorID,
            kIOHIDProductIDKey: MAD60.productID,
        ] as CFDictionary)
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        manager = m
        let openResult = IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))
        startupLog = [
            "listenEventAccess: \(IOHIDCheckAccess(kIOHIDRequestTypeListenEvent).rawValue)",
            "managerOpen: \(openResult)",
        ]

        // Trigger the permission prompt on a detached queue.  IOHIDRequestAccess
        // blocks until the system prompt is answered, so it must never sit in
        // front of the seize loop.
        if IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) != kIOHIDAccessTypeGranted {
            DispatchQueue.global(qos: .utility).async {
                _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
            }
        }

        while running {
            if enabled {
                attempt()
            } else if !seized.isEmpty {
                releaseAll()
                state = .off
            }
            pump(enabled ? 1.0 : 0.5)
        }

        releaseAll()
        if let m = manager { IOHIDManagerClose(m, IOOptionBits(kIOHIDOptionsTypeNone)) }
        manager = nil
    }

    private func attempt() {
        guard let manager else {
            lastResults = startupLog + ["manager deallocated"]
            state = .deviceMissing
            return
        }
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
            lastResults = startupLog + ["IOHIDManagerCopyDevices returned nil"]
            state = .deviceMissing
            return
        }
        guard !devices.isEmpty else {
            lastResults = startupLog + ["matched 0 devices"]
            // Do not drop a seize just because enumeration was momentarily empty.
            state = .deviceMissing
            return
        }
        let set = devices

        // Key devices by their true IOKit registry entry ID.  The "RegistryID"
        // *property* is not exposed through IOHIDDeviceGetProperty, so ask the
        // service itself; this ID is stable across CopyDevices calls.
        var byID: [UInt64: IOHIDDevice] = [:]
        for device in set {
            let service = IOHIDDeviceGetService(device)
            guard service != 0 else { continue }
            var entryID: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(service, &entryID) == KERN_SUCCESS else { continue }
            byID[entryID] = device
        }
        if byID.isEmpty {
            lastResults = startupLog + ["\(set.count) devices, none exposing a registry entry"]
            state = .deviceMissing
            return
        }

        // Only drop devices that are genuinely gone.  Never close one merely
        // because a property lookup was inconclusive — doing so silently
        // releases the seize and the keyboard starts typing again.
        releaseMissing(present: Set(byID.keys))

        var denied = false
        var held = 0
        var log: [String] = []

        for (registryID, device) in byID.sorted(by: { $0.key < $1.key }) {
            let page = (IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? NSNumber)?.intValue ?? 0
            let usage = (IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsageKey as CFString) as? NSNumber)?.intValue ?? 0
            // Never touch the vendor analogue collection — that is how we play.
            guard page == 0x01 else {
                log.append("registry \(registryID) usage page 0x\(String(page, radix: 16)): left alone")
                continue
            }
            // 0x06 is the boot-keyboard collection, which macOS reserves for the
            // system keyboard and refuses to hand over.  It carries no key data
            // on this board, so leaving it alone costs nothing.
            guard usage != 0x06 else {
                log.append("registry \(registryID) usage \(usage): reserved by macOS, skipped")
                continue
            }
            if isSeized(registryID) { held += 1; log.append("registry \(registryID) usage \(usage): held"); continue }

            let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
            log.append("registry \(registryID) usage \(usage): seize -> \(result)")
            if result == kIOReturnSuccess {
                lock.lock(); seized[registryID] = device; lock.unlock()
                held += 1
            } else if result == kIOReturnNotPermitted || result == kIOReturnNotPrivileged {
                denied = true
            } else if result != kIOReturnExclusiveAccess {
                lastResults = log
                state = .failed("Could not capture the keyboard (IOKit error \(result))")
                return
            }
        }

        lastResults = log
        if held > 0 {
            state = .captured
        } else if denied {
            state = .permissionNeeded
        } else {
            state = .deviceMissing
        }
    }

    /// Closes and forgets any seized device that is no longer attached.
    private func releaseMissing(present: Set<UInt64>) {
        lock.lock()
        let gone = seized.filter { !present.contains($0.key) }
        for key in gone.keys { seized.removeValue(forKey: key) }
        lock.unlock()
        for (_, device) in gone {
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        }
    }

    private func releaseAll() {
        lock.lock()
        let devices = seized.values
        seized.removeAll()
        lock.unlock()
        for device in devices {
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        }
    }

    private func isSeized(_ registryID: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return seized[registryID] != nil
    }

    private func pump(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        } while running && Date() < deadline
    }
}
