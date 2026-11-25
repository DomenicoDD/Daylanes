import SwiftUI

/// "Snoozed · 12 min", "Snoozed until tomorrow", or the live tracking status. Updates every second.
struct TrackingStatusText: View {
    @ObservedObject var recorder: FocusRecorder

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(Self.label(recorder, now: context.date))
        }
    }

    static func label(_ recorder: FocusRecorder, now: Date) -> String {
        guard let until = recorder.snoozedUntil, !recorder.enabled else { return recorder.status.label }
        if !Calendar.current.isDate(until, inSameDayAs: now) { return "Snoozed until tomorrow" }
        let seconds = max(0, Int(until.timeIntervalSince(now)))
        if seconds >= 3600 { return "Snoozed · \(seconds / 3600) h \(seconds % 3600 / 60) min" }
        if seconds >= 60 { return "Snoozed · \(seconds / 60 + (seconds % 60 > 0 ? 1 : 0)) min" }
        return "Snoozed · \(seconds) s"
    }
}

/// Menu items to snooze tracking, or resume it early.
struct SnoozeMenuItems: View {
    @ObservedObject var recorder: FocusRecorder
    var showRules: (() -> Void)?

    var body: some View {
        if recorder.snoozedUntil != nil && !recorder.enabled {
            Button("Resume tracking now") { recorder.resume() }
        } else {
            Section("Snooze tracking") {
                ForEach([15, 30, 60, 120], id: \.self) { minutes in
                    Button(minutes < 60 ? "For \(minutes) minutes" : "For \(minutes / 60) \(minutes == 60 ? "hour" : "hours")") {
                        recorder.snooze(minutes: minutes)
                    }
                }
                Button("Until tomorrow") { recorder.snooze(minutes: nil) }
            }
        }
        if let showRules {
            Divider()
            Button("Don’t track an app or site…", action: showRules)
        }
    }
}
