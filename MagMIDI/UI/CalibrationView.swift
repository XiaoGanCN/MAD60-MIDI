// CalibrationView.swift — teach MagMIDI where each key rests and bottoms out.

import SwiftUI

struct CalibrationView: View {
    @EnvironmentObject private var model: AppModel

    /// Single source of truth for the table geometry.  The header and the rows
    /// both use these, so the labels always sit over their data.
    private enum Column {
        static let key: CGFloat = 88
        static let matrix: CGFloat = 64
        static let rest: CGFloat = 62
        static let bottom: CGFloat = 62
        static let travel: CGFloat = 62
        static let meter: CGFloat = 120
        static let percent: CGFloat = 46
        static let raw: CGFloat = 58
    }

    private var calibratedCount: Int {
        model.configuration.calibration.values.filter { $0.rest - $0.bottom > 150 }.count
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Card(title: "Travel calibration", systemImage: "slider.horizontal.below.rectangle") {
                    Text("MagMIDI measures each key's resting ADC value on connect.  A full-travel pass teaches it the bottom of each key, which makes travel percentages and strike velocity accurate across the whole board — the same idea as the vendor's “axial alignment” page, but stored locally and used for playing rather than for setup. The pass has no time limit: start it, work across the keyboard, then press Finish.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                    HStack(spacing: 10) {
                        Button {
                            model.beginRestMeasurement()
                        } label: {
                            Label("Measure resting position", systemImage: "arrow.down.circle")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isMeasuringRest)

                        if model.isMeasuringRange {
                            Button {
                                model.finishRangeMeasurement()
                            } label: {
                                Label("Finish full-travel pass", systemImage: "checkmark.circle")
                            }
                            .buttonStyle(.borderedProminent)
                            Button(role: .cancel) {
                                model.cancelRangeMeasurement()
                            } label: {
                                Text("Cancel")
                            }
                        } else {
                            Button {
                                model.beginRangeMeasurement()
                            } label: {
                                Label("Measure full travel", systemImage: "arrow.down.to.line")
                            }
                            .disabled(model.isMeasuringRest)
                        }

                        Button(role: .destructive) {
                            model.resetCalibration()
                        } label: {
                            Label("Reset", systemImage: "arrow.counterclockwise")
                        }
                    }

                    if model.isMeasuringRange {
                        ProgressView(value: model.calibrationProgress)
                            .progressViewStyle(.linear)
                        Text("Press every key all the way down at your own pace — \(model.measuredKeyCount) of \(KeyLayout.positions.count) keys measured. Pressing Finish when you are done.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    } else if model.isMeasuringRest {
                        ProgressView().progressViewStyle(.linear)
                    }

                    HStack {
                        StatusPill(text: "\(calibratedCount) keys with full travel", color: calibratedCount > 55 ? .green : .orange, symbol: "ruler")
                        Text(model.activity)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }

                Card(title: "Per-key measurement", systemImage: "tablecells") {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 8) {
                            Text("Key").frame(width: Column.key, alignment: .leading)
                            Text("Matrix").frame(width: Column.matrix, alignment: .leading)
                            Text("Rest").frame(width: Column.rest, alignment: .trailing)
                            Text("Bottom").frame(width: Column.bottom, alignment: .trailing)
                            Text("Travel").frame(width: Column.travel, alignment: .trailing)
                            Text("Live").frame(width: Column.meter, alignment: .leading)
                            Text("%").frame(width: Column.percent, alignment: .trailing)
                            Text("Raw").frame(width: Column.raw, alignment: .trailing)
                            Spacer(minLength: 0)
                        }
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                        Divider()
                        ForEach(KeyLayout.positions) { position in
                            let cal = model.configuration.calibration[position.index]
                            let live = model.telemetry[position.index]
                            HStack(spacing: 8) {
                                Text(position.label)
                                    .frame(width: Column.key, alignment: .leading)
                                Text(position.matrixName)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .frame(width: Column.matrix, alignment: .leading)
                                Text(cal.map { String(format: "%.0f", $0.rest) } ?? "—")
                                    .font(.system(size: 11, design: .monospaced))
                                    .frame(width: Column.rest, alignment: .trailing)
                                Text(cal.map { String(format: "%.0f", $0.bottom) } ?? "—")
                                    .font(.system(size: 11, design: .monospaced))
                                    .frame(width: Column.bottom, alignment: .trailing)
                                Text(cal.map { String(format: "%.0f", $0.span) } ?? "—")
                                    .font(.system(size: 11, design: .monospaced))
                                    .frame(width: Column.travel, alignment: .trailing)
                                TravelMeter(value: live.travel,
                                            actuation: model.configuration.actuation,
                                            height: 6)
                                    .frame(width: Column.meter)
                                Text(String(format: "%.0f%%", live.travel * 100))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .frame(width: Column.percent, alignment: .trailing)
                                Text(live.raw > 0 ? "\(live.raw)" : "—")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .frame(width: Column.raw, alignment: .trailing)
                                Spacer(minLength: 0)
                            }
                            .font(.system(size: 12))
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
            .padding(20)
        }
    }
}
