// MappingView.swift — assign a MIDI action to every physical key.

import SwiftUI

struct MappingView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var selectedKey: Int?

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Card(title: "Presets", systemImage: "square.stack.3d.up") {
                        HStack(spacing: 8) {
                            ForEach(PresetKind.allCases) { kind in
                                Button(kind.title) { model.applyPreset(kind) }
                                    .buttonStyle(.bordered)
                            }
                            Spacer()
                            Button("Export…") { exportConfig() }
                            Button("Import…") { importConfig() }
                        }
                    }
                    Card(title: "Keyboard", systemImage: "keyboard") {
                        KeyboardGrid(selection: $selectedKey, showTravel: true, showLabels: true)
                        Text("Click a key to edit it.  Travel is shown live as you play.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(20)
            }
            .frame(minWidth: 520, maxWidth: .infinity)

            Divider()

            ScrollView {
                if let index = selectedKey {
                    KeyInspector(index: index)
                        .padding(20)
                } else {
                    Text("Select a key")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(40)
                }
            }
            .frame(minWidth: 300, idealWidth: 340, maxWidth: 380)
        }
    }

    private func exportConfig() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "MagMIDI-config.json"
        panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url { model.exportConfiguration(to: url) }
    }

    private func importConfig() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { model.importConfiguration(from: url) }
    }
}

struct KeyInspector: View {
    @EnvironmentObject private var model: AppModel
    let index: Int

    private var action: KeyAction { model.action(for: index) }
    private var isLearning: Bool { model.learnTarget == index }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Card(title: "Key", systemImage: "keyboard") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(KeyLayout.label(at: index))
                            .font(.system(size: 20, weight: .semibold))
                        Text("row \(index / MAD60.columns) · column \(index % MAD60.columns) · index \(index)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                TravelMeter(value: model.telemetry[index].travel, actuation: model.configuration.actuation)
                HStack {
                    Text(String(format: "%.0f%% travel", model.telemetry[index].travel * 100))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("velocity \(model.telemetry[index].velocity)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            Card(title: "MIDI action", systemImage: "music.note") {
                Picker("", selection: Binding(
                    get: { action.kind },
                    set: { newValue in
                        var updated = action
                        updated.kind = newValue
                        if newValue == .cc || newValue == .pitchBend { updated.continuous = newValue == .cc }
                        if newValue == .none { model.clearMapping(at: index); return }
                        if newValue == .note, updated.number < 21 || updated.number > 108 { updated.number = 60 }
                        model.setAction(updated, for: index)
                    }
                )) {
                    ForEach(ActionKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()

                if action.kind == .note || action.kind == .cc || action.kind == .program {
                    Divider()
                    HStack {
                        Text(action.kind == .note ? "Note" : (action.kind == .cc ? "Controller" : "Program"))
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                        Text(action.kind == .note ? KeyAction.noteName(action.number) : "\(action.number)")
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    }
                    Slider(value: Binding(
                        get: { Double(action.number) },
                        set: { newValue in
                            var updated = action
                            updated.number = Int(newValue.rounded())
                            model.setAction(updated, for: index)
                        }
                    ), in: 0...127, step: 1)
                    HStack {
                        Button("−") { nudge(-1) }
                        Button("+") { nudge(1) }
                        Button("−12") { nudge(-12) }
                        Button("+12") { nudge(12) }
                        Spacer()
                        Button(isLearning ? "Listening…" : "MIDI Learn") {
                            model.learnTarget = isLearning ? nil : index
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(action.kind != .note && action.kind != .cc)
                    }
                }

                if action.kind == .cc {
                    Toggle("Continuous (follows key travel)", isOn: Binding(
                        get: { action.continuous },
                        set: { newValue in
                            var updated = action
                            updated.continuous = newValue
                            model.setAction(updated, for: index)
                        }
                    ))
                    .font(.system(size: 12))
                }

                Divider()
                HStack {
                    Text("Channel").font(.system(size: 12, weight: .medium))
                    Spacer()
                    Picker("", selection: Binding(
                        get: { action.channel },
                        set: { newValue in
                            var updated = action
                            updated.channel = newValue
                            model.setAction(updated, for: index)
                        }
                    )) {
                        ForEach(1...16, id: \.self) { Text("\($0)").tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 80)
                }

                Button(role: .destructive) {
                    model.clearMapping(at: index)
                } label: {
                    Label("Clear assignment", systemImage: "trash")
                }
                .buttonStyle(.borderless)
                .font(.system(size: 12))
            }

            if isLearning {
                Text("Play a note on the MAD60 with another mapping, or from any MIDI app, to set this key's note.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func nudge(_ delta: Int) {
        var updated = action
        updated.number = max(0, min(127, updated.number + delta))
        model.setAction(updated, for: index)
    }
}
