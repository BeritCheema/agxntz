import SwiftUI

/// The Settings window: a sidebar (Dashboard / Appearance / Behavior / Agents)
/// with a detail panel, styled after the lazyagent reference.
struct SettingsView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var settings = AppSettings.shared
    @State private var page: Page = .dashboard

    enum Page: String, CaseIterable, Identifiable {
        case dashboard = "Dashboard"
        case appearance = "Appearance"
        case behavior = "Behavior"
        case agents = "Agents"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .dashboard: return "square.grid.2x2"
            case .appearance: return "paintbrush"
            case .behavior: return "slider.horizontal.3"
            case .agents: return "cpu"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(Page.allCases, selection: $page) { p in
                Label(p.rawValue, systemImage: p.icon).tag(p)
            }
            .navigationSplitViewColumnWidth(180)
        } detail: {
            ScrollView {
                Group {
                    switch page {
                    case .dashboard: DashboardPage(store: store, settings: settings)
                    case .appearance: AppearancePage(settings: settings)
                    case .behavior: BehaviorPage(settings: settings)
                    case .agents: AgentsPage(store: store, settings: settings)
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(page.rawValue)
        }
        .frame(minWidth: 680, minHeight: 460)
    }
}

// MARK: - Dashboard

private struct DashboardPage: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Live overview
            Card(title: "Live overview") {
                HStack(spacing: 24) {
                    ForEach([SessionState.working, .waiting, .done], id: \.rawValue) { state in
                        StatTile(color: state.color, label: state.groupTitle.capitalized,
                                 value: store.sessions(in: state).count)
                    }
                    StatTile(color: .secondary, label: "Total", value: store.sessions.count)
                }
            }

            // Per-agent list
            Card(title: "Agents") {
                VStack(spacing: 0) {
                    ForEach(AgentKind.allCases, id: \.rawValue) { kind in
                        let count = store.sessions.filter { $0.kind == kind }.count
                        HStack {
                            Circle()
                                .fill(count > 0 ? Color.green : Color.secondary.opacity(0.4))
                                .frame(width: 7, height: 7)
                            Text(kind.rawValue).font(.system(size: 13))
                            Spacer()
                            if !settings.isEnabled(kind) {
                                Text("disabled").font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            Text("\(count)")
                                .font(.system(size: 13, weight: .medium))
                                .monospacedDigit()
                                .foregroundStyle(count > 0 ? .primary : .secondary)
                        }
                        .padding(.vertical, 6)
                        if kind != AgentKind.allCases.last { Divider() }
                    }
                }
            }

            // Pinned sessions
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
}

// MARK: - Appearance

private struct AppearancePage: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Card(title: "Pinned ticker") {
                SliderRow(label: "Scroll speed", value: $settings.tickerSpeed,
                          range: 10...80, unit: "pt/s", format: "%.0f")
                Divider().padding(.vertical, 4)
                SliderRow(label: "Text size", value: $settings.tickerFontSize,
                          range: 9...16, unit: "pt", format: "%.0f")
            }
            Card(title: "Menu-bar dots") {
                Stepper(value: $settings.maxDots, in: 1...6) {
                    HStack {
                        Text("Dots before splitting").font(.system(size: 13))
                        Spacer()
                        Text("\(settings.maxDots)").font(.system(size: 13, weight: .medium)).monospacedDigit()
                    }
                }
                Text("Up to this many agent dots share one menu-bar element; beyond it the largest group splits off.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 4)
            }
        }
    }
}

// MARK: - Behavior

private struct BehaviorPage: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Card(title: "Retention") {
                SliderRow(label: "Keep finished sessions", value: $settings.doneRetentionMinutes,
                          range: 1...60, unit: "min", format: "%.0f")
                Divider().padding(.vertical, 4)
                SliderRow(label: "Keep killed sessions", value: $settings.killedRetentionMinutes,
                          range: 0.5...10, unit: "min", format: "%.1f")
            }
            Card(title: "Polling") {
                SliderRow(label: "Rescan interval", value: $settings.pollInterval,
                          range: 0.5...5, unit: "s", format: "%.1f")
                Text("How often agxntz rescans for agent activity. Lower is snappier; higher uses less CPU.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 4)
            }
        }
    }
}

// MARK: - Agents

private struct AgentsPage: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var settings: AppSettings

    var body: some View {
        Card(title: "Monitored agents") {
            VStack(spacing: 0) {
                ForEach(AgentKind.allCases, id: \.rawValue) { kind in
                    let count = store.sessions.filter { $0.kind == kind }.count
                    HStack {
                        Toggle(isOn: Binding(
                            get: { settings.isEnabled(kind) },
                            set: { settings.setEnabled(kind, $0) }
                        )) {
                            Text(kind.rawValue).font(.system(size: 13))
                        }
                        .toggleStyle(.switch)
                        Spacer()
                        Text(count > 0 ? "\(count) active" : "—")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                    if kind != AgentKind.allCases.last { Divider() }
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
                .background(Color.primary.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }
}

private struct StatTile: View {
    let color: Color
    let label: String
    let value: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Text("\(value)").font(.system(size: 26, weight: .semibold)).monospacedDigit()
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
            Slider(value: $value, in: range).frame(width: 220)
            Text("\(String(format: format, value)) \(unit)")
                .font(.system(size: 12)).monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .trailing)
        }
    }
}
