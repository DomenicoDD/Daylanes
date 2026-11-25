import SwiftUI

struct ActivityWeek: View {
    let days: [DayActivity]
    let calendar: Calendar
    let openDay: (Date) -> Void

    private let headerHeight: CGFloat = 44
    private let gridHeight: CGFloat = 288

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 15) {
                Text(weekLabel).font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
                Spacer()
                ForEach(TimeSource.allCases, id: \.self) { source in
                    Label(source.calendarLabel, systemImage: source.icon)
                        .font(.caption)
                        .foregroundStyle(source.calendarTint)
                }
            }
            HStack(alignment: .top, spacing: 0) {
                ruler
                    .padding(.trailing, 8)
                    .padding(.top, headerHeight)
                    .accessibilityHidden(true)
                ForEach(days) { day in
                    dayColumn(day)
                }
            }
            if days.allSatisfy({ $0.blocks.isEmpty }) {
                Text("No auto-tracked or imported time this week.").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var weekLabel: String {
        guard let first = days.first, let last = days.last else { return "This week" }
        let formatter = DateIntervalFormatter()
        formatter.timeZone = calendar.timeZone
        formatter.dateTemplate = "d MMM yyyy"
        return formatter.string(from: first.date, to: last.date)
    }

    private var ruler: some View {
        VStack(alignment: .trailing, spacing: 0) {
            ForEach(0..<4) { tick in
                Text(String(format: "%02d:00", tick * 6))
                    .frame(height: gridHeight / 4, alignment: .topTrailing)
            }
            Text("24:00")
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: true, vertical: false)
        .offset(y: -7)
    }

    private func dayColumn(_ day: DayActivity) -> some View {
        let isToday = calendar.isDateInToday(day.date)
        let future = day.date > Date()
        let dateLabel = format(day.date, as: .dateTime.weekday(.wide).day().month(.wide))
        let counts = TimeSource.allCases.compactMap { source -> String? in
            let count = day.blocks.filter { $0.timeSource == source }.count
            return count > 0 ? "\(source.calendarLabel), \(count) \(count == 1 ? "entry" : "entries")" : nil
        }
        return Button {
            openDay(day.date)
        } label: {
            VStack(spacing: 0) {
                VStack(spacing: 1) {
                    Text(format(day.date, as: .dateTime.weekday(.abbreviated))).font(.caption)
                    Text(format(day.date, as: .dateTime.day())).font(.callout.weight(.semibold)).monospacedDigit()
                }
                .frame(maxWidth: .infinity, minHeight: headerHeight)
                .foregroundStyle(isToday ? Color.accentColor : Color.primary)
                marks(day)
            }
            .frame(maxWidth: .infinity)
            .background(isToday ? Color.accentColor.opacity(0.06) : Color.clear)
            .overlay(alignment: .leading) { Divider() }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(future)
        .accessibilityLabel(dateLabel)
        .accessibilityValue(counts.isEmpty ? "No entries" : counts.joined(separator: ", "))
        .accessibilityHint("Opens the daily timeline")
        .help(([dateLabel] + counts).joined(separator: " · "))
    }

    private func marks(_ day: DayActivity) -> some View {
        let lanes = Dictionary(grouping: day.blocks, by: \.timeSource)
        let sources = TimeSource.allCases.filter { lanes[$0] != nil }
        return Canvas { context, size in
            for tick in 0...4 {
                let y = min(size.height - 0.5, CGFloat(tick) * size.height / 4 + 0.5)
                var line = Path()
                line.move(to: CGPoint(x: 0, y: y))
                line.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(line, with: .color(.secondary.opacity(0.25)), lineWidth: 1)
            }
            guard !sources.isEmpty else { return }
            let laneWidth = size.width / CGFloat(sources.count)
            guard laneWidth > 6 else { return }
            for (index, source) in sources.enumerated() {
                for block in lanes[source, default: []] {
                    let y = size.height * fraction(at: block.startedAt, on: day)
                    let end = size.height * fraction(at: block.endedAt, on: day)
                    let mark = CGRect(x: CGFloat(index) * laneWidth + 3, y: y,
                                      width: laneWidth - 6, height: min(size.height - y, max(3, end - y)))
                    let color = block.ignored ? Color.secondary : source.calendarTint
                    let shape = Path(roundedRect: mark, cornerRadius: 2)
                    context.fill(shape, with: .color(color.opacity(block.ignored ? 0.33 : 0.78)))
                    context.stroke(shape, with: .color(Color(nsColor: .windowBackgroundColor)), lineWidth: 1)
                }
            }
        }
        .frame(height: gridHeight)
        .accessibilityHidden(true)
    }

    private func fraction(at milliseconds: Double, on day: DayActivity) -> CGFloat {
        if milliseconds >= day.dayEnd { return 1 }
        let date = Date(timeIntervalSince1970: milliseconds / 1000)
        let time = calendar.dateComponents([.hour, .minute, .second], from: date)
        let seconds = (time.hour ?? 0) * 3600 + (time.minute ?? 0) * 60 + (time.second ?? 0)
        return CGFloat(seconds) / 86_400
    }

    private func format(_ date: Date, as style: Date.FormatStyle) -> String {
        var style = style
        style.timeZone = calendar.timeZone
        return date.formatted(style)
    }
}
