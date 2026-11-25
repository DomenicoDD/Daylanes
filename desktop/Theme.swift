import AppKit
import SwiftUI

/// Colours, radii and small building blocks for the woday-inspired look: a near-black window chrome and sidebar,
/// with the page and the inspector on floating warm cards. Everything follows the system light or dark setting
/// except the chrome, which stays dark.
enum Theme {
    /// Builds a colour that switches with the window's appearance.
    private static func dynamic(light: UInt32, dark: UInt32, alpha: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light, alpha: alpha)
        })
    }

    // Surfaces
    static let chrome = Color(nsColor: NSColor(hex: 0x111113))
    static let sidebarSelected = Color(nsColor: NSColor(hex: 0x2A2A2E))
    static let chromeField = Color(nsColor: NSColor(hex: 0x1F1F23))
    static let card = dynamic(light: 0xFBFAF8, dark: 0x1C1C1F)
    static let block = dynamic(light: 0xEFEEEB, dark: 0x2A2A2E)
    static let blockHover = dynamic(light: 0xE6E4E0, dark: 0x333338)
    static let hairline = dynamic(light: 0x000000, dark: 0xFFFFFF, alpha: 0.07)

    // Text
    static let text = dynamic(light: 0x18181B, dark: 0xF2F2F3)
    static let secondary = dynamic(light: 0x8E8E93, dark: 0x8E8E93)

    /// Placeholder accent until the brand colour is chosen.
    static let accent = Color(nsColor: NSColor(hex: 0x5856D6))
    static let recording = Color(nsColor: NSColor(hex: 0xFF453A))

    static let cardRadius: CGFloat = 16
    static let blockRadius: CGFloat = 8
    static let cardInset: CGFloat = 8

    enum Tint: CaseIterable {
        case blue, green, purple, amber, red, neutral

        var fill: Color {
            switch self {
            case .blue: Theme.dynamic(light: 0xE3ECFD, dark: 0x1E2A44)
            case .green: Theme.dynamic(light: 0xE2F3E8, dark: 0x1C3326)
            case .purple: Theme.dynamic(light: 0xEEE7FB, dark: 0x2D2442)
            case .amber: Theme.dynamic(light: 0xFCF0D9, dark: 0x3A2E17)
            case .red: Theme.dynamic(light: 0xFDE5E1, dark: 0x43211E)
            case .neutral: Theme.block
            }
        }

        var ink: Color {
            switch self {
            case .blue: Theme.dynamic(light: 0x2F5BD3, dark: 0x8FB0FF)
            case .green: Theme.dynamic(light: 0x23794A, dark: 0x7FD3A0)
            case .purple: Theme.dynamic(light: 0x6A3FC8, dark: 0xC4AAFF)
            case .amber: Theme.dynamic(light: 0x9A6400, dark: 0xF2C46B)
            case .red: Theme.dynamic(light: 0xC2311F, dark: 0xFF9C8F)
            case .neutral: Theme.dynamic(light: 0x3C3C43, dark: 0xD1D1D6)
            }
        }
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

/// A floating card on the dark chrome: the page itself, or the inspector beside it.
struct CardSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
    }
}

/// A soft grey panel inside a card, such as a stat or the summary sentence.
struct BlockSurface: ViewModifier {
    var radius: CGFloat = 12
    func body(content: Content) -> some View {
        content.background(Theme.block, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

extension View {
    func cardSurface() -> some View { modifier(CardSurface()) }
    func blockSurface(radius: CGFloat = 12) -> some View { modifier(BlockSurface(radius: radius)) }
}

/// A small pastel tag, such as a project name or "Unassigned".
struct Chip: View {
    let text: String
    var tint: Theme.Tint = .neutral
    var dot: Color?

    var body: some View {
        HStack(spacing: 4) {
            if let dot { Circle().fill(dot).frame(width: 6, height: 6) }
            Text(text).lineLimit(1)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(tint.ink)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(tint.fill, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

/// Rounded grey pill used for page actions ("This week", "Rules", "Today").
struct PillButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var enabled

    init(prominent: Bool = false) {
        self.prominent = prominent
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.medium))
            // The prominent pill is the text colour filled in, so its label takes the card colour (light on dark).
            .foregroundStyle(prominent ? Theme.card : Theme.text)
            .padding(.horizontal, 11)
            .frame(height: 26)
            .background(prominent ? Theme.text : Theme.block, in: Capsule())
            .opacity(configuration.isPressed ? 0.7 : (enabled ? 1 : 0.45))
            .contentShape(Capsule())
    }
}

/// Round icon button, used for previous/next and export.
struct CircleButtonStyle: ButtonStyle {
    var dark = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(.iconOnly)
            .font(.callout.weight(.semibold))
            .foregroundStyle(dark ? Color.white.opacity(0.95) : Theme.text)
            .frame(width: 26, height: 26)
            .background(dark ? Theme.sidebarSelected : Theme.block, in: Circle())
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Circle())
    }
}

/// Big bold page title with a grey subtitle, and the page's actions on the right.
struct PageHeader<Actions: View>: View {
    let title: String
    let subtitle: String
    /// Drawn before the title, such as a client's icon.
    var icon: AnyView?
    var openProjectSettings: (() -> Void)? = nil
    @ViewBuilder var actions: Actions
    @State private var titleHovered = false
    @FocusState private var settingsFocused: Bool

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 10) {
                    if let icon { icon }
                    Text(title).font(.system(size: 28, weight: .bold)).foregroundStyle(Theme.text)
                        .accessibilityAddTraits(.isHeader)
                    if let openProjectSettings {
                        Button("Project settings", systemImage: "pencil", action: openProjectSettings)
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .help("Open project settings")
                            .focused($settingsFocused)
                            .opacity(titleHovered || settingsFocused ? 1 : 0)
                            .allowsHitTesting(titleHovered || settingsFocused)
                    }
                }
                .onHover { titleHovered = $0 }
                if !subtitle.isEmpty {
                    Text(subtitle).font(.callout).foregroundStyle(Theme.secondary)
                }
            }
            Spacer(minLength: 16)
            HStack(spacing: 6) { actions }
                .padding(.top, 4)
        }
    }
}

/// One day in the horizontal date strip.
struct DateStripDay: Identifiable {
    let date: Date
    /// A short total under the weekday, such as "2h 10m"; nil leaves it out.
    var detail: String?
    /// 0 to 1, drawn as a thin bar under the day.
    var progress: Double?
    var id: Date { date }
}

/// Horizontal strip of days. The selected day is filled with the accent; future days are dimmed.
struct DateStrip: View {
    let days: [DateStripDay]
    let selected: Date?
    let calendar: Calendar
    var boxed = false
    var select: ((Date) -> Void)?

    var body: some View {
        HStack(spacing: boxed ? 8 : 2) {
            ForEach(days) { day in
                let isSelected = selected.map { calendar.isDate($0, inSameDayAs: day.date) } ?? false
                let future = calendar.startOfDay(for: day.date) > Date()
                Button {
                    select?(day.date)
                } label: {
                    cell(day, selected: isSelected, future: future)
                }
                .buttonStyle(.plain)
                .disabled(select == nil || future)
            }
        }
    }

    private func cell(_ day: DateStripDay, selected: Bool, future: Bool) -> some View {
        let today = calendar.isDateInToday(day.date)
        let format = Date.FormatStyle(locale: .current, calendar: calendar, timeZone: calendar.timeZone)
        return VStack(spacing: 1) {
            Text(day.date.formatted(format.day())).font(.system(size: 17, weight: .semibold))
            Text(day.date.formatted(format.weekday(.abbreviated))).font(.caption2)
                .foregroundStyle(selected ? Color.white.opacity(0.85) : Theme.secondary)
            if let detail = day.detail {
                Text(detail).font(.caption2.weight(.semibold)).monospacedDigit().padding(.top, 2)
            }
            if let progress = day.progress {
                Capsule().fill(selected ? Color.white.opacity(0.3) : Theme.hairline)
                    .frame(width: 34, height: 3)
                    .overlay(alignment: .leading) {
                        Capsule().fill(selected ? Color.white : Theme.accent)
                            .frame(width: 34 * min(1, max(0, progress)), height: 3)
                    }
                    .padding(.top, 3)
            } else if today && !selected {
                Circle().fill(Theme.accent).frame(width: 4, height: 4).padding(.top, 2)
            }
        }
        .foregroundStyle(selected ? Color.white : Theme.text)
        .opacity(future ? 0.4 : 1)
        .frame(maxWidth: .infinity)
        .padding(.vertical, boxed ? 10 : 6)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selected ? Theme.accent : Color.clear)
            if boxed && !selected {
                RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline)
            }
        }
        .contentShape(Rectangle())
    }
}

/// A sentence with inline chips, such as "This week you tracked [12 h] on [5 projects]". Wraps like text.
struct SummarySentence: View {
    enum Part {
        case text(String)
        case chip(String, Theme.Tint)
    }

    let parts: [Part]

    var body: some View {
        FlowLayout(spacing: 5, lineSpacing: 6) {
            ForEach(Array(words.enumerated()), id: \.offset) { _, part in
                switch part {
                case let .text(word):
                    Text(word).foregroundStyle(Theme.text)
                case let .chip(label, tint):
                    Text(label).fontWeight(.medium).foregroundStyle(tint.ink)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(tint.fill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }
        }
        .font(.system(size: 14))
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .blockSurface()
        .accessibilityElement(children: .combine)
    }

    /// Text is split into words so the layout can wrap between them; chips stay whole.
    private var words: [Part] {
        parts.flatMap { part -> [Part] in
            guard case let .text(text) = part else { return [part] }
            return text.split(separator: " ").map { .text(String($0)) }
        }
    }
}

/// Lays out children left to right and wraps onto new lines, aligned on their first baseline.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(0, rows.count - 1))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let extra = rows[rows.count - 1].indices.isEmpty ? size.width : size.width + spacing
            if rows[rows.count - 1].width + extra > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            let added = rows[rows.count - 1].indices.isEmpty ? size.width : size.width + spacing
            rows[rows.count - 1].indices.append(index)
            rows[rows.count - 1].width += added
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
        }
        return rows
    }
}

/// Stat tile: small grey label, big number, grey detail.
struct StatTile: View {
    let title: String
    let value: String
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(Theme.secondary)
            Text(value).font(.system(size: 22, weight: .bold)).monospacedDigit().foregroundStyle(Theme.text)
                .lineLimit(1).minimumScaleFactor(0.7)
            if let detail {
                Text(detail).font(.caption2).foregroundStyle(Theme.secondary).lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .blockSurface()
        .accessibilityElement(children: .combine)
    }
}

/// Section title inside a card, with an optional grey note on the right.
struct SectionTitle: View {
    let title: String
    var note: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.text)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if let note { Text(note).font(.caption).foregroundStyle(Theme.secondary) }
        }
    }
}

extension Theme.Tint {
    /// A stable pastel for a project, so the same project always gets the same chip.
    static func forProject(_ name: String) -> Theme.Tint {
        let palette: [Theme.Tint] = [.blue, .amber, .purple, .green, .red]
        let hash = name.unicodeScalars.reduce(5381) { ($0 << 5) &+ $0 &+ Int($1.value) }
        return palette[abs(hash) % palette.count]
    }
}
