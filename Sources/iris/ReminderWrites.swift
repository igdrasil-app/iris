import ArgumentParser
import EventKit
import Foundation

struct AddReminder: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Create a reminder. Prints it as `iris reminders list` does.",
        discussion: """
            Prints the reminder with the 12 keys of `iris reminders list`, read back after the save.

            --due takes three forms:
            - A bare date, 2026-10-13: due that day at no set time. date is 2026-10-13; time, timeZone and \
            at are null.
            - A date and time, 2026-10-13T09:30: that clock time in this Mac's zone. time is 09:30, timeZone \
            is this Mac's zone.
            - A date and time with an offset or Z, 2026-10-13T09:30+09:00: that moment, kept as this Mac's \
            clock time then, in this Mac's zone. time reads back as this Mac's clock time, not 09:30; at is \
            the moment given.
            Seconds are kept; fractions of a second are dropped. A moment in the second pass of the hour \
            that comes twice when this Mac's clocks go back is refused: a reminder keeps a clock time and \
            could not tell it from the first.

            No alarm is set, whatever the due, and nothing here promises a notification. Not offered: \
            alarms, URL, location, repeating, start date, completed.
            """
    )

    @Option(help: "List id or title, from `iris reminders lists`. Required. Must name one list, and it must be writable.")
    var list: String

    @Option(help: "Title. Required; not empty or only whitespace.")
    var title: String

    @Option(help: "Notes. An empty string means none. Default: none.")
    var notes: String?

    @Option(help: "Due date: 2026-10-13 (date only), 2026-10-13T09:00 (this Mac's time), or ISO 8601 with an offset or Z. Default: no due date.")
    var due: String?

    @Option(help: "Priority, in the words `iris reminders list` prints.")
    var priority: ReminderPriority = .none

    func validate() throws {
        guard isValidTitle(title) else { throw ValidationError("--title must not be empty") }
        _ = try due.map { try dueComponents($0, mac: macCalendar()) }
    }

    func run() async throws {
        let mac = macCalendar()
        let dueParts = try due.map { try dueComponents($0, mac: mac) }
        let store = try await grantedReminderStore()
        let target = try writableList(list, in: store, allowed: nil)

        let reminder = EKReminder(eventStore: store)
        reminder.calendar = target
        reminder.title = title
        reminder.notes = notes.flatMap { $0.isEmpty ? nil : $0 }
        reminder.dueDateComponents = dueParts
        reminder.priority = priority.value

        do {
            try store.save(reminder, commit: true)
        } catch {
            throw IrisError("save failed: \(error.localizedDescription)")
        }
        try emit(Reminder(reminder, mac: mac))
    }
}

struct UpdateReminder: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Change a reminder. Only the fields you name change. Prints it as `iris reminders list` does.",
        discussion: """
            Prints the reminder with the 12 keys of `iris reminders list`, read back after the save. Name at \
            least one option. The id stays the same, also when the reminder moves to another list. A \
            reminder in a read-only list cannot be changed.

            --due takes the forms of `iris reminders add`; an empty string clears the due date. The start \
            date Reminders keeps follows it: set to the due for a time, to 00:00 that day for a bare date, \
            as Reminders sets it when a reminder is first saved, and cleared with the due date. Without \
            --due the start date is left as it is, also one that differs from the due.

            --due is refused, with nothing changed, whatever its value, the same one included:
            - when the reminder has an alarm. An alarm set in Reminders would stay at its old time, and iris \
            cannot move it: change the time in Reminders.
            - when the reminder repeats. Its due date anchors every later occurrence, and iris does not \
            change a series yet: change it in Reminders.
            Its title, notes, priority and list can still be changed.

            Alarms are never added, moved or removed, and completed stays as it is. Not offered: alarms, \
            URL, location, repeating, start date, completed.
            """
    )

    @Argument(help: "Reminder id, from `iris reminders list`.")
    var id: String

    @Option(help: "New title; not empty or only whitespace.")
    var title: String?

    @Option(help: "New notes. An empty string clears them.")
    var notes: String?

    @Option(help: "New due date: 2026-10-13 (date only), 2026-10-13T09:00 (this Mac's time), or ISO 8601 with an offset or Z, as `iris reminders add` takes it. An empty string clears it. Refused when the reminder has an alarm or repeats.")
    var due: String?

    @Option(help: "New priority, in the words `iris reminders list` prints.")
    var priority: ReminderPriority?

    @Option(help: "Move the reminder to this list: id or title, from `iris reminders lists`. Must name one list, and it must be writable.")
    var list: String?

    func validate() throws {
        if title == nil, notes == nil, due == nil, priority == nil, list == nil {
            throw ValidationError("name at least one of --title, --notes, --due, --priority, --list")
        }
        if let title, !isValidTitle(title) { throw ValidationError("--title must not be empty") }
        _ = try newDue(mac: macCalendar())
    }

    func run() async throws {
        let mac = macCalendar()
        // nil both when --due is not given and when it is empty; `due != nil` below tells them apart.
        let dueParts = try newDue(mac: mac)
        let store = try await grantedReminderStore()
        let reminder = try findReminder(id, in: store, allowed: nil)
        guard let current = reminder.calendar, current.allowsContentModifications else {
            throw IrisError("list \(reminder.calendar?.title ?? "") is read-only")
        }
        let target = try list.map { try writableList($0, in: store, allowed: nil) }
        // The alarms themselves are read: only they say for certain whether there is one.
        let hasAlarms = !(reminder.alarms ?? []).isEmpty
        if due != nil, let refusal = dueChangeRefusal(hasAlarms: hasAlarms, repeats: reminder.hasRecurrenceRules) {
            throw IrisError(refusal)
        }

        if let title { reminder.title = title }
        if let notes { reminder.notes = notes.isEmpty ? nil : notes }
        if let priority { reminder.priority = priority.value }
        if let target, target.calendarIdentifier != current.calendarIdentifier { reminder.calendar = target }
        if due != nil {
            reminder.dueDateComponents = dueParts
            reminder.startDateComponents = dueParts.map(startComponents)
        }

        do {
            try store.save(reminder, commit: true)
        } catch {
            throw IrisError("save failed: \(error.localizedDescription)")
        }
        try emit(Reminder(reminder, mac: mac))
    }

    /// The due --due asks for; nil when it is not given or is empty, which clears the due date.
    private func newDue(mac: Calendar) throws -> DateComponents? {
        guard let due, !due.isEmpty else { return nil }
        return try dueComponents(due, mac: mac)
    }
}

/// Why the due date of a reminder cannot be changed here, or nil when it can.
func dueChangeRefusal(hasAlarms: Bool, repeats: Bool) -> String? {
    if hasAlarms {
        return "this reminder has an alarm set in Reminders, which would stay at its old time if the due date "
            + "changed, and iris cannot move it, so nothing was changed. Change the time in Reminders."
    }
    if repeats {
        return "this reminder repeats, and iris does not change the due date of a repeating reminder, so nothing "
            + "was changed. Change it in Reminders."
    }
    return nil
}

/// The start date Reminders itself sets when a reminder with this due is first saved: the due for a time,
/// 00:00 with no zone on that day for a bare date.
func startComponents(_ due: DateComponents) -> DateComponents {
    guard due.hour == nil else { return due }
    return DateComponents(year: due.year, month: due.month, day: due.day, hour: 0, minute: 0, second: 0)
}

struct DeleteReminder: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete a reminder. Prints {deleted, title, list, listId} as JSON.",
        discussion: """
            A repeating reminder is deleted whole, with every later occurrence; Reminders has no way to \
            delete one occurrence. Deleting an id a second time is an error, as is any id that is not a \
            reminder's.
            """
    )

    @Argument(help: "Reminder id, from `iris reminders list`.")
    var id: String

    func run() async throws {
        let store = try await grantedReminderStore()
        let reminder = try findReminder(id, in: store, allowed: nil)
        let list = reminder.calendar
        guard list?.allowsContentModifications == true else {
            throw IrisError("list \(list?.title ?? "") is read-only")
        }
        let result = DeletedReminder(deleted: id, title: reminder.title ?? "", list: list?.title ?? "",
                                     listId: list?.calendarIdentifier ?? "")
        do {
            try store.remove(reminder, commit: true)
        } catch {
            throw IrisError("delete failed: \(error.localizedDescription)")
        }
        try emit(result)
    }
}

struct DeletedReminder: Encodable {
    let deleted: String
    let title: String
    let list: String
    let listId: String
}

/// The priority words `iris reminders list` prints, with the value Reminders keeps for each.
enum ReminderPriority: String, CaseIterable, ExpressibleByArgument {
    case none, low, medium, high

    var value: Int {
        switch self {
        case .none: return 0
        case .low: return 9
        case .medium: return 5
        case .high: return 1
        }
    }
}

func isValidTitle(_ title: String) -> Bool {
    !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}

/// The due a --due value stores. A bare date is date only: year, month and day, no zone. Anything with a
/// time is a moment (one without an offset is read in this Mac's zone), kept as its clock time on `mac`
/// to the second, in `mac`'s zone.
func dueComponents(_ text: String, mac: Calendar) throws -> DateComponents {
    // A date needs no time of day, so it is read in UTC: in some zones the clocks skip midnight on one day
    // of the year, and that day is still a date.
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(secondsFromGMT: 0)!
    if let day = parseDay(text, timeZone: utc.timeZone) {
        let parts = utc.dateComponents([.year, .month, .day], from: day)
        return DateComponents(year: parts.year, month: parts.month, day: parts.day)
    }
    let moment = try parseDate(text)
    var parts = mac.dateComponents([.year, .month, .day, .hour, .minute, .second], from: moment)
    parts.timeZone = mac.timeZone
    // In the hour that comes twice when the clocks go back, a clock time cannot say which of the two it is:
    // the second one would be kept as the first, an hour early.
    guard let kept = reminderDue(parts, mac: mac)?.at, wholeSecond(kept) == wholeSecond(moment) else {
        throw ValidationError("--due names a moment in the hour that comes twice when the clocks go back in "
            + "\(mac.timeZone.identifier), which a reminder cannot keep apart from the first; give a time before or after it")
    }
    return parts
}

/// Finds the reminder to change or delete. Only a reminder's id finds one: an event's id, a list's, or
/// anything else answers as an id that does not exist, and so does a reminder in a list outside `allowed`.
func findReminder(_ id: String, in store: EKEventStore, allowed: Set<String>?) throws -> EKReminder {
    guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder,
          allowed?.contains(reminder.calendar?.calendarIdentifier ?? "") ?? true else {
        throw IrisError("no reminder with id \(id)")
    }
    return reminder
}

/// The one writable list `token` names among the allowed ones; any other is not found.
func writableList(_ token: String, in store: EKEventStore, allowed: Set<String>?) throws -> EKCalendar {
    let (found, missing) = pick([token], from: store.calendars(for: .reminder), allowed: allowed,
                                id: \.calendarIdentifier, name: \.title)
    guard missing.isEmpty, let hits = found else {
        throw IrisError("no reminder list named \(token); see `iris reminders lists`")
    }
    guard hits.count == 1 else {
        throw IrisError("reminder list name \(token) is ambiguous; use its id from `iris reminders lists`")
    }
    guard hits[0].allowsContentModifications else { throw IrisError("list \(hits[0].title) is read-only") }
    return hits[0]
}
