// madtrain.swift — learns the MAD60 analog-index -> HID keycode mapping and
// verifies that key presses actually move the ADC values.
//
// Usage: madtrain <seconds>

import Foundation
import IOKit.hid

let VENDOR = 0x373B
let PRODUCT = 0x105D
let KEY_COUNT = 70
let CHUNK = 12
let UNPOPULATED = 4000

setvbuf(stdout, nil, _IONBF, 0)
setvbuf(stderr, nil, _IONBF, 0)

func log(_ s: String) { print(s); fflush(stdout) }

// ---------- analog ----------

var gAnalogResp = [UInt8]()
var gAnalogSeq = 0

func analogCallback(context: UnsafeMutableRawPointer?, result: IOReturn,
                    sender: UnsafeMutableRawPointer?, type: IOHIDReportType,
                    reportID: UInt32, report: UnsafeMutablePointer<UInt8>,
                    reportLength: CFIndex) {
    gAnalogResp = Array(UnsafeBufferPointer(start: report, count: Int(reportLength)))
    gAnalogSeq += 1
}

final class Analog {
    let manager: IOHIDManager
    let device: IOHIDDevice
    init?() {
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(m, [kIOHIDVendorIDKey: VENDOR, kIOHIDProductIDKey: PRODUCT,
                                         kIOHIDPrimaryUsagePageKey: 0xFF60, kIOHIDPrimaryUsageKey: 0x61] as CFDictionary)
        IOHIDManagerRegisterInputReportCallback(m, analogCallback, nil)
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        guard IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess,
              let set = IOHIDManagerCopyDevices(m) as? Set<IOHIDDevice>, let d = set.first,
              IOHIDDeviceOpen(d, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { return nil }
        manager = m; device = d
    }
    func readChunk(_ start: Int, _ n: Int) -> [Int]? {
        var req = [UInt8](repeating: 0, count: 32)
        req[0] = 0x02; req[1] = 0x96; req[2] = 0x16
        req[5] = UInt8((start >> 8) & 0xFF); req[6] = UInt8(start & 0xFF); req[7] = UInt8(n)
        let want = gAnalogSeq
        let res = req.withUnsafeMutableBufferPointer { bp -> IOReturn in
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0, bp.baseAddress!, 32)
        }
        guard res == kIOReturnSuccess else { return nil }
        let deadline = Date().addingTimeInterval(0.2)
        while gAnalogSeq == want && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.0002))
        }
        guard gAnalogSeq != want, gAnalogResp.count >= 8, gAnalogResp[2] == 0x16 else { return nil }
        var out = [Int]()
        for i in 0..<n { out.append((Int(gAnalogResp[8 + 2 * i]) << 8) | Int(gAnalogResp[9 + 2 * i])) }
        return out
    }
    func readAll() -> [Int] {
        var all = [Int](repeating: -1, count: KEY_COUNT)
        var i = 0
        while i < KEY_COUNT {
            let n = min(CHUNK, KEY_COUNT - i)
            if let p = readChunk(i, n) { for (k, v) in p.enumerated() where i + k < KEY_COUNT { all[i + k] = v } }
            i += CHUNK
        }
        return all
    }
}

// ---------- keyboard ----------
// The boot-keyboard interface (usage page 1 / usage 6) only ever sends zeroed
// reports on this device.  Real keystrokes live in the composite interface's
// NKRO collection (report ID 6), so we listen for HID *values* instead.

var gKeyState = [Int: Bool]()
var gEvents: [(Date, Int, Bool)] = []
var gKbReports = 0
var gDebugEvents = 0

func keyboardValueCallback(context: UnsafeMutableRawPointer?, result: IOReturn,
                           sender: UnsafeMutableRawPointer?, value: IOHIDValue) {
    let el = IOHIDValueGetElement(value)
    let up = IOHIDElementGetUsagePage(el)
    guard up == 0x07 else { return }
    let usage = Int(IOHIDElementGetUsage(el))
    guard usage >= 4, usage <= 231 else { return }
    let on = IOHIDValueGetIntegerValue(value) != 0
    gKbReports += 1
    let prev = gKeyState[usage] ?? false
    if on != prev {
        gKeyState[usage] = on
        gEvents.append((Date(), usage, on))
        if gDebugEvents < 25 {
            gDebugEvents += 1
            log("  [kbd] usage \(usage) -> \(on ? "DOWN" : "up")")
        }
    }
}

final class Keyboard {
    let manager: IOHIDManager
    let device: IOHIDDevice
    init?() {
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(m, [kIOHIDVendorIDKey: VENDOR, kIOHIDProductIDKey: PRODUCT,
                                         kIOHIDPrimaryUsagePageKey: 0x1, kIOHIDPrimaryUsageKey: 0x2] as CFDictionary)
        IOHIDManagerRegisterInputValueCallback(m, keyboardValueCallback, nil)
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        guard IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess,
              let set = IOHIDManagerCopyDevices(m) as? Set<IOHIDDevice>, let d = set.first,
              IOHIDDeviceOpen(d, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { return nil }
        manager = m; device = d
    }
}

let NAMES: [Int: String] = [
    4:"A",5:"B",6:"C",7:"D",8:"E",9:"F",10:"G",11:"H",12:"I",13:"J",14:"K",15:"L",16:"M",
    17:"N",18:"O",19:"P",20:"Q",21:"R",22:"S",23:"T",24:"U",25:"V",26:"W",27:"X",28:"Y",29:"Z",
    30:"1",31:"2",32:"3",33:"4",34:"5",35:"6",36:"7",37:"8",38:"9",39:"0",
    40:"RETURN",41:"ESC",42:"DELETE",43:"TAB",44:"SPACE",45:"MINUS",46:"EQUAL",47:"LBRACKET",
    48:"RBRACKET",49:"BACKSLASH",51:"SEMICOLON",52:"QUOTE",53:"GRAVE",54:"COMMA",55:"PERIOD",
    56:"SLASH",57:"CAPS",58:"F1",59:"F2",60:"F3",61:"F4",62:"F5",63:"F6",64:"F7",65:"F8",
    66:"F9",67:"F10",68:"F11",69:"F12",74:"HOME",75:"PAGEUP",76:"DEL",79:"END",80:"PAGEDOWN",
    81:"DOWN",82:"UP",83:"RIGHT",84:"KP_DIV",224:"LCTRL",225:"LSHIFT",226:"LALT",227:"LGUI",
    228:"RCTRL",229:"RSHIFT",230:"RALT",231:"RGUI",
]

// ---------- main ----------

let secs = CommandLine.arguments.count > 1 ? (Double(CommandLine.arguments[1]) ?? 90) : 90

guard let analog = Analog() else { log("FATAL: cannot open analog channel"); exit(1) }
log("analog channel open")
guard let kbd = Keyboard() else { log("FATAL: cannot open keyboard channel"); exit(1) }
log("keyboard channel open")

// rest
log("measuring rest position — do not touch the keyboard for 2s...")
var rest = [Int](repeating: 0, count: KEY_COUNT)
var samples = 0
let restEnd = Date().addingTimeInterval(2.0)
while Date() < restEnd {
    let a = analog.readAll()
    for i in 0..<KEY_COUNT where a[i] >= 0 { rest[i] += a[i] }
    samples += 1
}
if samples > 0 { for i in 0..<KEY_COUNT { rest[i] /= samples } }

let empty = (0..<KEY_COUNT).filter { rest[$0] >= UNPOPULATED }
log("rest ok (\(samples) scans). empty positions: " + empty.map { "r\($0/14)c\($0%14)" }.joined(separator: " "))

// threshold: adaptive, 8% of a nominal 1400-count full travel, min 120
let DELTA = 120
log("\n>>> Press every key once, one at a time, ~0.5s apart. Ctrl/Alt/Shift/Cmd/Space included.")
log(">>> You have \(Int(secs))s.\n")

var map = [Int: Int]()
var pending: (usage: Int, t: Date)? = nil
var lastSeen = [Int](repeating: 0, count: KEY_COUNT)
var peakDelta = [Int](repeating: 0, count: KEY_COUNT)
var minADC = [Int](repeating: 1 << 20, count: KEY_COUNT)
var maxADC = [Int](repeating: -1, count: KEY_COUNT)
let t0 = Date()
var scans = 0
var lastStatus = Date()
var globalMaxDelta = 0
var globalMaxIndex = -1

while Date().timeIntervalSince(t0) < secs {
    let a = analog.readAll()
    scans += 1
    let now = Date()
    var activeIdx = [Int]()
    for i in 0..<KEY_COUNT where a[i] >= 0 && rest[i] < UNPOPULATED {
        let d = abs(a[i] - rest[i])
        if d > globalMaxDelta { globalMaxDelta = d; globalMaxIndex = i }
        if d > peakDelta[i] { peakDelta[i] = d }
        if a[i] < minADC[i] { minADC[i] = a[i] }
        if a[i] > maxADC[i] { maxADC[i] = a[i] }
        if d >= DELTA {
            activeIdx.append(i)
            lastSeen[i] = d
        } else {
            lastSeen[i] = d
        }
        // pair: rising analog edge + pending key-down
        if lastSeen[i] >= DELTA, let p = pending, map[i] == nil, now.timeIntervalSince(p.t) < 0.5 {
            map[i] = p.usage
            let nm = (NAMES[p.usage] ?? "usage\(p.usage)").padding(toLength: 9, withPad: " ", startingAt: 0)
            log(String(format: "  learnt r%02dc%02d (idx %2d) -> ", i / 14, i % 14, i) + nm
                + String(format: " peak delta %4d    (%d/61)", peakDelta[i], map.count))
            pending = nil
        }
    }
    while !gEvents.isEmpty {
        let (t, usage, isDown) = gEvents.removeFirst()
        guard isDown else { continue }
        let cands = activeIdx.filter { map[$0] == nil }
        if cands.count >= 1 {
            // newest rising edge wins
            let best = cands.max { x, y in
                let dx = peakDelta[x], dy = peakDelta[y]
                return dx < dy
            }!
            map[best] = usage
            let nm2 = (NAMES[usage] ?? "usage\(usage)").padding(toLength: 9, withPad: " ", startingAt: 0)
            log(String(format: "  learnt r%02dc%02d (idx %2d) -> ", best / 14, best % 14, best) + nm2
                + String(format: " peak delta %4d    (%d/61)", peakDelta[best], map.count))
        } else if pending == nil {
            pending = (usage, t)
        }
    }
    if now.timeIntervalSince(lastStatus) > 2.0 {
        lastStatus = now
        let populated: [Int] = (0..<KEY_COUNT).filter { rest[$0] < UNPOPULATED }
        let ranked: [Int] = populated.sorted { (a: Int, b: Int) -> Bool in peakDelta[a] > peakDelta[b] }
        let top: String = ranked.prefix(4).map { (i: Int) -> String in "r\(i/14)c\(i%14)=\(peakDelta[i])" }.joined(separator: " ")
        let gpos = globalMaxIndex >= 0 ? "r\(globalMaxIndex/14)c\(globalMaxIndex%14)" : "-"
        log(String(format: "  [%3.0fs] scans=%d kbReports=%d mapped=%d active=%d globalMax=%d@",
                   now.timeIntervalSince(t0), scans, gKbReports, map.count, activeIdx.count, globalMaxDelta)
            + gpos + " top:" + top)
    }
}

log("\n=== RESULT: \(map.count) keys mapped, \(scans) scans, \(gKbReports) keyboard reports ===")
log("max delta ever observed: \(globalMaxDelta) at " + (globalMaxIndex >= 0 ? "r\(globalMaxIndex/14)c\(globalMaxIndex%14)" : "-"))
let sorted = map.sorted { $0.key < $1.key }
for (idx, usage) in sorted {
    log(String(format: "  %2d  r%02dc%02d  %@", idx, idx / 14, idx % 14, NAMES[usage] ?? "?\(usage)"))
}
log("\nunmapped populated positions: " + (0..<KEY_COUNT).filter { rest[$0] < UNPOPULATED && map[$0] == nil }
        .map { "r\($0/14)c\($0%14)" }.joined(separator: " "))
log("\nSwift map (index -> HID usage):")
log("[" + sorted.map { "\($0.key): 0x\(String($0.value, radix: 16))" }.joined(separator: ", ") + "]")
log("\nper-key rest/min/max (raw ADC):")
for i in 0..<KEY_COUNT where rest[i] < UNPOPULATED {
    log(String(format: "  idx %2d r%02dc%02d rest=%4d min=%4d max=%4d range=%4d",
               i, i/14, i%14, rest[i], minADC[i] == 1 << 20 ? -1 : minADC[i], maxADC[i],
               (maxADC[i] < 0 ? 0 : maxADC[i] - (minADC[i] == 1 << 20 ? 0 : minADC[i]))))
}
log("\npeak deltas: " + (0..<KEY_COUNT).filter { rest[$0] < UNPOPULATED }
        .map { "\($0):\(peakDelta[$0])" }.joined(separator: " "))
