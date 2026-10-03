// Config.swift
// User configuration: per-key mappings, travel/velocity response, MIDI output.

import Foundation

// MARK: - Key action

enum ActionKind: String, Codable, CaseIterable, Identifiable {
    case note
    case cc
    case pitchBend
    case program
    case none

    var id: String { rawValue }

    var title: String {
        switch self {
        case .note: return "Note"
        case .cc: return "Control Change"
        case .pitchBend: return "Pitch Bend"
        case .program: return "Program Change"
        case .none: return "Unassigned"
        }
    }

    var shortTitle: String {
        switch self {
        case .note: return "NOTE"
        case .cc: return "CC"
        case .pitchBend: return "BEND"
        case .program: return "PROG"
        case .none: return "—"
        }
    }
}

struct KeyAction: Codable, Hashable {
    var kind: ActionKind = .none
    /// MIDI note number, CC number or program number.
    var number: Int = 60
    /// 1...16
    var channel: Int = 1
    /// When true the action fires while the key is held and the value follows
    /// the key's travel (useful for CC and pitch bend).
    var continuous: Bool = false

    var display: String {
        switch kind {
        case .none: return "—"
        case .note: return "\(Self.noteName(number))"
        case .cc: return "CC \(number)"
        case .pitchBend: return "Bend"
        case .program: return "Prog \(number)"
        }
    }

    static let noteNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

    static func noteName(_ n: Int) -> String {
        guard n >= 0, n <= 127 else { return "—" }
        return "\(noteNames[n % 12])\(n / 12 - 1)"
    }
}

// MARK: - Velocity

enum VelocitySource: String, Codable, CaseIterable, Identifiable {
    /// Velocity from how fast the key crossed the actuation point.  Real dynamics.
    case strikeSpeed
    /// Velocity from the depth the key reached, measured over a short settle
    /// window (adds ~20 ms of latency but is pressure-like rather than speed-like).
    case peakDepth
    /// A fixed velocity for every note.
    case fixed

    var id: String { rawValue }
    var title: String {
        switch self {
        case .strikeSpeed: return "Strike speed"
        case .peakDepth: return "Peak depth"
        case .fixed: return "Fixed"
        }
    }
}

// MARK: - Configuration

struct Configuration: Codable {
    var version = 3

    // MIDI
    var sourceName = "MAD60 Magnetic Keys"
    var globalChannel = 1

    // Travel response
    /// Fraction of full travel at which a note starts (0...1).
    var actuation = 0.35
    /// Fraction of full travel at which a note stops.  Must be < actuation.
    var release = 0.28
    /// Fallback full-travel span in ADC counts when a key has not been
    /// individually calibrated.
    var defaultTravelSpan = 900.0

    // Velocity
    var velocitySource: VelocitySource = .strikeSpeed
    var fixedVelocity = 100
    /// 0.3 (soft) ... 3.0 (hard) response curve exponent.
    var velocityCurve = 1.0
    /// Multiplier applied to the measured strike speed.
    var velocitySensitivity = 1.0
    /// Travel fraction per second that maps to full velocity.  Strike speed is
    /// measured from the start of the motion to the actuation point, so a firm
    /// press (about 0.30 of travel in ~20 ms) reads roughly 15/s.  Lower values
    /// make 127 easier to reach.
    var fullScaleSpeed = 14.0

    // Continuous expression
    /// CC number driven by the deepest held key's travel, or nil when off.
    var aftertouchCC: Int? = nil
    /// Pitch bend from key pressure.  Semitone range.
    var pitchBendEnabled = false
    var pitchBendRange = 2
    /// Travel beyond which pitch bend starts.
    var pitchBendStart = 0.7

    // Mappings: matrix index -> action
    var mappings: [Int: KeyAction] = [:]

    // Per-key calibration: index -> (rest, bottom) ADC counts
    var calibration: [Int: KeyCalibration] = [:]

    var engineEnabled = true

    /// Take exclusive ownership of the MAD60's keyboard collection so playing
    /// keys does not type into the focused app.  Off by default because macOS
    /// gates this behind the Input Monitoring permission.
    var silenceKeyboard = false
}

extension Configuration {
    /// Tolerant decoding: every field falls back to its default, so a config
    /// written by an older build keeps working after the model grows.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = Configuration()
        func value<T: Decodable>(_ key: CodingKeys, _ or: T) -> T {
            (try? container.decodeIfPresent(T.self, forKey: key)) .flatMap { $0 } ?? or
        }
        version = value(.version, fallback.version)
        sourceName = value(.sourceName, fallback.sourceName)
        globalChannel = value(.globalChannel, fallback.globalChannel)
        actuation = value(.actuation, fallback.actuation)
        release = value(.release, fallback.release)
        defaultTravelSpan = value(.defaultTravelSpan, fallback.defaultTravelSpan)
        velocitySource = value(.velocitySource, fallback.velocitySource)
        fixedVelocity = value(.fixedVelocity, fallback.fixedVelocity)
        velocityCurve = value(.velocityCurve, fallback.velocityCurve)
        velocitySensitivity = value(.velocitySensitivity, fallback.velocitySensitivity)
        fullScaleSpeed = value(.fullScaleSpeed, fallback.fullScaleSpeed)
        aftertouchCC = (try? container.decodeIfPresent(Int.self, forKey: .aftertouchCC)) ?? nil
        pitchBendEnabled = value(.pitchBendEnabled, fallback.pitchBendEnabled)
        pitchBendRange = value(.pitchBendRange, fallback.pitchBendRange)
        pitchBendStart = value(.pitchBendStart, fallback.pitchBendStart)
        mappings = value(.mappings, fallback.mappings)
        calibration = value(.calibration, fallback.calibration)
        engineEnabled = value(.engineEnabled, fallback.engineEnabled)
        silenceKeyboard = value(.silenceKeyboard, fallback.silenceKeyboard)
    }
}

struct KeyCalibration: Codable, Hashable {
    var rest: Double
    var bottom: Double

    var span: Double { max(1, rest - bottom) }
}

// MARK: - Default layout

enum Presets {
    /// Classic computer-keyboard piano: home row = white keys, upper row = black keys.
    static func piano() -> [Int: KeyAction] {
        var map: [Int: KeyAction] = [:]
        let white: [(String, Int)] = [
            ("A", 60), ("S", 62), ("D", 64), ("F", 65), ("G", 67),
            ("H", 69), ("J", 71), ("K", 72), ("L", 74), (";", 76), ("'", 77),
        ]
        let black: [(String, Int)] = [
            ("W", 61), ("E", 63), ("T", 66), ("Y", 68), ("U", 70),
            ("O", 73), ("P", 75),
        ]
        func assign(_ pairs: [(String, Int)], kind: ActionKind) {
            for (label, note) in pairs {
                guard let index = KeyLayout.table.firstIndex(where: { $0 == label }) else { continue }
                map[index] = KeyAction(kind: kind, number: note)
            }
        }
        assign(white, kind: .note)
        assign(black, kind: .note)

        // Number row drives the mod wheel and a few expression CCs so the board
        // is useful as a controller straight away.
        let ccs: [(String, Int)] = [
            ("1", 1), ("2", 74), ("3", 71), ("4", 91), ("5", 93),
            ("6", 10), ("7", 5), ("8", 84), ("9", 7), ("0", 11), ("-", 64), ("=", 66),
        ]
        for (label, cc) in ccs {
            guard let index = KeyLayout.table.firstIndex(where: { $0 == label }) else { continue }
            map[index] = KeyAction(kind: .cc, number: cc, continuous: true)
        }
        return map
    }

    /// Every populated key plays the next semitone.
    static func chromatic(startNote: Int = 48) -> [Int: KeyAction] {
        var map: [Int: KeyAction] = [:]
        var note = startNote
        for position in KeyLayout.positions {
            map[position.index] = KeyAction(kind: .note, number: min(note, 127))
            note += 1
        }
        return map
    }

    /// Bottom two rows become a 16-pad drum kit.
    static func drums() -> [Int: KeyAction] {
        var map: [Int: KeyAction] = [:]
        var note = 36
        for row in [3, 4] {
            for column in 0..<MAD60.columns {
                let index = row * MAD60.columns + column
                guard KeyLayout.isPopulated(index) else { continue }
                map[index] = KeyAction(kind: .note, number: min(note, 51))
                note += 1
            }
        }
        return map
    }

    /// Everything unassigned.
    static func empty() -> [Int: KeyAction] { [:] }
}

enum PresetKind: String, CaseIterable, Identifiable {
    case piano, chromatic, drums, empty
    var id: String { rawValue }
    var title: String {
        switch self {
        case .piano: return "Piano"
        case .chromatic: return "Chromatic"
        case .drums: return "Drum pads"
        case .empty: return "Empty"
        }
    }
    var mappings: [Int: KeyAction] {
        switch self {
        case .piano: return Presets.piano()
        case .chromatic: return Presets.chromatic()
        case .drums: return Presets.drums()
        case .empty: return Presets.empty()
        }
    }
}

// MARK: - Persistence

final class ConfigStore {
    static let shared = ConfigStore()

    private let directory: URL
    private let fileURL: URL

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        directory = base.appendingPathComponent("MagMIDI", isDirectory: true)
        fileURL = directory.appendingPathComponent("config.json")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    var path: String { fileURL.path }

    func load() -> Configuration {
        guard let data = try? Data(contentsOf: fileURL),
              var config = try? JSONDecoder().decode(Configuration.self, from: data) else {
            var fresh = Configuration()
            fresh.mappings = Presets.piano()
            return fresh
        }
        if config.version < 2 {
            // v1 silenced the keyboard through the HID event system.  Never carry
            // that over automatically.
            config.silenceKeyboard = false
        }
        if config.version < 3 {
            // v3 changed strike speed from a short derivative to a whole-strike
            // average, so the old ceiling no longer means the same thing.
            config.fullScaleSpeed = Configuration().fullScaleSpeed
        }
        config.version = 3
        return config
    }

    func save(_ config: Configuration) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(config) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    func writeDiagnostics(_ payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload,
                                                     options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: directory.appendingPathComponent("diagnostics.json"), options: .atomic)
    }

    func export(_ config: Configuration, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(config).write(to: url, options: .atomic)
    }

    func `import`(from url: URL) throws -> Configuration {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Configuration.self, from: data)
    }
}
