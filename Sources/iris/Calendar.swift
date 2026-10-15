import ArgumentParser
import EventKit
import Foundation

struct CalendarCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "calendar",
        abstract: "Read and write Apple Calendar.",
        subcommands: [Calendars.self, Events.self, AddEvent.self, UpdateEvent.self, DeleteEvent.self]
    )
}

struct Calendars: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List calendars.")

    func run() async throws {
        let store = try await grantedStore()
        let calendars = store.calendars(for: .event)
            .sorted { $0.title < $1.title }
            .map { CalendarInfo(id: $0.calendarIdentifier, title: $0.title,
                                writable: $0.allowsContentModifications, source: $0.source.title) }
        try emit(calendars)
    }
}

struct Events: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List events in a date range, earliest first.")

    @Option(help: "Range start: 2026-10-13, 2026-10-13T09:00 (local time), or ISO 8601 with offset. Default: start of today.")
    var from: String?

    @Option(help: "Range end, same formats. Default: 7 days after --from.")
    var to: String?

    @Option(name: .customLong("calendar"), help: "Calendar id or title; repeat for several. Default: every calendar.")
    var calendars: [String] = []

    func validate() throws {
        _ = try range()
    }

    func run() async throws {
        let store = try await grantedStore()
        let (start, end) = try range()
        let scope = try resolveCalendars(calendars, in: store)
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: scope)
        let events = store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .map(EventInfo.init)
        try emit(events)
    }

    private func range() throws -> (Date, Date) {
        let start = try from.map(parseDate) ?? Calendar.current.startOfDay(for: Date())
        let end = try to.map(parseDate) ?? start.addingTimeInterval(7 * 86400)
        guard start < end else { throw ValidationError("--to must be after --from") }
        return (start, end)
    }
}

struct CalendarInfo: Encodable {
    let id: String
    let title: String
    let writable: Bool
    let source: String
}

struct EventInfo: Encodable {
    let id: String
    let title: String
    let start: String
    let end: String
    let allDay: Bool
    let calendar: String
    let calendarId: String
    let location: String?
    let notes: String?
    let recurring: Bool
    let availability: String

    init(_ event: EKEvent) {
        id = event.eventIdentifier ?? ""
        title = event.title ?? ""
        start = iso(event.startDate)
        end = iso(event.endDate)
        allDay = event.isAllDay
        calendar = event.calendar.title
        calendarId = event.calendar.calendarIdentifier
        location = event.location.flatMap { $0.isEmpty ? nil : $0 }
        notes = event.notes.flatMap { $0.isEmpty ? nil : $0 }
        recurring = event.hasRecurrenceRules
        availability = describe(event.availability)
    }
}

struct IrisError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func grantedStore() async throws -> EKEventStore {
    let store = EKEventStore()
    guard try await store.requestFullAccessToEvents() else {
        throw IrisError("calendar access denied; allow Iris under System Settings › Privacy & Security › Calendars")
    }
    return store
}

/// Id first, title second. A name that matches nothing is an error, never a silent widening to every calendar.
func resolveCalendars(_ tokens: [String], in store: EKEventStore) throws -> [EKCalendar]? {
    if tokens.isEmpty { return nil }
    let all = store.calendars(for: .event)
    var found: [EKCalendar] = []
    var missing: [String] = []
    for token in tokens {
        let hits = all.filter { $0.calendarIdentifier == token || $0.title == token }
        if hits.isEmpty { missing.append(token) } else { found += hits }
    }
    guard missing.isEmpty else {
        throw IrisError("no calendar named \(missing.joined(separator: ", ")); see `iris calendar calendars`")
    }
    return found
}

/// ISO 8601 with offset, or a local wall-clock time without one.
func parseDate(_ text: String) throws -> Date {
    if let date = ISO8601DateFormatter().date(from: text) { return date }
    for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        if let date = formatter.date(from: text) { return date }
    }
    throw ValidationError("unrecognised date '\(text)'; use 2026-10-13, 2026-10-13T09:00, or ISO 8601 with offset")
}

/// A bare date such as 2026-10-13, at local midnight; nil for anything with a time.
func parseDay(_ text: String) -> Date? {
    guard text.count == 10 else { return nil }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.date(from: text)
}

private let isoFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = .current
    return formatter
}()

func iso(_ date: Date) -> String {
    isoFormatter.string(from: date)
}

func describe(_ availability: EKEventAvailability) -> String {
    switch availability {
    case .busy: return "busy"
    case .free: return "free"
    case .tentative: return "tentative"
    case .unavailable: return "unavailable"
    case .notSupported: return "unknown"
    @unknown default: return "unknown"
    }
}

func emit<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    print(String(decoding: try encoder.encode(value), as: UTF8.self))
}
