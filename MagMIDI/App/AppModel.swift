// AppModel.swift
// Wires the HID driver, travel engine and MIDI output together and exposes
// observable state for the UI.

import Foundation
import Combine
import QuartzCore

final class AppModel: ObservableObject {
    @Published var configuration: Configuration {
        didSet {
            engine.update(configuration: configuration)
            scheduleSave()
        }
    }

    @Published private(set) var status: MAD60HID.Status = .searching
    @Published private(set) var telemetry = [KeyTelemetry](repeating: KeyTelemetry(), count: MAD60.keyCount)
    @Published private(set) var engineRunning = false
    @Published var errorMessage: String?
    @Published var selectedKey: Int? = 29
    @Published var learnTarget: Int?
    @Published var activity: String = ""
    @Published private(set) var soundingNotes = 0
    @Published private(set) var captureState: KeyboardCapture.State = .off
    @Published private(set) var lastNote: (key: Int, note: Int, velocity: Int)?
    @Published private(set) var peakStrikeSpeed: Double = 0
    @Published private(set) var lastStrike: (speed: Double, velocity: Int)?
    /// Recent (strike speed, resulting velocity) pairs, for the tuning plot.
    @Published private(set) var strikeHistory: [(speed: Double, velocity: Int)] = []

    @Published var isMeasuringRest = false
    @Published private(set) var isMeasuringRange = false
    @Published private(set) var measuredKeyCount = 0
    @Published var calibrationProgress: Double = 0

    let midi = MIDIEngine()
    let hid = MAD60HID()
    let keyboardCapture = KeyboardCapture()
    private let engine: TravelEngine
    private let store = ConfigStore.shared
    private var saveWorkItem: DispatchWorkItem?
    private var restSamples = [[Double]]()
    private var restWindowEnd: Date?
    private var rangeMin = [Double](repeating: 4096, count: MAD60.keyCount)
    private var meterTimer: Timer?

    init() {
        let loaded = store.load()
        configuration = loaded
        engine = TravelEngine(midi: midi, configuration: loaded)

        hid.onStatusChange = { [weak self] status in
            self?.status = status
            if status.isConnected {
                self?.beginRestMeasurement()
            } else {
                self?.activity = "Waiting for MAD60…"
            }
        }
        hid.onScan = { [weak self] values in
            self?.handleScan(values)
        }

        engine.onTelemetry = { [weak self] snapshot in
            guard let self else { return }
            self.telemetry = snapshot
            self.peakStrikeSpeed = self.engine.peakStrikeSpeed
            self.lastStrike = (self.engine.lastStrikeSpeed, self.engine.lastVelocity)
        }

        engine.onNoteFired = { [weak self] index, note, velocity, speed in
            DispatchQueue.main.async {
                guard let self else { return }
                self.lastNote = (index, note, velocity)
                self.strikeHistory.append((speed, velocity))
                if self.strikeHistory.count > 60 {
                    self.strikeHistory.removeFirst(self.strikeHistory.count - 60)
                }
            }
        }

        midi.onNoteReceived = { [weak self] note, _ , channel in
            guard let self, let target = self.learnTarget else { return }
            var action = self.action(for: target)
            action.kind = .note
            action.number = note
            action.channel = channel
            self.setAction(action, for: target)
            self.learnTarget = nil
            self.activity = "Learned \(KeyAction.noteName(note)) for \(KeyLayout.label(at: target))"
        }

        keyboardCapture.onStateChange = { [weak self] state in
            self?.captureState = state
            self?.writeDiagnostics()
        }

        hid.start()
        startMIDI()
        if loaded.silenceKeyboard {
            keyboardCapture.activate()
        }
        activity = "Scanning USB for MAD60…"

        var ticks = 0
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.soundingNotes = self.midi.soundingNoteCount
            ticks += 1
            if ticks % 10 == 0 { self.writeDiagnostics() }
        }
        writeDiagnostics()
    }

    // MARK: MIDI

    func startMIDI() {
        do {
            try midi.start(name: configuration.sourceName)
            engineRunning = true
            errorMessage = nil
        } catch {
            engineRunning = false
            errorMessage = error.localizedDescription
        }
    }

    func stopMIDI() {
        engine.reset()
        midi.stop()
        engineRunning = false
    }

    func restartMIDI() {
        stopMIDI()
        startMIDI()
    }

    // MARK: keyboard capture

    func setSilenceKeyboard(_ enabled: Bool) {
        var config = configuration
        config.silenceKeyboard = enabled
        configuration = config
        if enabled {
            keyboardCapture.activate()
            activity = "Capturing the MAD60's keyboard output"
        } else {
            keyboardCapture.deactivate()
            activity = "Keyboard left as a normal keyboard"
        }
    }

    /// Writes a small status file next to the configuration.  Purely for
    /// troubleshooting — it makes permission and seize problems diagnosable
    /// without guessing from the UI.
    func writeDiagnostics() {
        let payload: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "deviceConnected": status.isConnected,
            "inputMonitoringGranted": KeyboardCapture.hasInputMonitoring,
            "captureEnabled": configuration.silenceKeyboard,
            "captureState": captureState.description,
            "captureAttempts": keyboardCapture.lastResults,
            "midiRunning": engineRunning,
            "midiSource": configuration.sourceName,
            "midiSoundingNotes": midi.soundingNoteCount,
            "configPath": store.path,
        ]
        store.writeDiagnostics(payload)
    }

    func resetPeakStrike() {
        engine.resetPeakStrike()
        peakStrikeSpeed = 0
        lastStrike = nil
        strikeHistory.removeAll()
    }

    func openInputMonitoringSettings() {
        KeyboardCapture.openInputMonitoringSettings()
    }

    func panic() {
        engine.reset()
        activity = "All notes off"
    }

    // MARK: scans

    private func handleScan(_ values: [UInt16]) {
        let now = CACurrentMediaTime()
        let wall = Date()

        if isMeasuringRest, let end = restWindowEnd {
            if wall < end {
                restSamples.append(values.map { Double($0) })
                return
            }
        }

        if isMeasuringRange {
            var measured = 0
            for index in 0..<MAD60.keyCount {
                let value = Double(values[index])
                guard value > 0, value < Double(MAD60.emptyADC) else { continue }
                if value < rangeMin[index] { rangeMin[index] = value }
                if let calibration = configuration.calibration[index],
                   rangeMin[index] < calibration.rest - 150 {
                    measured += 1
                }
            }
            if measured != measuredKeyCount {
                let progress = Double(measured) / Double(KeyLayout.positions.count)
                DispatchQueue.main.async { [weak self] in
                    self?.measuredKeyCount = measured
                    self?.calibrationProgress = progress
                }
            }
        }

        engine.process(values, at: now)
    }

    // MARK: rest calibration

    func beginRestMeasurement(duration: TimeInterval = 0.9) {
        restSamples.removeAll()
        restWindowEnd = Date().addingTimeInterval(duration)
        isMeasuringRest = true
        DispatchQueue.main.async { [weak self] in
            self?.activity = "Measuring resting position — don't touch the keys"
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.05) { [weak self] in
            self?.finishRestMeasurement()
        }
    }

    private func finishRestMeasurement() {
        isMeasuringRest = false
        restWindowEnd = nil
        guard !restSamples.isEmpty else { return }
        var rests = [Double](repeating: 0, count: MAD60.keyCount)
        for index in 0..<MAD60.keyCount {
            // Travel only ever pulls the ADC down, so the maximum over the
            // window is the true resting value even if a key was touched.
            rests[index] = restSamples.map { $0[index] }.max() ?? 0
        }
        engine.adoptRest(rests)

        var config = configuration
        for index in 0..<MAD60.keyCount where rests[index] > 0 && rests[index] < Double(MAD60.emptyADC) {
            let existing = config.calibration[index]
            let bottom = existing?.bottom ?? (rests[index] - config.defaultTravelSpan)
            config.calibration[index] = KeyCalibration(rest: rests[index], bottom: min(bottom, rests[index] - 100))
        }
        configuration = config
        activity = "Resting position captured"
    }

    // MARK: full-travel calibration

    /// Starts an open-ended full-travel pass.  There is no timer: press every key
    /// at your own pace and then call `finishRangeMeasurement()`.
    func beginRangeMeasurement() {
        rangeMin = [Double](repeating: 4096, count: MAD60.keyCount)
        isMeasuringRange = true
        measuredKeyCount = 0
        calibrationProgress = 0
        activity = "Press every key all the way down, then press Finish"
    }

    func cancelRangeMeasurement() {
        guard isMeasuringRange else { return }
        isMeasuringRange = false
        rangeMin = [Double](repeating: 4096, count: MAD60.keyCount)
        measuredKeyCount = 0
        calibrationProgress = 0
        activity = "Full-travel calibration cancelled"
    }

    func finishRangeMeasurement() {
        guard isMeasuringRange else { return }
        isMeasuringRange = false
        var config = configuration
        var updated = 0
        for index in 0..<MAD60.keyCount {
            guard rangeMin[index] < Double(MAD60.emptyADC) else { continue }
            guard let existing = config.calibration[index] else { continue }
            let bottom = min(rangeMin[index], existing.rest - 100)
            guard existing.rest - bottom > 150 else { continue }
            config.calibration[index] = KeyCalibration(rest: existing.rest, bottom: bottom)
            updated += 1
        }
        configuration = config
        for index in 0..<MAD60.keyCount {
            if let calibration = config.calibration[index] {
                engine.setSpan(index: index, span: calibration.span)
            }
        }
        engine.update(configuration: config)
        activity = "Travel range updated for \(updated) keys"
        measuredKeyCount = updated
    }

    // MARK: mapping

    func action(for index: Int) -> KeyAction {
        configuration.mappings[index] ?? KeyAction(kind: .none)
    }

    func setAction(_ action: KeyAction, for index: Int) {
        var config = configuration
        if action.kind == .none {
            config.mappings.removeValue(forKey: index)
        } else {
            config.mappings[index] = action
        }
        configuration = config
    }

    func clearMapping(at index: Int) {
        var config = configuration
        config.mappings.removeValue(forKey: index)
        configuration = config
    }

    func applyPreset(_ kind: PresetKind) {
        var config = configuration
        config.mappings = kind.mappings
        configuration = config
        activity = "Applied \(kind.title) preset"
    }

    func exportConfiguration(to url: URL) {
        do {
            try store.export(configuration, to: url)
            activity = "Exported to \(url.lastPathComponent)"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func importConfiguration(from url: URL) {
        do {
            let config = try store.import(from: url)
            configuration = config
            engine.update(configuration: config)
            activity = "Imported \(url.lastPathComponent)"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func resetCalibration() {
        var config = configuration
        config.calibration.removeAll()
        configuration = config
        engine.update(configuration: config)
        beginRestMeasurement()
    }

    // MARK: persistence

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.store.save(self.configuration)
        }
        saveWorkItem = item
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    var configPath: String { store.path }
}
