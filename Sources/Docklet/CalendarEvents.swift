import SwiftUI
import EventKit
import AppKit

// MARK: - Model

struct CalEvent: Identifiable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let color: Color
    let isAllDay: Bool

    var isNow: Bool  { start <= Date() && end > Date() }
    var isPast: Bool { end <= Date() }
}

// MARK: - Monitor

@MainActor
final class CalendarMonitor: ObservableObject {
    static let shared = CalendarMonitor()

    @Published var todayEvents: [CalEvent] = []
    @Published var nextEvent: CalEvent? = nil
    @Published var accessGranted: Bool? = nil

    private let store = EKEventStore()
    private var refreshTimer: Timer?

    init() {
        requestAccess()
        // Refresh every minute so countdowns stay accurate
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.loadEvents() }
        }
    }

    deinit { refreshTimer?.invalidate() }

    private var isAuthorized: Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        if #available(macOS 14.0, *) { return status == .fullAccess }
        return status == .authorized
    }

    /// Re-reads the current authorization status (e.g. after returning from
    /// System Settings) and loads events if we now have access.
    func recheckAccess() {
        accessGranted = isAuthorized
        if isAuthorized { loadEvents() }
    }

    func requestAccess() {
        if #available(macOS 14.0, *) {
            store.requestFullAccessToEvents { [weak self] granted, _ in
                Task { @MainActor in
                    self?.accessGranted = granted
                    if granted { self?.loadEvents() }
                }
            }
        } else {
            store.requestAccess(to: .event) { [weak self] granted, _ in
                Task { @MainActor in
                    self?.accessGranted = granted
                    if granted { self?.loadEvents() }
                }
            }
        }
    }

    /// Used by the "Grant Access" button. macOS only ever shows the permission
    /// prompt once — if access was already decided (denied/restricted), a second
    /// request silently no-ops, so send the user to System Settings instead.
    func grantOrOpenSettings() {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined:
            requestAccess()
        default:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    func loadEvents() {
        let cal = Calendar.current
        let now = Date()
        let start = cal.startOfDay(for: now)
        let end   = cal.date(byAdding: .day, value: 1, to: start)!

        let pred = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        todayEvents = store.events(matching: pred)
            .sorted { $0.startDate < $1.startDate }
            .map { ev in
                CalEvent(
                    id: ev.eventIdentifier ?? UUID().uuidString,
                    title: ev.title ?? "Untitled",
                    start: ev.startDate,
                    end: ev.endDate,
                    color: Color(nsColor: NSColor(cgColor: ev.calendar.cgColor) ?? .systemBlue),
                    isAllDay: ev.isAllDay
                )
            }
        nextEvent = todayEvents.first { !$0.isPast }
    }
}

// MARK: - View

struct CalendarView: View {
    @StateObject private var monitor = CalendarMonitor.shared

    // "Grant Access" can only prompt once; afterwards it opens System Settings.
    private var grantLabel: String {
        EKEventStore.authorizationStatus(for: .event) == .notDetermined ? "Grant Access" : "Open Settings"
    }

    var body: some View {
        Group {
            if monitor.accessGranted == false {
                VStack(spacing: 8) {
                    Image(systemName: "calendar.badge.exclamationmark")
                        .font(.system(size: 22)).foregroundColor(.white.opacity(0.4))
                    Text("Calendar access required")
                        .font(.system(size: 11)).foregroundColor(.white.opacity(0.5))
                    Button { monitor.grantOrOpenSettings() } label: {
                        Text(grantLabel)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.white.opacity(0.7))
                            .padding(.horizontal, 12).padding(.vertical, 5)
                            .background(Capsule().fill(Color.white.opacity(0.1)))
                    }.buttonStyle(.plain)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if monitor.todayEvents.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "calendar")
                        .font(.system(size: 22, weight: .light)).foregroundColor(.white.opacity(0.3))
                    Text("No events today")
                        .font(.system(size: 11)).foregroundColor(.white.opacity(0.4))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 3) {
                        ForEach(monitor.todayEvents) { CalEventRow(event: $0) }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Re-check whenever the tab is shown — picks up a grant made in System Settings.
        .onAppear { monitor.recheckAccess() }
    }
}

struct CalEventRow: View {
    let event: CalEvent

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2).fill(event.color)
                .frame(width: 3, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(event.isPast ? 0.4 : event.isNow ? 1 : 0.8))
                    .lineLimit(1)
                if !event.isAllDay {
                    Text(timeRange)
                        .font(.system(size: 9)).foregroundColor(.white.opacity(0.38))
                }
            }
            Spacer()
            badge
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(Color.white.opacity(event.isNow ? 0.08 : 0.03)))
    }

    @ViewBuilder var badge: some View {
        if event.isAllDay {
            Text("All day").font(.system(size: 9)).foregroundColor(.white.opacity(0.35))
        } else if event.isNow {
            Text("Now")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(event.color)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(event.color.opacity(0.18)))
        } else if !event.isPast {
            Text(countdown)
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.white.opacity(0.38))
        }
    }

    var timeRange: String {
        let f = DateFormatter(); f.dateFormat = "h:mm a"
        return "\(f.string(from: event.start)) – \(f.string(from: event.end))"
    }

    var countdown: String {
        let mins = Int(event.start.timeIntervalSinceNow / 60)
        if mins < 60 { return "in \(mins)m" }
        return "in \(mins / 60)h \(mins % 60)m"
    }
}
