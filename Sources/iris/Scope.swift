import ArgumentParser
import Foundation

// What a caller of `iris mcp --http` may see: the calendars, note folders and reminder lists the owner
// names in the scope file. The server pins them to ids at start and passes them to every tool call as
// --allowed-calendars, --allowed-folders or --allowed-lists; the commands treat everything else as not existing.

let defaultScopeFile = "~/Library/Application Support/Iris/http-scope"

/// The option a tool's command takes to be limited to the scope.
enum ScopeKind {
    case calendars, folders, lists

    var option: String {
        switch self {
        case .calendars: "--allowed-calendars"
        case .folders: "--allowed-folders"
        case .lists: "--allowed-lists"
        }
    }
}

/// The scope file as written: names or ids per kind, nil where it says "all", and no lists where it has
/// no lists key; whether callers may create, change and delete events in the calendars it names; whether
/// they may also change and delete events that have other people on them; and whether they may add,
/// change, complete and delete reminders in the lists it names.
struct ScopeFile: Equatable {
    let calendars: [String]?
    let folders: [String]?
    var lists: [String]? = []
    var writes = false
    var sharedEvents = false
    var reminderWrites = false
}

/// The scope as pinned at start: ids per kind, nil where the file says "all".
struct HTTPScope {
    let calendars: Set<String>?
    let folders: Set<String>?
    var lists: Set<String>? = []
    var writes = false
    var sharedEvents = false
    var reminderWrites = false

    func ids(_ kind: ScopeKind) -> Set<String>? {
        switch kind {
        case .calendars: calendars
        case .folders: folders
        case .lists: lists
        }
    }
}

let scopeExample = #"{"calendars": ["Work"], "folders": "all"}"#
private let scopeShape = #"each key holds a list of names or ids, [] for none, or "all" for every one; "#
    + #"an optional "lists" key names reminder lists the same way, none without it; "#
    + #"an optional "writes": true lets callers change events in those calendars, and with it an optional "#
    + #""sharedEvents": true lets them change and delete events that have other people on them; "#
    + #"an optional "reminderWrites": true, with lists named, lets them change reminders in those lists"#

/// Two keys, calendars and folders, each "all" or a list of strings; the optional lists, the same, and
/// none when it is not there; and the optional writes, sharedEvents and reminderWrites, each true or false,
/// sharedEvents true only with writes true, reminderWrites true only with lists named. Anything else is an error.
func parseScopeFile(_ data: Data) throws -> ScopeFile {
    guard let object = try? JSONSerialization.jsonObject(with: data), let keys = object as? [String: Any] else {
        throw IrisError("not a JSON object")
    }
    if let extra = keys.keys.sorted().first(where: { !["calendars", "folders", "lists", "writes", "sharedEvents", "reminderWrites"].contains($0) }) {
        throw IrisError("unknown key \(extra)")
    }
    // JSON true and 1 both arrive as NSNumber, so the type is checked before the value.
    func flag(_ key: String) throws -> Bool {
        guard let value = keys[key] else { return false }
        guard CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID(), let flag = value as? Bool else {
            throw IrisError("\(key) must be true or false")
        }
        return flag
    }
    let writes = try flag("writes")
    let sharedEvents = try flag("sharedEvents")
    let reminderWrites = try flag("reminderWrites")
    if sharedEvents && !writes {
        throw IrisError(#""sharedEvents": true needs "writes": true; without writes it would mean nothing"#)
    }
    func entries(_ key: String) throws -> [String]? {
        guard let value = keys[key] else { throw IrisError("no \(key) key") }
        if value as? String == "all" { return nil }
        guard let list = value as? [Any], let names = list as? [String], list.allSatisfy({ $0 is String }) else {
            throw IrisError("\(key) must be a list of strings or \"all\"")
        }
        return names
    }
    // A file written before reminders came to HTTP has no lists key, and offers what it did then.
    let lists = keys["lists"] == nil ? [] : try entries("lists")
    if reminderWrites && lists?.isEmpty == true {
        throw IrisError(#""reminderWrites": true needs reminder lists in "lists"; without them it would mean nothing"#)
    }
    return ScopeFile(calendars: try entries("calendars"), folders: try entries("folders"), lists: lists,
                     writes: writes, sharedEvents: sharedEvents, reminderWrites: reminderWrites)
}

/// Reads the scope file and pins its names to the ids they match now. Only a kind given as a list is
/// looked up, by this binary's own `calendar calendars`, `notes folders` or `reminders lists`, so "all"
/// never asks Notes. Lists "all" asks Reminders once all the same, so missing Reminders access stops the
/// start rather than every call; no lists, or [], never asks Reminders.
func readScope(_ path: String) throws -> HTTPScope {
    try pinScope(try readScopeFile(path), path).http
}

/// The scope file with the items it names as they are now, by id and current name; nil where it says "all".
struct PinnedScope {
    let file: ScopeFile
    let calendars: [Named]?
    let folders: [Named]?
    let lists: [Named]?

    var http: HTTPScope {
        HTTPScope(calendars: calendars.map { Set($0.map(\.id)) }, folders: folders.map { Set($0.map(\.id)) },
                  lists: lists.map { Set($0.map(\.id)) }, writes: file.writes, sharedEvents: file.sharedEvents,
                  reminderWrites: file.reminderWrites)
    }
}

/// The scope file as written, or the error the server stops on.
func readScopeFile(_ path: String) throws -> ScopeFile {
    let directory = (path as NSString).deletingLastPathComponent
    let recipe = "create one, for example: mkdir -p \"\(directory)\" && "
        + "(umask 077; echo '\(scopeExample)' > \"\(path)\"); \(scopeShape)"
    let data = try readPrivateFile(path, noun: "scope file", recipe: recipe, limit: 65536)
    do {
        return try parseScopeFile(data)
    } catch {
        throw IrisError("\(path): \(error); a scope file looks like \(scopeExample): \(scopeShape)")
    }
}

/// The pinning of `readScope`, with the items' names kept; `listing` runs each lookup, this binary unless given.
func pinScope(_ file: ScopeFile, _ path: String, listing: ([String]) throws -> Data = runIris) throws -> PinnedScope {
    let lists: [Named]?
    if let names = file.lists {
        lists = try pin(names, listing: ["reminders", "lists"], nameKey: "title", noun: "reminder list", path, listing)
    } else {
        _ = try listing(["reminders", "lists"])
        lists = nil
    }
    return PinnedScope(
        file: file,
        calendars: try file.calendars.map { try pin($0, listing: ["calendar", "calendars"], nameKey: "title", noun: "calendar", path, listing) },
        folders: try file.folders.map { try pin($0, listing: ["notes", "folders"], nameKey: "name", noun: "folder", path, listing) },
        lists: lists)
}

struct Named {
    let id: String
    let name: String
}

/// The items named, each once, in the order first named.
private func pin(_ entries: [String], listing: [String], nameKey: String, noun: String, _ path: String,
                 _ run: ([String]) throws -> Data) throws -> [Named] {
    if entries.isEmpty { return [] }
    let output = try run(listing)
    guard let listed = try? JSONSerialization.jsonObject(with: output) as? [[String: Any]] else {
        throw IrisError("cannot read the output of iris \(listing.joined(separator: " "))")
    }
    let items = listed.compactMap { item in
        (item["id"] as? String).map { Named(id: $0, name: item[nameKey] as? String ?? "") }
    }
    let (found, missing) = pick(entries, from: items, allowed: nil, id: \.id, name: \.name)
    guard missing.isEmpty else {
        throw IrisError("\(path): no \(noun) named \(missing.joined(separator: ", ")); see `iris \(listing.joined(separator: " "))`")
    }
    var seen = Set<String>()
    return (found ?? []).filter { seen.insert($0.id).inserted }
}

/// How long the scope may take to pin: the listing waits on Calendar or Notes, and on a permission dialog
/// nobody answers it would wait for ever, with the server not yet listening.
private let scopeDeadline = 60

/// This binary with these arguments, its stdout, or an error with its stderr.
func runIris(_ arguments: [String]) throws -> Data {
    guard let path = executablePath() else { throw IrisError("cannot find the iris binary") }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    process.standardInput = FileHandle.nullDevice
    let output = Pipe()
    let errors = Pipe()
    process.standardOutput = output
    process.standardError = errors
    let exited = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in exited.signal() }
    try process.run()
    let command = "iris \(arguments.joined(separator: " "))"
    guard let finished = collect(process, output, errors, exited: exited, within: scopeDeadline) else {
        let app = switch arguments.first {
        case "calendar": "Calendar"
        case "reminders": "Reminders"
        default: "Notes"
        }
        throw IrisError("\(command) did not finish within \(scopeDeadline) seconds and was stopped, so the scope file "
            + "could not be pinned and the server did not start. If a permission dialog for \(app) is open on this "
            + "Mac, answer it; if \(app) is not responding, open it; then start again.")
    }
    guard process.terminationStatus == 0 else {
        let message = String(decoding: finished.errors, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        throw IrisError("\(command) failed: \(message)")
    }
    return finished.output
}

/// The items a caller's --calendar or --folder values name, matched by id or name, in the order named; a
/// name several items share takes each. Only allowed items can be named: any other comes back in
/// `missing`, exactly as one that does not exist. No values name every allowed item, or nil (everything)
/// when there is no scope.
func pick<Item>(_ tokens: [String], from items: [Item], allowed: Set<String>?,
                id: KeyPath<Item, String>, name: KeyPath<Item, String>) -> (found: [Item]?, missing: [String]) {
    let visible = items.filter { allowed?.contains($0[keyPath: id]) ?? true }
    if tokens.isEmpty { return (allowed == nil ? nil : visible, []) }
    var found: [Item] = []
    var missing: [String] = []
    for token in tokens {
        // An id names that one item, also when another item has it as its name.
        let byId = visible.filter { $0[keyPath: id] == token }
        let hits = byId.isEmpty ? visible.filter { $0[keyPath: name] == token } : byId
        if hits.isEmpty { missing.append(token) } else { found += hits }
    }
    return (found, missing)
}

/// The value of --allowed-calendars, --allowed-folders or --allowed-lists: a JSON array of ids; nil when the
/// option is absent. Ids only, never names: a calendar, folder or list made later under an allowed name stays out.
func allowedIds(_ value: String?, _ option: String) throws -> Set<String>? {
    guard let value else { return nil }
    guard let list = try? JSONSerialization.jsonObject(with: Data(value.utf8)) as? [Any],
          let ids = list as? [String], list.allSatisfy({ $0 is String }) else {
        throw ValidationError("\(option) takes a JSON array of ids, such as [] or [\"id1\", \"id2\"]")
    }
    return Set(ids)
}

func allowedHelp(_ kind: ScopeKind) -> ArgumentHelp {
    let (things, listing) = switch kind {
    case .calendars: ("calendars and their events", "iris calendar calendars")
    case .folders: ("folders and the notes they show", "iris notes folders")
    case .lists: ("lists and their reminders", "iris reminders lists")
    }
    return ArgumentHelp("A JSON array of ids from `\(listing)`, as `iris mcp --http` passes them: only these \(things) exist for this command, anything else gets the error for one that does not exist, and a name matches only among these. [] allows none. Default: no limit.",
                        valueName: "ids")
}

extension Tool {
    /// This tool with the scope's ids for its kind right after the command, none where the scope file says
    /// "all". A tool that takes onlyMine also gets --only-mine in its command, and loses the parameter, unless
    /// the scope file says "sharedEvents": true; one that takes notRepeating always gets --not-repeating, and
    /// loses the parameter. A tool whose command takes no scope option is refused, never offered unscoped.
    func limited(to scope: HTTPScope) throws -> Tool {
        guard let kind = self.scope else {
            throw IrisError("\(name) cannot be limited to the scope file, so it cannot be offered over HTTP")
        }
        var command = self.command
        var parameters = self.parameters
        if let ids = scope.ids(kind) {
            let json = String(decoding: try JSONSerialization.data(withJSONObject: ids.sorted(), options: .withoutEscapingSlashes),
                              as: UTF8.self)
            command += [kind.option, json]
        }
        if !scope.sharedEvents && parameters.contains(where: { $0.name == onlyMineParameter.name }) {
            command.append("--only-mine")
            parameters.removeAll { $0.name == onlyMineParameter.name }
        }
        if parameters.contains(where: { $0.name == notRepeatingParameter.name }) {
            command.append("--not-repeating")
            parameters.removeAll { $0.name == notRepeatingParameter.name }
        }
        return Tool(name: name, description: description, command: command, scope: kind, parameters: parameters)
    }
}
