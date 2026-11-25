import AppKit

/// The Daylanes logo as a menu bar template image, so macOS tints it for light and dark menu bars.
/// The pills are the app icon's "lanes" layer (assets/icon/MenuBarIcon.svg), drawn in code so the
/// icon stays sharp at any scale without bundling an image.
enum MenuBarIcon {
    enum Style {
        /// Tracking now.
        case active
        /// Tracking is on but nothing is being recorded (idle, away or paused).
        case dimmed
        /// Snoozed: pills drawn as outlines.
        case outlined
    }

    /// Pill frames in the 1024-unit space of `lanes.svg`.
    private static let pills: [CGRect] = [
        CGRect(x: 165.95, y: 166.04, width: 197.23, height: 224.90),
        CGRect(x: 165.95, y: 474.56, width: 197.23, height: 380.10),
        CGRect(x: 413.39, y: 201.24, width: 197.23, height: 301.19),
        CGRect(x: 413.39, y: 561.59, width: 197.23, height: 261.45),
        CGRect(x: 660.82, y: 165.95, width: 197.23, height: 266.65),
        CGRect(x: 660.82, y: 495.77, width: 197.23, height: 358.99),
    ]

    private static let active = make(.active)
    private static let dimmed = make(.dimmed)
    private static let outlined = make(.outlined)

    static func image(_ style: Style) -> NSImage {
        switch style {
        case .active: active
        case .dimmed: dimmed
        case .outlined: outlined
        }
    }

    private static func make(_ style: Style) -> NSImage {
        let canvas = NSSize(width: 18, height: 18)
        let image = NSImage(size: canvas, flipped: true) { rect in
            let bounds = pills.reduce(CGRect.null) { $0.union($1) }
            let scale = 16 / max(bounds.width, bounds.height)
            let origin = CGPoint(x: rect.midX - bounds.width * scale / 2, y: rect.midY - bounds.height * scale / 2)
            NSColor.black.withAlphaComponent(style == .dimmed ? 0.45 : 1).set()
            for pill in pills {
                var frame = CGRect(x: origin.x + (pill.minX - bounds.minX) * scale,
                                   y: origin.y + (pill.minY - bounds.minY) * scale,
                                   width: pill.width * scale, height: pill.height * scale)
                if style == .outlined {
                    let line: CGFloat = 1.2
                    frame = frame.insetBy(dx: line / 2, dy: line / 2)
                    let path = NSBezierPath(roundedRect: frame, xRadius: frame.width / 2, yRadius: frame.width / 2)
                    path.lineWidth = line
                    path.stroke()
                } else {
                    NSBezierPath(roundedRect: frame, xRadius: frame.width / 2, yRadius: frame.width / 2).fill()
                }
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Daylanes"
        return image
    }
}
