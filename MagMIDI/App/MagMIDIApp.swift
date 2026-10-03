// MagMIDIApp.swift

import SwiftUI

@main
struct MagMIDIApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 1120, minHeight: 700)
        }
        .defaultSize(width: 1340, height: 880)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandMenu("Engine") {
                Button(model.engineRunning ? "Stop MIDI Output" : "Start MIDI Output") {
                    model.engineRunning ? model.stopMIDI() : model.startMIDI()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                Divider()
                Button("All Notes Off") { model.panic() }
                    .keyboardShortcut(".", modifiers: .command)
            }
            CommandMenu("Presets") {
                ForEach(PresetKind.allCases) { kind in
                    Button(kind.title) { model.applyPreset(kind) }
                }
            }
        }

        Settings {
            SettingsView()
                .environmentObject(model)
                .frame(width: 520)
        }
    }
}
