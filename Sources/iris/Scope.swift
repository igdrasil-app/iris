import ArgumentParser
import Foundation

// What a caller of `iris mcp --http` may see: the calendars and note folders the owner names in the
// scope file. The server pins them to ids at start and passes them to every tool call as
// --allowed-calendars or --allowed-folders; the commands treat everything else as not existing.

let defaultScopeFile = "~/Library/Application Support/Iris/http-scope"

/// The option a tool's command takes to be limited to the scope.
enum ScopeKind {
    case calendars, folders

    var option: String { self == .calendars ? "--allowed-calendars" : "--allowed-folders" }
}

/// The scope file as written: names or ids per kind, nil where it says "all".
struct ScopeFile: Equatable {
    let calendars: [String]?
    let folders: [String]?
}

/// The scope as pinned at start: ids per kind, nil where the file says "all".
struct HTTPScope {
    let calendars: Set<String>?
    let folders: Set<String>?

    func ids(_ kind: ScopeKind) -> Set<String>? { kind == .calendars ? calendars : folders }
}

let scopeExample = #"{"calendars": ["Work"], "folders": "all"}"#
private let scopeShape = #"each key holds a list of names or ids, [] for none, or "all" for every one"#

/// Two keys, calendars and folders, each "all" or a list of strings; anything else is an error.
func parseScopeFile(_ data: Data) throws -> ScopeFile {
    guard let object = try? JSONSerialization.jsonObject(with: data), let keys = object as? [String: Any] else {
        throw IrisError("not a JSON object")
    }
    if let extra = keys.keys.sorted().first(where: { !["calendars", "folders"].contains($0) }) {
        throw IrisError("unknown key \(extra)")
    }
    func entries(_ key: String) throws -> [String]? {
        guard let value = keys[key] else { throw IrisError("no \(key) key") }
        if value as? String == "all" { return nil }
        guard let list = value as? [Any], let names = list as? [String], list.allSatisfy({ $0 is String }) else {
            throw IrisError("\(key) must be a list of strings or \"all\"")
        }
        return names
    }
    return ScopeFile(calendars: try entries("calendars"), folders: try entries("folders"))
}

/// Reads the scope file and pins its names to the ids they match now. Only a kind given as a list is
/// looked up, by this binary's own `calendar calendars` or `notes folders`, so "all" never asks Notes.
func readScope(_ path: String) throws -> HTTPScope {
    let directory = (path as NSString).deletingLastPathComponent
    let recipe = "create one, for example: mkdir -p \"\(directory)\" && "
        + "(umask 077; echo '\(scopeExample)' > \"\(path)\"); \(scopeShape)"
    let data = try readPrivateFile(path, noun: "scope file", recipe: recipe, limit: 65536)
    let file: ScopeFile
    do {
        file = try parseScopeFile(data)
    } catch {
        throw IrisError("\(path): \(error); a scope file looks like \(scopeExample): \(scopeShape)")
    }
    return HTTPScope(
        calendars: try file.calendars.map { try pin($0, listing: ["calendar", "calendars"], nameKey: "title", noun: "calendar", path) },
        folders: try file.folders.map { try pin($0, listing: ["notes", "folders"], nameKey: "name", noun: "folder", path) })
}

struct Named {
    let id: String
    let name: String
}

private func pin(_ entries: [String], listing: [String], nameKey: String, noun: String, _ path: String) throws -> Set<String> {
    if entries.isEmpty { return [] }
    let output = try runIris(listing)
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
    return Set((found ?? []).map(\.id))
}

/// This binary with these arguments, its stdout, or an error with its stderr.
private func runIris(_ arguments: [String]) throws -> Data {
    guard let path = executablePath() else { throw IrisError("cannot find the iris binary") }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    process.standardInput = FileHandle.nullDevice
    let output = Pipe()
    let errors = Pipe()
    process.standardOutput = output
    process.standardError = errors
    try process.run()
    var errorBytes = Data()
    let draining = DispatchGroup()
    DispatchQueue.global().async(group: draining) { errorBytes = errors.fileHandleForReading.readDataToEndOfFile() }
    let outputBytes = output.fileHandleForReading.readDataToEndOfFile()
    draining.wait()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        let message = String(decoding: errorBytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        throw IrisError("iris \(arguments.joined(separator: " ")) failed: \(message)")
    }
    return outputBytes
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
        let hits = visible.filter { $0[keyPath: id] == token || $0[keyPath: name] == token }
        if hits.isEmpty { missing.append(token) } else { found += hits }
    }
    return (found, missing)
}

/// The value of --allowed-calendars or --allowed-folders: a JSON array of ids; nil when the option is absent.
/// Ids only, never names: a calendar or folder made later under an allowed name stays out.
func allowedIds(_ value: String?, _ option: String) throws -> Set<String>? {
    guard let value else { return nil }
    guard let list = try? JSONSerialization.jsonObject(with: Data(value.utf8)) as? [Any],
          let ids = list as? [String], list.allSatisfy({ $0 is String }) else {
        throw ValidationError("\(option) takes a JSON array of ids, such as [] or [\"id1\", \"id2\"]")
    }
    return Set(ids)
}

func allowedHelp(_ kind: ScopeKind) -> ArgumentHelp {
    let (things, listing) = kind == .calendars
        ? ("calendars and their events", "iris calendar calendars")
        : ("folders and the notes they show", "iris notes folders")
    return ArgumentHelp("A JSON array of ids from `\(listing)`, as `iris mcp --http` passes them: only these \(things) exist for this command, anything else gets the error for one that does not exist, and a name matches only among these. [] allows none. Default: no limit.",
                        valueName: "ids")
}

extension Tool {
    /// This tool with the scope's ids for its kind right after the command, or as it is where the scope
    /// file says "all". A tool whose command takes no scope option is refused, never offered unscoped.
    func limited(to scope: HTTPScope) throws -> Tool {
        guard let kind = self.scope else {
            throw IrisError("\(name) cannot be limited to the scope file, so it cannot be offered over HTTP")
        }
        guard let ids = scope.ids(kind) else { return self }
        let json = String(decoding: try JSONSerialization.data(withJSONObject: ids.sorted(), options: .withoutEscapingSlashes),
                          as: UTF8.self)
        return Tool(name: name, description: description, command: command + [kind.option, json],
                    scope: kind, parameters: parameters)
    }
}
