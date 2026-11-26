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

    @Option(help: "busy, free, tentative or unavailable; an error if the calendar does not support that value. Default: Calendar's own, busy where the calendar has availability; elsewhere the event reads \"not supported\".")
    var availability: String?

    @Option(name: .customLong("alarm"), help: "Alarm this many minutes before the start; repeat for several. Read back in the event's alarms. Default: no alarms.")
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

    @Option(help: allowedHelp(.calendars))
    var allowedCalendars: String?

    func validate() throws {
        _ = try allowedIds(allowedCalendars, "--allowed-calendars")
        _ = try availability.map(parseAvailability)
        if alarms.contains(where: { $0 < 0 }) { throw ValidationError("--alarm takes minutes of 0 or more") }
        if let url, URL(string: url)?.scheme == nil { throw ValidationError("--url needs a scheme, like https://example.com") }
        try checkRepeat(repeatFrequency, every: every, on: on, until: until, count: count)
        let (startDate, _) = try dates()
        if let until, try parseEnd(until) < startDate { throw ValidationError("--until must not be before --start") }
    }

    func run() async throws {
        let store = try await grantedStore()
        let allowed = try allowedIds(allowedCalendars, "--allowed-calendars")
        let target = try writableCalendar(calendar, in: store, allowed: allowed)
        let newAvailability = try availability.map { try supportedAvailability($0, in: target) }
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
        if let newAvailability { event.availability = newAvailability }
        setAlarms(alarms, on: event)
        if let repeatFrequency {
            event.recurrenceRules = [try recurrenceRule(repeatFrequency, every: every, on: on,
                                                        until: until.map(parseEnd), count: count)]
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
}

/// The usage errors of --repeat, --every, --on, --until and --count, as `calendar add` and `reminders add`
/// take them.
func checkRepeat(_ frequency: String?, every: Int?, on: String?, until: String?, count: Int?) throws {
    if frequency == nil, every != nil || on != nil || until != nil || count != nil {
        throw ValidationError("--every, --on, --until and --count need --repeat")
    }
    if until != nil, count != nil { throw ValidationError("use --until or --count, not both") }
    if let every, every < 1 { throw ValidationError("--every must be 1 or more") }
    if let count, count < 1 { throw ValidationError("--count must be 1 or more") }
    if on != nil, frequency != "weekly" { throw ValidationError("--on only works with --repeat weekly") }
    _ = try frequency.map(parseFrequency)
    _ = try on.map(parseWeekdays)
}

/// A new rule from --repeat, --every, --on and an end, a date or a count. Each item gets its own rule object.
func recurrenceRule(_ frequency: String, every: Int?, on: String?, until: Date?, count: Int?) throws -> EKRecurrenceRule {
    let recurrenceEnd: EKRecurrenceEnd?
    if let until {
        recurrenceEnd = EKRecurrenceEnd(end: until)
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

    @Option(help: "busy, free, tentative or unavailable; an error if the calendar (with --calendar, the new one) does not support that value. Default: unchanged, as far as the calendar supports it.")
    var availability: String?

    @Option(name: .customLong("alarm"), help: "Alarm this many minutes before the start; repeat for several. Replaces all existing alarms. Read back in the event's alarms. Default: alarms unchanged.")
    var alarms: [Int] = []

    @Flag(help: "Remove all alarms. Default: alarms unchanged.")
    var noAlarms = false

    @Option(help: "For a recurring event: the day of the occurrence to change; add a time if there are several that day: the one nearest it is taken, and a tie is refused.")
    var occurrence: String?

    @Option(help: "this or future. this: only the targeted occurrence. future: the targeted occurrence and all after it; without --occurrence, the whole series. Default: this.")
    var span = "this"

    @Option(help: allowedHelp(.calendars))
    var allowedCalendars: String?

    @Flag(help: onlyMineHelp)
    var onlyMine = false

    func validate() throws {
        _ = try allowedIds(allowedCalendars, "--allowed-calendars")
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
        let allowed = try allowedIds(allowedCalendars, "--allowed-calendars")
        let event = try findEvent(id, occurrence: occurrence, span: span, in: store, allowed: allowed)
        if onlyMine { try refuseShared(event, span: span, changing: "changing", "changed") }
        let target = try calendar.map { try writableCalendar($0, in: store, allowed: allowed) }
        let newAvailability = try availability.map { try supportedAvailability($0, in: target ?? event.calendar) }

        if let title { event.title = title }
        if let location { event.location = location }
        if let notes { event.notes = notes }
        if let url { event.url = url.isEmpty ? nil : URL(string: url) }
        // The calendar first: EventKit drops an availability the event's calendar does not support.
        if let target { event.calendar = target }
        if let newAvailability { event.availability = newAvailability }
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

    @Option(help: "For a recurring event: the day of the occurrence to delete; add a time if there are several that day: the one nearest it is taken, and a tie is refused.")
    var occurrence: String?

    @Option(help: "this or future. this: only the targeted occurrence. future: the targeted occurrence and all after it; without --occurrence, the whole series. Default: this.")
    var span = "this"

    @Option(help: allowedHelp(.calendars))
    var allowedCalendars: String?

    @Flag(help: onlyMineHelp)
    var onlyMine = false

    func validate() throws {
        _ = try allowedIds(allowedCalendars, "--allowed-calendars")
        _ = try parseSpan(span)
    }

    func run() async throws {
        let store = try await grantedStore()
        let span = try parseSpan(span)
        let allowed = try allowedIds(allowedCalendars, "--allowed-calendars")
        let event = try findEvent(id, occurrence: occurrence, span: span, in: store, allowed: allowed)
        if onlyMine { try refuseShared(event, span: span, changing: "deleting", "deleted") }
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

let onlyMineHelp: ArgumentHelp = """
    Refuse, with nothing changed, an event that has anyone on it but you: an attendee or an organizer \
    who is not you; and --span future on a repeating event, since the people on later occurrences cannot \
    be checked. `iris mcp --http` passes it unless its scope file says "sharedEvents": true. \
    Default: off.
    """

/// How many people besides the Mac's owner are on an event: its attendees who are not the current user,
/// and its organizer when that is not the current user either. An organizer who is also listed as an
/// attendee, by the same email ignoring case, is counted once. 0 means the event is the owner's alone.
func otherPeople(organizer: Organizer?, attendees: [Attendee]) -> Int {
    let others = attendees.filter { !$0.isCurrentUser }
    guard let organizer, !organizer.isCurrentUser else { return others.count }
    let folded = { (email: String) in email.folding(options: .caseInsensitive, locale: nil) }
    let listed = organizer.email.map { email in others.contains { $0.email.map(folded) == folded(email) } } ?? false
    return others.count + (listed ? 0 : 1)
}

/// With --only-mine: an event with other people on it is refused before anything about it is changed.
/// `doing` and `done` name the change in the message, as in "deleting" and "deleted".
func refuseShared(_ event: EKEvent, span: EKSpan, changing doing: String, _ done: String) throws {
    try refuseUncheckedSpan(span, recurring: event.hasRecurrenceRules, detached: event.isDetached, changing: doing, done)
    try refuseShared(organizer: event.organizer.map(Organizer.init), attendees: (event.attendees ?? []).map(Attendee.init),
                     changing: doing, done)
}

/// With --only-mine a change that reaches the occurrences after this one is refused: only this occurrence's
/// people can be read, and a later occurrence changed on its own can have others on it.
func refuseUncheckedSpan(_ span: EKSpan, recurring: Bool, detached: Bool, changing doing: String, _ done: String) throws {
    guard span == .futureEvents, recurring || detached else { return }
    throw IrisError("with only-mine on, \(doing) all future occurrences is refused, since the people on each of them "
        + "cannot be checked, so nothing was \(done). Change one occurrence at a time, or do it in Calendar on the Mac.")
}

func refuseShared(organizer: Organizer?, attendees: [Attendee], changing doing: String, _ done: String) throws {
    let count = otherPeople(organizer: organizer, attendees: attendees)
    guard count > 0 else { return }
    let people = count == 1 ? "1 other person" : "\(count) other people"
    throw IrisError("this event has \(people) on it, and \(doing) it would affect them, so nothing was \(done). "
        + "With only-mine on, only events that are the Mac owner's alone can be \(done); "
        + "this one has to be \(done) in Calendar on the Mac.")
}

/// Finds the event to change. `event(withIdentifier:)` returns a recurring series' first occurrence,
/// so a recurring event needs --occurrence or --span future to say what the caller means.
/// An event in a calendar outside `allowed` is not found, before anything else is said about it.
func findEvent(_ id: String, occurrence: String?, span: EKSpan, in store: EKEventStore,
               allowed: Set<String>?) throws -> EKEvent {
    if id.contains("NativeStorePersistentID") {
        throw IrisError("event has no stable id (Birthdays and similar calendars) and cannot be changed")
    }
    // event(withIdentifier:) raises an Objective-C exception, which Swift cannot catch, when given a
    // reminder's id, also as the part after a slash; such an id names no event.
    let parts = [id] + id.split(separator: "/").map(String.init).filter { $0 != id }
    if parts.contains(where: { store.calendarItem(withIdentifier: $0) is EKReminder }) {
        throw IrisError("no event with id \(id)")
    }
    let isAllowed = { (event: EKEvent) in allowed?.contains(event.calendar.calendarIdentifier) ?? true }
    guard let event = store.event(withIdentifier: id), isAllowed(event) else { throw IrisError("no event with id \(id)") }
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
    let candidates = store.events(matching: predicate)
        .filter { $0.eventIdentifier == id || $0.eventIdentifier?.hasPrefix(id + "/") == true }
        .filter { $0.startDate >= dayStart && $0.startDate < dayEnd && isAllowed($0) }
    let nearest: EKEvent
    switch nearestStart(candidates.map(\.startDate), to: date) {
    case .none:
        throw IrisError("no occurrence of \(id) on \(iso(dayStart).prefix(10))")
    case .tie:
        // EventKit lists events in no promised order, so taking either could change a different one each time.
        throw IrisError("more than one occurrence of \(id) on \(iso(dayStart).prefix(10)) is equally near \(occurrence), "
            + "so nothing was changed. If their starts differ, give --occurrence the exact start of the one you "
            + "mean; if they start together, use the id of the occurrence that was changed on its own, as "
            + "`iris calendar events` shows it.")
    case .unique(let index):
        nearest = candidates[index]
    }
    // Checked on the occurrence itself too, not only on its series.
    guard nearest.calendar.allowsContentModifications else {
        throw IrisError("calendar \(nearest.calendar.title) is read-only")
    }
    return nearest
}

enum NearestStart: Equatable {
    case none
    case unique(Int)
    case tie
}

/// Which of `starts` is nearest `wanted`: its index when only one is that near, `.tie` when several are.
func nearestStart(_ starts: [Date], to wanted: Date) -> NearestStart {
    let distances = starts.map { abs($0.timeIntervalSince(wanted)) }
    guard let least = distances.min() else { return .none }
    let nearest = distances.indices.filter { distances[$0] == least }
    return nearest.count == 1 ? .unique(nearest[0]) : .tie
}

/// The one writable calendar `token` names among the allowed ones; any other is not found.
func writableCalendar(_ token: String, in store: EKEventStore, allowed: Set<String>?) throws -> EKCalendar {
    let hits = try resolveCalendars([token], among: store.calendars(for: .event), allowed: allowed) ?? []
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

/// The value to set, refused when the calendar does not support it: EventKit would drop it without an error.
func supportedAvailability(_ text: String, in calendar: EKCalendar) throws -> EKEventAvailability {
    let value = try parseAvailability(text)
    let supported = availabilities(in: calendar.supportedEventAvailabilities)
    guard supported.contains(value) else {
        let names = supported.map(describe).joined(separator: ", ")
        throw IrisError("calendar \(calendar.title) "
            + (supported.isEmpty ? "supports no availability" : "supports only availability \(names), not \(text)"))
    }
    return value
}

/// The values a calendar supports; EventKit numbers them differently in the mask.
func availabilities(in mask: EKCalendarEventAvailabilityMask) -> [EKEventAvailability] {
    let bits: [(EKCalendarEventAvailabilityMask, EKEventAvailability)] = [
        (.busy, .busy), (.free, .free), (.tentative, .tentative), (.unavailable, .unavailable),
    ]
    return bits.filter { mask.contains($0.0) }.map { $0.1 }
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
