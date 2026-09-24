import AppIntents
import SwiftUI
import WidgetKit

private enum WidgetPages {
    static func capacity(for family: WidgetFamily) -> Int {
        switch family {
        case .systemSmall: return 1
        case .systemMedium: return 2
        default: return 6
        }
    }

    static func key(capacity: Int) -> String { "countdown.widget.page.\(capacity)" }
}

struct SetEventPageIntent: AppIntent {
    static var title: LocalizedStringResource = "Change countdown page"
    static var description = IntentDescription("Browse all saved countdown events in the widget.")
    static var isDiscoverable: Bool = false

    @Parameter(title: "Page") var page: Int
    @Parameter(title: "Events per page") var capacity: Int

    init() { }
    init(page: Int, capacity: Int) {
        self.page = page
        self.capacity = capacity
    }

    func perform() async throws -> some IntentResult {
        UserDefaults.standard.set(max(0, page), forKey: WidgetPages.key(capacity: capacity))
        UserDefaults.standard.synchronize()
        return .result()
    }
}

struct CountdownEntry: TimelineEntry {
    let date: Date
    let page: WidgetEventPage
    var hasReadError = false
}

struct CountdownProvider: TimelineProvider {
    func placeholder(in context: Context) -> CountdownEntry { preview(family: context.family) }

    func getSnapshot(in context: Context, completion: @escaping (CountdownEntry) -> Void) {
        if context.isPreview {
            completion(preview(family: context.family))
        } else {
            completion(entries(family: context.family).first!)
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CountdownEntry>) -> Void) {
        completion(Timeline(entries: entries(family: context.family), policy: .atEnd))
    }

    private func entries(family: WidgetFamily) -> [CountdownEntry] {
        let now = Date()
        let capacity = WidgetPages.capacity(for: family)
        let requestedPage = UserDefaults.standard.integer(forKey: WidgetPages.key(capacity: capacity))
        do {
            let events = try WidgetEventData.loadEvents()
            return WidgetEventData.timelineDates(events: events, now: now).map { date in
                CountdownEntry(date: date, page: WidgetEventPage(
                    events: events, requestedPage: requestedPage, capacity: capacity, now: date
                ))
            }
        } catch {
            return [CountdownEntry(date: now, page: WidgetEventPage(
                events: [], requestedPage: 0, capacity: capacity, now: now
            ), hasReadError: true)]
        }
    }

    private func preview(family: WidgetFamily) -> CountdownEntry {
        let now = Date()
        let events = [
            CountdownEvent(title: "Project launch", date: now.addingTimeInterval(3 * 86_400 + 8 * 3_600), timeZoneIdentifier: "UTC"),
            CountdownEvent(title: "Conference deadline", date: now.addingTimeInterval(18 * 86_400), timeZoneIdentifier: "AoE"),
            CountdownEvent(title: "Summer trip", date: now.addingTimeInterval(49 * 86_400))
        ]
        return CountdownEntry(date: now, page: WidgetEventPage(
            events: events, requestedPage: 0, capacity: WidgetPages.capacity(for: family), now: now
        ))
    }
}

struct CountdownWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: CountdownEntry

    var body: some View {
        CountdownWidgetContent(entry: entry, family: family)
            .containerBackground(.background, for: .widget)
            .widgetURL(entry.page.events.first.map(WidgetEventData.eventURL) ?? URL(string: "countdownmenubar://add"))
    }
}

struct CountdownWidgetContent: View {
    let entry: CountdownEntry
    let family: WidgetFamily

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Countdowns").font(.system(.subheadline, design: .rounded, weight: .semibold))
                Spacer(minLength: 2)
                Text("\(entry.page.totalEvents)").font(.caption).foregroundStyle(.secondary)
            }
            if entry.page.events.isEmpty {
                Spacer(minLength: 0)
                Text(entry.hasReadError ? "Open Countdown to reload your events." : "No events yet")
                    .font(.caption).foregroundStyle(.secondary)
                Link("Add an event", destination: URL(string: "countdownmenubar://add")!)
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 0)
            } else {
                ForEach(entry.page.events) { event in
                    Link(destination: WidgetEventData.eventURL(event)) {
                        if family == .systemSmall {
                            smallEvent(event)
                        } else {
                            eventRow(event)
                        }
                    }
                    .foregroundStyle(.primary)
                }
                Spacer(minLength: 0)
                pagination
            }
        }
    }

    private func smallEvent(_ event: CountdownEvent) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(event.title).font(.subheadline.weight(.medium)).lineLimit(1)
            HStack(spacing: 7) {
                WidgetMoon(progress: progress(event), urgency: MoonProgress.urgency(for: event, now: entry.date), completed: event.date <= entry.date).frame(width: 24, height: 24)
                countdown(event).font(.system(.title3, design: .rounded, weight: .semibold)).minimumScaleFactor(0.7)
            }
            Text(deadline(event)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private func eventRow(_ event: CountdownEvent) -> some View {
        HStack(spacing: 9) {
            WidgetMoon(progress: progress(event), urgency: MoonProgress.urgency(for: event, now: entry.date), completed: event.date <= entry.date).frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(event.title).font(.subheadline.weight(.medium)).lineLimit(1)
                    Spacer(minLength: 0)
                    countdown(event).font(.system(.subheadline, design: .rounded, weight: .semibold)).fixedSize()
                }
                Text(deadline(event)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, family == .systemLarge ? 2 : 1)
    }

    @ViewBuilder private func countdown(_ event: CountdownEvent) -> some View {
        let seconds = event.date.timeIntervalSince(entry.date)
        if seconds > 0 && seconds < 3_600 {
            // System-rendered timer text remains live while the extension sleeps
            // and stops at zero instead of counting up after the deadline.
            Text(timerInterval: entry.date...event.date, countsDown: true, showsHours: false)
                .monospacedDigit().lineLimit(1)
                .accessibilityLabel("Minutes and seconds remaining")
        } else {
            Text(CountdownFormat.compact(until: event.date, now: entry.date)).monospacedDigit().lineLimit(1)
        }
    }

    private var pagination: some View {
        HStack {
            if entry.page.count > 1 {
                Button(intent: SetEventPageIntent(page: entry.page.index - 1, capacity: WidgetPages.capacity(for: family))) {
                    Image(systemName: "chevron.left").frame(width: 22, height: 20)
                }
                .disabled(entry.page.index == 0)
                .accessibilityLabel("Previous events")
                Spacer(minLength: 0)
                Text("\(entry.page.index + 1) of \(entry.page.count)").font(.caption2).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button(intent: SetEventPageIntent(page: entry.page.index + 1, capacity: WidgetPages.capacity(for: family))) {
                    Image(systemName: "chevron.right").frame(width: 22, height: 20)
                }
                .disabled(entry.page.index + 1 == entry.page.count)
                .accessibilityLabel("Next events")
            } else {
                Text("All events").font(.caption2).foregroundStyle(.secondary)
                Spacer()
            }
        }
        .buttonStyle(.plain)
    }

    private func progress(_ event: CountdownEvent) -> Double {
        MoonProgress.value(for: event, now: entry.date)
    }

    private func deadline(_ event: CountdownEvent) -> String {
        let formatter = DateFormatter()
        formatter.calendar = EventTimeZone.calendar(in: event.timeZone)
        formatter.timeZone = event.timeZone
        formatter.dateFormat = "d MMM · HH:mm"
        return "\(formatter.string(from: event.date)) \(event.timeZoneIdentifier)"
    }
}

struct WidgetMoon: View {
    let progress: Double
    let urgency: Double
    let completed: Bool

    var body: some View {
        if completed {
            Image(systemName: "checkmark.circle").foregroundStyle(.secondary).accessibilityLabel("Deadline reached")
        } else {
            let color = Color(hue: MoonProgress.hue(progress: urgency), saturation: 0.88, brightness: 0.88)
            ZStack {
                Circle().fill(.primary.opacity(0.08))
                MoonPhase(progress: progress).fill(color)
                Circle().strokeBorder(color, lineWidth: 1)
            }
            .padding(1)
            .accessibilityLabel("Moon illuminated \(Int(progress * 100)) percent")
        }
    }
}

private struct MoonPhase: Shape {
    var progress: Double
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }
    func path(in rect: CGRect) -> Path {
        let radius = min(rect.width, rect.height) / 2
        let fill = min(1, max(0, progress))
        var path = Path()
        for step in 0...48 {
            let angle = -.pi / 2 + Double(step) * .pi / 48
            let point = CGPoint(x: rect.midX + radius * cos(angle), y: rect.midY + radius * sin(angle))
            if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        for step in 0...48 {
            let angle = .pi / 2 - Double(step) * .pi / 48
            path.addLine(to: CGPoint(x: rect.midX + (1 - 2 * fill) * radius * cos(angle), y: rect.midY + radius * sin(angle)))
        }
        path.closeSubpath()
        return path
    }
}

@main
struct CountdownEventsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetEventData.kind, provider: CountdownProvider()) { entry in
            CountdownWidgetView(entry: entry)
        }
        .configurationDisplayName("Countdown Events")
        .description("Your deadlines and countdowns. Browse every event using the page arrows.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
