// MIDIEngine.swift
// A Core MIDI virtual source.  Any DAW sees "MAD60 Magnetic Keys" as an input
// with no driver, kernel extension or background daemon required.

import Foundation
import CoreMIDI

final class MIDIEngine {
    private var client = MIDIClientRef()
    private var source = MIDIEndpointRef()
    private var listBuffer: UnsafeMutableRawPointer?
    private let listSize = 1024

    private(set) var isRunning = false
    private(set) var sourceName = ""

    /// (channel << 8) | note for every note we believe is sounding.
    private var activeNotes = Set<Int>()
    private let lock = NSLock()
    private var group: UInt8 = 0

    private var inputPort = MIDIPortRef()

    var onSetupChanged: (() -> Void)?
    /// Called with (note, velocity, channel) for notes arriving from other apps.
    var onNoteReceived: ((Int, Int, Int) -> Void)?

    // MARK: lifecycle

    func start(name: String) throws {
        stop()

        var status = MIDIClientCreateWithBlock(name as CFString, &client) { [weak self] _ in
            self?.onSetupChanged?()
        }
        guard status == noErr else { throw MIDIError.client(status) }

        status = MIDISourceCreateWithProtocol(client, name as CFString, ._1_0, &source)
        guard status == noErr else {
            MIDIClientDispose(client)
            client = 0
            throw MIDIError.source(status)
        }

        listBuffer = UnsafeMutableRawPointer.allocate(byteCount: listSize, alignment: 8)
        sourceName = name
        isRunning = true
        startInput()
    }

    func stop() {
        allNotesOff()
        if inputPort != 0 { MIDIPortDispose(inputPort); inputPort = 0 }
        if source != 0 { MIDIEndpointDispose(source); source = 0 }
        if client != 0 { MIDIClientDispose(client); client = 0 }
        listBuffer?.deallocate()
        listBuffer = nil
        isRunning = false
    }

    enum MIDIError: LocalizedError {
        case client(OSStatus)
        case source(OSStatus)

        var errorDescription: String? {
            switch self {
            case .client(let s): return "Could not create the Core MIDI client (OSStatus \(s))."
            case .source(let s): return "Could not create the virtual MIDI source (OSStatus \(s))."
            }
        }
    }

    // MARK: input (MIDI learn)

    private func startInput() {
        let status = MIDIInputPortCreateWithProtocol(client, "MagMIDI Learn" as CFString, ._1_0, &inputPort) { [weak self] list, _ in
            self?.handleInput(list)
        }
        guard status == noErr else { return }
        connectAllSources()
    }

    private func connectAllSources() {
        guard inputPort != 0 else { return }
        let count = MIDIGetNumberOfSources()
        for index in 0..<count {
            let source = MIDIGetSource(index)
            guard source != 0, source != self.source else { continue }
            MIDIPortConnectSource(inputPort, source, nil)
        }
    }

    private func handleInput(_ list: UnsafePointer<MIDIEventList>) {
        var packet = list.pointee.packet
        for _ in 0..<list.pointee.numPackets {
            let wordCount = Int(packet.wordCount)
            withUnsafeBytes(of: packet.words) { raw in
                let words = raw.bindMemory(to: UInt32.self)
                var index = 0
                while index < min(wordCount, words.count) {
                    let word = words[index]
                    let messageType = (word >> 28) & 0xF
                    // MIDI 1.0 channel voice is a single 32-bit UMP word.
                    if messageType == 0x2 {
                        let status = UInt8((word >> 16) & 0xFF)
                        let data1 = Int((word >> 8) & 0x7F)
                        let data2 = Int(word & 0x7F)
                        if status & 0xF0 == 0x90, data2 > 0 {
                            let channel = Int(status & 0x0F) + 1
                            let note = data1
                            let velocity = data2
                            DispatchQueue.main.async { [weak self] in
                                self?.onNoteReceived?(note, velocity, channel)
                            }
                        }
                        index += 1
                    } else {
                        // Skip larger UMP message types by their word count.
                        switch messageType {
                        case 0x0, 0x1, 0x2: index += 1
                        case 0x3, 0x4: index += 2
                        case 0x5: index += 4
                        default: index += 1
                        }
                    }
                }
            }
            packet = MIDIEventPacketNext(&packet).pointee
        }
    }

    // MARK: sending

    private func sendWords(_ words: [UInt32]) {
        guard isRunning, let raw = listBuffer, !words.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        let list = raw.bindMemory(to: MIDIEventList.self, capacity: 1)
        var packet = MIDIEventListInit(list, ._1_0)
        var storage = words
        packet = storage.withUnsafeMutableBufferPointer { buffer in
            MIDIEventListAdd(list, listSize, packet, 0, buffer.count, buffer.baseAddress!)
        }
        _ = packet
        MIDIReceivedEventList(source, list)
    }

    private func channelVoice(status: UInt8, channel: Int, data1: Int, data2: Int) {
        let ch = UInt8(max(1, min(16, channel)) - 1)
        let word = (UInt32(2) << 28)
            | (UInt32(group) << 24)
            | (UInt32(status | ch) << 16)
            | (UInt32(max(0, min(127, data1))) << 8)
            | UInt32(max(0, min(127, data2)))
        sendWords([word])
    }

    func noteOn(note: Int, velocity: Int, channel: Int) {
        let clamped = max(1, min(127, velocity))
        lock.lock()
        activeNotes.insert((channel << 8) | note)
        lock.unlock()
        channelVoice(status: 0x90, channel: channel, data1: note, data2: clamped)
    }

    func noteOff(note: Int, channel: Int) {
        lock.lock()
        activeNotes.remove((channel << 8) | note)
        lock.unlock()
        channelVoice(status: 0x80, channel: channel, data1: note, data2: 0)
    }

    func controlChange(_ controller: Int, value: Int, channel: Int) {
        channelVoice(status: 0xB0, channel: channel, data1: controller, data2: value)
    }

    func programChange(_ program: Int, channel: Int) {
        channelVoice(status: 0xC0, channel: channel, data1: program, data2: 0)
    }

    /// value 0...16383, centred at 8192.
    func pitchBend(_ value: Int, channel: Int) {
        let v = max(0, min(16383, value))
        channelVoice(status: 0xE0, channel: channel, data1: v & 0x7F, data2: (v >> 7) & 0x7F)
    }

    func allNotesOff() {
        lock.lock()
        let notes = activeNotes
        activeNotes.removeAll()
        lock.unlock()
        for entry in notes {
            let channel = entry >> 8
            let note = entry & 0xFF
            channelVoice(status: 0x80, channel: channel, data1: note, data2: 0)
            // Belt and braces: CC 123 (all notes off) on every channel we touched.
            _ = channel
        }
        for channel in 1...16 {
            channelVoice(status: 0xB0, channel: channel, data1: 123, data2: 0)
        }
    }

    var soundingNoteCount: Int {
        lock.lock(); defer { lock.unlock() }
        return activeNotes.count
    }
}
