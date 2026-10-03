// TravelView.swift — how key travel becomes velocity and expression.

import SwiftUI

struct TravelView: View {
    @EnvironmentObject private var model: AppModel

    private var config: Configuration { model.configuration }

    /// Fastest strike seen in the most recent telemetry frame, for tuning.
    private var liveSpeed: Double {
        model.telemetry.map(\.speed).max() ?? 0
    }

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
                            range: 4...40,
                            format: { String(format: "%.1f travel/s", $0) }
                        )
                        Text("Lower this until your normal hard press reaches 127.  Right now your fastest strike is about \(String(format: "%.1f", liveSpeed)) /s.")
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

                    VelocityCurveView(config: config)
                        .frame(height: 110)
                        .padding(.top, 4)
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

/// Draws velocity against strike speed (or depth) using the current settings.
struct VelocityCurveView: View {
    let config: Configuration

    var body: some View {
        GeometryReader { geo in
            let steps = 120
            let points: [CGPoint] = (0...steps).map { step in
                let x = Double(step) / Double(steps)
                let velocity: Double
                if config.velocitySource == .fixed {
                    velocity = Double(config.fixedVelocity) / 127.0
                } else {
                    let scaled = min(1.0, x * config.velocitySensitivity)
                    velocity = pow(scaled, max(0.2, config.velocityCurve))
                }
                return CGPoint(x: x * geo.size.width,
                               y: geo.size.height - velocity * geo.size.height)
            }
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
                Path { path in
                    path.move(to: CGPoint(x: 0, y: geo.size.height))
                    for point in points { path.addLine(to: point) }
                    path.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height))
                    path.closeSubpath()
                }
                .fill(Color.accentColor.opacity(0.15))
                Path { path in
                    path.move(to: points[0])
                    for point in points.dropFirst() { path.addLine(to: point) }
                }
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .background(
                    VStack {
                        Spacer()
                        HStack { Text("slow").font(.system(size: 9)).foregroundStyle(.tertiary); Spacer(); Text("fast").font(.system(size: 9)).foregroundStyle(.tertiary) }
                    }.padding(6)
                )
            }
        }
    }
}
