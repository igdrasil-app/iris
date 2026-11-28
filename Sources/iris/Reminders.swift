import ArgumentParser
import EventKit
import Foundation
import os

struct RemindersCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reminders",
        abstract: "Apple Reminders: read the lists and the reminders in them, add, change, complete and delete reminders.",
        subcommands: [ReminderLists.self, ReminderList.self, AddReminder.self, UpdateReminder.self, CompleteReminder.self, DeleteReminder.self]
    )
}

struct ReminderLists: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "lists",
        abstract: "List reminder lists: id, title, writable, source, open.",
        discussion: """
            Sorted by title as calendars are. open is how many reminders in the list are not completed. \
            `iris reminders list` reads the reminders, `iris reminders add`, `update`, `complete` and `delete` \
            add, change, complete and delete one. The first run asks for Reminders access; \
            a prompt not answered within \(reminderPromptSeconds) seconds is an error, and the call can be \
            repeated once it is answered. A denial is changed under System Settings › Privacy & Security › Reminders.
            """
    )

    @Option(help: allowedHelp(.lists))
    var allowedLists: String?

    func validate() throws {
        _ = try allowedIds(allowedLists, "--allowed-lists")
    }

    func run() async throws {
        let allowed = try allowedIds(allowedLists, "--allowed-lists")
        // Nothing allowed: answered without asking Reminders.
        if allowed?.isEmpty == true { return try emit([ReminderListInfo]()) }
        let store = try await grantedReminderStore()
        // The lists are EventKit objects read below, so their store is kept until the end.
        defer { withExtendedLifetime(store) {} }
        let lists = store.calendars(for: .reminder).filter { allowed?.contains($0.calendarIdentifier) ?? true }
        let open = openCounts(listIds: try await fetchReminders(in: store, lists: lists, status: .open).map(\.listId))
        let infos = lists
            .sorted { calendarPrecedes(($0.title, $0.calendarIdentifier), ($1.title, $1.calendarIdentifier)) }
            .map { ReminderListInfo(id: $0.calendarIdentifier, title: $0.title, writable: $0.allowsContentModifications,
                                    source: $0.source.title, open: open[$0.calendarIdentifier] ?? 0) }
        try emit(infos)
    }
}

struct ReminderListInfo: Encodable {
    let id: String
    let title: String
    let writable: Bool
    let source: String
    let open: Int
}

struct ReminderList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List reminders, open ones by default: those with a due date first, soonest first.",
        discussion: """
            Each reminder has every one of these keys; a value that is not there is null. id. title. \
            list: the list's title. listId: its id, from `iris reminders lists`. notes: null when there are \
            none. due: below. priority: none, high, medium or low (Reminders keeps 0 to 9: 0 is none, 1 to 4 \
            high, 5 medium, 6 to 9 low). completed: true or false. completedAt, created, modified: ISO 8601 in \
            this Mac's zone, or null. recurring: the reminder repeats. alarms: always there; one entry per \
            timed alarm, in whole minutes before due.at as `iris reminders add --alarm` takes them, largest \
            first, as Reminders keeps no order; negative is after it. An alarm at a set time is counted from due.at, \
            and seconds round to the nearest minute; when due.at is null (no due, date only, or a date that \
            is no moment) such an alarm cannot be counted and is left out. An alarm on arriving at or leaving \
            a place is left out too, so [] is no timed alarm that can be counted.

            due is null when the reminder has no due date. Otherwise it is {date, time, timeZone, at}, always \
            those four keys. date (YYYY-MM-DD) and time (HH:MM, or HH:MM:SS when the seconds are not zero) are \
            as kept in the reminder, never converted. timeZone is the zone the time is kept in. at is that \
            moment in ISO 8601 in this Mac's zone. Four shapes:
            - Date only, say due on 2026-10-13 at no set time: date is 2026-10-13, and time, timeZone and at \
            are null.
            - A time in this Mac's zone, say 09:30 on 2026-10-13: date and time say so, timeZone is this \
            Mac's zone, and at shows the same date and time.
            - A time in another zone, say 09:00 in Asia/Tokyo: date and time say 09:00 that day, timeZone \
            says Asia/Tokyo, and at is that moment as it is here.
            - A floating time, kept without a zone, which each device reads as its own clock time, say 14:00: \
            time says 14:00, timeZone is null, and at is 14:00 that day on this Mac, in its zone now; a Mac \
            in another zone gives another at.
            at is also null when the date and time kept do not name a moment, as 30 February does not. A \
            clock time the zone skips when its clocks go forward does name one: the system reads it as the \
            later time, so where clocks jump from 02:00 to 03:00 a time of 02:30 is read as 03:30 there. at \
            is that moment in this Mac's zone, while time still says 02:30.

            --due-from and --due-to keep the reminders due in that range, both ends included. Without either, \
            every reminder is listed, with or without a due date; with either, one without a due date is left \
            out. A due with a time goes by at. A date-only due goes by its day against the days of --due-from \
            and --due-to on this Mac's calendar, so --due-from 2026-10-13T15:00 --due-to 2026-10-13 finds a \
            reminder due on 2026-10-13 with no time. A due with a time whose at is null goes by its date, as \
            date only.

            Order: reminders with a due date first, by day (a due with a time on the day of its at, on this \
            Mac, so a Mac in another zone can order them differently), on the same day date only first, then \
            by at, a time whose at is null last; then those without a due date, newest created first, those \
            without a created date last. A tie goes to the title byte by byte, then listId, then id.

            Not visible here: subtasks, tags, flags and sections. A subtask reads as an ordinary reminder. A \
            completed occurrence of a repeating reminder reads as a separate completed reminder with recurring \
            false. URL, location, start date and how a reminder repeats are not shown. `iris reminders \
            add`, `update`, `complete` and `delete` add, change, complete and delete one.
            """
    )

    @Option(name: .customLong("list"),
            help: "List id or title, from `iris reminders lists`; repeat for several. A name that matches nothing is an error. Default: every list.")
    var lists: [String] = []

    @Option(help: "open (not completed), completed or all.")
    var status: ReminderStatus = .open

    @Option(help: "Only reminders due at or after this: 2026-10-13, 2026-10-13T09:00 (local time), or ISO 8601 with an offset or Z. Default: no lower bound.")
    var dueFrom: String?

    @Option(help: "Only reminders due at or before this, same formats; a bare date includes that whole day. Default: no upper bound.")
    var dueTo: String?

    @Option(help: allowedHelp(.lists))
    var allowedLists: String?

    func validate() throws {
        _ = try dueRange()
        _ = try allowedIds(allowedLists, "--allowed-lists")
    }

    func run() async throws {
        let (from, to) = try dueRange()
        let allowed = try allowedIds(allowedLists, "--allowed-lists")
        // Nothing allowed: answered without asking Reminders, by the same rule, so any list named is missing.
        if allowed?.isEmpty == true {
            _ = try resolveLists(lists, among: [], allowed: [])
            return try emit([Reminder]())
        }
        let store = try await grantedReminderStore()
        let found = try resolveLists(lists, among: store.calendars(for: .reminder), allowed: allowed)
        let mac = macCalendar()
        // fetchReminders answers an empty list of lists with none, never every list.
        let reminders = try await fetchReminders(in: store, lists: found, status: status, mac: mac)
            .filter { allowed?.contains($0.listId) ?? true }
            .filter { dueInRange($0.due, from: from, to: to, mac: mac) }
            .sorted(by: reminderPrecedes)
        try emit(reminders)
    }

    private func dueRange() throws -> (Date?, Date?) {
        let from = try dueFrom.map(parseDate)
        let to = try dueTo.map(parseEnd)
        if let from, let to, from > to { throw ValidationError("--due-from must not be after --due-to") }
        return (from, to)
    }
}

enum ReminderStatus: String, CaseIterable, ExpressibleByArgument {
    case open, completed, all
}

/// A reminder as listed, copied out of EventKit.
struct Reminder: Encodable {
    let id: String
    let title: String
    let list: String
    let listId: String
    let notes: String?
    let due: Due?
    let priority: String
    let completed: Bool
    let completedAt: Date?
    let created: Date?
    let modified: Date?
    let recurring: Bool
    let alarms: [Int]

    enum CodingKeys: CodingKey {
        case id, title, list, listId, notes, due, priority, completed, completedAt, created, modified, recurring, alarms
    }

    // Written out so a missing value reads null instead of dropping the key.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(list, forKey: .list)
        try container.encode(listId, forKey: .listId)
        try container.encode(notes, forKey: .notes)
        try container.encode(due, forKey: .due)
        try container.encode(priority, forKey: .priority)
        try container.encode(completed, forKey: .completed)
        try container.encode(completedAt.map(reminderISO), forKey: .completedAt)
        try container.encode(created.map(reminderISO), forKey: .created)
        try container.encode(modified.map(reminderISO), forKey: .modified)
        try container.encode(recurring, forKey: .recurring)
        try container.encode(alarms, forKey: .alarms)
    }
}

extension Reminder {
    init(_ reminder: EKReminder, mac: Calendar) {
        let due = reminderDue(reminder.dueDateComponents, mac: mac)
        self.init(id: reminder.calendarItemIdentifier, title: reminder.title ?? "",
                  list: reminder.calendar?.title ?? "", listId: reminder.calendar?.calendarIdentifier ?? "",
                  notes: reminder.notes.flatMap { $0.isEmpty ? nil : $0 },
                  due: due, priority: priorityWord(reminder.priority),
                  completed: reminder.isCompleted, completedAt: reminder.completionDate,
                  created: reminder.creationDate, modified: reminder.lastModifiedDate,
                  recurring: reminder.hasRecurrenceRules,
                  alarms: reminderAlarmMinutes(reminder.alarms ?? [], due: due?.at))
    }
}

/// A reminder's timed alarms in whole minutes before its due moment, largest first, as Reminders keeps no order. An
/// alarm at a set time needs that moment to count from, so without one (no due, date only, or a date that is
/// no moment) it is left out; so is an alarm on arriving at or leaving a place.
func reminderAlarmMinutes(_ alarms: [EKAlarm], due: Date?) -> [Int] {
    alarms.filter(isTimedAlarm).compactMap { minutesBefore($0, start: due) }.sorted(by: >)
}

/// An alarm that fires at a time, not on arriving at or leaving a place.
func isTimedAlarm(_ alarm: EKAlarm) -> Bool {
    alarm.structuredLocation == nil && alarm.proximity == .none
}

/// When a reminder is due. date and time are as kept in the reminder; at is the moment, nil for date only.
struct Due: Encodable, Equatable {
    let date: String
    let time: String?
    let timeZone: String?
    let at: Date?
    /// The day it is listed and filtered under: for a due with a moment, that moment's day on this Mac;
    /// otherwise its own date.
    let day: Day

    /// On one day: date only first, then a due with a moment, then one with a time that names none.
    var rankInDay: Int { time == nil ? 0 : at == nil ? 2 : 1 }

    enum CodingKeys: CodingKey { case date, time, timeZone, at }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(date, forKey: .date)
        try container.encode(time, forKey: .time)
        try container.encode(timeZone, forKey: .timeZone)
        try container.encode(at.map(reminderISO), forKey: .at)
    }
}

struct Day: Comparable {
    let year: Int
    let month: Int
    let day: Int

    init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    init(_ date: Date, in calendar: Calendar) {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: parts.year ?? 0, month: parts.month ?? 0, day: parts.day ?? 0)
    }

    static func < (a: Day, b: Day) -> Bool {
        (a.year, a.month, a.day) < (b.year, b.month, b.day)
    }
}

/// The Gregorian calendar in this Mac's zone. Reminders keep Gregorian dates whatever calendar the Mac shows.
func macCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    return calendar
}

/// The due from a reminder's date components; nil when there is none, or no year, month and day. Only
/// year to second and the zone are read. A time without a zone is floating: its moment is that clock time
/// in `mac`'s zone.
func reminderDue(_ components: DateComponents?, mac: Calendar) -> Due? {
    guard let components, let year = components.year, let month = components.month, let day = components.day else {
        return nil
    }
    let date = String(format: "%04ld-%02ld-%02ld", year, month, day)
    let ownDay = Day(year: year, month: month, day: day)
    guard let hour = components.hour else {
        return Due(date: date, time: nil, timeZone: nil, at: nil, day: ownDay)
    }
    let minute = components.minute ?? 0
    let second = components.second ?? 0
    let time = second == 0 ? String(format: "%02ld:%02ld", hour, minute)
                           : String(format: "%02ld:%02ld:%02ld", hour, minute, second)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = components.timeZone ?? mac.timeZone
    let at = moment(year, month, day, hour, minute, second, in: calendar)
    return Due(date: date, time: time, timeZone: components.timeZone?.identifier, at: at,
               day: at.map { Day($0, in: mac) } ?? ownDay)
}

/// nil when a part is out of range: Calendar would roll it into another day instead.
private func moment(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int,
                    in calendar: Calendar) -> Date? {
    guard (1...12).contains(month), (0...23).contains(hour), (0...59).contains(minute), (0...59).contains(second),
          let first = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
          let days = calendar.range(of: .day, in: .month, for: first), days.contains(day) else { return nil }
    return calendar.date(from: DateComponents(year: year, month: month, day: day,
                                              hour: hour, minute: minute, second: second))
}

/// The word for EventKit's priority, 0 to 9. Anything else, which Reminders cannot save, reads none.
func priorityWord(_ priority: Int) -> String {
    switch priority {
    case 1...4: return "high"
    case 5: return "medium"
    case 6...9: return "low"
    default: return "none"
    }
}

/// Whether a reminder due `due` passes --due-from and --due-to, either of which can be absent. A moment is
/// compared as it is; a due without one by its day against the days of the bounds on `mac`.
func dueInRange(_ due: Due?, from: Date?, to: Date?, mac: Calendar) -> Bool {
    if from == nil && to == nil { return true }
    guard let due else { return false }
    if let at = due.at {
        return (from.map { $0 <= at } ?? true) && (to.map { at <= $0 } ?? true)
    }
    return (from.map { Day($0, in: mac) <= due.day } ?? true) && (to.map { due.day <= Day($0, in: mac) } ?? true)
}

/// Reminders are listed by due day, date only before a time that day, then by moment; those with no due
/// date after, newest created first, no created date last. A tie goes to title, list id and id, byte by
/// byte, so two reminders tie only when all three are the same. EventKit's own order means nothing.
func reminderPrecedes(_ a: Reminder, _ b: Reminder) -> Bool {
    switch (a.due, b.due) {
    case let (x?, y?):
        if x.day != y.day { return x.day < y.day }
        if x.rankInDay != y.rankInDay { return x.rankInDay < y.rankInDay }
        if let p = x.at.map(wholeSecond), let q = y.at.map(wholeSecond), p != q { return p < q }
    case (.some, nil):
        return true
    case (nil, .some):
        return false
    case (nil, nil):
        if let first = newerFirst(a.created, b.created) { return first }
    }
    return [a.title, a.listId, a.id].lexicographicallyPrecedes([b.title, b.listId, b.id], by: bytesPrecede)
}

/// Whether `a` comes before `b`, the later first and a missing one last; nil when they are the same.
private func newerFirst(_ a: Date?, _ b: Date?) -> Bool? {
    switch (a, b) {
    case (nil, nil): return nil
    case (nil, _): return false
    case (_, nil): return true
    case let (a?, b?): return wholeSecond(a) == wholeSecond(b) ? nil : wholeSecond(a) > wholeSecond(b)
    }
}

/// Times are ordered and printed by the whole second they fall in, so the order can be told from the
/// output and a fraction nobody sees never decides it.
func wholeSecond(_ date: Date) -> Int {
    Int(date.timeIntervalSince1970.rounded(.down))
}

/// A reminder's time as printed: cut to its whole second first, since the formatter would round a late
/// fraction up into the next second and so disagree with the order.
func reminderISO(_ date: Date) -> String {
    iso(Date(timeIntervalSince1970: TimeInterval(wholeSecond(date))))
}

/// How long a person at the Mac has to answer the Reminders prompt before the command gives up.
let reminderPromptSeconds = 30

func grantedReminderStore() async throws -> EKEventStore {
    let store = EKEventStore()
    switch EKEventStore.authorizationStatus(for: .reminder) {
    case .fullAccess:
        return store
    case .notDetermined:
        if try await reminderAccess(within: Double(reminderPromptSeconds), { try await store.requestFullAccessToReminders() }) {
            return store
        }
    default:
        break
    }
    throw IrisError("reminders access denied; allow Iris under System Settings › Privacy & Security › Reminders")
}

/// The answer to `request`, which asks for access. An unanswered prompt keeps the request waiting for as long
/// as it is on screen, so after `seconds` this gives up with an error and leaves the request behind.
func reminderAccess(within seconds: Double, _ request: @escaping @Sendable () async throws -> Bool) async throws -> Bool {
    let answered = OSAllocatedUnfairLock(initialState: false)
    return try await withCheckedThrowingContinuation { continuation in
        // Whichever comes first, the answer or the time limit, resumes; the other is ignored.
        @Sendable func finish(_ result: Result<Bool, Error>) {
            let first = answered.withLock { done in
                guard !done else { return false }
                done = true
                return true
            }
            if first { continuation.resume(with: result) }
        }
        Task {
            do { finish(.success(try await request())) } catch { finish(.failure(error)) }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
            finish(.failure(IrisError("Reminders access was not answered within \(Int(seconds)) seconds: a prompt "
                + "asking to give Iris access to Reminders is waiting on this Mac's screen; repeat the call once it is answered")))
        }
    }
}

/// Match by id or title, among the allowed lists only; one outside them is missing, as one that does not
/// exist. A name that matches nothing is an error. nil is every list, and only without a scope.
func resolveLists(_ tokens: [String], among lists: [EKCalendar], allowed: Set<String>?) throws -> [EKCalendar]? {
    let (found, missing) = pick(tokens, from: lists, allowed: allowed, id: \.calendarIdentifier, name: \.title)
    guard missing.isEmpty else {
        throw IrisError("no reminder list named \(missing.joined(separator: ", ")); see `iris reminders lists`")
    }
    return found
}

/// The reminders of the given lists with that status, copied out of EventKit while the store is alive;
/// nil lists is every list. No dates go to EventKit: its due-date range leaves out reminders without one
/// and misreads date-only ones, so the due filter is `dueInRange`.
func fetchReminders(in store: EKEventStore, lists: [EKCalendar]?, status: ReminderStatus,
                    mac: Calendar = macCalendar()) async throws -> [Reminder] {
    // EventKit reads an empty list of lists as every list.
    if lists?.isEmpty == true { return [] }
    let predicate = switch status {
    case .open: store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: lists)
    case .completed: store.predicateForCompletedReminders(withCompletionDateStarting: nil, ending: nil, calendars: lists)
    case .all: store.predicateForReminders(in: lists)
    }
    return try await withCheckedThrowingContinuation { continuation in
        store.fetchReminders(matching: predicate) { reminders in
            guard let reminders else {
                return continuation.resume(throwing: IrisError("Reminders did not return the reminders; try again"))
            }
            continuation.resume(returning: reminders.map { Reminder($0, mac: mac) })
        }
    }
}

func openCounts(listIds: [String]) -> [String: Int] {
    listIds.reduce(into: [:]) { counts, id in counts[id, default: 0] += 1 }
}
