// KeyboardGrid.swift
// The live 5x14 matrix view used across the app.

import SwiftUI

struct KeyboardGrid: View {
    @EnvironmentObject private var model: AppModel
    @Binding var selection: Int?
    var showTravel = true
    var showLabels = true

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: MAD60.columns)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 6) {
            ForEach(0..<MAD60.keyCount, id: \.self) { index in
                if KeyLayout.isPopulated(index) {
                    KeyCell(
                        index: index,
                        label: KeyLayout.label(at: index),
                        action: model.action(for: index),
                        telemetry: model.telemetry[index],
                        selected: selection == index,
                        showTravel: showTravel,
                        showLabels: showLabels
                    )
                    .onTapGesture { selection = index }
                } else {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(0.03))
                        .frame(height: 46)
                }
            }
        }
    }
}

struct KeyCell: View {
    let index: Int
    let label: String
    let action: KeyAction
    let telemetry: KeyTelemetry
    let selected: Bool
    let showTravel: Bool
    let showLabels: Bool

    private var fill: Color {
        guard showTravel else { return Color(nsColor: .controlBackgroundColor) }
        let intensity = min(1, telemetry.travel * 1.15)
        return Color.accentColor.opacity(0.08 + intensity * 0.72)
    }

    var body: some View {
        VStack(spacing: 1) {
            Text(label)
                .font(.system(size: label.count > 4 ? 8 : 10, weight: .medium, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .foregroundStyle(telemetry.travel > 0.45 ? Color.white : Color.primary)
            if showLabels {
                Text(action.display)
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .foregroundStyle(telemetry.travel > 0.45 ? Color.white.opacity(0.85) : Color.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 46)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(fill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.12),
                              lineWidth: selected ? 2 : 0.5)
        )
        .scaleEffect(telemetry.isDown ? 0.96 : 1.0)
        .animation(.interactiveSpring(response: 0.12, dampingFraction: 0.7), value: telemetry.isDown)
        .help("\(label) — \(KeyLayout.label(at: index)) • \(action.display)")
    }
}

/// A compact horizontal travel meter used in the dashboard.
struct TravelMeter: View {
    let value: Double
    let actuation: Double
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(LinearGradient(colors: [.accentColor.opacity(0.65), .accentColor],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(0, min(1, value)) * geo.size.width)
                Rectangle()
                    .fill(Color.primary.opacity(0.35))
                    .frame(width: 1)
                    .offset(x: max(0, min(1, actuation)) * geo.size.width)
            }
        }
        .frame(height: height)
    }
}

struct StatusPill: View {
    let text: String
    let color: Color
    let symbol: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
            Text(text)
                .font(.system(size: 11, weight: .semibold))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(color.opacity(0.15)))
        .foregroundStyle(color)
    }
}

struct Card<Content: View>: View {
    var title: String?
    var systemImage: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Label(title, systemImage: systemImage ?? "circle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .kerning(0.5)
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }
}
