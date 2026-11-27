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
    var calendars: [String]?
    var folders: [String]?
    var lists: [String]? = []
    var writes = false
    var sharedEvents = false
    var reminderWrites = false

    subscript(kind: ScopeKind) -> [String]? {
        get {
            switch kind {
            case .calendars: calendars
            case .folders: folders
            case .lists: lists
            }
        }
        set {
            switch kind {
            case .calendars: calendars = newValue
            case .folders: folders = newValue
            case .lists: lists = newValue
            }
        }
    }
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

/// The file as the menu bar writes it: every key that holds items, "lists" too, and each flag only when true;
/// keys sorted and one entry to a line, so a person can still read and edit it.
func encodeScopeFile(_ file: ScopeFile) -> Data {
    var keys: [String: Any] = [:]
    for (key, kind) in [("calendars", ScopeKind.calendars), ("folders", .folders), ("lists", .lists)] {
        keys[key] = file[kind].map { $0 as Any } ?? "all"
    }
    for (key, on) in [("writes", file.writes), ("sharedEvents", file.sharedEvents), ("reminderWrites", file.reminderWrites)] where on {
        keys[key] = true
    }
    // Nothing here can fail to encode: strings, lists of strings and booleans.
    let data = try! JSONSerialization.data(withJSONObject: keys, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    return data + Data("\n".utf8)
}

/// One click in a row's submenu in the menu bar.
enum ScopeTick: Equatable {
    case all(ScopeKind, Bool)           // All Calendars, All Lists or All Folders on or off
    case item(ScopeKind, String, Bool)  // one calendar, list or folder, by id, on or off
    case remove(ScopeKind, String)      // an entry of the file that names nothing now, as written
    case writes(Bool)
    case sharedEvents(Bool)
    case reminderWrites(Bool)

    var kind: ScopeKind {
        switch self {
        case .all(let kind, _), .item(let kind, _, _), .remove(let kind, _): kind
        case .writes, .sharedEvents: .calendars
        case .reminderWrites: .lists
        }
    }

    /// Whether the tick needs the kind's items as they are now: it changes which items are shared, by id.
    var needsListing: Bool {
        switch self {
        case .item, .remove: true
        default: false
        }
    }
}

/// The scope file after one tick, `items` being the kind's calendars, lists or folders as they are now.
///
/// All on is "all"; All off shares none. An item ticked while the file says "all" leaves every other item shared;
/// otherwise it is added or taken out. A key an item tick or a removal changes is written by id: each entry that
/// names items becomes their ids, and one that names nothing stays as written, until it is removed on its own.
///
/// The file's rules hold after every tick, and changes need something shared: a tick of Calendar that leaves no
/// calendars turns writes and events with other people off, one of Reminders that leaves no lists turns reminder
/// writes off. A tick the rules do not allow changes nothing; one app's tick leaves the others' keys as written.
func applying(_ tick: ScopeTick, to file: ScopeFile, items: [Named]) -> ScopeFile {
    var file = file
    switch tick {
    case .all(let kind, let on):
        file[kind] = on ? nil : []
    case .item(let kind, let id, let on):
        var ids = asIds(file[kind] ?? items.map(\.id), items)
        ids.removeAll { $0 == id }
        if on { ids.append(id) }
        file[kind] = ids
    case .remove(let kind, let entry):
        file[kind] = file[kind].map { asIds($0.filter { $0 != entry }, items) }
    case .writes(let on):
        file.writes = on
    case .sharedEvents(let on):
        file.sharedEvents = on
    case .reminderWrites(let on):
        file.reminderWrites = on
    }
    switch tick.kind {
    case .calendars:
        if file.calendars == [] { file.writes = false }
        if !file.writes { file.sharedEvents = false }
    case .lists:
        if file.lists == [] { file.reminderWrites = false }
    case .folders:
        break
    }
    return file
}

/// The entries as the ids of the items they name, each once; one that names nothing stays as written.
private func asIds(_ entries: [String], _ items: [Named]) -> [String] {
    var ids: [String] = []
    for entry in entries {
        let found = pick([entry], from: items, allowed: nil, id: \.id, name: \.name).found ?? []
        for id in found.isEmpty ? [entry] : found.map(\.id) where !ids.contains(id) { ids.append(id) }
    }
    return ids
}

/// `applying`, refused when the key it changes would not mean to a server what the menu showed, `items` being the
/// kind's items listed just now: an entry it adds that names nothing (an item deleted since the menu listed it), or
/// an entry that is one item's id and another's name while that other is not shared, which a server would take
/// for the other should the first be deleted. Refused, nothing is written and the error says why.
func checkedApplying(_ tick: ScopeTick, to file: ScopeFile, items: [Named]) throws -> ScopeFile {
    let changed = applying(tick, to: file, items: items)
    let kind = tick.kind
    guard let entries = changed[kind], entries != file[kind] else { return changed }
    let (noun, app) = switch kind {
    case .calendars: ("calendar", "Calendar")
    case .lists: ("reminder list", "Reminders")
    case .folders: ("folder", "Notes")
    }
    let ids = Set(items.map(\.id))
    let before = Set(file[kind] ?? [])
    if entries.contains(where: { !ids.contains($0) && !before.contains($0) }) {
        throw IrisError("That \(noun) no longer exists, so nothing was changed.")
    }
    let shared = Set(entries)
    if items.contains(where: { shared.contains($0.name) && ids.contains($0.name) && !shared.contains($0.id) }) {
        throw IrisError("One \(noun) is named exactly like another \(noun)'s internal id, so Iris cannot tell them apart "
            + "safely. Rename it in \(app) and try again; nothing was changed.")
    }
    return changed
}

/// Runs `body` holding an exclusive lock that every copy of Iris takes before it reads the scope file to change it,
/// so two changes never overwrite each other. The lock is on a file of its own beside the scope file (beside its
/// target, when the path is a link), <name>.lock, made owner-only and never written or removed: not the scope file,
/// which each write replaces, and not its folder, which a server with writes on holds locked as its state folder.
/// Waits at most `wait` seconds for another copy to finish; never call it on the main thread.
func withScopeLock<T>(_ path: String, wait: Double = 2, _ body: () throws -> T) throws -> T {
    let target = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    let directory = (target as NSString).deletingLastPathComponent
    do {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    } catch {
        throw IrisError("cannot create \(directory): \(error.localizedDescription)")
    }
    // Nothing is made in a folder others can write in, the lock file included.
    let folder = open(directory, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard folder >= 0 else { throw IrisError("cannot open \(directory): \(String(cString: strerror(errno)))") }
    defer { close(folder) }
    try checkFolder(folder, directory, "the folder", forbidden: 0o022, only: "writable by you only", fix: "chmod go-w")
    let lockPath = target + ".lock"
    // Non-blocking: something that is not a file at that path is refused below, not waited on.
    let lock = open(lockPath, O_RDONLY | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
    guard lock >= 0 else { throw IrisError("cannot open \(lockPath): \(String(cString: strerror(errno)))") }
    // Closing it releases the lock.
    defer { close(lock) }
    var info = stat()
    guard fstat(lock, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() else {
        throw IrisError("\(lockPath) must be a file of yours")
    }
    let deadline = DispatchTime.now() + wait
    while flock(lock, LOCK_EX | LOCK_NB) != 0 {
        guard errno == EWOULDBLOCK, DispatchTime.now() < deadline else {
            throw IrisError("Another copy of Iris is changing what is shared; try again.")
        }
        usleep(10_000)
    }
    return try body()
}

/// One tick to the scope file at `path`, under the lock: the file after it, and whether it was written. A missing
/// file starts from one that shares nothing; a file that cannot be read is never written over, and its problem is
/// the error. `items` are the kind's items as listed just now.
func changeScopeFile(_ path: String, _ tick: ScopeTick, items: [Named]) throws -> (file: ScopeFile, written: Bool) {
    try withScopeLock(path) {
        let current: ScopeFile
        switch loadScopeFile(path) {
        case .missing: current = ScopeFile(calendars: [], folders: [])
        case .file(let file): current = file
        case .broken(let problem): throw IrisError(problem)
        }
        let changed = try checkedApplying(tick, to: current, items: items)
        guard changed != current else { return (current, false) }
        try writeScopeFile(changed, to: path)
        return (changed, true)
    }
}

/// The scope file at a path as the menu bar finds it.
enum ScopeFileState: Equatable {
    case missing
    case file(ScopeFile)
    case broken(String)  // there, but not a scope file a server would read: why, in the server's words
}

func loadScopeFile(_ path: String) -> ScopeFileState {
    var info = stat()
    if lstat(path, &info) != 0 && errno == ENOENT { return .missing }
    do {
        return .file(try readScopeFile(path))
    } catch {
        return .broken("\(error)")
    }
}

/// Replaces the scope file with this one. A missing file is made, and its folder, open to this user only.
func writeScopeFile(_ file: ScopeFile, to path: String) throws {
    let data = encodeScopeFile(file)
    guard data.count <= scopeFileLimit else { throw IrisError("the scope file would be too long for a server to read") }
    try replacePrivateFile(path, data)
}

/// The most of a scope file a server reads.
private let scopeFileLimit = 65536

/// Replaces a scope file that cannot be read with one that shares nothing, after keeping the old one beside it
/// as <name>.broken-<date and time>; that path is returned.
func resetScopeFile(_ path: String, now: Date = Date()) throws -> String {
    let target = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    let format = DateFormatter()
    format.locale = Locale(identifier: "en_US_POSIX")
    format.dateFormat = "yyyyMMdd-HHmmss"
    let copy = target + ".broken-" + format.string(from: now)
    // A second name for the old file, so the path is never without a file.
    guard link(target, copy) == 0 else {
        throw IrisError("cannot keep a copy of \(target) as \(copy): \(String(cString: strerror(errno)))")
    }
    try writeScopeFile(ScopeFile(calendars: [], folders: []), to: target)
    return copy
}

/// Writes the file whole beside its place, owner-only and without an access control list, then renames it over
/// the old one, so a reader sees the old file or the new, never a part. Links are followed: the file they lead to
/// is replaced. The folder must be this user's and writable by no one else, so no one can put another file in
/// its place; one made here is open to this user only.
private func replacePrivateFile(_ path: String, _ contents: Data) throws {
    let target = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    let directory = (target as NSString).deletingLastPathComponent
    do {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    } catch {
        throw IrisError("cannot create \(directory): \(error.localizedDescription)")
    }
    let folder = open(directory, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard folder >= 0 else { throw IrisError("cannot open \(directory): \(String(cString: strerror(errno)))") }
    defer { close(folder) }
    try checkFolder(folder, directory, "the folder", forbidden: 0o022, only: "writable by you only", fix: "chmod go-w")
    let temporary = target + "." + UUID().uuidString + ".new"
    let descriptor = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw IrisError("cannot write \(target): \(String(cString: strerror(errno)))") }
    let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    var renamed = false
    defer { if !renamed { unlink(temporary) } }
    try makePrivate(descriptor, temporary)
    try file.write(contentsOf: contents)
    guard fsync(descriptor) == 0, rename(temporary, target) == 0 else {
        throw IrisError("cannot write \(target): \(String(cString: strerror(errno)))")
    }
    renamed = true
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
    let data = try readPrivateFile(path, noun: "scope file", recipe: recipe, limit: scopeFileLimit)
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
