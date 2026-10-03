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

    private var thread: Thread?
    private var running = false
    private var enabled = false
    private var manager: IOHIDManager?
    private var seized: [IOHIDDevice] = []
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

    static func openInputMonitoringSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
        NSWorkspace.shared.open(url)
    }

    static var hasInputMonitoring: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    // MARK: worker

    private func run() {
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(m, [
            kIOHIDVendorIDKey: MAD60.vendorID,
            kIOHIDProductIDKey: MAD60.productID,
            kIOHIDPrimaryUsagePageKey: 0x01,
        ] as CFDictionary)
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        manager = m
        _ = IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))

        // Ask once, on this worker thread — the call can block while the system
        // prompt is on screen, which must never happen on the main thread.
        if IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) != kIOHIDAccessTypeGranted {
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
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
        guard let manager, let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, !set.isEmpty else {
            state = .deviceMissing
            return
        }

        var denied = false
        var held = 0

        for device in set {
            let usage = (IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsageKey as CFString) as? NSNumber)?.intValue ?? 0
            // 0x06 is the boot-keyboard collection, which macOS reserves for the
            // system keyboard and refuses to hand over.  It carries no key data
            // on this board, so leaving it alone costs nothing.
            guard usage != 0x06 else { continue }

            if isSeized(device) { held += 1; continue }

            let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
            if result == kIOReturnSuccess {
                lock.lock(); seized.append(device); lock.unlock()
                held += 1
            } else if result == kIOReturnNotPermitted || result == kIOReturnNotPrivileged {
                denied = true
            } else if result != kIOReturnExclusiveAccess {
                state = .failed("Could not capture the keyboard (IOKit error \(result))")
                return
            }
        }

        pruneDisconnected()

        if held > 0 {
            state = .captured
        } else if denied {
            state = .permissionNeeded
        } else {
            state = .deviceMissing
        }
    }

    private func pruneDisconnected() {
        lock.lock()
        let alive = seized.filter { IOHIDDeviceGetProperty($0, kIOHIDProductKey as CFString) != nil }
        let dead = seized.filter { device in !alive.contains(where: { $0 === device }) }
        seized = alive
        lock.unlock()
        for device in dead {
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        }
    }

    private func releaseAll() {
        lock.lock()
        let devices = seized
        seized.removeAll()
        lock.unlock()
        for device in devices {
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        }
    }

    private func isSeized(_ device: IOHIDDevice) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return seized.contains { $0 === device }
    }

    private func pump(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        } while running && Date() < deadline
    }
}
