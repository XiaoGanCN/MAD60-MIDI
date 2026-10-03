// TravelView.swift — how key travel becomes velocity and expression.

import SwiftUI

struct TravelView: View {
    @EnvironmentObject private var model: AppModel

    private var config: Configuration { model.configuration }


    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Card(title: "Actuation", systemImage: "arrow.down.to.line") {
                    LabeledSlider(
                        title: "Note on at",
                        value: Binding(get: { config.actuation }, set: { newValue in
                            var c = config
                            c.actuation = newValue
                            if c.release > newValue - 0.02 { c.release = max(0.02, newValue - 0.02) }
                            model.configuration = c
                        }),
                        range: 0.05...0.95,
                        format: { String(format: "%.0f%% of travel", $0 * 100) }
                    )
                    LabeledSlider(
                        title: "Note off at",
                        value: Binding(get: { config.release }, set: { newValue in
                            var c = config
                            c.release = min(newValue, c.actuation - 0.02)
                            model.configuration = c
                        }),
                        range: 0.02...0.9,
                        format: { String(format: "%.0f%% of travel", $0 * 100) }
                    )
                    Text("The gap between the two points is the hysteresis that stops a key chattering around the trigger.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        Text("Trigger test").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        TravelMeter(value: model.telemetry.compactMap { $0.travel }.max() ?? 0, actuation: config.actuation)
                            .frame(width: 240)
                    }
                }

                Card(title: "Velocity", systemImage: "speedometer") {
                    Picker("Source", selection: Binding(get: { config.velocitySource }, set: { newValue in
                        var c = config; c.velocitySource = newValue; model.configuration = c
                    })) {
                        ForEach(VelocitySource.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    Text(explanation)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    if config.velocitySource == .fixed {
                        LabeledSlider(
                            title: "Fixed velocity",
                            value: Binding(get: { Double(config.fixedVelocity) }, set: { newValue in
                                var c = config; c.fixedVelocity = Int(newValue); model.configuration = c
                            }),
                            range: 1...127,
                            format: { "\(Int($0))" }
                        )
                    } else {
                        LabeledSlider(
                            title: "Full velocity at",
                            value: Binding(get: { config.fullScaleSpeed }, set: { newValue in
                                var c = config; c.fullScaleSpeed = newValue; model.configuration = c
                            }),
                            range: 4...80,
                            format: { String(format: "%.1f travel/s", $0) }
                        )
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text("Last strike")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.secondary)
                                if let strike = model.lastStrike, strike.speed > 0 {
                                    Text(String(format: "%.1f", strike.speed))
                                        .font(.system(size: 16, weight: .bold, design: .rounded))
                                        .monospacedDigit()
                                    Text("travel/s →")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.tertiary)
                                    Text("velocity")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.tertiary)
                                    Text("\(strike.velocity)")
                                        .font(.system(size: 16, weight: .bold, design: .rounded))
                                        .monospacedDigit()
                                        .foregroundStyle(strike.velocity > 110 ? Color.accentColor : Color.primary)
                                } else {
                                    Text("play a hard note…")
                                        .font(.system(size: 12))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            HStack(spacing: 8) {
                                Text("Hardest in the last 10 s")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                Text(String(format: "%.1f travel/s", model.peakStrikeSpeed))
                                    .font(.system(size: 11, weight: .medium, design: .rounded))
                                    .monospacedDigit()
                                Button("Reset") { model.resetPeakStrike() }
                                    .buttonStyle(.borderless)
                                    .font(.system(size: 11))
                            }
                        }
                        Text("“travel/s” is how much of the key's full travel it covers per second, so it does not depend on the key. Play a few notes as hard as you normally would and set “Full velocity at” just below your hardest strike, so a firm press reaches 127.")
                        LabeledSlider(
                            title: "Timing damper",
                            value: Binding(get: { config.velocityDamperMs }, set: { newValue in
                                var c = config; c.velocityDamperMs = newValue; model.configuration = c
                            }),
                            range: 0...20,
                            format: { $0 < 0.5 ? "off — lowest latency" : String(format: "%.0f ms", $0) }
                        )
                        Text("How long to keep listening before a note fires. A few milliseconds trades latency for a steadier reading, and on a quick press it lets the measurement run to the bottom of the key's travel — the classic “time from top to bottom” approach. Raise it if fast repeated notes still feel uneven; set it to 0 for the lowest possible latency.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        LabeledSlider(
                            title: "Curve",
                            value: Binding(get: { config.velocityCurve }, set: { newValue in
                                var c = config; c.velocityCurve = newValue; model.configuration = c
                            }),
                            range: 0.4...2.5,
                            format: { String(format: "%.2f", $0) }
                        )
                    }

                    VelocityCurveView(config: config, history: model.strikeHistory)
                        .frame(height: 150)
                        .padding(.top, 4)
                    HStack(spacing: 14) {
                        Label("response curve", systemImage: "line.diagonal")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Label("\(model.strikeHistory.count) recent strike\(model.strikeHistory.count == 1 ? "" : "s")", systemImage: "circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.accentColor)
                        Spacer()
                        Text("Play a range of soft→hard notes to fill this in.")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }

                Card(title: "Expression", systemImage: "waveform") {
                    Toggle("Send aftertouch CC from the deepest held key", isOn: Binding(
                        get: { config.aftertouchCC != nil },
                        set: { newValue in
                            var c = config
                            c.aftertouchCC = newValue ? (c.aftertouchCC ?? 1) : nil
                            model.configuration = c
                        }
                    ))
                    if let cc = config.aftertouchCC {
                        LabeledSlider(
                            title: "Controller number",
                            value: Binding(get: { Double(cc) }, set: { newValue in
                                var c = config; c.aftertouchCC = Int(newValue); model.configuration = c
                            }),
                            range: 0...127,
                            format: { "CC \(Int($0))" }
                        )
                    }

                    Divider()

                    Toggle("Bend pitch with key pressure", isOn: Binding(
                        get: { config.pitchBendEnabled },
                        set: { newValue in
                            var c = config; c.pitchBendEnabled = newValue; model.configuration = c
                        }
                    ))
                    if config.pitchBendEnabled {
                        LabeledSlider(
                            title: "Bend range",
                            value: Binding(get: { Double(config.pitchBendRange) }, set: { newValue in
                                var c = config; c.pitchBendRange = max(1, Int(newValue)); model.configuration = c
                            }),
                            range: 1...24,
                            format: { "±\(Int($0)) semitones" }
                        )
                        LabeledSlider(
                            title: "Starts at",
                            value: Binding(get: { config.pitchBendStart }, set: { newValue in
                                var c = config; c.pitchBendStart = newValue; model.configuration = c
                            }),
                            range: 0.3...0.95,
                            format: { String(format: "%.0f%% of travel", $0 * 100) }
                        )
                        Text("Push any held key past the start point to bend upward, release pressure to return to centre. The deepest key wins.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(20)
        }
    }

    private var explanation: String {
        switch config.velocitySource {
        case .strikeSpeed:
            return "Velocity follows how fast the key crossed the actuation point — press gently for soft notes, snap the key for accents."
        case .peakDepth:
            return "Velocity follows how far the key travelled. Adds roughly 20 ms of latency while the key settles."
        case .fixed:
            return "Every note is sent at the same velocity."
        }
    }
}

struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.system(size: 12, weight: .medium))
                Spacer()
                Text(format(value))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range)
        }
    }
}

/// Plots the configured response curve together with every recent strike, so
/// the relationship between how hard you play and the velocity you get is
/// visible rather than guessed at.
struct VelocityCurveView: View {
    let config: Configuration
    let history: [(speed: Double, velocity: Int)]

    private var maxSpeed: Double { max(4.0, config.fullScaleSpeed * 1.45) }

    /// Mirrors VelocitySource.strikeSpeed in TravelEngine.
    private func velocity(for speed: Double) -> Double {
        switch config.velocitySource {
        case .fixed:
            return Double(config.fixedVelocity)
        case .peakDepth:
            // The x axis is speed, which does not drive velocity in this mode;
            // show the average of what actually happened instead.
            guard !history.isEmpty else { return 0 }
            let peak = config.actuation + (1 - config.actuation)
            _ = peak
            return history.map { Double($0.velocity) }.reduce(0, +) / Double(history.count)
        case .strikeSpeed:
            let normalized = max(0, speed) / max(1, config.fullScaleSpeed) * max(0.05, config.velocitySensitivity)
            let shaped = pow(min(1.0, normalized), max(0.2, config.velocityCurve))
            return 1 + shaped * 126
        }
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height
            let steps = 140
            let curve: [CGPoint] = (0...steps).map { step in
                let speed = maxSpeed * Double(step) / Double(steps)
                return CGPoint(x: CGFloat(speed / maxSpeed) * width,
                               y: height - CGFloat(min(1, velocity(for: speed) / 127)) * height)
            }
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.04))

                // Reference lines at velocity 32/64/96.
                ForEach([32, 64, 96], id: \.self) { mark in
                    Rectangle()
                        .fill(Color.primary.opacity(0.07))
                        .frame(height: 1)
                        .offset(y: height - CGFloat(Double(mark) / 127) * height)
                }

                // The configured response.
                Path { path in
                    path.move(to: CGPoint(x: 0, y: height))
                    for point in curve { path.addLine(to: point) }
                    path.addLine(to: CGPoint(x: width, y: height))
                    path.closeSubpath()
                }
                .fill(Color.accentColor.opacity(0.12))

                Path { path in
                    path.move(to: curve[0])
                    for point in curve.dropFirst() { path.addLine(to: point) }
                }
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))

                // The full-velocity threshold.
                Rectangle()
                    .fill(Color.accentColor.opacity(0.35))
                    .frame(width: 1)
                    .offset(x: CGFloat(config.fullScaleSpeed / maxSpeed) * width)

                // Actual strikes.
                ForEach(Array(history.enumerated()), id: \.offset) { _, strike in
                    Circle()
                        .fill(Color.accentColor.opacity(0.85))
                        .overlay(Circle().stroke(Color.white.opacity(0.6), lineWidth: 0.5))
                        .frame(width: 6, height: 6)
                        .position(x: min(width, CGFloat(strike.speed / maxSpeed) * width),
                                  y: height - CGFloat(min(1, Double(strike.velocity) / 127)) * height)
                }

                VStack {
                    Spacer()
                    HStack {
                        Text("soft / slow").font(.system(size: 9)).foregroundStyle(.tertiary)
                        Spacer()
                        Text("strike speed →  \(String(format: "%.0f", maxSpeed)) travel/s")
                            .font(.system(size: 9)).foregroundStyle(.tertiary)
                    }
                }
                .padding(6)
                VStack(alignment: .leading) {
                    Text("127").font(.system(size: 9)).foregroundStyle(.tertiary)
                    Spacer()
                    Text("1").font(.system(size: 9)).foregroundStyle(.tertiary)
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 4)
            }
        }
    }
}
