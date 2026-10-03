// madrate.swift — measure how fast the MAD60 can stream key-travel data.
//
// Compares two strategies:
//   sequential  send one request, wait for its answer, repeat  (6 round trips)
//   pipelined   send all 6 requests, then collect 6 answers
//
// If pipelining works, the effective sample rate for velocity estimation goes up
// by roughly the round-trip latency factor.
//
// Usage: madrate [iterations]

import Foundation
import IOKit.hid

let VENDOR = 0x373B
let PRODUCT = 0x105D
let KEY_COUNT = 70
let CHUNK = 12

setvbuf(stdout, nil, _IONBF, 0)

var queue: [[UInt8]] = []

func reportCB(context: UnsafeMutableRawPointer?, result: IOReturn, sender: UnsafeMutableRawPointer?,
              type: IOHIDReportType, reportID: UInt32, report: UnsafeMutablePointer<UInt8>, reportLength: CFIndex) {
    queue.append(Array(UnsafeBufferPointer(start: report, count: Int(reportLength))))
}

final class Raw {
    let manager: IOHIDManager
    let device: IOHIDDevice
    init?() {
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(m, [kIOHIDVendorIDKey: VENDOR, kIOHIDProductIDKey: PRODUCT,
                                         kIOHIDPrimaryUsagePageKey: 0xFF60, kIOHIDPrimaryUsageKey: 0x61] as CFDictionary)
        IOHIDManagerRegisterInputReportCallback(m, reportCB, nil)
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        guard IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess,
              let set = IOHIDManagerCopyDevices(m) as? Set<IOHIDDevice>, let d = set.first,
              IOHIDDeviceOpen(d, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { return nil }
        manager = m; device = d
    }

    func request(_ start: Int, _ count: Int) -> [UInt8] {
        var req = [UInt8](repeating: 0, count: 32)
        req[0] = 0x02; req[1] = 0x96; req[2] = 0x16
        req[5] = 0; req[6] = UInt8(start); req[7] = UInt8(count)
        _ = req.withUnsafeMutableBufferPointer { bp in
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0, bp.baseAddress!, 32)
        }
        return req
    }

    func pump(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.0002))
        } while Date() < deadline
    }
}

guard let raw = Raw() else { print("no MAD60"); exit(1) }
let iterations = CommandLine.arguments.count > 1 ? (Int(CommandLine.arguments[1]) ?? 200) : 200

// ---- sequential ----
queue.removeAll()
var seqValues = [Int]()
var t0 = Date()
for _ in 0..<iterations {
    var values = [Int]()
    for start in stride(from: 0, to: KEY_COUNT, by: CHUNK) {
        queue.removeAll()
        _ = raw.request(start, CHUNK)
        let deadline = Date().addingTimeInterval(0.05)
        while queue.isEmpty && Date() < deadline { raw.pump(0.0005) }
        if let r = queue.first, r.count >= 8, r[2] == 0x16 {
            let n = min(CHUNK, KEY_COUNT - start)
            for i in 0..<n { values.append((Int(r[8 + 2 * i]) << 8) | Int(r[9 + 2 * i])) }
        }
    }
    if seqValues.isEmpty { seqValues = values }
}
let seqSeconds = Date().timeIntervalSince(t0)
print(String(format: "sequential : %6.1f scans/s  (%.2f ms per full 70-key scan)",
             Double(iterations) / seqSeconds, seqSeconds / Double(iterations) * 1000))

// ---- pipelined ----
queue.removeAll()
var pipeValues = [Int]()
var echoOrder = [Int]()
var mismatches = 0
var missing = 0
t0 = Date()
for _ in 0..<iterations {
    queue.removeAll()
    var starts = [Int]()
    for start in stride(from: 0, to: KEY_COUNT, by: CHUNK) {
        _ = raw.request(start, CHUNK)
        starts.append(start)
    }
    let deadline = Date().addingTimeInterval(0.05)
    while queue.count < starts.count && Date() < deadline { raw.pump(0.0005) }

    var values = [Int](repeating: -1, count: KEY_COUNT)
    var seen = Set<Int>()
    for r in queue {
        guard r.count >= 8, r[2] == 0x16 else { mismatches += 1; continue }
        // Pair the answer with its request using the echoed start index rather
        // than arrival order.
        let echo = (Int(r[5]) << 8) | Int(r[6])
        guard starts.contains(echo) else { mismatches += 1; continue }
        if seen.contains(echo) { mismatches += 1; continue }
        seen.insert(echo)
        for i in 0..<CHUNK where echo + i < KEY_COUNT {
            values[echo + i] = (Int(r[8 + 2 * i]) << 8) | Int(r[9 + 2 * i])
        }
    }
    if iterations == 1 || pipeValues.isEmpty { pipeValues = values }
    if seen.count < starts.count { missing += 1 }
    if pipeValues.isEmpty { pipeValues = values }
}
let pipeSeconds = Date().timeIntervalSince(t0)
print(String(format: "pipelined  : %6.1f scans/s  (%.2f ms per full 70-key scan)",
             Double(iterations) / pipeSeconds, pipeSeconds / Double(iterations) * 1000))
print("pipelined integrity: \(mismatches) unmatched responses, \(missing) incomplete scans")

func similarity(_ a: [Int], _ b: [Int]) -> String {
    guard a.count == b.count, !a.isEmpty else { return "n/a" }
    let diff = zip(a, b).map { abs($0 - $1) }.max() ?? -1
    let filled = b.filter { $0 >= 0 }.count
    return "populated \(filled)/\(KEY_COUNT), max difference vs sequential \(diff)"
}
print("pipelined data: " + similarity(seqValues, pipeValues))
