// MAD60.swift
// Device constants, the physical key layout, and the low-level HID driver for the
// MADLION MAD60 magnetic-switch keyboard.
//
// Protocol (reverse-engineered from the vendor's own web configurator; see
// docs/PROTOCOL.md):
//   The keyboard exposes a 32-byte VIA-style raw HID channel on usage page
//   0xFF60 / usage 0x61.  Live per-key ADC ("key travel") is read with
//      02 96 16 <00> <offHi> <offLo> <count>            (32-byte output report)
//   and comes back as
//      02 96 16 ... <count * big-endian UInt16 ADC>     (32-byte input report)
//   starting at byte 8.  At most 12 keys fit in one round trip, so a full
//   70-position scan is 6 requests (~4 ms, ~250 Hz).

import Foundation
import IOKit.hid

enum MAD60 {
    static let vendorID = 0x373B
    static let productID = 0x105D
    static let usagePage = 0xFF60
    static let usage = 0x61

    static let rows = 5
    static let columns = 14
    static let keyCount = rows * columns

    /// Keys per request (24 payload bytes / 2).
    static let chunkSize = 12

    /// ADC value reported for a matrix position with no switch fitted.
    static let emptyADC = 4096

    static let productName = "MADLION MAD60"
}

/// One physical key position on the 5x14 electrical matrix.
struct KeyPosition: Identifiable, Hashable {
    let index: Int
    let label: String
    var row: Int { index / MAD60.columns }
    var column: Int { index % MAD60.columns }
    var id: Int { index }

    /// Row/column description, e.g. "r2c1".
    var matrixName: String { "r\(row)c\(column)" }
}

/// The MAD60 is a standard 60% ANSI board.  Positions without a switch are
/// `nil`; they are detected automatically from the ADC reading as well.
enum KeyLayout {
    static let table: [String?] = [
        // row 0
        "Esc", "1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "-", "=", "Backspace",
        // row 1
        "Tab", "Q", "W", "E", "R", "T", "Y", "U", "I", "O", "P", "[", "]", "\\",
        // row 2
        "Caps", "A", "S", "D", "F", "G", "H", "J", "K", "L", ";", "'", nil, "Enter",
        // row 3
        "LShift", nil, "Z", "X", "C", "V", "B", "N", "M", ",", ".", "/", nil, "RShift",
        // row 4
        "LCtrl", "LCmd", "LAlt", nil, nil, nil, "Space", nil, nil, nil,
        "RAlt", "RCmd", "Menu", "RCtrl",
    ]

    static var positions: [KeyPosition] {
        table.enumerated().compactMap { index, label in
            guard let label else { return nil }
            return KeyPosition(index: index, label: label)
        }
    }

    static func label(at index: Int) -> String {
        guard index >= 0, index < table.count, let l = table[index] else { return "r\(index / MAD60.columns)c\(index % MAD60.columns)" }
        return l
    }

    static func isPopulated(_ index: Int) -> Bool {
        guard index >= 0, index < table.count else { return false }
        return table[index] != nil
    }
}

// MARK: - HID driver

/// Owns the raw HID channel and continuously scans the key matrix on a
/// dedicated, high-priority thread.
final class MAD60HID {
    enum Status: Equatable {
        case searching
        case connected
        case failed(String)

        var isConnected: Bool { self == .connected }
    }

    /// Called on the polling thread for every completed scan.
    var onScan: (([UInt16]) -> Void)?
    /// Called on the main thread whenever the connection state changes.
    var onStatusChange: ((Status) -> Void)?

    private(set) var status: Status = .searching {
        didSet {
            guard status != oldValue else { return }
            let s = status
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.onStatusChange?(s)
            }
        }
    }

    private var thread: Thread?
    private var running = false
    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private var reportBuffer = [UInt8](repeating: 0, count: 32)
    private var reportSeq: UInt64 = 0
    private let reportLock = NSLock()
    private var transferStart = Date()

    /// Most recent full-matrix scan, in ADC counts.
    private(set) var lastScan = [UInt16](repeating: 0, count: MAD60.keyCount)

    func start() {
        guard thread == nil else { return }
        running = true
        let t = Thread { [weak self] in self?.runLoop() }
        t.name = "MagMIDI.MAD60"
        t.qualityOfService = .userInteractive
        t.stackSize = 1 << 20
        thread = t
        t.start()
    }

    func stop() {
        running = false
        manager.map { IOHIDManagerUnscheduleFromRunLoop($0, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue) }
        thread = nil
    }

    // MARK: polling thread

    private func runLoop() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let match: [String: Any] = [
            kIOHIDVendorIDKey: MAD60.vendorID,
            kIOHIDProductIDKey: MAD60.productID,
            kIOHIDPrimaryUsagePageKey: MAD60.usagePage,
            kIOHIDPrimaryUsageKey: MAD60.usage,
        ]
        IOHIDManagerSetDeviceMatching(m, match as CFDictionary)

        let reportCallback: IOHIDReportCallback = { ctx, _, _, _, _, report, length in
            guard let ctx else { return }
            let me = Unmanaged<MAD60HID>.fromOpaque(ctx).takeUnretainedValue()
            me.captureReport(report, Int(length))
        }
        IOHIDManagerRegisterInputReportCallback(m, reportCallback, context)
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        manager = m

        let openResult = IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))
        if openResult != kIOReturnSuccess {
            status = .failed("Cannot open the MAD60 HID interface (0x\(String(openResult, radix: 16))).")
        }

        while running {
            if device == nil {
                attachDevice(from: m)
                if device == nil {
                    status = .searching
                    pump(0.2)
                    continue
                }
            }
            guard let d = device else { continue }
            var values = [UInt16](repeating: 0, count: MAD60.keyCount)
            var ok = true
            var start = 0
            while start < MAD60.keyCount {
                let count = min(MAD60.chunkSize, MAD60.keyCount - start)
                guard let part = readChunk(d, start: start, count: count) else { ok = false; break }
                for (offset, value) in part.enumerated() where start + offset < MAD60.keyCount {
                    values[start + offset] = value
                }
                start += MAD60.chunkSize
            }
            if ok {
                if status != .connected { status = .connected }
                lastScan = values
                onScan?(values)
            } else {
                detachDevice()
                status = .searching
                pump(0.05)
            }
        }

        if let d = device { IOHIDDeviceClose(d, IOOptionBits(kIOHIDOptionsTypeNone)) }
        IOHIDManagerClose(m, IOOptionBits(kIOHIDOptionsTypeNone))
        device = nil
        manager = nil
    }

    private func attachDevice(from m: IOHIDManager) {
        guard let set = IOHIDManagerCopyDevices(m) as? Set<IOHIDDevice> else { return }
        for d in set {
            guard IOHIDDeviceOpen(d, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { continue }
            device = d
            break
        }
    }

    private func detachDevice() {
        if let d = device { IOHIDDeviceClose(d, IOOptionBits(kIOHIDOptionsTypeNone)) }
        device = nil
    }

    private func captureReport(_ report: UnsafeMutablePointer<UInt8>, _ length: Int) {
        reportLock.lock()
        reportBuffer = Array(UnsafeBufferPointer(start: report, count: length))
        reportSeq &+= 1
        reportLock.unlock()
    }

    /// Runs the current run loop briefly so HID callbacks can be delivered.
    private func pump(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.0004))
        } while Date() < deadline
    }

    /// Sends one analog request and waits for its answer.
    private func readChunk(_ d: IOHIDDevice, start: Int, count: Int) -> [UInt16]? {
        var request = [UInt8](repeating: 0, count: 32)
        request[0] = 0x02                     // id_get_keyboard_value
        request[1] = 0x96                     // vendor namespace
        request[2] = 0x16                     // realTimeAdcAxleBuffer
        request[5] = UInt8((start >> 8) & 0xFF)
        request[6] = UInt8(start & 0xFF)
        request[7] = UInt8(count)

        reportLock.lock()
        let want = reportSeq
        reportLock.unlock()

        let result = request.withUnsafeMutableBufferPointer { buffer -> IOReturn in
            IOHIDDeviceSetReport(d, kIOHIDReportTypeOutput, 0, buffer.baseAddress!, buffer.count)
        }
        guard result == kIOReturnSuccess else { return nil }

        let deadline = Date().addingTimeInterval(0.15)
        while Date() < deadline {
            reportLock.lock()
            let seq = reportSeq
            let report = reportBuffer
            reportLock.unlock()
            if seq != want {
                guard report.count >= 8, report[0] == 0x02, report[1] == 0x96, report[2] == 0x16 else { return nil }
                var out = [UInt16]()
                out.reserveCapacity(count)
                for i in 0..<count {
                    let hi = UInt16(report[8 + 2 * i])
                    let lo = UInt16(report[9 + 2 * i])
                    out.append((hi << 8) | lo)
                }
                return out
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.0003))
        }
        return nil
    }

    /// Reads the firmware's travel metadata (`02 96 24`).  Returns raw bytes.
    func readTravelInfo() -> [UInt8]? {
        guard let d = device else { return nil }
        var request = [UInt8](repeating: 0, count: 32)
        request[0] = 0x02; request[1] = 0x96; request[2] = 0x24
        reportLock.lock()
        let want = reportSeq
        reportLock.unlock()
        guard request.withUnsafeMutableBufferPointer({ IOHIDDeviceSetReport(d, kIOHIDReportTypeOutput, 0, $0.baseAddress!, 32) }) == kIOReturnSuccess else { return nil }
        let deadline = Date().addingTimeInterval(0.2)
        while Date() < deadline {
            reportLock.lock()
            let seq = reportSeq
            let report = reportBuffer
            reportLock.unlock()
            if seq != want { return report }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.0003))
        }
        return nil
    }
}
