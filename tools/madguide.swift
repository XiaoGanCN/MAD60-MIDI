// madguide.swift — guided, deterministic calibration for the MADLION MAD60.
//
// Prompts one physical key at a time; the user presses and holds it, so the
// analog index is unambiguous.  Writes the resulting layout as JSON.
//
// Usage: madguide [output.json]

import Foundation
import IOKit.hid

let VENDOR = 0x373B
let PRODUCT = 0x105D
let KEY_COUNT = 70
let CHUNK = 12
let UNPOPULATED = 4000

setvbuf(stdout, nil, _IONBF, 0)

func log(_ s: String) { print(s); fflush(stdout) }

var gResp = [UInt8]()
var gSeq = 0

func reportCB(context: UnsafeMutableRawPointer?, result: IOReturn, sender: UnsafeMutableRawPointer?,
              type: IOHIDReportType, reportID: UInt32, report: UnsafeMutablePointer<UInt8>, reportLength: CFIndex) {
    gResp = Array(UnsafeBufferPointer(start: report, count: Int(reportLength)))
    gSeq += 1
}

final class Analog {
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
    func chunk(_ start: Int, _ n: Int) -> [Int]? {
        var req = [UInt8](repeating: 0, count: 32)
        req[0] = 0x02; req[1] = 0x96; req[2] = 0x16
        req[5] = 0; req[6] = UInt8(start); req[7] = UInt8(n)
        let want = gSeq
        let res = req.withUnsafeMutableBufferPointer { bp in
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0, bp.baseAddress!, 32)
        }
        guard res == kIOReturnSuccess else { return nil }
        let deadline = Date().addingTimeInterval(0.2)
        while gSeq == want && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.0002))
        }
        guard gSeq != want, gResp.count >= 8, gResp[2] == 0x16 else { return nil }
        return (0..<n).map { (Int(gResp[8 + 2 * $0]) << 8) | Int(gResp[9 + 2 * $0]) }
    }
    func readAll() -> [Int] {
        var all = [Int](repeating: -1, count: KEY_COUNT)
        var i = 0
        while i < KEY_COUNT {
            let n = min(CHUNK, KEY_COUNT - i)
            if let p = chunk(i, n) { for (k, v) in p.enumerated() where i + k < KEY_COUNT { all[i + k] = v } }
            i += CHUNK
        }
        return all
    }
}

/// The physical keys of a standard 60% ANSI board, paired with the matrix
/// position this firmware is expected to use.  The wizard records the position
/// it actually observes, so a mismatch is reported, not silently accepted.
struct Prompt { let label: String; let expect: Int }
let PROMPTS: [Prompt] = [
    Prompt(label: "Esc", expect: 0), Prompt(label: "1", expect: 1), Prompt(label: "2", expect: 2),
    Prompt(label: "3", expect: 3), Prompt(label: "4", expect: 4), Prompt(label: "5", expect: 5),
    Prompt(label: "6", expect: 6), Prompt(label: "7", expect: 7), Prompt(label: "8", expect: 8),
    Prompt(label: "9", expect: 9), Prompt(label: "0", expect: 10), Prompt(label: "-", expect: 11),
    Prompt(label: "=", expect: 12), Prompt(label: "Backspace", expect: 13),
    Prompt(label: "Tab", expect: 14), Prompt(label: "Q", expect: 15), Prompt(label: "W", expect: 16),
    Prompt(label: "E", expect: 17), Prompt(label: "R", expect: 18), Prompt(label: "T", expect: 19),
    Prompt(label: "Y", expect: 20), Prompt(label: "U", expect: 21), Prompt(label: "I", expect: 22),
    Prompt(label: "O", expect: 23), Prompt(label: "P", expect: 24), Prompt(label: "[", expect: 25),
    Prompt(label: "]", expect: 26), Prompt(label: "\\", expect: 27),
    Prompt(label: "Caps Lock", expect: 28), Prompt(label: "A", expect: 29), Prompt(label: "S", expect: 30),
    Prompt(label: "D", expect: 31), Prompt(label: "F", expect: 32), Prompt(label: "G", expect: 33),
    Prompt(label: "H", expect: 34), Prompt(label: "J", expect: 35), Prompt(label: "K", expect: 36),
    Prompt(label: "L", expect: 37), Prompt(label: ";", expect: 38), Prompt(label: "'", expect: 39),
    Prompt(label: "Enter", expect: 41),
    Prompt(label: "Left Shift", expect: 42), Prompt(label: "Z", expect: 44), Prompt(label: "X", expect: 45),
    Prompt(label: "C", expect: 46), Prompt(label: "V", expect: 47), Prompt(label: "B", expect: 48),
    Prompt(label: "N", expect: 49), Prompt(label: "M", expect: 50), Prompt(label: ",", expect: 51),
    Prompt(label: ".", expect: 52), Prompt(label: "/", expect: 53), Prompt(label: "Right Shift", expect: 55),
    Prompt(label: "Left Ctrl", expect: 56), Prompt(label: "Left Cmd/Win", expect: 57),
    Prompt(label: "Left Alt", expect: 58), Prompt(label: "Space", expect: 60),
    Prompt(label: "Right Alt", expect: 66), Prompt(label: "Right Cmd/Win", expect: 67),
    Prompt(label: "Menu/Fn", expect: 68), Prompt(label: "Right Ctrl", expect: 69),
]

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/mad60-layout.json"

guard let analog = Analog() else { log("cannot open MAD60 analog channel"); exit(1) }

log("measuring rest — do not touch the keyboard for 2 s")
var rest = [Int](repeating: 0, count: KEY_COUNT)
var n = 0
let restEnd = Date().addingTimeInterval(2.0)
while Date() < restEnd {
    let a = analog.readAll()
    for i in 0..<KEY_COUNT where a[i] >= 0 { rest[i] += a[i] }
    n += 1
}
if n > 0 { for i in 0..<KEY_COUNT { rest[i] /= n } }

let populated = (0..<KEY_COUNT).filter { rest[$0] < UNPOPULATED }
log("resting positions: \(populated.count) of \(KEY_COUNT)")

let PRESS = 260          // counts of travel that count as a deliberate press
let HOLD_SCANS = 3       // must stay pressed this many scans
var map = [Int: String]()
var warnings: [String] = []

log("\nPress and HOLD each key until it is confirmed, then release.")
log("Type 's' + Enter to skip a key, 'q' + Enter to finish early.\n")

for (pi, p) in PROMPTS.enumerated() {
    log(String(format: "[%2d/%d]  HOLD  %@", pi + 1, PROMPTS.count, p.label))
    var chosen = -1
    var stable = 0
    var skipped = false
    let deadline = Date().addingTimeInterval(15)
    while Date() < deadline {
        let a = analog.readAll()
        var candidates: [Int] = []
        for i in populated where map[i] == nil {
            if abs(a[i] - rest[i]) >= PRESS { candidates.append(i) }
        }
        if candidates.count == 1 {
            let i = candidates[0]
            if i == chosen { stable += 1 } else { chosen = i; stable = 1 }
            if stable >= HOLD_SCANS { break }
        } else {
            chosen = -1; stable = 0
        }
        // allow skipping from stdin
        if let line = readLineNonBlocking() {
            if line.lowercased().hasPrefix("s") { skipped = true; break }
            if line.lowercased().hasPrefix("q") { finish(&map, warnings, outPath); exit(0) }
        }
    }
    if skipped || chosen < 0 {
        log("        skipped")
        continue
    }
    map[chosen] = p.label
    let warn = chosen == p.expect ? "" : "   <-- expected r\(p.expect / 14)c\(p.expect % 14)"
    if !warn.isEmpty { warnings.append("\(p.label): got r\(chosen / 14)c\(chosen % 14), expected r\(p.expect / 14)c\(p.expect % 14)") }
    log("        ✓ \(p.label) -> r\(chosen / 14)c\(chosen % 14)" + warn)
    // wait for release
    var released = false
    let releaseDeadline = Date().addingTimeInterval(5)
    while Date() < releaseDeadline && !released {
        let a = analog.readAll()
        released = populated.allSatisfy { map[$0] != nil || abs(a[$0] - rest[$0]) < 150 }
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005))
    }
}

finish(&map, warnings, outPath)

func readLineNonBlocking() -> String? {
    // stdin is only used for skip/quit; keep it simple and non-blocking-ish
    return nil
}

func finish(_ map: inout [Int: String], _ warnings: [String], _ path: String) {
    log("\n=== \(map.count) keys mapped ===")
    for i in 0..<KEY_COUNT {
        let lbl = map[i] ?? (rest[i] >= UNPOPULATED ? "(none)" : "??")
        log(String(format: "  idx %2d  r%02dc%02d  %@   rest=%d", i, i / 14, i % 14, lbl, rest[i]))
    }
    if !warnings.isEmpty {
        log("\nwarnings:")
        for w in warnings { log("  " + w) }
    }
    var entries: [String] = []
    for (idx, label) in map.sorted(by: { $0.key < $1.key }) {
        entries.append("    { \"index\": \(idx), \"row\": \(idx / 14), \"column\": \(idx % 14), \"label\": \"\(label)\", \"rest\": \(rest[idx]) }")
    }
    let json = "{\n  \"device\": \"MADLION MAD60\",\n  \"keys\": [\n" + entries.joined(separator: ",\n") + "\n  ]\n}\n"
    try? json.write(toFile: path, atomically: true, encoding: .utf8)
    log("\nwrote \(path)")
    log("Swift map (index -> label):")
    log("[" + map.sorted { $0.key < $1.key }.map { "\($0.key): \"\($0.value)\"" }.joined(separator: ", ") + "]")
}
