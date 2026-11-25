import SwiftUI

/// The centred search field in the dark toolbar. ⌘K focuses it; it filters the lists on the current page.
struct SearchPill: View {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.callout).foregroundStyle(Color.white.opacity(0.5))
                .accessibilityHidden(true)
            TextField("Search", text: $text, prompt: Text("Search activity, folders or branches…").foregroundStyle(Color.white.opacity(0.62)))
                .textFieldStyle(.plain)
                .foregroundStyle(Color.white)
                .focused(focused)
                .focusEffectDisabled()
            if text.isEmpty {
                Text("⌘K").font(.caption.weight(.medium)).foregroundStyle(Color.white.opacity(0.62))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
            } else {
                Button("Clear search", systemImage: "xmark.circle.fill") { text = "" }
                    .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(Color.white.opacity(0.5))
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .frame(minWidth: 280, idealWidth: 400, maxWidth: 420)
        .frame(height: 28)
        .modifier(LegacyCapsule(fill: Theme.chromeField))
        .background {
            Button("Search") { focused.wrappedValue = true }
                .keyboardShortcut("k", modifiers: .command)
                .hidden()
        }
    }
}

/// The dark capsule behind toolbar controls (the system glass is hidden, see the toolbar).
struct LegacyCapsule: ViewModifier {
    var fill: Color = Theme.sidebarSelected

    func body(content: Content) -> some View {
        content.background(fill, in: Capsule())
    }
}

/// Leaves the page title to the card instead of repeating it in the toolbar, where macOS 15 allows it.
struct HiddenWindowTitle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.toolbar(removing: .title)
        } else {
            content
        }
    }
}

/// A one-column preview of the current day, independent of the Overview period.
struct TodayPanel: View {
    @EnvironmentObject private var recorder: FocusRecorder
    @EnvironmentObject private var model: LedgerModel
    let timezone: String
    let filter: String
    let openTimeline: () -> Void
    @State private var source = DayCalendar.Source.you
    @State private var now = Date()
    @State private var day: DayActivity?
    @State private var failedDay: String?
    @State private var reloadCount = 0

    private var zone: TimeZone { TimeZone(identifier: timezone) ?? .current }

    var body: some View {
        let date = Day.local(Int(now.timeIntervalSince1970 * 1000), zone).iso
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Today").font(.system(size: 22, weight: .bold)).foregroundStyle(Theme.text)
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    Button("Open", action: openTimeline).buttonStyle(PillButtonStyle())
                        .accessibilityLabel("Open today’s timeline")
                        .help("Open today’s timeline")
                }
                SheetSegments(selection: $source, options: DayCalendar.Source.allCases.map { ($0, $0.title) })
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Activity source")
            }
            .padding([.top, .horizontal], 20)
            .padding(.bottom, 8)
            if failedDay == date {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Couldn’t load today’s activity.").font(.callout).foregroundStyle(.secondary)
                    Button("Retry") { reloadCount += 1 }.buttonStyle(.link)
                }
                .padding(.horizontal, 20)
            }
            if let day, day.day == date {
                DayCalendar(day: day, source: source, query: filter, zone: zone)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            } else if failedDay != date {
                ProgressView("Loading today’s activity…").controlSize(.small).padding(.horizontal, 20)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            TimelineView(.everyMinute) { context in
                Color.clear.onChange(of: context.date, initial: true) { _, tick in now = tick }
            }
            .accessibilityHidden(true)
        }
        .task(id: "\(timezone)-\(date)-\(recorder.revision)-\(model.revision)-\(reloadCount)") { await load(date) }
    }

    private func load(_ date: String) async {
        do {
            let data = try await Ledger.run(["focus", "timeline", "--day", date])
            let result = try JSONDecoder().decode(DayActivity.self, from: data)
            guard !Task.isCancelled else { return }
            day = result
            failedDay = nil
        } catch {
            guard !Task.isCancelled else { return }
            failedDay = date
        }
    }
}

/// What the right-hand panel shows on the Timeline: the block the person clicked.
@MainActor
final class Inspector: ObservableObject {
    @Published private(set) var id: String?
    @Published private(set) var title = ""
    @Published private(set) var content: AnyView?

    func show(id: String, title: String, _ content: AnyView) {
        self.id = id
        self.title = title
        self.content = content
    }

    func close() {
        id = nil
        content = nil
    }
}

/// The inspector card beside the day calendar, like the block panel in the Figma Day view.
struct InspectorPanel: View {
    @ObservedObject var inspector: Inspector

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Block").font(.caption.weight(.medium)).foregroundStyle(Theme.secondary)
                Spacer()
                Button("Close", systemImage: "xmark") { inspector.close() }
                    .buttonStyle(CircleButtonStyle())
                    .keyboardShortcut(.cancelAction)
            }
            .padding([.horizontal, .top], 18)
            ScrollView {
                inspector.content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id(inspector.id)
            }
            .scrollIndicators(.never)
        }
    }
}

/// Daily portions of the Overview's logged human time. Clicking a day opens it on the Timeline.
struct OverviewWeekStrip: View {
    let snapshot: Snapshot
    let open: (Date) -> Void

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: snapshot.timezone) ?? .current
        calendar.firstWeekday = 2
        return calendar
    }

    var body: some View {
        if let start = try? Day.parse(snapshot.start) {
            let calendar = calendar
            let days = (0..<7).map { offset in
                let day = start.adding(days: offset)
                let date = Date(timeIntervalSince1970: Double(day.midnight(calendar.timeZone)) / 1000)
                let future = date > Date()
                let hours = (snapshot.dailyHumanMillis[day.iso] ?? 0) / 3_600_000
                return DateStripDay(date: date, detail: future ? "–" : hoursText(String(hours)),
                                    progress: future ? nil : min(1, hours / 8))
            }
            DateStrip(days: days, selected: days.first { calendar.isDateInToday($0.date) }?.date,
                      calendar: calendar, boxed: true, select: open)
                .frame(minHeight: 72)
                .accessibilityLabel("Logged human time by day")
        }
    }
}
