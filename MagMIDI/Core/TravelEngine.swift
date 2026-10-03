// TravelEngine.swift
// Turns raw per-key ADC counts into musical events.
//
//  * a key "presses" when its travel crosses the actuation point
//  * note velocity comes from how fast the key was moving at that moment
//    (strike speed), from the depth reached, or from a fixed value
//  * keeping a key held past the actuation point acts as a continuous
//    expression source (aftertouch CC and/or pitch bend)

import Foundation

struct KeyTelemetry {
    var travel: Double = 0
    var isDown = false
    var velocity: Int = 0
    var peak: Double = 0
    /// Most recent strike speed, in travel-fractions per second.
    var speed: Double = 0
}

final class TravelEngine {
    private let midi: MIDIEngine
    private let lock = NSLock()
    private var config: Configuration

    private struct KeyState {
        var travel: Double = 0
        var previousTravel: Double = 0
        var isDown = false
        var peak: Double = 0
        var velocity: Int = 0
        var firingNote = -1
        var pendingNote: (note: Int, channel: Int)?
        var pendingSince: TimeInterval = 0
        var lastCC = -1
        var lastBend = -1
        var rest: Double = 0
        var span: Double = 900
        var hasRest = false
        var history: [(TimeInterval, Double)] = []
        /// When and where the current downward motion began — the strike is
        /// measured across the whole motion, which is far more stable than a
        /// short derivative at 5 ms sampling.
        var motionStart: TimeInterval?
        var motionStartTravel: Double = 0
        var speed: Double = 0
    }

    private var states = [KeyState](repeating: KeyState(), count: MAD60.keyCount)
    private var telemetry = [KeyTelemetry](repeating: KeyTelemetry(), count: MAD60.keyCount)

    /// Published on the main thread, throttled.
    var onTelemetry: (([KeyTelemetry]) -> Void)?
    /// Fired (on the polling thread) as (matrixIndex, note, velocity).
    var onNoteFired: ((Int, Int, Int) -> Void)?

    private var lastPublish: TimeInterval = 0
    private var lastAftertouch = -1
    private var lastBendSent = -1
    private var bendCenterSent = false

    /// Rest positions measured at startup / calibration, in ADC counts.
    private(set) var restValues = [Double](repeating: 0, count: MAD60.keyCount)

    init(midi: MIDIEngine, configuration: Configuration) {
        self.midi = midi
        self.config = configuration
        applyCalibration()
    }

    // MARK: configuration

    func update(configuration: Configuration) {
        lock.lock()
        self.config = configuration
        lock.unlock()
        applyCalibration()
    }

    private func applyCalibration() {
        var local = [KeyState]()
        local.reserveCapacity(MAD60.keyCount)
        lock.lock()
        let calibration = config.calibration
        let fallbackSpan = config.defaultTravelSpan
        lock.unlock()
        for index in 0..<MAD60.keyCount {
            var state = states[index]
            if let cal = calibration[index] {
                state.rest = cal.rest
                state.span = cal.span
                state.hasRest = true
                restValues[index] = cal.rest
            } else {
                state.span = fallbackSpan
            }
            state.history.removeAll(keepingCapacity: true)
            local.append(state)
        }
        states = local
    }

    /// Adopt a freshly measured rest snapshot (ADC counts).
    func adoptRest(_ rests: [Double]) {
        lock.lock()
        for index in 0..<min(rests.count, MAD60.keyCount) where rests[index] > 0 {
            states[index].rest = rests[index]
            states[index].hasRest = true
            restValues[index] = rests[index]
            if config.calibration[index] == nil {
                states[index].span = config.defaultTravelSpan
            }
        }
        let snapshot = config
        lock.unlock()
        update(configuration: snapshot)
    }

    func setSpan(index: Int, span: Double) {
        lock.lock()
        states[index].span = max(50, span)
        lock.unlock()
    }

    // MARK: processing

    func process(_ values: [UInt16], at time: TimeInterval) {
        lock.lock()
        let cfg = config
        lock.unlock()

        guard cfg.engineEnabled else { return }

        var deepestHeldTravel = 0.0

        for index in 0..<MAD60.keyCount {
            let raw = Double(values[index])
            guard raw > 0, raw < Double(MAD60.emptyADC) else { continue }

            var state = states[index]
            if !state.hasRest {
                // No calibration yet: treat the first reading as rest.
                state.rest = raw
                state.hasRest = true
                restValues[index] = raw
                states[index] = state
                continue
            }

            let travel = max(0, min(1, (state.rest - raw) / state.span))
            state.previousTravel = state.travel
            state.travel = travel

            // Rolling history for strike-speed estimation (~15 ms window).
            state.history.append((time, travel))
            if state.history.count > 12 { state.history.removeFirst(state.history.count - 12) }
            // Track the start of the downward motion.
            if travel <= 0.02 {
                state.motionStart = nil
            } else if state.motionStart == nil {
                state.motionStart = time
                state.motionStartTravel = travel
            }

            // Prefer the whole-strike average; fall back to the short-window
            // derivative when the motion was already underway when we looked.
            var speed = strikeSpeed(state.history, now: time)
            if let start = state.motionStart, time - start >= 0.004, travel > state.motionStartTravel {
                speed = (travel - state.motionStartTravel) / (time - start)
            }
            state.speed = speed

            let action = cfg.mappings[index] ?? KeyAction(kind: .none)
            let channel = action.channel > 0 ? action.channel : cfg.globalChannel

            switch action.kind {
            case .none:
                if state.isDown { release(&state, cfg: cfg, channel: channel) }
                break

            case .note:
                if !state.isDown && travel >= cfg.actuation {
                    state.isDown = true
                    state.peak = travel
                    state.velocity = makeVelocity(speed: speed, peak: travel, cfg: cfg)
                    state.firingNote = action.number
                    if cfg.velocitySource == .peakDepth {
                        state.pendingNote = (action.number, channel)
                        state.pendingSince = time
                    } else {
                        fireNote(index: index, note: action.number, velocity: state.velocity, channel: channel)
                    }
                } else if state.isDown {
                    state.peak = max(state.peak, travel)
                    if let pending = state.pendingNote {
                        let settled = speed < cfg.fullScaleSpeed * 0.08 || (time - state.pendingSince) > 0.02
                        if settled {
                            let velocity = makeVelocity(speed: speed, peak: state.peak, cfg: cfg)
                            state.velocity = velocity
                            fireNote(index: index, note: pending.note, velocity: velocity, channel: pending.channel)
                            state.pendingNote = nil
                        }
                    }
                    if travel < cfg.release {
                        if let pending = state.pendingNote {
                            fireNote(index: index, note: pending.note, velocity: state.velocity, channel: pending.channel)
                            state.pendingNote = nil
                        }
                        release(&state, cfg: cfg, channel: channel)
                    }
                }

            case .cc where action.continuous:
                // CC follows the key's travel for as long as it is held.
                if travel > cfg.actuation * 0.5 {
                    let value = Int(min(1.0, max(0, (travel - cfg.release) / max(0.05, 1 - cfg.release))) * 127)
                    if value != state.lastCC {
                        state.lastCC = value
                        midi.controlChange(action.number, value: value, channel: channel)
                    }
                } else if state.lastCC != 0 && state.lastCC != -1 {
                    state.lastCC = 0
                    midi.controlChange(action.number, value: 0, channel: channel)
                }
                state.isDown = travel >= cfg.actuation

            case .cc, .program:
                if !state.isDown && travel >= cfg.actuation {
                    state.isDown = true
                    if action.kind == .cc {
                        midi.controlChange(action.number, value: 127, channel: channel)
                    } else {
                        midi.programChange(action.number, channel: channel)
                    }
                } else if state.isDown && travel < cfg.release {
                    state.isDown = false
                    if action.kind == .cc {
                        midi.controlChange(action.number, value: 0, channel: channel)
                    }
                }

            case .pitchBend:
                // Per-key bend: travel past the actuation point bends upward.
                if travel > cfg.actuation {
                    let amount = (travel - cfg.actuation) / max(0.05, 1 - cfg.actuation)
                    let value = 8192 + Int(amount * 8191)
                    if abs(value - state.lastBend) > 16 {
                        state.lastBend = value
                        midi.pitchBend(value, channel: channel)
                    }
                } else if state.lastBend != -1 {
                    state.lastBend = -1
                    midi.pitchBend(8192, channel: channel)
                }
                state.isDown = travel >= cfg.actuation
            }

            if state.isDown { deepestHeldTravel = max(deepestHeldTravel, travel) }
            telemetry[index].travel = travel
            telemetry[index].isDown = state.isDown
            telemetry[index].velocity = state.velocity
            telemetry[index].peak = state.peak
            telemetry[index].speed = state.speed
            states[index] = state
        }

        applyGlobalExpression(deepestHeldTravel: deepestHeldTravel, cfg: cfg)

        if time - lastPublish > 1.0 / 30.0 {
            lastPublish = time
            let snapshot = telemetry
            DispatchQueue.main.async { [weak self] in self?.onTelemetry?(snapshot) }
        }
    }

    private func fireNote(index: Int, note: Int, velocity: Int, channel: Int) {
        midi.noteOn(note: note, velocity: velocity, channel: channel)
        onNoteFired?(index, note, velocity)
    }

    private func release(_ state: inout KeyState, cfg: Configuration, channel: Int) {
        guard state.isDown else { return }
        state.isDown = false
        state.peak = 0
        if state.firingNote >= 0 {
            midi.noteOff(note: state.firingNote, channel: channel)
            state.firingNote = -1
        }
    }

    /// Travel units (fraction of full travel) per second, measured over a short
    /// window so it reflects the strike rather than the whole motion.
    private func strikeSpeed(_ history: [(TimeInterval, Double)], now: TimeInterval) -> Double {
        guard let last = history.last else { return 0 }
        // Look back ~15 ms, or as far as the buffer allows.
        var earliest = last
        for sample in history.reversed() {
            if now - sample.0 > 0.015 { break }
            earliest = sample
        }
        let dt = last.0 - earliest.0
        guard dt > 0.0005 else {
            // Fall back to the previous sample pair.
            if history.count >= 2 {
                let a = history[history.count - 2]
                let d = last.0 - a.0
                if d > 0 { return (last.1 - a.1) / d }
            }
            return 0
        }
        return (last.1 - earliest.1) / dt
    }

    private func makeVelocity(speed: Double, peak: Double, cfg: Configuration) -> Int {
        switch cfg.velocitySource {
        case .fixed:
            return max(1, min(127, cfg.fixedVelocity))
        case .strikeSpeed:
            let normalized = max(0, speed) / max(1, cfg.fullScaleSpeed) * max(0.05, cfg.velocitySensitivity)
            let shaped = pow(min(1.0, normalized), max(0.2, cfg.velocityCurve))
            return max(1, min(127, Int(1 + shaped * 126)))
        case .peakDepth:
            let normalized = max(0, min(1, (peak - cfg.actuation) / max(0.05, 1 - cfg.actuation)))
            let shaped = pow(normalized, max(0.2, cfg.velocityCurve))
            return max(1, min(127, Int(1 + shaped * 126)))
        }
    }

    /// Aftertouch CC and pitch bend driven by the deepest key currently held.
    private func applyGlobalExpression(deepestHeldTravel: Double, cfg: Configuration) {
        if let cc = cfg.aftertouchCC {
            let value = deepestHeldTravel <= cfg.actuation
                ? 0
                : Int(min(1.0, (deepestHeldTravel - cfg.actuation) / max(0.05, 1 - cfg.actuation)) * 127)
            if value != lastAftertouch {
                lastAftertouch = value
                midi.controlChange(cc, value: value, channel: cfg.globalChannel)
            }
        }

        if cfg.pitchBendEnabled {
            if deepestHeldTravel >= cfg.pitchBendStart {
                let amount = (deepestHeldTravel - cfg.pitchBendStart) / max(0.05, 1 - cfg.pitchBendStart)
                let value = 8192 + Int(amount * 8191)
                if abs(value - lastBendSent) > 24 {
                    lastBendSent = value
                    bendCenterSent = false
                    midi.pitchBend(value, channel: cfg.globalChannel)
                }
            } else if !bendCenterSent && lastBendSent != -1 {
                lastBendSent = 8192
                bendCenterSent = true
                midi.pitchBend(8192, channel: cfg.globalChannel)
            }
        }
    }

    /// Everything off — used by the panic button and when stopping.
    func reset() {
        for index in 0..<MAD60.keyCount {
            states[index].isDown = false
            states[index].pendingNote = nil
            states[index].lastCC = -1
            states[index].lastBend = -1
            telemetry[index] = KeyTelemetry()
        }
        lastAftertouch = -1
        lastBendSent = -1
        bendCenterSent = false
        midi.allNotesOff()
    }
}
