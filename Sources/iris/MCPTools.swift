import Foundation

// Each tool is one calendar command. The table below is the only place a tool's parameters
// live: it produces the JSON schema the host reads and the command line the call runs, so
// a new command option needs a new row here to reach MCP.

struct Tool {
    let name: String
    let description: String
    let command: [String]
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

    /// `--option=value` keeps text starting with "-" a value; only an empty value needs its own word.
    private func join(_ option: String, _ value: String) -> [String] {
        value.isEmpty ? [option, value] : ["\(option)=\(value)"]
    }

    private func string(_ value: Any) throws -> String {
        guard let string = value as? String else { throw IrisError("\(name) must be a string") }
        // A command-line word cannot carry NUL; Process would raise an exception Swift cannot catch.
        guard !string.contains("\0") else { throw IrisError("\(name) must not contain NUL") }
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
    description: "For a recurring event: the day of the occurrence to target; add a time if there are several that day.")

private let span = Parameter(
    name: "span", kind: .string,
    description: "this: only the targeted occurrence. future: the targeted occurrence and all after it; without occurrence, the whole series. Default: this.",
    choices: ["this", "future"])

let tools: [Tool] = [
    Tool(name: "calendars", description: "List calendars: id, title, writable, source.",
         command: ["calendar", "calendars"], parameters: []),

    Tool(name: "events", description: "List events in a date range, earliest first.",
         command: ["calendar", "events"], parameters: [
        Parameter(name: "from", kind: .string, description: "Range start: \(dateFormats). Default: start of today."),
        Parameter(name: "to", kind: .string, description: "Range end, same formats; a bare date includes that whole day. Default: 7 days after from."),
        Parameter(name: "calendars", kind: .strings, description: "Calendar ids or titles. Default: every calendar.", flag: "calendar"),
        Parameter(name: "title", kind: .string, description: "Only events whose title contains this text, ignoring case. Default: every event."),
    ]),

    Tool(name: "add_event", description: "Create an event. Returns the created event.",
         command: ["calendar", "add"], parameters: [
        Parameter(name: "calendar", kind: .string, description: "Calendar id or title to create the event in. Must be writable (see calendars).", required: true),
        Parameter(name: "title", kind: .string, description: "Event title.", required: true),
        Parameter(name: "start", kind: .string, description: "Start: \(dateFormats). With allDay only the day counts.", required: true),
        Parameter(name: "end", kind: .string, description: "End, same formats; a bare date includes that whole day. Default: one hour after start, or the start day with allDay."),
        Parameter(name: "allDay", kind: .flag, description: "Make it an all-day event. Default: a timed event.", flag: "all-day"),
        Parameter(name: "location", kind: .string, description: "Location. Default: none."),
        Parameter(name: "notes", kind: .string, description: "Notes. Default: none."),
        Parameter(name: "url", kind: .string, description: "URL, with a scheme. Default: none."),
        Parameter(name: "availability", kind: .string, description: "Default: busy.", choices: ["busy", "free", "tentative", "unavailable"]),
        Parameter(name: "alarms", kind: .integers, description: "Minutes before the start, one entry per alarm. Default: no alarms.", flag: "alarm"),
        Parameter(name: "repeat", kind: .string, description: "Default: does not repeat. Without until or count it repeats forever.", choices: ["daily", "weekly", "monthly", "yearly"]),
        Parameter(name: "every", kind: .integer, description: "With repeat: repeat every n days, weeks, months or years. Default: 1."),
        Parameter(name: "on", kind: .string, description: "With repeat weekly: comma-separated days from su,mo,tu,we,th,fr,sa. Default: the weekday of start."),
        Parameter(name: "until", kind: .string, description: "With repeat: no occurrence starts after this date (same formats as start; a bare date includes that whole day). Not with count. Default: no end."),
        Parameter(name: "count", kind: .integer, description: "With repeat: stop after this many occurrences. Not with until. Default: no limit."),
    ]),

    Tool(name: "update_event", description: "Change an event. Only the fields you name change. Returns the updated event.",
         command: ["calendar", "update"], parameters: [
        eventId,
        Parameter(name: "title", kind: .string, description: "New title."),
        Parameter(name: "start", kind: .string, description: "New start: \(dateFormats). The end moves with it, keeping the duration, unless you pass end."),
        Parameter(name: "end", kind: .string, description: "New end, same formats; a bare date includes that whole day."),
        Parameter(name: "allDay", kind: .toggle, description: "true makes it an all-day event; false makes it timed and needs start and end. Default: unchanged.", flag: "all-day"),
        Parameter(name: "calendar", kind: .string, description: "Move the event to this calendar (id or title). Must be writable. Default: unchanged."),
        Parameter(name: "location", kind: .string, description: "New location. An empty string clears it."),
        Parameter(name: "notes", kind: .string, description: "New notes. An empty string clears them."),
        Parameter(name: "url", kind: .string, description: "New URL, with a scheme. An empty string clears it."),
        Parameter(name: "availability", kind: .string, description: "New availability.", choices: ["busy", "free", "tentative", "unavailable"]),
        Parameter(name: "alarms", kind: .integers, description: "Minutes before the start, one entry per alarm. Replaces all existing alarms. Default: alarms unchanged.", flag: "alarm"),
        Parameter(name: "noAlarms", kind: .flag, description: "Remove all alarms. Default: alarms unchanged.", flag: "no-alarms"),
        occurrence,
        span,
    ]),

    Tool(name: "delete_event", description: "Delete an event. Returns {deleted, title, start, span}.",
         command: ["calendar", "delete"], parameters: [eventId, occurrence, span]),
]
