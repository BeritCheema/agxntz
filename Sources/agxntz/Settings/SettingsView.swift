import SwiftUI

/// Accent used for interactive controls in Settings (slider tracks, toggle "on"
/// state) — a soft pastel lime.
let settingsAccent = Color(red: 206 / 255, green: 245 / 255, blue: 160 / 255)

/// The Settings window: a single scrolling page of cards — overview, appearance,
/// behavior, agents, and pinned sessions.
struct SettingsView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ticker
                dots
                colors
                retention
                polling
                agents
                pinned
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 520, height: 640)
    }

    // MARK: Sections

    private var ticker: some View {
        Card(title: "Pinned ticker") {
            SliderRow(label: "Scroll speed", value: $settings.tickerSpeed,
                      range: 10...80, unit: "pt/s", format: "%.0f")
            Divider().padding(.vertical, 4)
            SliderRow(label: "Text size", value: $settings.tickerFontSize,
                      range: 9...16, unit: "pt", format: "%.0f")
        }
    }

    private var dots: some View {
        Card(title: "Menu-bar dots") {
            Stepper(value: $settings.maxDots, in: 1...99) {
                HStack {
                    Text("Dots before splitting").font(.system(size: 13))
                    Spacer()
                    Text("\(settings.maxDots)").font(.system(size: 13, weight: .medium)).monospacedDigit()
                        .textSelection(.enabled)
                }
            }
            Text("Up to this many agent dots share one menu-bar element; beyond it the largest group splits off.")
                .font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 4)
        }
    }

    private var colors: some View {
        Card(title: "State colors") {
            ColorRow(label: "Working", hex: $settings.workingColorHex, fallback: Palette.defaultWorking)
            Divider().padding(.vertical, 4)
            ColorRow(label: "Waiting", hex: $settings.waitingColorHex, fallback: Palette.defaultWaiting)
            Divider().padding(.vertical, 4)
            ColorRow(label: "Done", hex: $settings.doneColorHex, fallback: Palette.defaultDone)
            HStack {
                Text("Used for the menu-bar dots, pinned items, and dropdown.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("Reset") { settings.resetStateColors() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 12))
                    .disabled(settings.workingColorHex == nil
                              && settings.waitingColorHex == nil
                              && settings.doneColorHex == nil)
            }
            .padding(.top, 6)
        }
    }

    private var retention: some View {
        Card(title: "Retention") {
            SliderRow(label: "Keep finished sessions", value: $settings.doneRetentionMinutes,
                      range: 1...60, unit: "min", format: "%.0f")
            Divider().padding(.vertical, 4)
            SliderRow(label: "Keep killed sessions", value: $settings.killedRetentionMinutes,
                      range: 0.5...10, unit: "min", format: "%.1f")
        }
    }

    private var polling: some View {
        Card(title: "Polling") {
            SliderRow(label: "Rescan interval", value: $settings.pollInterval,
                      range: 0.5...5, unit: "s", format: "%.1f")
            Text("How often agxntz rescans for agent activity. Lower is snappier; higher uses less CPU.")
                .font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 4)
        }
    }

    private var agents: some View {
        Card(title: "Agents") {
            VStack(spacing: 0) {
                ForEach(AgentKind.allCases, id: \.rawValue) { kind in
                    let count = store.sessions.filter { $0.kind == kind }.count
                    HStack(spacing: 10) {
                        Text(kind.rawValue).font(.system(size: 13))
                        Spacer(minLength: 8)
                        Text(count > 0 ? "\(count) active" : "—")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Toggle("", isOn: Binding(
                            get: { settings.isEnabled(kind) },
                            set: { settings.setEnabled(kind, $0) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .tint(settingsAccent)
                    }
                    .padding(.vertical, 7)
                    if kind != AgentKind.allCases.last { Divider() }
                }
            }
        }
    }

    private var pinned: some View {
        Card(title: "Pinned sessions") {
            if store.pinnedSessions.isEmpty {
                Text("Nothing pinned. Use the pin icon on a session in the dropdown.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(store.pinnedSessions) { s in
                        HStack {
                            Circle().fill(s.state.color).frame(width: 8, height: 8)
                            Text(s.projectName).font(.system(size: 13, weight: .medium))
                            Text(s.kind.rawValue).font(.system(size: 11)).foregroundStyle(.secondary)
                            Spacer()
                            Button("Unpin") { store.togglePin(s.id) }
                                .buttonStyle(.borderless)
                                .font(.system(size: 12))
                        }
                        .padding(.vertical, 6)
                        if s.id != store.pinnedSessions.last?.id { Divider() }
                    }
                }
            }
        }
    }
}

// MARK: - Reusable bits

private struct Card<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) { content }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }
}

/// A state-color row: label, the current hex (selectable), and a picker.
/// Stores "#RRGGBB"; a nil value shows the system default for that state.
private struct ColorRow: View {
    let label: String
    @Binding var hex: String?
    let fallback: NSColor

    private var current: NSColor { hex.flatMap(NSColor.init(hex:)) ?? fallback }

    var body: some View {
        HStack(spacing: 10) {
            Text(label).font(.system(size: 13))
            Spacer()
            Text(hex ?? "Default")
                .font(.system(size: 12)).monospacedDigit()
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            ColorPicker("", selection: Binding(
                get: { Color(nsColor: current) },
                set: { hex = NSColor($0).hexString }
            ), supportsOpacity: false)
            .labelsHidden()
        }
    }
}

private struct SliderRow: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let unit: String
    let format: String
    var body: some View {
        HStack {
            Text(label).font(.system(size: 13))
            Spacer()
            Slider(value: $value, in: range).frame(width: 200).tint(settingsAccent)
            Text("\(String(format: format, value)) \(unit)")
                .font(.system(size: 12)).monospacedDigit()
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(width: 60, alignment: .trailing)
        }
    }
}
