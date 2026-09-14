import AppKit

/// Renders aggregate menu-bar elements as NSImages. Using `button.image`
/// (rather than a hosted subview) makes the system position the content
/// exactly like every other menu-bar icon — perfectly centered in the bar.
enum MenuBarImage {
    private static let dot: CGFloat = 6
    private static let big: CGFloat = 10
    private static let s: CGFloat = 9   // center spacing, matches DotClusterView

    static func aggregate(_ element: AggregateElement) -> NSImage {
        switch element {
        case .dots(let states): return dots(states)
        case .number(let state, let count): return number(state: state, count: count)
        }
    }

    private static func dots(_ states: [SessionState]) -> NSImage {
        let positions = DotClusterView.positions(states.count)
        let dia = states.count == 1 ? big : dot
        let minX = positions.map(\.0).min() ?? 0
        let minY = positions.map(\.1).min() ?? 0
        let width = (positions.map(\.0).max() ?? 0) - minX + dia
        let height = (positions.map(\.1).max() ?? 0) - minY + dia

        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        for (i, p) in positions.enumerated() where i < states.count {
            states[i].nsColor.setFill()
            let x = p.0 - minX
            // NSImage is bottom-left origin; flip the y from the top-left model.
            let y = height - (p.1 - minY) - dia
            NSBezierPath(ovalIn: NSRect(x: x, y: y, width: dia, height: dia)).fill()
        }
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    private static func number(state: SessionState, count: Int) -> NSImage {
        let dia: CGFloat = 8
        let gap: CGFloat = 4
        let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let text = "\(count)" as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
        let textSize = text.size(withAttributes: attrs)
        let height = max(dia, ceil(textSize.height))
        let width = dia + gap + ceil(textSize.width)

        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        state.nsColor.setFill()
        NSBezierPath(ovalIn: NSRect(x: 0, y: (height - dia) / 2, width: dia, height: dia)).fill()
        text.draw(at: NSPoint(x: dia + gap, y: (height - textSize.height) / 2), withAttributes: attrs)
        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}
