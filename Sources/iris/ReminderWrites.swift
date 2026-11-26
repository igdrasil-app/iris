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

struct CompleteReminder: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "complete",
        abstract: "Mark a reminder completed, or not completed with --undo. Prints it as `iris reminders list` does, and the occurrence completed.",
        discussion: """
            Prints the reminder whose id was given, with the 12 keys of `iris reminders list`, read back after \
            the call, and a 13th key, completedOccurrence: null, except after completing an occurrence of a \
            repeating reminder (below), where it is that occurrence, with the same 12 keys.

            A reminder that does not repeat is marked completed, and completedAt says when. One already \
            completed is left as it is, completedAt kept, so the same call sent twice changes nothing the \
            second time. --undo marks a completed reminder not completed and clears completedAt; on an open \
            one it changes nothing. Either way the reminder is printed.

            A reminder that repeats is completed one occurrence at a time, and --occurrence must name that \
            occurrence: its current due date, due.date as `iris reminders list` prints it. Without \
            --occurrence, or with another date, nothing is changed and the error says the date it is due \
            now; another date can be an occurrence already completed. So the same call sent twice completes \
            one occurrence, and the second call is refused, since the reminder is due later by then. That \
            holds for calls made one after the other; a change made at the same moment by another device or \
            program is not guarded against.

            Completing an occurrence works as it does in Reminders: the reminder keeps its id, stays open \
            (completed false) and repeating, and is now due on its next occurrence, which Reminders chooses. \
            That is not always the one right after: completing one long overdue has been seen to move it \
            to an occurrence after today, and the occurrences skipped get no reminder of their own. The occurrence completed becomes a separate reminder in the same list, with its own id: \
            completed, recurring false, due on the old due. completedOccurrence is that reminder. So \
            completed false on the reminder printed is not a failure: that occurrence is done, and the next \
            one is open. completedOccurrence is null when that reminder cannot be told apart for certain, as \
            when another reminder in the list is completed at the same moment; the occurrence is completed \
            all the same, and `iris reminders list --status completed` shows it.

            Example: a reminder that repeats daily is due 2026-10-13. Completing it with --occurrence \
            2026-10-13 prints it due 2026-10-14, completed false, recurring true, and as completedOccurrence a \
            reminder with a new id, due 2026-10-13, completed true, recurring false. The same call again is \
            refused, since it is due 2026-10-14 now.

            The last occurrence of a series that ends, after a number of times or on a date, is not made a \
            separate reminder: the reminder itself becomes completed, still recurring true, its due \
            unchanged, and completedOccurrence is null. Completing it again, with or without --occurrence, \
            changes nothing and prints it; --undo opens it \
            again on that last occurrence. On a repeating reminder that is open, --undo is refused: each \
            completed occurrence is a separate reminder, undone by its own id.

            --occurrence on a reminder that does not repeat is refused, and so is --occurrence with --undo. \
            A refusal changes nothing. Only completed and completedAt change: no alarm is added or touched. A \
            reminder in a read-only list cannot be changed.
            """
    )

    @Argument(help: "Reminder id, from `iris reminders list`.")
    var id: String

    @Flag(help: "Mark it not completed instead.")
    var undo = false

    @Option(help: "Required to complete an open repeating reminder: its current due date, YYYY-MM-DD. Ignored when a repeating reminder is already completed. Refused for a reminder that does not repeat, and with --undo.")
    var occurrence: String?

    func validate() throws {
        if let occurrence, !isDay(occurrence) { throw ValidationError("--occurrence must be a date, YYYY-MM-DD") }
        if undo, occurrence != nil { throw ValidationError("--occurrence is not taken with --undo") }
    }

    func run() async throws {
        let mac = macCalendar()
        let store = try await grantedReminderStore()
        let reminder = try findReminder(id, in: store, allowed: nil)
        guard let list = reminder.calendar, list.allowsContentModifications else {
            throw IrisError("list \(reminder.calendar?.title ?? "") is read-only")
        }
        let repeats = reminder.hasRecurrenceRules
        let step = completionStep(repeats: repeats, completed: reminder.isCompleted, undo: undo,
                                  occurrence: occurrence, due: reminderDue(reminder.dueDateComponents, mac: mac)?.date)
        let completed: Bool
        switch step {
        case .refuse(let reason):
            throw IrisError(reason)
        case .nothing:
            return try emit(CompletedReminder(reminder: Reminder(reminder, mac: mac), completedOccurrence: nil))
        case .mark(let value):
            completed = value
        }

        // Completing an occurrence saves it as a new reminder, and the save does not say which: it is found as
        // the reminder completed in this list after the save and not before.
        let completedBefore = repeats && completed
            ? Set(try await fetchReminders(in: store, lists: [list], status: .completed, mac: mac).map(\.id)) : nil
        reminder.isCompleted = completed
        do {
            try store.save(reminder, commit: true)
        } catch {
            throw IrisError("save failed: \(error.localizedDescription)")
        }
        let saved = Reminder(reminder, mac: mac)
        var copy: Reminder? = nil
        // A series that has ended completes the reminder itself, and no copy is made. The save is done by now,
        // so a lookup that fails leaves completedOccurrence null instead of reporting an error.
        if let completedBefore, let occurrence, !saved.completed,
           let after = try? await fetchReminders(in: store, lists: [list], status: .completed, mac: mac) {
            // The occurrence carries the series' title and does not repeat; anything else is another reminder.
            let found = completedOccurrence(before: completedBefore, after: after, saved: saved.id, occurrence: occurrence)
            if let found, found.title == saved.title, !found.recurring { copy = found }
        }
        try emit(CompletedReminder(reminder: saved, completedOccurrence: copy))
    }
}

enum CompletionStep: Equatable {
    case mark(completed: Bool)
    case nothing
    case refuse(String)
}

/// What `complete` does with a reminder: mark it, leave it as it is, or refuse with the reason.
func completionStep(repeats: Bool, completed: Bool, undo: Bool, occurrence: String?, due: String?) -> CompletionStep {
    if !repeats {
        if occurrence != nil {
            return .refuse("this reminder does not repeat, so --occurrence does not apply, and nothing was changed. "
                + "Call again without it.")
        }
        if undo { return completed ? .mark(completed: false) : .nothing }
        return completed ? .nothing : .mark(completed: true)
    }
    if undo {
        if completed { return .mark(completed: false) }
        return .refuse("this reminder repeats and is open, so there is nothing to undo, and nothing was changed. "
            + "A completed occurrence is a separate reminder, recurring false: undo it by its own id.")
    }
    // A series that has ended is itself completed on its last occurrence: there is nothing left to complete.
    if completed { return .nothing }
    guard let due else {
        return .refuse("this reminder repeats but has no due date, so no occurrence can be named, and nothing was "
            + "changed. Complete it in Reminders.")
    }
    guard let occurrence else {
        return .refuse("this reminder repeats, and its current occurrence is due \(due); nothing was changed. "
            + "Pass --occurrence \(due) to complete that occurrence.")
    }
    guard occurrence == due else {
        return .refuse("this reminder repeats, and its current occurrence is due \(due), not \(occurrence); nothing "
            + "was changed. The occurrence of \(occurrence) may already have been completed: see "
            + "`iris reminders list --status completed`.")
    }
    return .mark(completed: true)
}

/// The occurrence a save completed: the one reminder completed after the save and not before, other than the
/// reminder saved, due on the occurrence's date. nil when there is not exactly one such reminder.
func completedOccurrence(before: Set<String>, after: [Reminder], saved: String, occurrence: String) -> Reminder? {
    let new = after.filter { !before.contains($0.id) && $0.id != saved }
    guard new.count == 1, new[0].due?.date == occurrence else { return nil }
    return new[0]
}

/// Whether text is a date written YYYY-MM-DD, as due.date prints one.
func isDay(_ text: String) -> Bool {
    guard text.utf8.count == 10 else { return false }       // a year of five digits would pass what follows
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(secondsFromGMT: 0)!
    guard let day = parseDay(text, timeZone: utc.timeZone) else { return false }
    let parts = utc.dateComponents([.year, .month, .day], from: day)
    return String(format: "%04ld-%02ld-%02ld", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0) == text
}

/// A reminder as `complete` prints it: the 12 keys of `iris reminders list`, and completedOccurrence.
struct CompletedReminder: Encodable {
    let reminder: Reminder
    let completedOccurrence: Reminder?

    enum CodingKeys: CodingKey { case completedOccurrence }

    func encode(to encoder: Encoder) throws {
        try reminder.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(completedOccurrence, forKey: .completedOccurrence)
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
