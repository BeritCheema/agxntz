import SwiftUI

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

/// Menu-bar content: one colored dot + count per non-empty state. Nothing else.
struct CounterView: View {
    @ObservedObject var store: SessionStore

    var body: some View {
        HStack(spacing: 10) {
            ForEach([SessionState.working, .waiting, .done], id: \.rawValue) { state in
                let count = store.unpinnedCount(of: state)
                if count > 0 {
                    HStack(spacing: 4) {
                        Circle().fill(state.color).frame(width: 8, height: 8)
                        Text("\(count)")
                            .font(.system(size: 12, weight: .semibold))
                            .monospacedDigit()
                    }
                }
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 22)
        .fixedSize()
    }
}

/// Menu-bar content for a pinned session: dot + live activity only.
struct PinnedItemView: View {
    let session: AgentSession

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
                    Text(session.activity)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: 140)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 22)
        .fixedSize()
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

    var body: some View {
        // cmux-style row: header line with identity + time + pin, then the
        // live status, then the agent's latest message text.
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

                Spacer(minLength: 8)

                Text(session.state == .done ? AgentSession.shortDuration(-session.lastActivityAt.timeIntervalSinceNow) + " ago" : session.elapsedText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                Button {
                    store.togglePin(session.id)
                } label: {
                    Image(systemName: store.isPinned(session.id) ? "pin.fill" : "pin")
                        .font(.system(size: 11))
                        .foregroundStyle(store.isPinned(session.id) ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .help(store.isPinned(session.id) ? "Unpin from menu bar" : "Pin to menu bar")
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
