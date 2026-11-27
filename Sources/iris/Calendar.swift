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

    @Option(help: allowedHelp(.calendars))
    var allowedCalendars: String?

    func validate() throws {
        _ = try allowedIds(allowedCalendars, "--allowed-calendars")
    }

    func run() async throws {
        let allowed = try allowedIds(allowedCalendars, "--allowed-calendars")
        // Nothing allowed: answered without asking Calendar.
        if allowed?.isEmpty == true { return try emit([CalendarInfo]()) }
        let store = try await grantedStore()
        let calendars = store.calendars(for: .event)
            .filter { allowed?.contains($0.calendarIdentifier) ?? true }
            .sorted { calendarPrecedes(($0.title, $0.calendarIdentifier), ($1.title, $1.calendarIdentifier)) }
            .map { CalendarInfo(id: $0.calendarIdentifier, title: $0.title,
                                writable: $0.allowsContentModifications, source: $0.source.title) }
        try emit(calendars)
    }
}

struct Events: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List events in a date range, earliest first; a tie by end, then title, calendar id and id.",
        discussion: """
            recurring: the event repeats, so changing or deleting it needs --occurrence or --span future. \
            detached: one occurrence of a repeating event that was changed on its own; it has its own id and \
            recurring is false. By that id, the default --span this changes or deletes only this occurrence; \
            --span future still reaches the occurrences after it.
            alarms: always there; one entry per timed alarm, in whole minutes before this event's start as \
            --alarm takes them, earliest first; negative is after the start. An alarm at a set time is \
            counted from this event's start, and seconds round to the nearest minute. An alarm on arriving \
            at or leaving a place is left out, so [] is no timed alarms.
            availability: busy, free, tentative or unavailable; "not supported" when the event's calendar has no \
            availability; "unknown" is a value Iris cannot name.
            organizer: {name, email, isCurrentUser}, or null. attendees: always there, [] for none, sorted by \
            email ignoring case, then name, missing ones last; each is {name, email, status, role, type, \
            isCurrentUser}. status: accepted, declined, tentative, pending, delegated, completed, in process or \
            unknown. role: required, optional, chair, non-participant or unknown. type: person, room, resource, \
            group or unknown. name can be null. email can be null: it is the participant's mailto: address, or \
            else a plain address Calendar holds for them; null when neither can be read. \
            The organizer may also be among the attendees. isCurrentUser marks the account's owner, who \
            need not be among them.
            """
    )

    @Option(help: "Range start: 2026-10-13, 2026-10-13T09:00 (local time), or ISO 8601 with an offset or Z, seconds and fractions optional. Default: start of today.")
    var from: String?

    @Option(help: "Range end, same formats; a bare date includes that whole day. Default: 7 days after --from.")
    var to: String?

    @Option(name: .customLong("calendar"), help: "Calendar id or title; repeat for several. Default: every calendar.")
    var calendars: [String] = []

    @Option(help: "Only events whose title contains this text, ignoring case. Default: every event.")
    var title: String?

    @Option(help: allowedHelp(.calendars))
    var allowedCalendars: String?

    func validate() throws {
        _ = try range()
        if title == "" { throw ValidationError("--title must not be empty") }
        _ = try allowedIds(allowedCalendars, "--allowed-calendars")
    }

    func run() async throws {
        let allowed = try allowedIds(allowedCalendars, "--allowed-calendars")
        // Nothing allowed: answered without asking Calendar, by the same rule, so any calendar named is missing.
        if allowed?.isEmpty == true {
            _ = try resolveCalendars(calendars, among: [], allowed: [])
            return try emit([EventInfo]())
        }
        let store = try await grantedStore()
        let (start, end) = try range()
        let scope = try resolveCalendars(calendars, among: store.calendars(for: .event), allowed: allowed)
        // EventKit is never given an empty list: what it does with one is not documented.
        let events = (scope?.isEmpty == true ? [] : fetchEvents(in: store, from: start, to: end, calendars: scope))
            .filter { allowed?.contains($0.calendar.calendarIdentifier) ?? true }
            .filter(matches)
            .map { (key: EventKey($0), event: $0) }
            .sorted { $0.key.precedes($1.key) }
            .map { EventInfo($0.event) }
        try emit(events)
    }

    private func matches(_ event: EKEvent) -> Bool {
        guard let title else { return true }
        return (event.title ?? "").range(of: title, options: .caseInsensitive) != nil
    }

    private func range() throws -> (Date, Date) {
        let start = try from.map(parseDate) ?? Calendar.current.startOfDay(for: Date())
        let end = try to.map(parseEnd) ?? Calendar.current.date(byAdding: .day, value: 7, to: start) ?? start
        guard start < end else { throw ValidationError("--to must be after --from") }
        return (start, end)
    }
}

/// EventKit silently caps one predicate at four years, so walk the range in three-year windows.
/// An event is taken from the window it starts in, so one spanning a boundary is not counted twice;
/// the first window also keeps events already running at `start`, as a single query would.
func fetchEvents(in store: EKEventStore, from start: Date, to end: Date, calendars: [EKCalendar]?) -> [EKEvent] {
    var events: [EKEvent] = []
    var cursor = start
    while cursor < end {
        let next = min(Calendar.current.date(byAdding: .year, value: 3, to: cursor) ?? end, end)
        let predicate = store.predicateForEvents(withStart: cursor, end: next, calendars: calendars)
        events += store.events(matching: predicate).filter { event in
            (cursor == start || event.startDate >= cursor) && (next == end || event.startDate < next)
        }
        cursor = next
    }
    return events
}

/// What events are listed by: start, then end, title, calendar id and id, the strings byte by byte, so two
/// events tie only when all five are the same. EventKit promises no order of its own.
struct EventKey {
    let start: Date
    let end: Date
    let title: String
    let calendarId: String
    let id: String

    init(start: Date, end: Date, title: String, calendarId: String, id: String) {
        self.start = start
        self.end = end
        self.title = title
        self.calendarId = calendarId
        self.id = id
    }

    init(_ event: EKEvent) {
        self.init(start: event.startDate, end: event.endDate, title: event.title ?? "",
                  calendarId: event.calendar.calendarIdentifier, id: event.eventIdentifier ?? "")
    }

    func precedes(_ other: EventKey) -> Bool {
        if start != other.start { return start < other.start }
        if end != other.end { return end < other.end }
        return [title, calendarId, id].lexicographicallyPrecedes(
            [other.title, other.calendarId, other.id], by: bytesPrecede)
    }
}

/// Calendars are listed by title, as they always were. Titles can repeat, and two that Swift calls equal can
/// still differ in their bytes, so a tie goes to the bytes and then to the id.
func calendarPrecedes(_ a: (title: String, id: String), _ b: (title: String, id: String)) -> Bool {
    if a.title != b.title { return a.title < b.title }
    return [a.title, a.id].lexicographicallyPrecedes([b.title, b.id], by: bytesPrecede)
}

func bytesPrecede(_ a: String, _ b: String) -> Bool {
    a.utf8.lexicographicallyPrecedes(b.utf8)
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
    let detached: Bool
    let availability: String
    let alarms: [Int]
    let organizer: Organizer?
    let attendees: [Attendee]

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
        detached = event.isDetached
        availability = describe(event.availability)
        alarms = alarmMinutes(event.alarms ?? [], start: event.startDate)
        organizer = event.organizer.map(Organizer.init)
        attendees = sortedAttendees((event.attendees ?? []).map(Attendee.init))
    }

    enum CodingKeys: CodingKey {
        case id, title, start, end, allDay, calendar, calendarId, location, notes, recurring, detached
        case availability, alarms, organizer, attendees
    }

    // Written out so an event without an organizer carries "organizer": null; location and notes
    // are still left out when empty.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(start, forKey: .start)
        try container.encode(end, forKey: .end)
        try container.encode(allDay, forKey: .allDay)
        try container.encode(calendar, forKey: .calendar)
        try container.encode(calendarId, forKey: .calendarId)
        try container.encodeIfPresent(location, forKey: .location)
        try container.encodeIfPresent(notes, forKey: .notes)
        try container.encode(recurring, forKey: .recurring)
        try container.encode(detached, forKey: .detached)
        try container.encode(availability, forKey: .availability)
        try container.encode(alarms, forKey: .alarms)
        try container.encode(organizer, forKey: .organizer)
        try container.encode(attendees, forKey: .attendees)
    }
}

struct Organizer: Encodable {
    let name: String?
    let email: String?
    let isCurrentUser: Bool

    init(name: String?, email: String?, isCurrentUser: Bool) {
        self.name = name
        self.email = email
        self.isCurrentUser = isCurrentUser
    }

    init(_ participant: EKParticipant) {
        self.init(name: participant.name.flatMap { $0.isEmpty ? nil : $0 },
                  email: participantEmail(participant),
                  isCurrentUser: participant.isCurrentUser)
    }

    enum CodingKeys: CodingKey { case name, email, isCurrentUser }

    // Written out so a missing name or email reads null instead of dropping the key.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(email, forKey: .email)
        try container.encode(isCurrentUser, forKey: .isCurrentUser)
    }
}

struct Attendee: Encodable {
    let name: String?
    let email: String?
    let status: String
    let role: String
    let type: String
    let isCurrentUser: Bool

    init(name: String?, email: String?, status: String, role: String, type: String, isCurrentUser: Bool) {
        self.name = name
        self.email = email
        self.status = status
        self.role = role
        self.type = type
        self.isCurrentUser = isCurrentUser
    }

    init(_ participant: EKParticipant) {
        self.init(name: participant.name.flatMap { $0.isEmpty ? nil : $0 },
                  email: participantEmail(participant),
                  status: describe(participant.participantStatus),
                  role: describe(participant.participantRole),
                  type: describe(participant.participantType),
                  isCurrentUser: participant.isCurrentUser)
    }

    enum CodingKeys: CodingKey { case name, email, status, role, type, isCurrentUser }

    // Written out so a missing name or email reads null instead of dropping the key.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(email, forKey: .email)
        try container.encode(status, forKey: .status)
        try container.encode(role, forKey: .role)
        try container.encode(type, forKey: .type)
        try container.encode(isCurrentUser, forKey: .isCurrentUser)
    }
}

/// The header promises a URL; read as optional so a nil one, never seen, cannot stop the whole listing.
private func participantURL(_ participant: EKParticipant) -> URL? {
    participant.value(forKey: "URL") as? URL
}

/// emailAddress is not documented: it is read because iCloud gives most participants a principal path
/// instead of a mailto: URL. If Apple removes it or changes its type, email is null as it was before.
private func participantEmail(_ participant: EKParticipant) -> String? {
    // The undocumented getter is called only when there is no mailto: address.
    if let mailto = emailAddress(participantURL(participant)) { return mailto }
    return participantEmail(mailto: nil, property: stringValue(of: participant, forKey: "emailAddress"))
}

/// The mailto: address if there is one, otherwise the property's value if it is shaped like an address.
func participantEmail(mailto: String?, property: String?) -> String? {
    mailto ?? property.flatMap(plainAddress)
}

/// What the getter named `key` returns, if that is a string. A getter that is not there, takes arguments or
/// returns no object (a pointer, say) cannot be called safely, and an Objective-C exception cannot be caught
/// from Swift, so all three are ruled out first, on the object's real class, and then that very method is
/// called. It is taken to return an object it still owns, as getters do. Not covered: a getter that raises
/// by itself.
func stringValue(of object: NSObject, forKey key: String) -> String? {
    let selector = NSSelectorFromString(key)
    guard object.responds(to: selector), let method = class_getInstanceMethod(object_getClass(object), selector),
          method_getNumberOfArguments(method) == 2 else { return nil }   // self and _cmd only
    let returnType = method_copyReturnType(method)
    defer { free(returnType) }
    guard String(cString: returnType) == "@" else { return nil }
    return object.perform(selector)?.takeUnretainedValue() as? String
}

private let refusedInAddress = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
    .union(CharacterSet(charactersIn: ":<>,;/\\\""))

/// The text if it is shaped like a bare address: one "@" with something on each side, a domain that
/// neither starts nor ends with ".", and no whitespace, control or format character, nor any of
/// : < > , ; / \ ". Checked scalar by scalar, so a combining mark cannot hide one. Anything else is nil.
func plainAddress(_ text: String) -> String? {
    let scalars = Array(text.unicodeScalars)
    guard let at = scalars.firstIndex(of: "@"), at == scalars.lastIndex(of: "@"),
          at > 0, at < scalars.count - 1, scalars[at + 1] != ".", scalars.last != ".",
          !scalars.contains(where: { refusedInAddress.contains($0) }) else { return nil }
    return text
}

/// EventKit returns the attendees in a different order from one read to the next, so they are sorted:
/// by email without regard to case, then by name, a missing one last; any tie left is broken by every
/// printed field, byte by byte, so the same attendees always print in the same order.
func sortedAttendees(_ attendees: [Attendee]) -> [Attendee] {
    func fields(_ attendee: Attendee) -> [String] {
        [attendee.email ?? "", attendee.name ?? "", attendee.status, attendee.role, attendee.type,
         String(attendee.isCurrentUser)]
    }
    return attendees.sorted { a, b in
        let folded = { (email: String) in email.folding(options: .caseInsensitive, locale: nil) }
        if let first = missingLast(a.email.map(folded), b.email.map(folded)) { return first }
        if let first = missingLast(a.name, b.name) { return first }
        return fields(a).lexicographicallyPrecedes(fields(b)) { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    }
}

/// Whether `a` comes before `b`, a missing value last; nil when they are equal.
private func missingLast(_ a: String?, _ b: String?) -> Bool? {
    switch (a, b) {
    case (nil, nil): return nil
    case (nil, _): return false
    case (_, nil): return true
    case let (a?, b?): return a == b ? nil : a < b
    }
}

/// The address of a mailto: URL, percent-decoded, without the scheme or a query. Any other URL is nil,
/// so it is never shown as if it were an address.
func emailAddress(_ url: URL?) -> String? {
    guard let url, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
          parts.scheme?.lowercased() == "mailto", !parts.path.isEmpty else { return nil }
    return parts.path
}

/// Each alarm in whole minutes before `start`, the unit --alarm takes, earliest alarm first.
/// An alarm at a set time counts from `start`; one after the start is negative; seconds round to
/// the nearest minute. An alarm that fires on arriving or leaving a place has no time and is left out;
/// so is one whose time is not a number, which would otherwise stop the whole listing.
func alarmMinutes(_ alarms: [EKAlarm], start: Date) -> [Int] {
    alarms
        .filter { $0.proximity == .none }
        .compactMap { minutesBefore($0, start: start) }
        .sorted(by: >)
}

/// One alarm in whole minutes before `start`, seconds rounded to the nearest minute; nil when its time is not
/// a number, or when it is at a set time and there is no `start` to count from.
func minutesBefore(_ alarm: EKAlarm, start: Date?) -> Int? {
    let secondsBefore: Double
    if let absoluteDate = alarm.absoluteDate {
        guard let start else { return nil }
        secondsBefore = start.timeIntervalSince(absoluteDate)
    } else {
        secondsBefore = -alarm.relativeOffset
    }
    return Int(exactly: (secondsBefore / 60).rounded())
}

struct IrisError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func grantedStore() async throws -> EKEventStore {
    let store = EKEventStore()
    guard try await store.requestFullAccessToEvents() else {
        let fix = EKEventStore.authorizationStatus(for: .event) == .writeOnly ? "give Iris Full Access" : "allow Iris"
        throw IrisError("calendar access denied; \(fix) under System Settings › Privacy & Security › Calendars")
    }
    return store
}

/// Match by id or title, among the allowed calendars only. A name that matches nothing is an error, never a
/// silent widening to every calendar; nil is every calendar, and only without a scope. A command with
/// nothing allowed passes no calendars, without asking Calendar.
func resolveCalendars(_ tokens: [String], among calendars: [EKCalendar], allowed: Set<String>?) throws -> [EKCalendar]? {
    let (found, missing) = pick(tokens, from: calendars, allowed: allowed, id: \.calendarIdentifier, name: \.title)
    guard missing.isEmpty else {
        throw IrisError("no calendar named \(missing.joined(separator: ", ")); see `iris calendar calendars`")
    }
    return found
}

/// ISO 8601 with an offset or Z, seconds and fractions optional; a value without an offset is read as local wall-clock time.
func parseDate(_ text: String) throws -> Date {
    let formats = [
        "yyyy-MM-dd'T'HH:mm:ss.SSSSSSXXXXX", "yyyy-MM-dd'T'HH:mm:ssXXXXX", "yyyy-MM-dd'T'HH:mmXXXXX",
        "yyyy-MM-dd'T'HH:mm:ss.SSSSSS", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd",
    ]
    for format in formats {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        if let date = formatter.date(from: text) { return date }
    }
    throw ValidationError("unrecognised date '\(text)'; use 2026-10-13, 2026-10-13T09:00, or ISO 8601 with offset")
}

/// A bare date such as 2026-10-13, at midnight in `timeZone`, the Mac's unless given; nil for anything with
/// a time.
func parseDay(_ text: String, timeZone: TimeZone = .current) -> Date? {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.date(from: text)
}

/// An end of a range: a bare date includes that whole day.
func parseEnd(_ text: String) throws -> Date {
    try parseDay(text).map(endOfDay) ?? parseDate(text)
}

/// All-day events end at 23:59:59 of their last day.
func endOfDay(_ date: Date) -> Date {
    Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: date) ?? date
}

/// All-day events run from the start of their first day to the end of their last.
func allDayBounds(_ start: Date, _ end: Date) -> (Date, Date) {
    (Calendar.current.startOfDay(for: start), endOfDay(end))
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
    case .notSupported: return "not supported"
    @unknown default: return "unknown"
    }
}

func describe(_ status: EKParticipantStatus) -> String {
    switch status {
    case .accepted: return "accepted"
    case .declined: return "declined"
    case .tentative: return "tentative"
    case .pending: return "pending"
    case .delegated: return "delegated"
    case .completed: return "completed"
    case .inProcess: return "in process"
    case .unknown: return "unknown"
    @unknown default: return "unknown"
    }
}

func describe(_ role: EKParticipantRole) -> String {
    switch role {
    case .required: return "required"
    case .optional: return "optional"
    case .chair: return "chair"
    case .nonParticipant: return "non-participant"
    case .unknown: return "unknown"
    @unknown default: return "unknown"
    }
}

func describe(_ type: EKParticipantType) -> String {
    switch type {
    case .person: return "person"
    case .room: return "room"
    case .resource: return "resource"
    case .group: return "group"
    case .unknown: return "unknown"
    @unknown default: return "unknown"
    }
}

func emit<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    print(String(decoding: try encoder.encode(value), as: UTF8.self))
}
