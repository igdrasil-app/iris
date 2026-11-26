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
            Seconds are kept; fractions of a second are dropped.

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
    if let day = parseDay(text) {
        // parseDay reads the date at midnight in the current zone, so the day is taken back in that zone.
        var current = Calendar(identifier: .gregorian)
        current.timeZone = .current
        let parts = current.dateComponents([.year, .month, .day], from: day)
        return DateComponents(year: parts.year, month: parts.month, day: parts.day)
    }
    let moment = try parseDate(text)
    var parts = mac.dateComponents([.year, .month, .day, .hour, .minute, .second], from: moment)
    parts.timeZone = mac.timeZone
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
