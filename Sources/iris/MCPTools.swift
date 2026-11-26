import Foundation

// Each tool is one calendar, notes or reminders command. The table below is the only place a tool's parameters
// live: it produces the JSON schema the host reads and the command line the call runs, so
// a new command option needs a new row here to reach MCP.

struct Tool {
    let name: String
    let description: String
    let command: [String]
    /// Which scope option the command takes; nil for none, and then the tool cannot be offered over HTTP.
    let scope: ScopeKind?
    let parameters: [Parameter]

    var definition: [String: Any] {
        var schema: [String: Any] = ["type": "object", "additionalProperties": false]
        if !parameters.isEmpty {
            schema["properties"] = Dictionary(uniqueKeysWithValues: parameters.map { ($0.name, $0.schema) })
        }
        let required = parameters.filter(\.required).map(\.name)
        if !required.isEmpty { schema["required"] = required }
        return ["name": name, "description": description, "inputSchema": schema]
    }

    func argv(_ arguments: [String: Any]) throws -> [String] {
        if let unknown = arguments.keys.first(where: { key in !parameters.contains { $0.name == key } }) {
            throw IrisError("unknown parameter \(unknown); \(name) takes \(parameters.map(\.name).joined(separator: ", "))")
        }
        var options: [String] = []
        var positionals: [String] = []
        for parameter in parameters {
            guard let value = arguments[parameter.name], !(value is NSNull) else {
                if parameter.required { throw IrisError("\(parameter.name) is required") }
                continue
            }
            if parameter.kind == .positional {
                positionals += try parameter.arguments(for: value)
            } else {
                options += try parameter.arguments(for: value)
            }
        }
        // After "--" every word is a value, so an id of "--help" is looked up, not obeyed.
        return command + options + (positionals.isEmpty ? [] : ["--"] + positionals)
    }
}

struct Parameter {
    enum Kind {
        case string, integer, strings, integers
        case flag           // true adds --flag
        case toggle         // true adds --flag, false adds --no-flag
        case positional     // a bare argument, no option name
    }

    let name: String
    let kind: Kind
    let description: String
    /// The option name when it differs from `name`, as in calendars → --calendar.
    var flag: String? = nil
    var required = false
    var choices: [String]? = nil

    var schema: [String: Any] {
        var schema: [String: Any] = ["description": description]
        switch kind {
        case .string, .positional: schema["type"] = "string"
        case .integer: schema["type"] = "integer"
        case .flag, .toggle: schema["type"] = "boolean"
        case .strings: schema["type"] = "array"; schema["items"] = ["type": "string"]
        case .integers: schema["type"] = "array"; schema["items"] = ["type": "integer"]
        }
        if let choices { schema["enum"] = choices }
        return schema
    }

    func arguments(for value: Any) throws -> [String] {
        let option = "--\(flag ?? name)"
        switch kind {
        case .positional: return [try string(value)]
        case .string: return join(option, try string(value))
        case .integer: return join(option, try integer(value))
        case .strings: return try list(value).flatMap { join(option, try string($0)) }
        case .integers: return try list(value).flatMap { join(option, try integer($0)) }
        case .flag: return try bool(value) ? [option] : []
        case .toggle: return try bool(value) ? [option] : ["--no-\(flag ?? name)"]
        }
    }

    /// Text starting with "-" rides on `--option=value` so ArgumentParser reads it as a value. Anything else
    /// is its own word: a leading combining mark would fuse with the "=" into one character and hide it.
    private func join(_ option: String, _ value: String) -> [String] {
        value.unicodeScalars.first == "-" ? ["\(option)=\(value)"] : [option, value]
    }

    private func string(_ value: Any) throws -> String {
        guard let string = value as? String else { throw IrisError("\(name) must be a string") }
        // A command-line word cannot carry NUL; Process would raise an exception Swift cannot catch.
        // Checked on the bytes: a NUL followed by a combining mark is one character that is not "\0".
        guard !string.utf8.contains(0) else { throw IrisError("\(name) must not contain NUL") }
        return string
    }

    // JSON true and 1 both arrive as NSNumber, so the type is checked before the value.
    private func integer(_ value: Any) throws -> String {
        guard !isBoolean(value), let number = value as? Int else { throw IrisError("\(name) must be a whole number") }
        return String(number)
    }

    private func bool(_ value: Any) throws -> Bool {
        guard isBoolean(value), let bool = value as? Bool else { throw IrisError("\(name) must be true or false") }
        return bool
    }

    private func isBoolean(_ value: Any) -> Bool {
        CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID()
    }

    private func list(_ value: Any) throws -> [Any] {
        guard let list = value as? [Any] else { throw IrisError("\(name) must be a list") }
        return list
    }
}

private let dateFormats = "2026-10-13, 2026-10-13T09:00 (local time), or ISO 8601 with an offset or Z"

private let eventId = Parameter(name: "id", kind: .positional, description: "Event id, from events.", required: true)

private let occurrence = Parameter(
    name: "occurrence", kind: .string,
    description: "For a recurring event: the day of the occurrence to target; add a time if there are several that day: the one nearest it is taken, and a tie is refused.")

private let span = Parameter(
    name: "span", kind: .string,
    description: "this: only the targeted occurrence. future: the targeted occurrence and all after it; without occurrence, the whole series. Default: this.",
    choices: ["this", "future"])

/// Over HTTP this parameter is dropped and --only-mine pinned in its place, unless the scope file allows
/// shared events (`Tool.limited(to:)`).
let onlyMineParameter = Parameter(
    name: "onlyMine", kind: .flag,
    description: "Refuse, with nothing changed, an event that has anyone on it besides the Mac's owner: an attendee or an organizer who is not the owner; and span future on a repeating event, since the people on later occurrences cannot be checked. Default: off.",
    flag: "only-mine")

private let sharedNote = " An event with other people on it can be refused, with nothing changed, where changing such events is not allowed."

let tools: [Tool] = [
    Tool(name: "calendars", description: "List calendars: id, title, writable, source.",
         command: ["calendar", "calendars"], scope: .calendars, parameters: []),

    Tool(name: "events", description: "List events in a date range, earliest first; a tie by end, then title, calendar id and id. alarms: one entry per timed alarm, whole minutes before that event's start; negative is after it. availability: \"not supported\" when the event's calendar has none. organizer (or null) and attendees: who is invited, each with name, email (both can be null) and isCurrentUser; attendees add status, role and type.",
         command: ["calendar", "events"], scope: .calendars, parameters: [
        Parameter(name: "from", kind: .string, description: "Range start: \(dateFormats). Default: start of today."),
        Parameter(name: "to", kind: .string, description: "Range end, same formats; a bare date includes that whole day. Default: 7 days after from."),
        Parameter(name: "calendars", kind: .strings, description: "Calendar ids or titles. Default: every calendar.", flag: "calendar"),
        Parameter(name: "title", kind: .string, description: "Only events whose title contains this text, ignoring case. Default: every event."),
    ]),

    Tool(name: "add_event", description: "Create an event. Returns the created event.",
         command: ["calendar", "add"], scope: .calendars, parameters: [
        Parameter(name: "calendar", kind: .string, description: "Calendar id or title to create the event in. Must be writable (see calendars).", required: true),
        Parameter(name: "title", kind: .string, description: "Event title.", required: true),
        Parameter(name: "start", kind: .string, description: "Start: \(dateFormats). With allDay only the day counts.", required: true),
        Parameter(name: "end", kind: .string, description: "End, same formats; a bare date includes that whole day. Default: one hour after start, or the start day with allDay."),
        Parameter(name: "allDay", kind: .flag, description: "Make it an all-day event. Default: a timed event.", flag: "all-day"),
        Parameter(name: "location", kind: .string, description: "Location. Default: none."),
        Parameter(name: "notes", kind: .string, description: "Notes. Default: none."),
        Parameter(name: "url", kind: .string, description: "URL, with a scheme. Default: none."),
        Parameter(name: "availability", kind: .string, description: "An error if the calendar does not support that value. Default: Calendar's own, busy where the calendar has availability; elsewhere the event reads \"not supported\".", choices: ["busy", "free", "tentative", "unavailable"]),
        Parameter(name: "alarms", kind: .integers, description: "Minutes before the start, one entry per alarm. Default: no alarms.", flag: "alarm"),
        Parameter(name: "repeat", kind: .string, description: "Default: does not repeat. Without until or count it repeats forever.", choices: ["daily", "weekly", "monthly", "yearly"]),
        Parameter(name: "every", kind: .integer, description: "With repeat: repeat every n days, weeks, months or years. Default: 1."),
        Parameter(name: "on", kind: .string, description: "With repeat weekly: comma-separated days from su,mo,tu,we,th,fr,sa. Default: the weekday of start."),
        Parameter(name: "until", kind: .string, description: "With repeat: no occurrence starts after this date (same formats as start; a bare date includes that whole day). Not with count. Default: no end."),
        Parameter(name: "count", kind: .integer, description: "With repeat: stop after this many occurrences. Not with until. Default: no limit."),
    ]),

    Tool(name: "update_event", description: "Change an event. Only the fields you name change. Returns the updated event." + sharedNote,
         command: ["calendar", "update"], scope: .calendars, parameters: [
        eventId,
        Parameter(name: "title", kind: .string, description: "New title."),
        Parameter(name: "start", kind: .string, description: "New start: \(dateFormats). The end moves with it, keeping the duration, unless you pass end."),
        Parameter(name: "end", kind: .string, description: "New end, same formats; a bare date includes that whole day."),
        Parameter(name: "allDay", kind: .toggle, description: "true makes it an all-day event; false makes it timed and needs start and end. Default: unchanged.", flag: "all-day"),
        Parameter(name: "calendar", kind: .string, description: "Move the event to this calendar (id or title). Must be writable. Default: unchanged."),
        Parameter(name: "location", kind: .string, description: "New location. An empty string clears it."),
        Parameter(name: "notes", kind: .string, description: "New notes. An empty string clears them."),
        Parameter(name: "url", kind: .string, description: "New URL, with a scheme. An empty string clears it."),
        Parameter(name: "availability", kind: .string, description: "New availability; an error if the calendar (with calendar, the new one) does not support that value. Default: unchanged, as far as the calendar supports it.", choices: ["busy", "free", "tentative", "unavailable"]),
        Parameter(name: "alarms", kind: .integers, description: "Minutes before the start, one entry per alarm. Replaces all existing alarms. Default: alarms unchanged.", flag: "alarm"),
        Parameter(name: "noAlarms", kind: .flag, description: "Remove all alarms. Default: alarms unchanged.", flag: "no-alarms"),
        occurrence,
        span,
        onlyMineParameter,
    ]),

    Tool(name: "delete_event", description: "Delete an event. Returns {deleted, title, start, span}." + sharedNote,
         command: ["calendar", "delete"], scope: .calendars, parameters: [eventId, occurrence, span, onlyMineParameter]),

    Tool(name: "note_folders",
         description: "List Apple Notes folders: id, name, account, parent (folder id, null at the top), noteCount. Subfolders included; names can repeat, ids cannot.",
         command: ["notes", "folders"], scope: .folders, parameters: []),

    Tool(name: "notes",
         description: "List Apple Notes, newest modified first: id, title, folder, folderId, account, created, modified, locked, shared. No note text. Filters apply first, then the sort, then limit. A note shown in several folders is listed once, with the folder it is kept in.",
         command: ["notes", "list"], scope: .folders, parameters: [
        Parameter(name: "folders", kind: .strings, description: "Folder ids or names, from note_folders: the notes those folders show, smart folders included. A name that matches nothing is an error. Default: every folder.", flag: "folder"),
        Parameter(name: "since", kind: .string, description: "Only notes modified at or after this time: \(dateFormats). Default: any time."),
        Parameter(name: "title", kind: .string, description: "Only notes whose title contains this text, ignoring case. Default: every note."),
        Parameter(name: "limit", kind: .integer, description: "At most this many notes. Default: 50."),
    ]),

    Tool(name: "search_notes",
         description: "Find Apple Notes whose title or text contains every word of text, ignoring case and diacritics: id, title, folder, folderId, modified, snippet. No ranking: newest modified first, then limit. snippet is 160 characters of the text, whitespace collapsed, from 60 before the first word found there; null when the words are only in the title. A locked note is matched on its title only. Reads every note's text on each call.",
         command: ["notes", "search"], scope: .folders, parameters: [
        Parameter(name: "text", kind: .positional, description: "The words to find, separated by spaces; every one must occur.", required: true),
        Parameter(name: "folders", kind: .strings, description: "Folder ids or names, from note_folders: the notes those folders show, smart folders included. A name that matches nothing is an error. Default: every folder.", flag: "folder"),
        Parameter(name: "limit", kind: .integer, description: "At most this many notes. Default: 20."),
    ]),

    Tool(name: "show_note",
         description: "Show one Apple Note: id, title, folder, folderId, account, created, modified, locked, shared, body (plain text, can run to megabytes), attachments (names; null for an unnamed one). A locked note gives locked true and null body and attachments.",
         command: ["notes", "show"], scope: .folders, parameters: [
        // --html stays CLI-only: HTML bodies embed images as data URIs and run to tens of megabytes.
        Parameter(name: "id", kind: .positional, description: "Note id, from notes.", required: true),
    ]),

    Tool(name: "reminder_lists",
         description: "List Apple Reminders lists: id, title, writable, source, open (how many reminders in the list are not completed).",
         command: ["reminders", "lists"], scope: nil, parameters: []),

    Tool(name: "reminders",
         description: "List Apple Reminders, open ones by default: id, title, list, listId, notes, due, priority (none, high, medium, low), completed, completedAt, created, modified, recurring; every key always there, null when empty. due is null or {date, time, timeZone, at}: date and time as kept in the reminder; time, timeZone and at null for a date-only due; timeZone null for a floating time, whose at is that clock time on this Mac. Dated reminders first by day (date only before timed), then by at; then undated, newest created first. Subtasks, tags, flags and sections are not visible; a subtask reads as an ordinary reminder.",
         command: ["reminders", "list"], scope: nil, parameters: [
        Parameter(name: "lists", kind: .strings, description: "List ids or titles, from reminder_lists. A name that matches nothing is an error. Default: every list.", flag: "list"),
        Parameter(name: "status", kind: .string, description: "open (not completed), completed or all. Default: open.", choices: ["open", "completed", "all"]),
        Parameter(name: "dueFrom", kind: .string, description: "Only reminders due at or after this: \(dateFormats). With dueFrom or dueTo, reminders without a due date are left out; a date-only due goes by its day. Default: no lower bound.", flag: "due-from"),
        Parameter(name: "dueTo", kind: .string, description: "Only reminders due at or before this, same formats; a bare date includes that whole day. Default: no upper bound.", flag: "due-to"),
    ]),

    Tool(name: "add_reminder",
         description: "Create a reminder. Returns it as reminders lists it. No alarm is set.",
         command: ["reminders", "add"], scope: nil, parameters: [
        Parameter(name: "list", kind: .string, description: "List id or title, from reminder_lists. Must name one writable list.", required: true),
        Parameter(name: "title", kind: .string, description: "Title, not empty.", required: true),
        Parameter(name: "notes", kind: .string, description: "Notes. Default: none."),
        Parameter(name: "due", kind: .string, description: "2026-10-13 is due that day at no set time; 2026-10-13T09:00 is that time on this Mac; with an offset or Z, that moment, kept as this Mac's clock time. Default: no due date."),
        Parameter(name: "priority", kind: .string, description: "Default: none.", choices: ["none", "low", "medium", "high"]),
    ]),

    Tool(name: "update_reminder",
         description: "Change a reminder. Only the fields you name, at least one, change; the id stays. Returns it as reminders lists it. due is refused, with nothing changed, whatever its value, when the reminder has an alarm (iris cannot move it; the time is changed in Reminders) or repeats. Alarms and completed are never changed.",
         command: ["reminders", "update"], scope: nil, parameters: [
        Parameter(name: "id", kind: .positional, description: "Reminder id, from reminders.", required: true),
        Parameter(name: "title", kind: .string, description: "New title, not empty."),
        Parameter(name: "notes", kind: .string, description: "New notes. An empty string clears them."),
        Parameter(name: "due", kind: .string, description: "New due date, in the forms of add_reminder. An empty string clears it. The start date Reminders keeps follows it."),
        Parameter(name: "priority", kind: .string, description: "New priority.", choices: ["none", "low", "medium", "high"]),
        Parameter(name: "list", kind: .string, description: "Move the reminder to this list: id or title, from reminder_lists. Must name one writable list."),
    ]),

    Tool(name: "complete_reminder",
         description: "Mark a reminder completed, or not completed with undo. Returns it as reminders lists it, read back after the call, plus completedOccurrence. Already in the state asked for: nothing changes. A repeating reminder needs occurrence, its current due date; it then stays open (completed false) and repeating, due on its next occurrence, and the occurrence done becomes a separate completed reminder with its own id: completedOccurrence, null if it cannot be told apart. The last occurrence of a series that ends completes the reminder itself. undo on an open repeating reminder is refused: undo a completed occurrence by its own id. Alarms are never touched.",
         command: ["reminders", "complete"], scope: nil, parameters: [
        Parameter(name: "id", kind: .positional, description: "Reminder id, from reminders.", required: true),
        Parameter(name: "undo", kind: .flag, description: "Mark it not completed instead. Not with occurrence. Default: off."),
        Parameter(name: "occurrence", kind: .string, description: "Required to complete an open repeating reminder: its current due date (due.date), YYYY-MM-DD. Another date is refused, with the date it is due now. Ignored when a repeating reminder is already completed. Refused for a reminder that does not repeat, and with undo."),
    ]),

    Tool(name: "delete_reminder",
         description: "Delete a reminder. Returns {deleted, title, list, listId}. A repeating reminder is deleted whole.",
         command: ["reminders", "delete"], scope: nil, parameters: [
        Parameter(name: "id", kind: .positional, description: "Reminder id, from reminders.", required: true),
    ]),
]
