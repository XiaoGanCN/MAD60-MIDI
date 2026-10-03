// ContentView.swift — the main window.

import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable {
    case dashboard, mapping, travel, calibration, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .dashboard: return "Overview"
        case .mapping: return "Mapping"
        case .travel: return "Travel & Velocity"
        case .calibration: return "Calibration"
        case .settings: return "Settings"
        }
    }
    var symbol: String {
        switch self {
        case .dashboard: return "pianokeys"
        case .mapping: return "arrow.left.arrow.right.square"
        case .travel: return "waveform.path.ecg"
        case .calibration: return "slider.horizontal.below.rectangle"
        case .settings: return "gearshape"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selection: SidebarItem = .dashboard
    @State private var selectedKey: Int? = 29

    var body: some View {
        NavigationSplitView {
            // A plain List would let macOS type-select jump between rows while
            // you are playing the keyboard, so the sidebar is built by hand.
            VStack(alignment: .leading, spacing: 2) {
                ForEach(SidebarItem.allCases) { item in
                    Button {
                        selection = item
                    } label: {
                        HStack(spacing: 9) {
                            Image(systemName: item.symbol)
                                .font(.system(size: 12, weight: .medium))
                                .frame(width: 18)
                            Text(item.title)
                                .font(.system(size: 13, weight: selection == item ? .semibold : .regular))
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 7)
                        .padding(.horizontal, 9)
                        .contentShape(Rectangle())
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(selection == item ? Color.accentColor.opacity(0.14) : Color.clear)
                        )
                        .foregroundStyle(selection == item ? Color.accentColor : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 12)
                Divider()
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(model.status.isConnected ? Color.green : Color.orange)
                            .frame(width: 7, height: 7)
                        Text(model.status.isConnected ? "MAD60 connected" : "Searching…")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    HStack(spacing: 6) {
                        Image(systemName: model.captureState.isCapturing ? "lock.fill" : "keyboard")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                        Text(model.captureState.isCapturing ? "Keys play MIDI only" : "Keys also type")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 4)
            }
            .padding(10)
            .frame(maxHeight: .infinity, alignment: .top)
            .navigationSplitViewColumnWidth(min: 200, ideal: 215, max: 260)
        } detail: {
            Group {
                switch selection {
                case .dashboard: DashboardView(selectedKey: $selectedKey)
                case .mapping: MappingView(selectedKey: $selectedKey)
                case .travel: TravelView()
                case .calibration: CalibrationView()
                case .settings: SettingsView()
                }
            }
            .navigationTitle(selection.title)
        }
        .toolbar {
            ToolbarItemGroup {
                if model.engineRunning {
                    StatusPill(text: "MIDI \(model.soundingNotes) notes", color: .accentColor, symbol: "music.note")
                } else {
                    StatusPill(text: "MIDI stopped", color: .orange, symbol: "pause.circle")
                }
                Button {
                    model.panic()
                } label: {
                    Label("All Notes Off", systemImage: "exclamationmark.octagon")
                }
                .help("Send All Notes Off on every channel (⌘.)")
                Button {
                    model.engineRunning ? model.stopMIDI() : model.startMIDI()
                } label: {
                    Label(model.engineRunning ? "Stop" : "Start", systemImage: model.engineRunning ? "stop.circle" : "play.circle")
                }
                .help("Toggle MIDI output (⇧⌘R)")
            }
        }
    }
}

// MARK: - Dashboard

struct DashboardView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var selectedKey: Int?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Card(title: "Device", systemImage: "keyboard") {
                    HStack(alignment: .top, spacing: 24) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(MAD60.productName)
                                .font(.system(size: 17, weight: .semibold))
                            Text("VID 0x\(String(MAD60.vendorID, radix: 16).uppercased()) · PID 0x\(String(MAD60.productID, radix: 16).uppercased()) · raw HID 0xFF60/0x61")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Text(model.activity)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 6) {
                            StatusPill(
                                text: model.status.isConnected ? "Connected" : "Not found",
                                color: model.status.isConnected ? .green : .orange,
                                symbol: model.status.isConnected ? "checkmark.circle" : "magnifyingglass"
                            )
                            Text("≈250 scans / second")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                Card(title: "Keys", systemImage: "pianokeys") {
                    HStack(spacing: 10) {
                        Text("Last note")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        if let last = model.lastNote {
                            Text(KeyLayout.label(at: last.key))
                                .font(.system(size: 12, weight: .semibold))
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                            Text(KeyAction.noteName(last.note))
                                .font(.system(size: 15, weight: .bold, design: .rounded))
                            Text("velocity \(last.velocity)")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.secondary)
                        } else {
                            Text("play a key…")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Text("Sampled ~250×/s · travel, then velocity")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    KeyboardGrid(selection: $selectedKey, showTravel: true, showLabels: true)
                    if let index = selectedKey {
                        Divider().padding(.vertical, 2)
                        HStack(spacing: 16) {
                            Text(KeyLayout.label(at: index))
                                .font(.system(size: 15, weight: .semibold))
                            Text("row \(index / MAD60.columns) · column \(index % MAD60.columns)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(model.action(for: index).display)
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Text(String(format: "travel %.0f%%", model.telemetry[index].travel * 100))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Text("vel \(model.telemetry[index].velocity)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Card(title: "Keyboard capture", systemImage: model.captureState.isCapturing ? "lock.fill" : "lock.open") {
                    HStack(alignment: .top, spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            Toggle("Play MIDI only — stop the MAD60 from typing", isOn: Binding(
                                get: { model.configuration.silenceKeyboard },
                                set: { model.setSilenceKeyboard($0) }
                            ))
                            .toggleStyle(.switch)
                            Text(model.captureState.description)
                                .font(.system(size: 11))
                                .foregroundStyle(model.captureState.isCapturing ? Color.secondary : Color.orange)
                            Text("MagMIDI takes exclusive ownership of the keyboard collection that carries keystrokes, so notes you play never reach the focused app. The grab is released the moment you switch this off or quit MagMIDI. macOS asks for Input Monitoring the first time.")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        if model.captureState.isCapturing {
                            StatusPill(text: "Captured", color: .green, symbol: "checkmark.circle")
                        } else if model.captureState == .permissionNeeded {
                            VStack(alignment: .trailing, spacing: 6) {
                                Button("Open Input Monitoring…") { model.openInputMonitoringSettings() }
                                    .buttonStyle(.borderedProminent)
                                Text("Then quit and reopen MagMIDI")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Card(title: "Signal path", systemImage: "arrow.triangle.branch") {
                    HStack(spacing: 10) {
                        FlowNode(symbol: "keyboard", title: "MAD60", subtitle: "magnetic switches")
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        FlowNode(symbol: "waveform.path", title: "Travel engine", subtitle: "actuation · velocity")
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        FlowNode(symbol: "music.note.list", title: "Core MIDI", subtitle: model.configuration.sourceName)
                        Spacer()
                    }
                }
            }
            .padding(20)
        }
    }
}

struct FlowNode: View {
    let symbol: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 16))
                .foregroundStyle(Color.accentColor)
            Text(title).font(.system(size: 12, weight: .semibold))
            Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .frame(width: 132, height: 78)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
    }
}
