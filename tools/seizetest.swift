// seizetest.swift — can a user-space process seize the MAD60's keyboard
// interfaces so keystrokes stop reaching macOS?
//
// Usage: seizetest <seconds>

import Foundation
import IOKit.hid

let VENDOR = 0x373B
let PRODUCT = 0x105D

setvbuf(stdout, nil, _IONBF, 0)

var devices: [IOHIDDevice] = []

func valueCallback(context: UnsafeMutableRawPointer?, result: IOReturn,
                   sender: UnsafeMutableRawPointer?, value: IOHIDValue) {
    let el = IOHIDValueGetElement(value)
    let page = IOHIDElementGetUsagePage(el)
    let usage = IOHIDElementGetUsage(el)
    let on = IOHIDValueGetIntegerValue(value) != 0
    if page == 0x07, usage >= 4, usage <= 231 {
        print("  saw HID key usage \(usage) -> \(on ? "down" : "up")")
    }
}

let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatching(manager, [
    kIOHIDVendorIDKey: VENDOR,
    kIOHIDProductIDKey: PRODUCT,
] as CFDictionary)
IOHIDManagerRegisterInputValueCallback(manager, valueCallback, nil)
IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
print("IOHIDManagerOpen -> \(openResult)")

guard let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
    print("no devices"); exit(1)
}

func intProp(_ d: IOHIDDevice, _ key: String) -> Int {
    (IOHIDDeviceGetProperty(d, key as CFString) as? NSNumber)?.intValue ?? 0
}

for device in set {
    let page = intProp(device, kIOHIDPrimaryUsagePageKey)
    let usage = intProp(device, kIOHIDPrimaryUsageKey)
    let label = "usagePage 0x\(String(page, radix: 16)) usage \(usage)"
    // Only the keyboard-ish collections need to be silenced.
    guard page == 0x01 else {
        print("\(label): vendor collection, skipping")
        continue
    }
    let probeOnly = CommandLine.arguments.contains("--probe")
    let plain = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
    if plain == kIOReturnSuccess {
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
    }
    if probeOnly {
        // Read-only: never seizes, never alters state.  kIOReturnExclusiveAccess
        // means somebody else (e.g. MagMIDI) currently owns the device.
        let note = plain == kIOReturnExclusiveAccess ? "held by another process" : "free"
        print("\(label): plain open=\(plain) (\(note))")
        continue
    }
    let seize = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
    print("\(label): open=\(plain) seize=\(seize) \(seize == kIOReturnSuccess ? "✅ SEIZED" : "❌ denied")")
    if seize == kIOReturnSuccess {
        devices.append(device)
    }
}

if devices.isEmpty {
    print("\nSeizing not permitted — keystrokes cannot be suppressed this way.")
    exit(2)
}

print("\n\(devices.count) device(s) seized. TYPE ON THE MAD60 NOW — nothing should reach macOS.")
print("Listening for \(CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "12")s…")
let seconds = Double(CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "12") ?? 12
let deadline = Date().addingTimeInterval(seconds)
while Date() < deadline {
    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
}

for device in devices {
    IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
}
print("released")
