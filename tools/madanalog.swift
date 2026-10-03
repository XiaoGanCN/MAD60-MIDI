// madanalog.swift — reads live per-key ADC (key travel) from the MADLION MAD60.
//
// Protocol (reverse-engineered from the vendor web driver):
//   32-byte report, reportId 0, on HID usage page 0xFF60 usage 0x61.
//   cmd 0x02 (id_get_keyboard_value), [1]=0x96 (customId), [2]=0x16 (realTimeAdcAxleBuffer)
//   [5..6] = start key index, big-endian u16
//   [7]    = key count, max 12
//   response: [0]=0x02 [1]=0x96 [2]=0x16 [5..6]=offset echo [7]=count echo
//             [8...] = count * big-endian u16 ADC values
//
// Usage: madanalog scan            one full pass, table of raw ADC + mm
//        madanalog watch <sec>     continuous poll, prints changed keys

import Foundation
import IOKit.hid

let VENDOR = 0x373B
let PRODUCT = 0x105D

let KEY_COUNT = 70            // 5 rows x 14 cols
let CHUNK = 12                // max keys per request

let RESERVED_HI: UInt8 = 0x00
let RESERVED_LO: UInt8 = 0x00

var gResp = [UInt8]()
var gRespSeq = 0

let DEBUG = ProcessInfo.processInfo.environment["MADDEBUG"] != nil

func reportCallback(context: UnsafeMutableRawPointer?, result: IOReturn,
                    sender: UnsafeMutableRawPointer?, type: IOHIDReportType,
                    reportID: UInt32, report: UnsafeMutablePointer<UInt8>,
                    reportLength: CFIndex) {
    gResp = Array(UnsafeBufferPointer(start: report, count: Int(reportLength)))
    gRespSeq += 1
    if DEBUG {
        let hex = gResp.map { String(format: "%02X", $0) }.joined(separator: " ")
        FileHandle.standardError.write(("RX(" + String(reportLength) + "): " + hex + "\n").data(using: .utf8)!)
    }
}

final class Mad60 {
    let manager: IOHIDManager      // must be retained: releasing it closes the device
    let device: IOHIDDevice
    var name: String = "MAD60"

    init?() {
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let match: [String: Any] = [
            kIOHIDVendorIDKey: VENDOR,
            kIOHIDProductIDKey: PRODUCT,
            kIOHIDPrimaryUsagePageKey: 0xFF60,
            kIOHIDPrimaryUsageKey: 0x61,
        ]
        IOHIDManagerSetDeviceMatching(m, match as CFDictionary)
        IOHIDManagerRegisterInputReportCallback(m, reportCallback, nil)
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        guard IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess,
              let set = IOHIDManagerCopyDevices(m) as? Set<IOHIDDevice>,
              let d = set.first else { return nil }
        guard IOHIDDeviceOpen(d, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { return nil }
        self.manager = m
        self.device = d
        if let p = IOHIDDeviceGetProperty(d, kIOHIDProductKey as CFString) as? String { self.name = p }
    }

    /// Send a report and wait for the matching response.
    func transfer(_ req: [UInt8], timeout: Double = 0.25) -> [UInt8]? {
        var payload = req
        if payload.count < 32 { payload.append(contentsOf: [UInt8](repeating: 0, count: 32 - payload.count)) }
        let want = gRespSeq
        let res = payload.withUnsafeMutableBufferPointer { bp -> IOReturn in
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0, bp.baseAddress!, bp.count)
        }
        if DEBUG { FileHandle.standardError.write("TX res=\(res) seq=\(gRespSeq) want=\(want)\n".data(using: .utf8)!) }
        if res != kIOReturnSuccess { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while gRespSeq == want && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.0005))
        }
        guard gRespSeq != want, gResp.count >= 8 else { return nil }
        return gResp
    }

    /// Read `count` key ADC values starting at `start`.
    func readADC(start: Int, count: Int) -> [Int]? {
        let n = min(count, CHUNK)
        var req = [UInt8](repeating: 0, count: 32)
        req[0] = 0x02
        req[1] = 0x96
        req[2] = 0x16
        req[3] = RESERVED_HI
        req[4] = RESERVED_LO
        req[5] = UInt8((start >> 8) & 0xFF)
        req[6] = UInt8(start & 0xFF)
        req[7] = UInt8(n)
        guard let resp = transfer(req) else { return nil }
        guard resp[0] == 0x02, resp[1] == 0x96, resp[2] == 0x16 else { return nil }
        var out = [Int]()
        for i in 0..<n {
            let hi = Int(resp[8 + 2 * i]), lo = Int(resp[9 + 2 * i])
            out.append((hi << 8) | lo)
        }
        return out
    }

    func readAll() -> [Int] {
        var all = [Int](repeating: -1, count: KEY_COUNT)
        var i = 0
        while i < KEY_COUNT {
            let n = min(CHUNK, KEY_COUNT - i)
            if let part = readADC(start: i, count: n) {
                for (k, v) in part.enumerated() where i + k < KEY_COUNT { all[i + k] = v }
            }
            i += CHUNK
        }
        return all
    }

    func travelInfo() -> [String: Int] {
        var req = [UInt8](repeating: 0, count: 32)
        req[0] = 0x02; req[1] = 0x96; req[2] = 0x24
        guard let r = transfer(req) else { return [:] }
        func u16(_ o: Int) -> Int { (Int(r[o]) << 8) | Int(r[o + 1]) }
        func u16le(_ o: Int) -> Int { (Int(r[o + 1]) << 8) | Int(r[o]) }
        return ["raw": 0,
                "be_max": u16(3), "be_min": u16(5), "be_step": u16(7),
                "be_rtMax": u16(9), "be_rtMin": u16(11), "be_rtStep": u16(13),
                "le_max": u16le(3), "le_min": u16le(5), "le_step": u16le(7),
                "le_rtMax": u16le(9), "le_rtMin": u16le(11), "le_rtStep": u16le(13)]
    }
}

// MARK: - main

guard let dev = Mad60() else {
    print("MAD60 raw HID interface (0xFF60/0x61) not found")
    exit(1)
}

let args = Array(CommandLine.arguments.dropFirst())
let mode = args.first ?? "scan"

switch mode {
case "scan":
    print("device: \(dev.name)")
    let all = dev.readAll()
    for row in 0..<5 {
        var line = "row \(row): "
        for col in 0..<14 {
            let v = all[row * 14 + col]
            line += v < 0 ? "  ---- " : String(format: " %5d ", v)
        }
        print(line)
    }
    print("min=\(all.filter { $0 >= 0 }.min() ?? 0) max=\(all.filter { $0 >= 0 }.max() ?? 0)")
    let ti = dev.travelInfo()
    print("travelInfo: \(ti)")

case "watch":
    let secs = args.count > 1 ? (Double(args[1]) ?? 10) : 10
    let thresh = args.count > 2 ? (Int(args[2]) ?? 8) : 8
    print("watching \(secs)s (threshold \(thresh)) — press keys")
    var base = dev.readAll()
    var last = base
    let t0 = Date()
    var scans = 0
    var fails = 0
    while Date().timeIntervalSince(t0) < secs {
        var cur = dev.readAll()
        scans += 1
        if cur.contains(-1) { fails += 1 }
        for i in 0..<KEY_COUNT where cur[i] >= 0 {
            if abs(cur[i] - last[i]) >= thresh {
                let dt = Date().timeIntervalSince(t0)
                print(String(format: "[%7.3f] key %2d (r%02d c%02d) %5d -> %5d  (delta %+d, base %d)",
                             dt, i, i / 14, i % 14, last[i], cur[i], cur[i] - last[i], base[i]))
                fflush(stdout)
                last[i] = cur[i]
            }
        }
    }
    print("scans=\(scans) failures=\(fails) => \(String(format: "%.1f", Double(scans) / secs)) full scans/s")

case "calib":
    // report per-key min/max observed while the user presses every key
    let secs = args.count > 1 ? (Double(args[1]) ?? 30) : 30
    print("calibrating for \(secs)s — press every key several times, slowly and fully")
    var lo = [Int](repeating: 1 << 20, count: KEY_COUNT)
    var hi = [Int](repeating: -1, count: KEY_COUNT)
    let t0 = Date()
    while Date().timeIntervalSince(t0) < secs {
        let cur = dev.readAll()
        for i in 0..<KEY_COUNT where cur[i] >= 0 {
            if cur[i] < lo[i] { lo[i] = cur[i] }
            if cur[i] > hi[i] { hi[i] = cur[i] }
        }
    }
    for i in 0..<KEY_COUNT {
        print(String(format: "key %2d (r%02d c%02d) min=%5d max=%5d range=%5d",
                     i, i / 14, i % 14, lo[i] == 1 << 20 ? -1 : lo[i], hi[i], hi[i] - (lo[i] == 1 << 20 ? 0 : lo[i])))
    }

default:
    print("usage: madanalog scan | watch <sec> [thresh] | calib <sec>")
}
