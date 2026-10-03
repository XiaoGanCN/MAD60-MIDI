// CalibrationView.swift — teach MagMIDI where each key rests and bottoms out.

import SwiftUI

struct CalibrationView: View {
    @EnvironmentObject private var model: AppModel

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
                    VStack(spacing: 0) {
                        HStack {
                            Text("Key").frame(width: 76, alignment: .leading)
                            Text("Matrix").frame(width: 70, alignment: .leading)
                            Text("Rest").frame(width: 70, alignment: .trailing)
                            Text("Bottom").frame(width: 70, alignment: .trailing)
                            Text("Travel").frame(width: 70, alignment: .trailing)
                            Text("Now").frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                        Divider()
                        ForEach(KeyLayout.positions) { position in
                            let cal = model.configuration.calibration[position.index]
                            HStack {
                                Text(position.label).frame(width: 76, alignment: .leading)
                                Text(position.matrixName)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 70, alignment: .leading)
                                Text(cal.map { String(format: "%.0f", $0.rest) } ?? "—")
                                    .font(.system(size: 11, design: .monospaced))
                                    .frame(width: 70, alignment: .trailing)
                                Text(cal.map { String(format: "%.0f", $0.bottom) } ?? "—")
                                    .font(.system(size: 11, design: .monospaced))
                                    .frame(width: 70, alignment: .trailing)
                                Text(cal.map { String(format: "%.0f", $0.span) } ?? "—")
                                    .font(.system(size: 11, design: .monospaced))
                                    .frame(width: 70, alignment: .trailing)
                                TravelMeter(value: model.telemetry[position.index].travel, actuation: model.configuration.actuation, height: 6)
                                    .frame(width: 90)
                                Text(String(format: "%3.0f%%", model.telemetry[position.index].travel * 100))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 42, alignment: .trailing)
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
