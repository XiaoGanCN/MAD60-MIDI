// madprobe.swift — reconnaissance tool for the MADLION MAD60 magnetic keyboard.
//
// Usage:
//   madprobe list                      enumerate matching HID devices + elements
//   madprobe listen [seconds]          dump input reports / values
//   madprobe send <up> <usage> <hex>   send OUTPUT report (hex may be "AA BB ..")
//   madprobe feature <up> <usage> <hex> set FEATURE report
//   madprobe getfeature <up> <usage> <len>
//
// <up> is the device primary usage page in decimal (or 0x..), <usage> the primary usage.

import Foundation
import IOKit.hid

let VENDOR = 0x373B
let PRODUCT = 0x105D

func parseNum(_ s: String) -> Int {
    if s.hasPrefix("0x") || s.hasPrefix("0X") { return Int(s.dropFirst(2), radix: 16) ?? -1 }
    return Int(s) ?? -1
}

func hexDump(_ bytes: UnsafePointer<UInt8>, _ count: Int) -> String {
    if count == 0 { return "" }
    var s = ""
    for i in 0..<count { s += String(format: "%02X ", bytes[i]) }
    return String(s.dropLast())
}

func hexDump(_ data: Data) -> String {
    return hexDump([UInt8](data))
}

func hexDump(_ bytes: [UInt8]) -> String {
    return bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
}

func bytesFromHex(_ s: String) -> [UInt8] {
    let parts = s.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "-" })
    var out: [UInt8] = []
    for p in parts {
        var t = String(p)
        if t.hasPrefix("0x") || t.hasPrefix("0X") { t = String(t.dropFirst(2)) }
        if let v = UInt8(t, radix: 16) { out.append(v) }
    }
    return out
}

var gStart = Date()
var gPrevValues: [UInt32: Int] = [:]
var gValueCount = 0
var gReportCount = 0
var gVerboseReports = false

func devProps(_ d: IOHIDDevice) -> (up: Int, u: Int, prod: String, maxIn: Int, maxOut: Int) {
    let up = (IOHIDDeviceGetProperty(d, kIOHIDPrimaryUsagePageKey as CFString) as? NSNumber)?.intValue ?? 0
    let u = (IOHIDDeviceGetProperty(d, kIOHIDPrimaryUsageKey as CFString) as? NSNumber)?.intValue ?? 0
    let prod = (IOHIDDeviceGetProperty(d, kIOHIDProductKey as CFString) as? String) ?? "?"
    let maxIn = (IOHIDDeviceGetProperty(d, kIOHIDMaxInputReportSizeKey as CFString) as? NSNumber)?.intValue ?? 0
    let maxOut = (IOHIDDeviceGetProperty(d, kIOHIDMaxOutputReportSizeKey as CFString) as? NSNumber)?.intValue ?? 0
    return (up, u, prod, maxIn, maxOut)
}

func inputReportCallback(context: UnsafeMutableRawPointer?, result: IOReturn,
                         sender: UnsafeMutableRawPointer?, type: IOHIDReportType,
                         reportID: UInt32, report: UnsafeMutablePointer<UInt8>,
                         reportLength: CFIndex) {
    guard let sender = sender else { return }
    let dev = Unmanaged<IOHIDDevice>.fromOpaque(sender).takeUnretainedValue()
    let p = devProps(dev)
    let t = Date().timeIntervalSince(gStart)
    // Suppress the flood of all-zero / unchanged reports unless verbose.
    var allZero = true
    for i in 0..<reportLength where report[i] != 0 { allZero = false; break }
    if allZero && !gVerboseReports { return }
    gReportCount += 1
    print(String(format: "[%9.3f] REPORT up=0x%04X u=%-3d id=%-3d len=%-3d | %@",
                 t, p.up, p.u, Int(reportID), Int(reportLength), hexDump(report, Int(reportLength))))
    fflush(stdout)
}

func inputValueCallback(context: UnsafeMutableRawPointer?, result: IOReturn,
                        sender: UnsafeMutableRawPointer?, value: IOHIDValue) {
    let el = IOHIDValueGetElement(value)
    let up = IOHIDElementGetUsagePage(el)
    let u = IOHIDElementGetUsage(el)
    let iv = IOHIDValueGetIntegerValue(value)
    let key = (UInt32(up) << 16) | UInt32(u)
    if gPrevValues[key] == iv { return }
    gPrevValues[key] = iv
    gValueCount += 1
    let t = Date().timeIntervalSince(gStart)
    print(String(format: "[%9.3f] VALUE up=0x%04X u=%-5d val=%-8d (cookie=%d)",
                 t, up, u, iv, Int(IOHIDElementGetCookie(el))))
    fflush(stdout)
}

func makeManager() -> IOHIDManager {
    let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    let match: [String: Any] = [
        kIOHIDVendorIDKey: VENDOR,
        kIOHIDProductIDKey: PRODUCT,
    ]
    IOHIDManagerSetDeviceMatching(m, match as CFDictionary)
    return m
}

func allDevices(_ m: IOHIDManager) -> [IOHIDDevice] {
    guard let set = IOHIDManagerCopyDevices(m) as? Set<IOHIDDevice> else { return [] }
    return Array(set)
}

func cmdList() {
    let m = makeManager()
    let r = IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))
    print("IOHIDManagerOpen -> \(r)")
    let devs = allDevices(m)
    print("matching devices: \(devs.count)")
    for (i, d) in devs.enumerated() {
        let p = devProps(d)
        let loc = (IOHIDDeviceGetProperty(d, kIOHIDLocationIDKey as CFString) as? NSNumber)?.intValue ?? 0
        let transport = (IOHIDDeviceGetProperty(d, kIOHIDTransportKey as CFString) as? String) ?? "?"
        let serial = (IOHIDDeviceGetProperty(d, kIOHIDSerialNumberKey as CFString) as? String) ?? "?"
        let maxFeat = (IOHIDDeviceGetProperty(d, kIOHIDMaxFeatureReportSizeKey as CFString) as? NSNumber)?.intValue ?? 0
        print("\n#\(i) product=\"\(p.prod)\" primaryUsagePage=0x\(String(p.up, radix: 16)) primaryUsage=\(p.u)")
        print("    transport=\(transport) locationID=0x\(String(loc, radix: 16)) serial=\(serial)")
        print("    maxInput=\(p.maxIn) maxOutput=\(p.maxOut) maxFeature=\(maxFeat)")
        if let rd = IOHIDDeviceGetProperty(d, kIOHIDReportDescriptorKey as CFString) as? Data {
            print("    reportDescriptor=\(hexDump(rd))")
        }
        if let els = IOHIDDeviceCopyMatchingElements(d, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement] {
            print("    elements=\(els.count)")
            for e in els {
                let t = IOHIDElementGetType(e)
                guard t == kIOHIDElementTypeInput_Misc || t == kIOHIDElementTypeInput_Button ||
                      t == kIOHIDElementTypeInput_Axis || t == kIOHIDElementTypeInput_ScanCodes ||
                      t == kIOHIDElementTypeOutput || t == kIOHIDElementTypeFeature else { continue }
                let rmin = IOHIDElementGetLogicalMin(e), rmax = IOHIDElementGetLogicalMax(e)
                if rmax - rmin <= 1 && t != kIOHIDElementTypeFeature { continue }
                print(String(format: "      type=%d up=0x%04X usage=%-5d reportID=%-3d size=%-3d count=%-3d min=%-6d max=%-6d cookie=%d",
                             Int(t.rawValue), IOHIDElementGetUsagePage(e), IOHIDElementGetUsage(e),
                             Int(IOHIDElementGetReportID(e)), Int(IOHIDElementGetReportSize(e)),
                             Int(IOHIDElementGetReportCount(e)), rmin, rmax, Int(IOHIDElementGetCookie(e))))
            }
        }
    }
}

func cmdListen(seconds: Double, verbose: Bool) {
    gVerboseReports = verbose
    let m = makeManager()
    IOHIDManagerRegisterInputReportCallback(m, inputReportCallback, nil)
    IOHIDManagerRegisterInputValueCallback(m, inputValueCallback, nil)
    IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
    let r = IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))
    print("IOHIDManagerOpen -> \(r)  (0 == success)")
    let devs = allDevices(m)
    print("devices: \(devs.count)")
    for d in devs {
        let p = devProps(d)
        print("  attached up=0x\(String(p.up, radix: 16)) usage=\(p.u) maxIn=\(p.maxIn)")
        // Belt & braces: also register a direct input report callback per device.
        let bufSize = max(p.maxIn, 64)
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        buf.initialize(repeating: 0, count: bufSize)
        let openRes = IOHIDDeviceOpen(d, IOOptionBits(kIOHIDOptionsTypeNone))
        print("  IOHIDDeviceOpen(up=0x\(String(p.up, radix: 16))) -> \(openRes)")
        IOHIDDeviceRegisterInputReportCallback(d, buf, bufSize, inputReportCallback, nil)
        IOHIDDeviceRegisterInputValueCallback(d, inputValueCallback, nil)
        IOHIDDeviceScheduleWithRunLoop(d, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
    }
    print("--- listening for \(seconds)s (press keys!) ---")
    gStart = Date()
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    print("--- done: \(gReportCount) reports, \(gValueCount) value changes ---")
}

func findDevice(_ m: IOHIDManager, up: Int, usage: Int) -> IOHIDDevice? {
    for d in allDevices(m) {
        let p = devProps(d)
        if p.up == up && p.u == usage { return d }
        if up == 0 { return d }
    }
    return nil
}

func cmdSend(up: Int, usage: Int, bytes: [UInt8], feature: Bool) {
    let m = makeManager()
    IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))
    guard let d = findDevice(m, up: up, usage: usage) else {
        print("device not found"); exit(1)
    }
    let p = devProps(d)
    print("using up=0x\(String(p.up, radix: 16)) usage=\(p.u)")
    let openRes = IOHIDDeviceOpen(d, IOOptionBits(kIOHIDOptionsTypeNone))
    print("open -> \(openRes)")
    var buf = bytes
    let type: IOHIDReportType = feature ? kIOHIDReportTypeFeature : kIOHIDReportTypeOutput
    let res = buf.withUnsafeMutableBufferPointer { bp -> IOReturn in
        return IOHIDDeviceSetReport(d, type, 0, bp.baseAddress!, bp.count)
    }
    print("setReport(\(feature ? "feature" : "output")) \(hexDump(bytes)) -> \(res)")
}

func cmdGetFeature(up: Int, usage: Int, len: Int) {
    let m = makeManager()
    IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))
    guard let d = findDevice(m, up: up, usage: usage) else { print("device not found"); exit(1) }
    IOHIDDeviceOpen(d, IOOptionBits(kIOHIDOptionsTypeNone))
    let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: len)
    buf.initialize(repeating: 0, count: len)
    var rlen = CFIndex(len)
    let res = IOHIDDeviceGetReport(d, kIOHIDReportTypeFeature, 0, buf, &rlen)
    print("getReport -> \(res) len=\(rlen) : \(hexDump(buf, Int(rlen)))")
}


func cmdQuery(bytes: [UInt8], waitMs: Double, repeatN: Int, padsTo: Int) {
    let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    let match: [String: Any] = [
        kIOHIDVendorIDKey: VENDOR,
        kIOHIDProductIDKey: PRODUCT,
        kIOHIDPrimaryUsagePageKey: 0xFF60,
        kIOHIDPrimaryUsageKey: 0x61,
    ]
    IOHIDManagerSetDeviceMatching(m, match as CFDictionary)
    IOHIDManagerRegisterInputReportCallback(m, inputReportCallback, nil)
    IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
    let r = IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))
    print("managerOpen -> \(r)")
    let devs = allDevices(m)
    guard let d = devs.first else { print("no raw hid device"); exit(1) }
    let openRes = IOHIDDeviceOpen(d, IOOptionBits(kIOHIDOptionsTypeNone))
    let p = devProps(d)
    print("device up=0x\(String(p.up, radix: 16)) usage=\(p.u) maxIn=\(p.maxIn) maxOut=\(p.maxOut) open -> \(openRes)")
    var payload = bytes
    let size = max(padsTo, payload.count)
    if payload.count < size { payload.append(contentsOf: [UInt8](repeating: 0, count: size - payload.count)) }
    gStart = Date()
    for i in 0..<max(1, repeatN) {
        let res = payload.withUnsafeMutableBufferPointer { bp -> IOReturn in
            return IOHIDDeviceSetReport(d, kIOHIDReportTypeOutput, 0, bp.baseAddress!, bp.count)
        }
        print(String(format: "[%7.3f] TX[%d] %@ -> %d", Date().timeIntervalSince(gStart), i, hexDump(payload), res))
        fflush(stdout)
        let deadline = Date().addingTimeInterval(waitMs / 1000.0)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }
}

// MARK: - main

let args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first else {
    print("usage: madprobe list | listen [sec] [--verbose] | send <up> <usage> <hex> | feature <up> <usage> <hex> | getfeature <up> <usage> <len>")
    exit(2)
}
switch cmd {
case "list":
    cmdList()
case "listen":
    let secs = args.count > 1 ? (Double(args[1]) ?? 10) : 10
    cmdListen(seconds: secs, verbose: args.contains("--verbose"))
case "send", "feature":
    guard args.count >= 4 else { print("need <up> <usage> <hex>"); exit(2) }
    cmdSend(up: parseNum(args[1]), usage: parseNum(args[2]), bytes: bytesFromHex(args[3]), feature: cmd == "feature")
case "query":
    guard args.count >= 2 else { print("need <hex> [waitMs] [repeat] [padTo]"); exit(2) }
    cmdQuery(bytes: bytesFromHex(args[1]),
             waitMs: args.count > 2 ? (Double(args[2]) ?? 50) : 50,
             repeatN: args.count > 3 ? (Int(args[3]) ?? 1) : 1,
             padsTo: args.count > 4 ? (Int(args[4]) ?? 32) : 32)
case "getfeature":
    guard args.count >= 4 else { print("need <up> <usage> <len>"); exit(2) }
    cmdGetFeature(up: parseNum(args[1]), usage: parseNum(args[2]), len: parseNum(args[3]))
default:
    print("unknown command \(cmd)")
    exit(2)
}
