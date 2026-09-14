import SwiftUI
import AppKit

extension SessionState {
    var color: Color {
        switch self {
        case .working: return Color(nsColor: .systemGreen)
        case .waiting: return Color(nsColor: .systemOrange)
        case .done: return Color(nsColor: .systemBlue)
        }
    }

    var groupTitle: String {
        switch self {
        case .working: return "WORKING"
        case .waiting: return "WAITING"
        case .done: return "DONE"
        }
    }
}

/// One agent per dot, colored by state, laid out as a compact pyramid:
/// 1 (bigger) · 2 stacked · 3 = stack + centered right apex · 4 square ·
/// 5 = square + centered right apex · 6 = two rows of three. Spacing is
/// uniform across all counts.
struct DotClusterView: View {
    let colors: [Color]          // ordered, 1...6

    private let dot: CGFloat = 6
    private let big: CGFloat = 10
    private static let s: CGFloat = 9   // center spacing (dot + gap)

    var body: some View {
        let positions = Self.positions(colors.count)
        let dia = colors.count == 1 ? big : dot
        let minX = positions.map(\.0).min() ?? 0
        let minY = positions.map(\.1).min() ?? 0
        let width = (positions.map(\.0).max() ?? 0) - minX + dia
        let height = (positions.map(\.1).max() ?? 0) - minY + dia

        ZStack(alignment: .topLeading) {
            ForEach(Array(positions.enumerated()), id: \.offset) { i, p in
                Circle()
                    .fill(i < colors.count ? colors[i] : .clear)
                    .frame(width: dia, height: dia)
                    .offset(x: p.0 - minX, y: p.1 - minY)
            }
        }
        .frame(width: width, height: height)
    }

    /// Top-left dot origins (points) for each count. Odd counts add a
    /// vertically-centered apex one unit to the right of the base.
    static func positions(_ n: Int) -> [(CGFloat, CGFloat)] {
        switch n {
        case 1:  return [(0, 0)]
        case 2:  return [(0, 0), (0, s)]
        case 3:  return [(0, 0), (0, s), (s, s / 2)]
        case 4:  return [(0, 0), (s, 0), (0, s), (s, s)]
        case 5:  return [(0, 0), (s, 0), (0, s), (s, s), (2 * s, s / 2)]
        default: return [(0, 0), (s, 0), (2 * s, 0), (0, s), (s, s), (2 * s, s)]
        }
    }
}

/// A single aggregate menu-bar element: a dot cluster, or a "● N" count for a
/// state with more than 6 agents.
struct AggregateElementView: View {
    let element: AggregateElement

    var body: some View {
        Group {
            switch element {
            case .dots(let states):
                DotClusterView(colors: states.map(\.color))
            case .number(let state, let count):
                HStack(spacing: 4) {
                    Circle().fill(state.color).frame(width: 8, height: 8)
                    Text("\(count)")
                        .font(.system(size: 12, weight: .semibold))
                        .monospacedDigit()
                }
            }
        }
        .padding(.horizontal, 7)
        .frame(maxHeight: .infinity)                       // fill the button height…
        .fixedSize(horizontal: true, vertical: false)     // …and center; hug width
    }
}

/// Menu-bar content for a pinned session: state dot + a scrolling ticker of
/// exactly what the agent is doing right now (its activity, plus its latest
/// message for context) — like a news headline scan.
struct PinnedItemView: View {
    let session: AgentSession
    private let tickerWidth: CGFloat = 150

    private var scanText: String {
        if let message = session.lastMessage, !message.isEmpty, message != session.activity {
            return "\(session.activity) — \(message)"
        }
        return session.activity
    }

    var body: some View {
        Group {
            if session.state == .done {
                // Finished: a single glyph, no text.
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(session.state.color)
            } else {
                HStack(spacing: 5) {
                    Circle().fill(session.state.color).frame(width: 8, height: 8)
                    MarqueeText(text: scanText, width: tickerWidth)
                }
            }
        }
        .padding(.horizontal, 6)
        .frame(maxHeight: .infinity)
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// Horizontally scrolling single-line text (a marquee/ticker). Scrolls only
/// when the text is wider than `width`; otherwise it sits static.
///
/// The scroll position is a pure function of wall-clock time, and the text
/// width is measured synchronously — no `@State`. That way rebuilding this
/// view (which the menu-bar item does whenever data is polled) can never
/// briefly reset the ticker to the base position; identical text keeps
/// scrolling seamlessly across rebuilds.
struct MarqueeText: View {
    let text: String
    let width: CGFloat
    var fontSize: CGFloat = 12
    var speed: Double = 30          // points per second
    private let gap: CGFloat = 40   // space between the repeated copies

    private var textWidth: CGFloat {
        let nsFont = NSFont.systemFont(ofSize: fontSize)
        return ceil((text as NSString).size(withAttributes: [.font: nsFont]).width)
    }

    var body: some View {
        let font = Font.system(size: fontSize)
        let tw = textWidth
        if tw <= width + 0.5 {
            Text(text).font(font).lineLimit(1)
                .frame(width: width, height: 22, alignment: .leading)
        } else {
            let period = Double(tw + gap)
            TimelineView(.animation(minimumInterval: 0.04)) { timeline in
                let elapsed = timeline.date.timeIntervalSinceReferenceDate
                let x = -CGFloat((elapsed * speed).truncatingRemainder(dividingBy: period))
                HStack(spacing: gap) {
                    Text(text).font(font).fixedSize()
                    Text(text).font(font).fixedSize()
                }
                .offset(x: x)
                .frame(width: width, height: 22, alignment: .leading)
                .clipped()
            }
        }
    }
}

/// The dropdown: straight into Working / Waiting / Done groups, empty groups omitted.
struct DropdownView: View {
    @ObservedObject var store: SessionStore

    var body: some View {
        let groups = [SessionState.working, .waiting, .done]
            .map { ($0, store.sessions(in: $0)) }
            .filter { !$0.1.isEmpty }

        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(groups.enumerated()), id: \.element.0.rawValue) { index, group in
                    if index > 0 { Divider().padding(.vertical, 4) }
                    Text("\(group.0.groupTitle) (\(group.1.count))")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.top, index == 0 ? 12 : 4)
                        .padding(.bottom, 2)
                    ForEach(group.1) { session in
                        SessionRow(session: session, store: store)
                    }
                }
            }
            .padding(.bottom, 10)
        }
        .frame(width: 360)
        .frame(maxHeight: 520)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct SessionRow: View {
    let session: AgentSession
    @ObservedObject var store: SessionStore
    @State private var hovering = false
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            mainRow
            if expanded {
                ForEach(session.subAgents) { sub in
                    SubAgentRow(session: sub, store: store)
                }
            }
        }
    }

    // cmux-style row: header line with identity + sub-agents + time + pin,
    // then the live status, then the agent's latest message text.
    private var mainRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Circle()
                    .fill(session.state.color)
                    .frame(width: 9, height: 9)
                    .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 3 }

                Text(session.projectName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)

                Text(session.kind.rawValue)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                // One dot per sub-agent, tinted by its state. Tapping toggles
                // the nested list below.
                if !session.subAgents.isEmpty {
                    Button {
                        expanded.toggle()
                    } label: {
                        HStack(spacing: 3) {
                            ForEach(session.subAgents) { sub in
                                Circle().fill(sub.state.color).frame(width: 6, height: 6)
                            }
                            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                    .help("\(session.subAgents.count) sub-agent\(session.subAgents.count == 1 ? "" : "s")")
                }

                Spacer(minLength: 8)

                Text(session.state == .done ? AgentSession.shortDuration(-session.lastActivityAt.timeIntervalSinceNow) + " ago" : session.elapsedText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                PinButton(id: session.id, store: store)
            }

            Text(session.state == .done ? "finished" : session.activity)
                .font(.system(size: 12))
                .foregroundStyle(session.state == .done ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.leading, 15)

            if let message = session.lastMessage {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .padding(.leading, 15)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(hovering ? Color.primary.opacity(0.05) : Color.clear)
        .onHover { hovering = $0 }
    }
}

/// A sub-agent, rendered indented beneath its parent session.
struct SubAgentRow: View {
    let session: AgentSession
    @ObservedObject var store: SessionStore
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle()
                .fill(session.state.color)
                .frame(width: 7, height: 7)
                .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 3 }

            VStack(alignment: .leading, spacing: 1) {
                Text(session.projectName)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text(session.state == .done ? "finished" : session.activity)
                    .font(.system(size: 11))
                    .foregroundStyle(session.state == .done ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 8)

            Text(session.state == .done ? AgentSession.shortDuration(-session.lastActivityAt.timeIntervalSinceNow) + " ago" : session.elapsedText)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .monospacedDigit()

            PinButton(id: session.id, store: store)
        }
        .padding(.leading, 34)
        .padding(.trailing, 14)
        .padding(.vertical, 4)
        .background(hovering ? Color.primary.opacity(0.05) : Color.clear)
        .onHover { hovering = $0 }
    }
}

struct PinButton: View {
    let id: String
    @ObservedObject var store: SessionStore

    var body: some View {
        Button {
            store.togglePin(id)
        } label: {
            Image(systemName: store.isPinned(id) ? "pin.fill" : "pin")
                .font(.system(size: 11))
                .foregroundStyle(store.isPinned(id) ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
        .help(store.isPinned(id) ? "Unpin from menu bar" : "Pin to menu bar")
    }
}
