// SettingsView.swift

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var draftName: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Card(title: "MIDI output", systemImage: "music.note.list") {
                    HStack {
                        Text("Virtual source name").font(.system(size: 12, weight: .medium))
                        Spacer()
                        TextField("Name", text: $draftName)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 240)
                            .onSubmit {
                                var c = model.configuration
                                c.sourceName = draftName.isEmpty ? "MagMIDI" : draftName
                                model.configuration = c
                                model.restartMIDI()
                            }
                    }
                    LabeledSlider(
                        title: "Default channel",
                        value: Binding(
                            get: { Double(model.configuration.globalChannel) },
                            set: { var c = model.configuration; c.globalChannel = Int($0); model.configuration = c }
                        ),
                        range: 1...16,
                        format: { "Channel \(Int($0))" }
                    )
                    HStack {
                        StatusPill(text: model.engineRunning ? "Source active" : "Stopped",
                                   color: model.engineRunning ? .green : .orange,
                                   symbol: model.engineRunning ? "checkmark.circle" : "pause.circle")
                        Button("Restart MIDI") { model.restartMIDI() }
                        Spacer()
                    }
                    Text("Select “\(model.configuration.sourceName)” as the MIDI input in your DAW.  No driver or background service is involved — the source lives as long as MagMIDI is running.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Card(title: "Travel model", systemImage: "ruler") {
                    LabeledSlider(
                        title: "Fallback full travel",
                        value: Binding(
                            get: { model.configuration.defaultTravelSpan },
                            set: { var c = model.configuration; c.defaultTravelSpan = $0; model.configuration = c }
                        ),
                        range: 300...2000,
                        format: { "\(Int($0)) ADC counts" }
                    )
                    Text("Used for keys that have not been through a full-travel calibration. The MAD60 measures roughly 880–970 counts from rest to bottom.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Card(title: "Configuration file", systemImage: "doc") {
                    Text(model.configPath)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    HStack {
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: model.configPath)])
                        }
                        Button("Duplicate / Export…") {
                            let panel = NSSavePanel()
                            panel.nameFieldStringValue = "MagMIDI-config.json"
                            panel.allowedContentTypes = [.json]
                            if panel.runModal() == .OK, let url = panel.url { model.exportConfiguration(to: url) }
                        }
                        Spacer()
                    }
                }

                Card(title: "About", systemImage: "info.circle") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("MagMIDI").font(.system(size: 14, weight: .semibold))
                        Text("Turns a MADLION MAD60 magnetic-switch keyboard into a velocity-sensitive MIDI controller.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text("Reads live per-key ADC values straight from the keyboard's raw HID interface (usage page 0xFF60, usage 0x61) using the command the vendor's own web configurator uses (0x02 0x96 0x16).  A full 70-position scan takes about 4 ms, so travel is sampled roughly 250 times a second.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text("Apple silicon · macOS 14 or later · no kernel extension, no Input Monitoring, no Accessibility permission.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(20)
        }
        .onAppear { draftName = model.configuration.sourceName }
    }
}
