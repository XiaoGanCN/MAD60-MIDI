// midimon.swift — connects to every Core MIDI source and prints incoming events.
// Used to verify MagMIDI end-to-end without a DAW.

import Foundation
import CoreMIDI

setvbuf(stdout, nil, _IONBF, 0)

var client = MIDIClientRef()
var port = MIDIPortRef()
var connected = Set<MIDIUniqueID>()

func describe(_ word: UInt32) -> String? {
    let status = UInt8((word >> 16) & 0xFF)
    let d1 = Int((word >> 8) & 0x7F)
    let d2 = Int(word & 0x7F)
    let channel = Int(status & 0x0F) + 1
    switch status & 0xF0 {
    case 0x90 where d2 > 0: return String(format: "ch%-2d NOTE ON   %3d  vel %3d", channel, d1, d2)
    case 0x80, 0x90:        return String(format: "ch%-2d NOTE OFF  %3d", channel, d1)
    case 0xB0:              return String(format: "ch%-2d CC        %3d  val %3d", channel, d1, d2)
    case 0xE0:              return String(format: "ch%-2d PITCHBEND %5d", channel, (d2 << 7) | d1)
    case 0xC0:              return String(format: "ch%-2d PROGRAM   %3d", channel, d1)
    default:                return nil
    }
}

func handle(_ list: UnsafePointer<MIDIEventList>) {
    var packet = list.pointee.packet
    for _ in 0..<list.pointee.numPackets {
        let count = Int(packet.wordCount)
        withUnsafeBytes(of: packet.words) { raw in
            let words = raw.bindMemory(to: UInt32.self)
            for index in 0..<min(count, words.count) {
                let word = words[index]
                if (word >> 28) & 0xF == 0x2, let text = describe(word) {
                    let elapsed = Date().timeIntervalSince(startTime)
                    print(String(format: "[%8.3f] %@", elapsed, text))
                }
            }
        }
        packet = MIDIEventPacketNext(&packet).pointee
    }
}

let startTime = Date()

MIDIClientCreateWithBlock("midimon" as CFString, &client, nil)
MIDIInputPortCreateWithProtocol(client, "midimon in" as CFString, ._1_0, &port) { list, _ in
    handle(list)
}

func connectNewSources() {
    let count = MIDIGetNumberOfSources()
    for index in 0..<count {
        let source = MIDIGetSource(index)
        guard source != 0 else { continue }
        var uniqueID: MIDIUniqueID = 0
        MIDIObjectGetIntegerProperty(source, kMIDIPropertyUniqueID, &uniqueID)
        guard !connected.contains(uniqueID) else { continue }
        connected.insert(uniqueID)
        var name: Unmanaged<CFString>?
        MIDIObjectGetStringProperty(source, kMIDIPropertyDisplayName, &name)
        let label = name?.takeRetainedValue() as String? ?? "?"
        print("connected to source: \(label)")
        MIDIPortConnectSource(port, source, nil)
    }
}

connectNewSources()
print("listening for MIDI (Ctrl-C to stop)…")
Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in connectNewSources() }
RunLoop.main.run()
