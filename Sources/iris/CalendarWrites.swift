import ArgumentParser
import EventKit
import Foundation

struct AddEvent: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Create an event. Prints the created event as JSON."
    )

    @Option(help: "Calendar id or title to create the event in. Required. Must be writable (see `iris calendar calendars`).")
    var calendar: String

    @Option(help: "Event title. Required.")
    var title: String

    @Option(help: "Start: 2026-10-13, 2026-10-13T09:00 (local time), or ISO 8601 with offset. Required. With --all-day only the day counts.")
    var start: String

    @Option(help: "End, same formats; a bare date includes that whole day. Default: one hour after --start, or the start day with --all-day.")
    var end: String?

    @Flag(help: "Make it an all-day event. Default: a timed event.")
    var allDay = false

    @Option(help: "Location. Default: none.")
    var location: String?

    @Option(help: "Notes. Default: none.")
    var notes: String?

    @Option(help: "URL. Default: none.")
    var url: String?

    @Option(help: "busy, free, tentative or unavailable. Default: busy.")
    var availability: String?

    @Option(name: .customLong("alarm"), help: "Alarm this many minutes before the start; repeat for several. Default: no alarms.")
    var alarms: [Int] = []

    @Option(name: .customLong("repeat"), help: "Repeat daily, weekly, monthly or yearly. Default: does not repeat. Without --until or --count it repeats forever.")
    var repeatFrequency: String?

    @Option(help: "With --repeat: repeat every n days/weeks/months/years. Default: 1.")
    var every: Int?

    @Option(help: "With --repeat weekly: comma-separated days, from su,mo,tu,we,th,fr,sa. Default: the weekday of --start.")
    var on: String?

    @Option(help: "With --repeat: no occurrence starts after this date (same formats as --start; a bare date includes that whole day). Not with --count. Default: no end.")
    var until: String?

    @Option(help: "With --repeat: stop after this many occurrences. Not with --until. Default: no limit.")
    var count: Int?

    func validate() throws {
        _ = try availability.map(parseAvailability)
        if alarms.contains(where: { $0 < 0 }) { throw ValidationError("--alarm takes minutes of 0 or more") }
        if let url, URL(string: url)?.scheme == nil { throw ValidationError("--url needs a scheme, like https://example.com") }
        if repeatFrequency == nil, every != nil || on != nil || until != nil || count != nil {
            throw ValidationError("--every, --on, --until and --count need --repeat")
        }
        if until != nil, count != nil { throw ValidationError("use --until or --count, not both") }
        if let every, every < 1 { throw ValidationError("--every must be 1 or more") }
        if let count, count < 1 { throw ValidationError("--count must be 1 or more") }
        if on != nil, repeatFrequency != "weekly" { throw ValidationError("--on only works with --repeat weekly") }
        _ = try repeatFrequency.map(parseFrequency)
        _ = try on.map(parseWeekdays)
        let (startDate, _) = try dates()
        if let until, try parseEnd(until) < startDate { throw ValidationError("--until must not be before --start") }
    }

    func run() async throws {
        let store = try await grantedStore()
        let target = try writableCalendar(calendar, in: store)
        let (startDate, endDate) = try dates()

        let event = EKEvent(eventStore: store)
        event.calendar = target
        event.title = title
        event.isAllDay = allDay
        event.startDate = startDate
        event.endDate = endDate
        if !allDay { event.timeZone = .current }
        event.location = location
        event.notes = notes
        event.url = url.flatMap { URL(string: $0) }
        if let availability { event.availability = try parseAvailability(availability) }
        setAlarms(alarms, on: event)
        if let repeatFrequency {
            event.recurrenceRules = [try recurrenceRule(frequency: repeatFrequency)]
        }

        try save(event, span: .thisEvent, in: store)
        try emit(EventInfo(event))
    }

    private func dates() throws -> (Date, Date) {
        let startDate = try parseDate(start)
        let (first, last) = try allDay
            ? allDayBounds(startDate, end.map(parseEnd) ?? startDate)
            : (startDate, end.map(parseEnd) ?? startDate.addingTimeInterval(3600))
        guard first < last else { throw ValidationError("--end must be after --start") }
        return (first, last)
    }

    private func recurrenceRule(frequency: String) throws -> EKRecurrenceRule {
        let recurrenceEnd: EKRecurrenceEnd?
        if let until {
            recurrenceEnd = EKRecurrenceEnd(end: try parseEnd(until))
        } else if let count {
            recurrenceEnd = EKRecurrenceEnd(occurrenceCount: count)
        } else {
            recurrenceEnd = nil
        }
        return EKRecurrenceRule(
            recurrenceWith: try parseFrequency(frequency),
            interval: every ?? 1,
            daysOfTheWeek: try on.map(parseWeekdays),
            daysOfTheMonth: nil, monthsOfTheYear: nil, weeksOfTheYear: nil,
            daysOfTheYear: nil, setPositions: nil,
            end: recurrenceEnd
        )
    }
}

struct UpdateEvent: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Change an event. Only the fields you name change. Prints the updated event as JSON."
    )

    @Argument(help: "Event id, from `iris calendar events`.")
    var id: String

    @Option(help: "New title.")
    var title: String?

    @Option(help: "New start: 2026-10-13, 2026-10-13T09:00 (local time), or ISO 8601 with offset. The end moves with it, keeping the duration, unless you pass --end.")
    var start: String?

    @Option(help: "New end, same formats; a bare date includes that whole day.")
    var end: String?

    @Flag(inversion: .prefixedNo, help: "--all-day makes it an all-day event; --no-all-day makes it timed and needs --start and --end. Default: unchanged.")
    var allDay: Bool?

    @Option(help: "Move the event to this calendar (id or title). Must be writable. Default: unchanged.")
    var calendar: String?

    @Option(help: "New location. An empty string clears it.")
    var location: String?

    @Option(help: "New notes. An empty string clears them.")
    var notes: String?

    @Option(help: "New URL. An empty string clears it.")
    var url: String?

    @Option(help: "busy, free, tentative or unavailable.")
    var availability: String?

    @Option(name: .customLong("alarm"), help: "Alarm this many minutes before the start; repeat for several. Replaces all existing alarms. Default: alarms unchanged.")
    var alarms: [Int] = []

    @Flag(help: "Remove all alarms. Default: alarms unchanged.")
    var noAlarms = false

    @Option(help: "For a recurring event: the day of the occurrence to change; add a time if there are several that day.")
    var occurrence: String?

    @Option(help: "this or future. this: only the targeted occurrence. future: the targeted occurrence and all after it; without --occurrence, the whole series. Default: this.")
    var span = "this"

    func validate() throws {
        _ = try parseSpan(span)
        _ = try availability.map(parseAvailability)
        _ = try occurrence.map(parseDate)
        if alarms.contains(where: { $0 < 0 }) { throw ValidationError("--alarm takes minutes of 0 or more") }
        if noAlarms, !alarms.isEmpty { throw ValidationError("--no-alarms and --alarm do not mix") }
        if let url, !url.isEmpty, URL(string: url)?.scheme == nil { throw ValidationError("--url needs a scheme, like https://example.com") }
        if allDay == false, start == nil || end == nil { throw ValidationError("--no-all-day needs --start and --end") }
        if span == "future", occurrence == nil, start != nil || end != nil {
            throw ValidationError("--span future with --start or --end needs --occurrence to say where the change begins")
        }
        let startDate = try start.map(parseDate)
        let endDate = try end.map(parseEnd)
        if let startDate, let endDate {
            // A same-day all-day range is valid, so only a clearly inverted pair is refused up front.
            let inverted = allDay == false
                ? startDate >= endDate
                : Calendar.current.startOfDay(for: startDate) > Calendar.current.startOfDay(for: endDate)
            if inverted { throw ValidationError("--end must be after --start") }
        }
    }

    func run() async throws {
        let store = try await grantedStore()
        let span = try parseSpan(span)
        let event = try findEvent(id, occurrence: occurrence, span: span, in: store)

        if let title { event.title = title }
        if let location { event.location = location }
        if let notes { event.notes = notes }
        if let url { event.url = url.isEmpty ? nil : URL(string: url) }
        if let availability { event.availability = try parseAvailability(availability) }
        if let calendar { event.calendar = try writableCalendar(calendar, in: store) }
        if noAlarms { setAlarms([], on: event) } else if !alarms.isEmpty { setAlarms(alarms, on: event) }

        // Moving the start keeps the length: in seconds for timed events, in calendar days for
        // all-day ones, so a move across a DST change does not gain or lose a day.
        let duration = event.endDate.timeIntervalSince(event.startDate)
        let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: event.startDate),
                                                   to: Calendar.current.startOfDay(for: event.endDate)).day ?? 0
        if let allDay {
            event.isAllDay = allDay
            event.timeZone = allDay ? nil : .current
        }
        if let start { event.startDate = try parseDate(start) }
        if let end {
            event.endDate = try parseEnd(end)
        } else if start != nil {
            event.endDate = event.isAllDay
                ? Calendar.current.date(byAdding: .day, value: days, to: event.startDate) ?? event.startDate
                : event.startDate.addingTimeInterval(duration)
        }
        if event.isAllDay, allDay != nil || start != nil || end != nil {
            (event.startDate, event.endDate) = allDayBounds(event.startDate, event.endDate)
        }
        guard event.startDate < event.endDate else { throw IrisError("the end must be after the start") }

        try save(event, span: span, in: store)
        try emit(EventInfo(event))
    }
}

struct DeleteEvent: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete an event. Prints {deleted, title, start, span} as JSON."
    )

    @Argument(help: "Event id, from `iris calendar events`.")
    var id: String

    @Option(help: "For a recurring event: the day of the occurrence to delete; add a time if there are several that day.")
    var occurrence: String?

    @Option(help: "this or future. this: only the targeted occurrence. future: the targeted occurrence and all after it; without --occurrence, the whole series. Default: this.")
    var span = "this"

    func validate() throws {
        _ = try parseSpan(span)
    }

    func run() async throws {
        let store = try await grantedStore()
        let span = try parseSpan(span)
        let event = try findEvent(id, occurrence: occurrence, span: span, in: store)
        let result = DeletedInfo(deleted: id, title: event.title ?? "", start: iso(event.startDate), span: self.span)
        do {
            try store.remove(event, span: span, commit: true)
        } catch {
            throw IrisError("delete failed: \(error.localizedDescription)")
        }
        try emit(result)
    }
}

struct DeletedInfo: Encodable {
    let deleted: String
    let title: String
    let start: String
    let span: String
}

/// Finds the event to change. `event(withIdentifier:)` returns a recurring series' first occurrence,
/// so a recurring event needs --occurrence or --span future to say what the caller means.
func findEvent(_ id: String, occurrence: String?, span: EKSpan, in store: EKEventStore) throws -> EKEvent {
    if id.contains("NativeStorePersistentID") {
        throw IrisError("event has no stable id (Birthdays and similar calendars) and cannot be changed")
    }
    guard let event = store.event(withIdentifier: id) else { throw IrisError("no event with id \(id)") }
    guard event.calendar.allowsContentModifications else { throw IrisError("calendar \(event.calendar.title) is read-only") }
    if event.hasRecurrenceRules, occurrence == nil, span != .futureEvents {
        throw IrisError("recurring event; pass --occurrence <date> to change one occurrence, or --span future to change the whole series")
    }
    guard let occurrence else { return event }

    // The occurrence that starts on the named day; a time only chooses between several that day.
    let date = try parseDate(occurrence)
    let dayStart = Calendar.current.startOfDay(for: date)
    let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
    let predicate = store.predicateForEvents(withStart: dayStart, end: dayEnd, calendars: nil)
    // An occurrence edited earlier is detached and carries the series id plus "/RID=…".
    let nearest = store.events(matching: predicate)
        .filter { $0.eventIdentifier == id || $0.eventIdentifier?.hasPrefix(id + "/") == true }
        .filter { $0.startDate >= dayStart && $0.startDate < dayEnd }
        .min { abs($0.startDate.timeIntervalSince(date)) < abs($1.startDate.timeIntervalSince(date)) }
    guard let nearest else { throw IrisError("no occurrence of \(id) on \(iso(dayStart).prefix(10))") }
    return nearest
}

func writableCalendar(_ token: String, in store: EKEventStore) throws -> EKCalendar {
    let hits = try resolveCalendars([token], in: store) ?? []
    guard hits.count == 1 else { throw IrisError("calendar name \(token) is ambiguous; use its id from `iris calendar calendars`") }
    guard hits[0].allowsContentModifications else { throw IrisError("calendar \(token) is read-only") }
    return hits[0]
}

func save(_ event: EKEvent, span: EKSpan, in store: EKEventStore) throws {
    do {
        try store.save(event, span: span, commit: true)
    } catch {
        throw IrisError("save failed: \(error.localizedDescription)")
    }
}

func setAlarms(_ minutes: [Int], on event: EKEvent) {
    for alarm in event.alarms ?? [] { event.removeAlarm(alarm) }
    for minute in minutes { event.addAlarm(EKAlarm(relativeOffset: -Double(minute) * 60)) }
}

func parseSpan(_ text: String) throws -> EKSpan {
    switch text {
    case "this": return .thisEvent
    case "future": return .futureEvents
    default: throw ValidationError("--span must be this or future, not '\(text)'")
    }
}

func parseAvailability(_ text: String) throws -> EKEventAvailability {
    switch text {
    case "busy": return .busy
    case "free": return .free
    case "tentative": return .tentative
    case "unavailable": return .unavailable
    default: throw ValidationError("--availability must be busy, free, tentative or unavailable, not '\(text)'")
    }
}

func parseFrequency(_ text: String) throws -> EKRecurrenceFrequency {
    switch text {
    case "daily": return .daily
    case "weekly": return .weekly
    case "monthly": return .monthly
    case "yearly": return .yearly
    default: throw ValidationError("--repeat must be daily, weekly, monthly or yearly, not '\(text)'")
    }
}

func parseWeekdays(_ text: String) throws -> [EKRecurrenceDayOfWeek] {
    let weekdays: [String: EKWeekday] = ["su": .sunday, "mo": .monday, "tu": .tuesday, "we": .wednesday,
                                         "th": .thursday, "fr": .friday, "sa": .saturday]
    return try text.split(separator: ",", omittingEmptySubsequences: false).map { token in
        guard let day = weekdays[token.trimmingCharacters(in: .whitespaces).lowercased()] else {
            throw ValidationError("--on takes su,mo,tu,we,th,fr,sa, not '\(token)'")
        }
        return EKRecurrenceDayOfWeek(day)
    }
}
