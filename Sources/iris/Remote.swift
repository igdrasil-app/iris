import ArgumentParser
import EventKit
import Foundation

// `iris remote status`: what `iris mcp --http` lets a remote assistant do, and which servers run now. For the
// owner at the terminal only: it is not a tool, over stdio or HTTP, since it names what is in scope.

struct RemoteCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remote",
        abstract: "See what a remote assistant may do through iris mcp --http on this Mac.",
        discussion: "For you at this Mac, not for agents: it is not an MCP tool, over stdio or HTTP. See iris help remote status.",
        subcommands: [RemoteStatus.self]
    )
}

struct RemoteStatus: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show what iris mcp --http allows with a scope file, whether its token file would do, and the servers running now. Changes nothing.",
        discussion: """
            Prints one JSON object. It writes no file, starts no server, takes no lock, and never shows the token, its length or anything derived from it. It looks up the calendars, folders and lists the scope file names as a server does at start, but never in a way that can show a permission dialog.

            summary: a few plain sentences: whether the scope file would do, which servers run, and whether one must be restarted to take a change of the scope file. It names ports, never calendars, folders or lists.

            scopeFile: path, the file read (--scope-file, or the default a server uses); modified, when it was last changed, null when it cannot be read; usable, true when a server started now with it would start, false when it would stop, null when that cannot be told without asking for a permission; problem, why, in the words a server would stop with, or why it was not checked; else null.

            calendar, notes, reminders: what the scope file allows in each app, null when the file cannot be read as a scope file. access is none, read, or read and write. calendars, folders or lists is "all", or the names of those in scope as they are called now (an entry written as an id shows the current name), null when they could not be looked up; count is how many, null for "all". A file without lists allows no reminders. Calendar also has eventsWithOtherPeople: whether events that have anyone but you on them can be changed and deleted ("sharedEvents": true). With "writes": true and calendars [], calendar access is none, though the write tools are still offered and find nothing.

            writesPerHour: null when no write is on; else limit, the write calls allowed in any rolling hour, and counts, which writes share it.

            tools: the tools a server started now with this scope file would offer, as its ready line lists them; null when it would not start.

            tokenFile: path (--token-file, or the default); exists; passes, whether a server would accept it; problem, why not, in the words a server would stop with, else null.

            listeners: every iris mcp --http running as you on this Mac, from any copy of iris, [] when none: pid, port, scopeFile (as it was started with, or the default), started, usesThisScopeFile, and current: true when it started after the scope file was last changed, false when the file was changed since, so it still uses what it read at start and must be restarted for the change to take effect; null when it uses another file or the file cannot be read.

            Exit 0 whatever the setup holds: a broken setup is in the output. Exit 1 only when the running processes cannot be read.
            """
    )

    @Option(help: "The scope file to check. Default: ~/Library/Application Support/Iris/http-scope, as iris mcp --http.")
    var scopeFile: String?

    @Option(help: "The token file to check. Default: ~/Library/Application Support/Iris/http-token, as iris mcp --http.")
    var tokenFile: String?

    func run() throws {
        let scopePath = ((scopeFile ?? defaultScopeFile) as NSString).expandingTildeInPath
        let tokenPath = ((tokenFile ?? defaultTokenFile) as NSString).expandingTildeInPath
        let modified = modificationDate(scopePath)

        var file: ScopeFile?
        var pinned: PinnedScope?
        var usable: Bool?
        var problem: String?
        do {
            let read = try readScopeFile(scopePath)
            file = read
            pinned = try pinScope(read, scopePath, listing: listWithoutAsking)
            usable = true
        } catch let error as NotAsked {
            problem = error.description
        } catch {
            usable = false
            problem = "\(error)"
        }

        var tokenProblem: String?
        do {
            _ = try readToken(tokenPath)
        } catch {
            tokenProblem = "\(error)"
        }

        let thisFile = URL(fileURLWithPath: scopePath).resolvingSymlinksInPath().path
        let listeners = try runningListeners().map { listener -> (Listener, ListenerState) in
            let state: ListenerState = if resolvedScopeFile(of: listener) != thisFile {
                .otherFile
            } else if let modified {
                listener.started > modified ? .current : .changed
            } else {
                .unknown
            }
            return (listener, state)
        }

        let status: [String: Any] = [
            "summary": remoteSummary(usable: usable, listeners: listeners.map { ($0.0.port, $0.1) }),
            "scopeFile": ["path": scopePath, "modified": orNull(modified.map(iso)), "usable": orNull(usable),
                          "problem": orNull(problem)],
            "calendar": orNull(file.map { file in
                var entry = appEntry(.calendars, file, file.calendars, pinned.map { $0.calendars })
                let changeable = entry["access"] as? String == "read and write" && file.sharedEvents
                entry["eventsWithOtherPeople"] = changeable ? "can be changed" : "cannot be changed"
                return entry
            }),
            "notes": orNull(file.map { appEntry(.folders, $0, $0.folders, pinned.map { $0.folders }) }),
            "reminders": orNull(file.map { appEntry(.lists, $0, $0.lists, pinned.map { $0.lists }) }),
            "writesPerHour": orNull(file.flatMap(writeLimit)),
            "tools": orNull(try pinned.map { try httpOffering($0.http).map(\.name) }),
            "tokenFile": ["path": tokenPath, "exists": FileManager.default.fileExists(atPath: tokenPath),
                          "passes": tokenProblem == nil, "problem": orNull(tokenProblem)],
            "listeners": listeners.map { listener, state -> [String: Any] in
                ["pid": Int(listener.pid), "port": listener.port, "scopeFile": listener.scopeFile,
                 "started": iso(listener.started), "usesThisScopeFile": state != .otherFile,
                 "current": orNull(state == .current ? true : state == .changed ? false : nil)]
            },
        ]
        let data = try JSONSerialization.data(withJSONObject: status, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        print(String(decoding: data, as: UTF8.self))
    }
}

/// What the scope file allows in one app: none when it names none of the kind (no lists key names no
/// lists), read and write where it turns that app's writes on, else read.
func accessWord(_ kind: ScopeKind, _ file: ScopeFile) -> String {
    switch kind {
    case .calendars: file.calendars?.isEmpty == true ? "none" : file.writes ? "read and write" : "read"
    case .folders: file.folders?.isEmpty == true ? "none" : "read"
    case .lists: file.lists?.isEmpty == true ? "none" : file.reminderWrites ? "read and write" : "read"
    }
}

/// `named` is nil when the scope could not be pinned, and holds nil when the file says "all".
private func appEntry(_ kind: ScopeKind, _ file: ScopeFile, _ written: [String]?, _ named: [Named]??) -> [String: Any] {
    let key = switch kind {
    case .calendars: "calendars"
    case .folders: "folders"
    case .lists: "lists"
    }
    var entry: [String: Any] = ["access": accessWord(kind, file)]
    if written == nil {
        entry[key] = "all"
        entry["count"] = NSNull()
    } else if written == [] {
        entry[key] = [String]()
        entry["count"] = 0
    } else if let named, let items = named {
        entry[key] = items.map(\.name)
        entry["count"] = items.count
    } else {
        entry[key] = NSNull()
        entry["count"] = NSNull()
    }
    return entry
}

private func orNull(_ value: Any?) -> Any {
    value ?? NSNull()
}

private func writeLimit(_ file: ScopeFile) -> [String: Any]? {
    let counts = switch (file.writes, file.reminderWrites) {
    case (true, true): "calendar and reminder writes together"
    case (true, false): "calendar writes"
    case (false, true): "reminder writes"
    case (false, false): ""
    }
    return counts.isEmpty ? nil : ["limit": writesPerHour, "counts": counts]
}

private func modificationDate(_ path: String) -> Date? {
    var info = stat()
    guard stat(path, &info) == 0 else { return nil }
    let time = info.st_mtimespec
    return Date(timeIntervalSince1970: Double(time.tv_sec) + Double(time.tv_nsec) / 1e9)
}

/// A lookup that would have to ask for a permission, so it was not made.
private struct NotAsked: Error, CustomStringConvertible {
    let description: String
}

/// A server's lookup, made only when it cannot show a permission dialog: with access given or denied. Not
/// yet asked, it would ask, and Notes not running cannot be asked without opening it.
private func listWithoutAsking(_ arguments: [String]) throws -> Data {
    let command = "iris \(arguments.joined(separator: " "))"
    if arguments.first == "notes" && notesPermission() == "unknown (Notes not running)" {
        throw NotAsked(description: "not checked: Notes is not running, and whether Iris may control it cannot be told "
            + "without opening it. Open Notes, then check again.")
    }
    let reason: String? = switch arguments.first {
    case "calendar":
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined: "Iris has not been given Calendar access yet"
        case .writeOnly: "Iris has write-only Calendar access, and a server would ask for full access"
        default: nil
        }
    case "reminders":
        EKEventStore.authorizationStatus(for: .reminder) == .notDetermined ? "Iris has not been given Reminders access yet" : nil
    default:
        switch notesPermission() {
        case "granted", "denied": nil
        case "not determined": "Iris has not been allowed to control Notes yet"
        case let other: "whether Iris may control Notes is \(other)"
        }
    }
    guard let reason else { return try runIris(arguments) }
    throw NotAsked(description: "not checked, since checking would ask for a permission: \(reason). A server started now "
        + "would ask at start and wait for an answer. Run \(command) at this Mac (open Notes first for notes), "
        + "answer any dialog, then check again.")
}

enum ListenerState {
    case current     // started after the scope file was last changed
    case changed     // the scope file was changed after it started
    case unknown     // this scope file, which cannot be read now
    case otherFile
}

/// One or two sentences on the scope file and the servers running; ports only, never what is in scope.
func remoteSummary(usable: Bool?, listeners: [(port: Int, state: ListenerState)]) -> String {
    var sentences: [String] = []
    switch usable {
    case false: sentences.append("The scope file has a problem: a listener started with it now would stop (see scopeFile.problem).")
    case nil: sentences.append("Whether the scope file would work could not be checked without asking for a permission (see scopeFile.problem).")
    default: break
    }
    if listeners.isEmpty {
        sentences.append("No listener is running.")
        return sentences.joined(separator: " ")
    }
    if listeners.count == 1 {
        let port = listeners[0].port
        let sentence = switch listeners[0].state {
        case .current: "A listener is running on port \(port) and is using this scope file as it stands."
        case .changed: "A listener is running on port \(port), but the scope file was changed after it started: restart it for the change to take effect."
        case .unknown: "A listener is running on port \(port) with this scope file, which cannot be read now; it keeps what it read at start."
        case .otherFile: "A listener is running on port \(port) with another scope file."
        }
        return (sentences + [sentence]).joined(separator: " ")
    }
    sentences.append("\(listeners.count) listeners are running, on \(ports(listeners.map(\.port))).")
    func group(_ state: ListenerState) -> [Int] { listeners.filter { $0.state == state }.map(\.port) }
    let changed = group(.changed)
    if !changed.isEmpty {
        let them = changed.count == 1 ? "it" : "them"
        sentences.append("The scope file was changed after the one\(changed.count == 1 ? "" : "s") on \(ports(changed)) started: restart \(them) for the change to take effect.")
    }
    let current = group(.current)
    if current.count == listeners.count {
        sentences.append("All are using this scope file as it stands.")
    } else if !current.isEmpty {
        sentences.append("The one\(current.count == 1 ? "" : "s") on \(ports(current)) \(current.count == 1 ? "is" : "are") using this scope file as it stands.")
    }
    let unknown = group(.unknown)
    if !unknown.isEmpty {
        sentences.append("The one\(unknown.count == 1 ? "" : "s") on \(ports(unknown)) \(unknown.count == 1 ? "uses" : "use") this scope file, which cannot be read now.")
    }
    let other = group(.otherFile)
    if !other.isEmpty {
        sentences.append("The one\(other.count == 1 ? "" : "s") on \(ports(other)) \(other.count == 1 ? "uses" : "use") another scope file.")
    }
    return sentences.joined(separator: " ")
}

private func ports(_ numbers: [Int]) -> String {
    let words = numbers.map(String.init)
    guard words.count > 1 else { return "port \(words.joined())" }
    return "ports \(words.dropLast().joined(separator: ", ")) and \(words.last!)"
}

struct Listener {
    let pid: pid_t
    let port: Int
    let scopeFile: String
    let started: Date
}

/// The file a server's --scope-file names, to compare with another: a relative path is taken from the
/// server's own working directory, and links are followed. nil when that directory cannot be read.
private func resolvedScopeFile(of listener: Listener) -> String? {
    var path = listener.scopeFile
    if !(path as NSString).isAbsolutePath {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(listener.pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let directory = withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        guard !directory.isEmpty else { return nil }
        path = (directory as NSString).appendingPathComponent(path)
    }
    return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
}

/// The port and scope file of an `iris mcp --http` started with this executable and these arguments (argv[0]
/// first), read by the mcp command's own parser, so its defaults and spellings are the server's; nil for any
/// other process.
func listenerOptions(executable: String, _ arguments: [String]) -> (port: Int, scopeFile: String)? {
    guard (executable as NSString).lastPathComponent == "iris", arguments.count >= 2, arguments[1] == "mcp",
          let mcp = try? MCP.parse(Array(arguments.dropFirst(2))), mcp.http else { return nil }
    return (mcp.port ?? defaultHTTPPort, ((mcp.scopeFile ?? defaultScopeFile) as NSString).expandingTildeInPath)
}

/// Every `iris mcp --http` running as this user, by port. The kernel gives each process's arguments as they
/// were passed, separately, so a path with spaces stays one argument; another user's are not readable.
func runningListeners() throws -> [Listener] {
    var request = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(bitPattern: getuid())]
    var size = 0
    guard sysctl(&request, 4, nil, &size, nil, 0) == 0 else { throw IrisError("cannot list the running processes: \(String(cString: strerror(errno)))") }
    // Room for processes started between the two calls.
    size += 64 * MemoryLayout<kinfo_proc>.stride
    var processes = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
    guard sysctl(&request, 4, &processes, &size, nil, 0) == 0 else { throw IrisError("cannot list the running processes: \(String(cString: strerror(errno)))") }
    let listeners = processes.prefix(size / MemoryLayout<kinfo_proc>.stride).compactMap { process -> Listener? in
        let pid = process.kp_proc.p_pid
        guard let (executable, arguments) = processArguments(pid),
              let options = listenerOptions(executable: executable, arguments) else { return nil }
        let start = process.kp_proc.p_un.__p_starttime
        return Listener(pid: pid, port: options.port, scopeFile: options.scopeFile,
                        started: Date(timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1e6))
    }
    return listeners.sorted { ($0.port, $0.pid) < ($1.port, $1.pid) }
}

/// The executable path and arguments of a process, or nil when it is gone or not readable.
private func processArguments(_ pid: pid_t) -> (String, [String])? {
    var request = [CTL_KERN, KERN_ARGMAX]
    var limit: Int32 = 0
    var size = MemoryLayout<Int32>.size
    guard sysctl(&request, 2, &limit, &size, nil, 0) == 0 else { return nil }
    var buffer = [UInt8](repeating: 0, count: Int(limit))
    request = [CTL_KERN, KERN_PROCARGS2, pid]
    size = buffer.count
    guard sysctl(&request, 3, &buffer, &size, nil, 0) == 0 else { return nil }
    return parseProcessArguments(Array(buffer.prefix(size)))
}

/// KERN_PROCARGS2: the argument count (a 32-bit int), the executable path, NULs up to the first argument,
/// then the arguments, each ending in NUL, then the environment, which is not read.
func parseProcessArguments(_ bytes: [UInt8]) -> (String, [String])? {
    guard bytes.count >= 4 else { return nil }
    let count = Int(bytes.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
    var index = 4
    func string() -> String? {
        guard let end = bytes[index...].firstIndex(of: 0) else { return nil }
        defer { index = end + 1 }
        return String(decoding: bytes[index..<end], as: UTF8.self)
    }
    guard let executable = string() else { return nil }
    while index < bytes.count && bytes[index] == 0 { index += 1 }
    var arguments: [String] = []
    for _ in 0..<max(count, 0) {
        guard index < bytes.count, let argument = string() else { return nil }
        arguments.append(argument)
    }
    return (executable, arguments)
}
