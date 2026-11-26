import ArgumentParser
import Foundation

struct MCP: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: "Serve the calendar, notes and reminders commands as MCP tools over stdio, or the read tools (and, if turned on, the calendar writes) over HTTP.",
        // Lines stay under 80 columns: help wraps at 80 when piped, and a wrapped command no longer pastes.
        discussion: """
            Hosts start this, not people. Tools: calendars, events, add_event, update_event, delete_event, note_folders, notes, search_notes, show_note, reminder_lists, reminders, add_reminder, update_reminder, complete_reminder, delete_reminder, with the fields of the commands. A call still running after 60 seconds is stopped and returns an error, so the server keeps answering. Each host adds iris with its own line; Claude Code, Codex and Grok CLI:

              claude mcp add --scope user iris -- iris mcp
              codex mcp add iris -- iris mcp
              grok mcp add iris -- iris mcp

            OpenClaw's Gateway has its own PATH, so it gets the binary inside the app:

              openclaw mcp add iris \\
                --command /Applications/Iris.app/Contents/MacOS/iris --arg mcp

            Cursor and Claude Desktop are apps without Homebrew on their PATH, so they get the binary inside the app too, in these files:

              ~/.cursor/mcp.json
              ~/Library/Application Support/Claude/claude_desktop_config.json

              { "mcpServers": { "iris": {
                  "command": "/Applications/Iris.app/Contents/MacOS/iris",
                  "args": ["mcp"] } } }

            Hermes (~/.hermes/config.yaml):

              mcp_servers:
                iris:
                  command: iris
                  args: [mcp]

            Muse Code (~/.config/muse/settings.json):

              { "schema_version": 1, "mcpServers": { "iris": {
                  "command": "iris", "args": ["mcp"] } } }

            The reminder tools are offered over stdio only, not over HTTP.

            Over HTTP, for a host that cannot start a process on this Mac:

              iris mcp --http

            serves the read tools (calendars, events, note_folders, notes, search_notes, show_note), and the calendar writes only if the scope file turns them on (below), at http://127.0.0.1:8765/mcp, with no sessions: a request gets one JSON reply and a notification an empty 202; a request with an Expect header is refused (417). At most 16 connections and 4 tool calls at a time, and 60 seconds for a request to arrive. It prints one JSON line on stdout once it listens, then one line per request on stderr: time, methods, tool, status, duration; never arguments, results or the token. It listens on 127.0.0.1 only. Iris never makes it reachable from another machine; a proxy of your own can, and then the calendars and notes in its scope are reachable from wherever that proxy is, behind one token.

            Every request needs the header Authorization: Bearer <token>. The token is read once at start from --token-file, by default ~/Library/Application Support/Iris/http-token: a file of yours that only you can read (mode 600), holding at least 32 characters. Iris never creates it; this does:

              mkdir -p ~/Library/Application\\ Support/Iris
              (umask 077; openssl rand -base64 32 \\
                > ~/Library/Application\\ Support/Iris/http-token)

            Callers see only the calendars and note folders named in the scope file, read once at start from --scope-file, by default ~/Library/Application Support/Iris/http-scope. Without one the server does not start. Any other calendar or folder does not exist for them: naming it, or the id of a note no allowed folder shows, gets the same error as a name or id that matches nothing. A note is in scope when an allowed folder shows it, smart folders included; its folder, folderId and account are null when the folder it is kept in is not allowed, and a folder's parent is null when that is not allowed. The file is JSON, a file of yours that only you can read (mode 600); Iris never creates it; this does:

              (umask 077; echo '{"calendars": ["Work"], "folders": "all"}' \\
                > ~/Library/Application\\ Support/Iris/http-scope)

            Both keys must be there. Each holds a list of names or ids, from iris calendar calendars and iris notes folders, or "all"; [] allows none. A name that several calendars or folders share includes each; one that matches nothing stops the start. Names are matched to ids at start, so restart the server after changing the file. A calendar or folder renamed later stays in scope, one deleted later drops out, and one created later is not in scope, even under an allowed name; "all" is every one, those created later included.

            Writes are off unless the scope file also says "writes": true (false or no key: off; any other value stops the start):

              (umask 077; echo \\
                '{"calendars": ["Work"], "folders": "all", "writes": true}' \\
                > ~/Library/Application\\ Support/Iris/http-scope)

            Then add_event, update_event and delete_event are offered too, in the scope's calendars only: an event is created in, changed in, moved to or deleted from an allowed calendar, and any other answers as one that does not exist, with nothing changed. Notes stay read only. Whoever holds the token can then change those events, so the guards below are there for a mistaken or misled assistant:

            update_event and delete_event then refuse, with nothing changed, an event that has anyone on it but you: an attendee, or an organizer who is not you. Changing or deleting such an event can notify them or cancel their meeting, which cannot be taken back. A change to all future occurrences of a repeating event (span future) is refused too, since the people on later occurrences cannot be checked; one occurrence at a time still works. Each call carries --only-mine, and the tools do not offer onlyMine. To let callers change and delete those events too, the scope file also says "sharedEvents": true (false or no key: refused; any other value, or true without "writes": true, stops the start):

              (umask 077; echo '{"calendars": ["Work"], "folders": "all",
                "writes": true, "sharedEvents": true}' \\
                > ~/Library/Application\\ Support/Iris/http-scope)

            One write at a time; reads go on meanwhile. At most 20 write calls reach their command in any rolling hour, one the command refuses included; past that a call is refused and says when the next is possible. delete_event with span future is refused: a whole series is deleted on the Mac. add_event with repeat still creates a whole series in one call; changing a whole series with update_event and span future needs "sharedEvents": true.

            Two files in --state-dir, by default ~/Library/Application Support/Iris, mode 600 with no access control list. The folder is created owner-only when missing; one that exists must be yours, writable by no one else and without an access control list that lets others in, or the server does not start. One server with writes on uses a folder at a time; a second one on the same folder does not start. http-write-times holds the times of the write calls counted in the last hour, saved before each one runs, so the limit holds across a restart; a write whose count cannot be saved is refused. The times are kept on a clock that setting the date does not move; after a restart of the Mac, those saved count as just made. A missing file counts as no writes; one that cannot be read, as a full hour. http-writes.log records each write that reached its command: time, tool, whether it failed, and the text iris returned, for a success the event as it now is, so a wrong change can be undone by hand. It holds calendar content, unlike the request log. When it passes 4 MB it is trimmed to its newest lines; the newest entry is always kept whole. When a write's outcome is not known (stopped at 60 seconds, or cut short), the caller is told to check with events before repeating it, and that is recorded too. The request log on stderr marks what the guards did, never what was written: write-busy, span-refused, write-limit, times-failed, record-failed.

            Who can call it: a web page in your browser is stopped by the token, and by the refusal of every request that carries an Origin header. Another user of this Mac, and anything that arrives through your own proxy, is stopped by the token. A process running as you on this Mac is not stopped: it can read the token file, or run iris itself.

            A host adds it by URL and header; for Claude Code:

              claude mcp add --transport http iris-http \\
                http://127.0.0.1:8765/mcp \\
                --header "Authorization: Bearer <token>"
            """
    )

    @Flag(help: "Serve the read tools, and the calendar writes if the scope file turns them on, over HTTP on 127.0.0.1 instead of stdio.")
    var http = false

    @Option(help: "With --http: the port. Default: 8765.")
    var port: Int?

    @Option(help: "With --http: the file that holds the token. Default: ~/Library/Application Support/Iris/http-token.")
    var tokenFile: String?

    @Option(help: "With --http: the file that names the calendars and note folders callers may read, and whether they may change events. Default: ~/Library/Application Support/Iris/http-scope.")
    var scopeFile: String?

    @Option(help: "With --http and writes on: the folder for http-writes.log and http-write-times. Default: ~/Library/Application Support/Iris.")
    var stateDir: String?

    func validate() throws {
        if !http && (port != nil || tokenFile != nil || scopeFile != nil || stateDir != nil) {
            throw ValidationError("--port, --token-file, --scope-file and --state-dir need --http")
        }
        if let port, !(1...65535).contains(port) { throw ValidationError("--port must be between 1 and 65535") }
    }

    func run() throws {
        if http {
            return try serveHTTP(port: port ?? defaultHTTPPort, tokenFile: tokenFile ?? defaultTokenFile,
                                 scopeFile: scopeFile ?? defaultScopeFile, stateDir: stateDir ?? defaultStateDir)
        }
        // One JSON-RPC message per line in, one per line out. EOF is the host saying goodbye.
        while let line = readLine() {
            if line.allSatisfy(\.isWhitespace) { continue }
            guard let response = respond(to: line, offering: tools) else { continue }
            let data = try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys, .withoutEscapingSlashes])
            FileHandle.standardOutput.write(data + Data("\n".utf8))
        }
    }
}

// Two generations of the protocol are in use. Since 2026-07-28 every request carries its
// version in `_meta` and there is no handshake; before that a client sends `initialize`
// once. Claude Code probes with the new form and falls back to the old one, so we answer both.
let modernVersion = "2026-07-28"
let legacyVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
let versionKey = "io.modelcontextprotocol/protocolVersion"

private let serverInfo: [String: Any] = [
    "name": "iris",
    "version": installedVersion() ?? "dev",
]

private let instructions = """
    Apple Calendar and Apple Notes on this Mac. Use these tools for anything in Calendar or Notes, not the \
    apps' windows, AppleScript or screen control; use those only when none of these tools covers the task. \
    Notes are read only: search_notes or notes finds a note and its id; show_note gives its text unless \
    the note is password protected. \
    Apple Reminders can be read, added, changed, completed and deleted, where reminder_lists, reminders, \
    add_reminder, update_reminder, complete_reminder and delete_reminder are offered; completing a repeating \
    reminder needs occurrence, its current due date, and it stays open, due on its next occurrence, \
    unless that was the last one of a series that ends, which completes the reminder itself; \
    a reminder's due date and time are as kept in the reminder, and its at is the moment in the Mac's zone. \
    Dates in: 2026-10-13, 2026-10-13T09:00 (local time), or ISO 8601 with an offset or Z; \
    a bare date given as an end (to, end, until) includes that whole day. Dates out: ISO 8601 in the Mac's zone. \
    Changing or deleting a recurring event needs occurrence (one occurrence) or span future (the whole series). \
    An occurrence changed on its own is detached: its own id, recurring false, detached true. By that id, the default span this \
    changes or deletes only this occurrence; span future still reaches the occurrences after it.
    """

struct RPCError: Error {
    let code: Int
    let message: String
}

/// What a tool call came to: its result, whether its command started, and whether a signal ended the
/// command before the deadline did (the server stopping it, or a crash), when what it did is not known.
struct ToolCall {
    var result: [String: Any]
    var started = false
    var signalled = false
}

/// Stands around a tool call that passed the unknown-tool and arguments checks: it may answer without
/// calling `run`, and it sees what the call came to. Over stdio there is none.
typealias ToolCallGuard = (_ tool: Tool, _ arguments: [String: Any], _ run: () throws -> ToolCall) throws -> [String: Any]

/// The reply to one message, or nil when none is due: a notification, or a stray response.
/// `offering` is every tool this caller may list or call: one outside it is not listed, and a call
/// to it is an unknown tool, answered before any process starts. The instructions and the tools'
/// own descriptions are not narrowed; a caller that offers fewer tools has to see to those itself.
func respond(to line: String, offering: [Tool], guarded: ToolCallGuard? = nil) -> [String: Any]? {
    guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) else {
        return failure(id: NSNull(), code: -32700, message: "parse error")
    }
    guard let message = json as? [String: Any] else { return failure(id: NSNull(), code: -32600, message: "invalid request") }
    guard message["method"] != nil else { return nil }
    guard let method = message["method"] as? String else {
        return failure(id: message["id"] ?? NSNull(), code: -32600, message: "invalid request")
    }
    guard let id = message["id"] else { return nil }
    let params = message["params"] as? [String: Any] ?? [:]
    let requested = (params["_meta"] as? [String: Any])?[versionKey] as? String
    if let requested, requested != modernVersion {
        return failure(id: id, code: -32022, message: "unsupported protocol version",
                       data: ["supported": [modernVersion], "requested": requested])
    }
    do {
        var result = try handle(method, params, offering, guarded)
        if requested != nil {
            result["resultType"] = "complete"
            result["_meta"] = ["io.modelcontextprotocol/serverInfo": serverInfo]
        }
        return ["jsonrpc": "2.0", "id": id, "result": result]
    } catch let error as RPCError {
        return failure(id: id, code: error.code, message: error.message)
    } catch {
        return failure(id: id, code: -32603, message: "\(error)")
    }
}

private func handle(_ method: String, _ params: [String: Any], _ offering: [Tool],
                    _ guarded: ToolCallGuard?) throws -> [String: Any] {
    switch method {
    case "server/discover":
        return cacheable(["supportedVersions": [modernVersion], "capabilities": ["tools": [:]], "instructions": instructions])
    case "initialize":
        let requested = params["protocolVersion"] as? String ?? ""
        return ["protocolVersion": legacyVersions.contains(requested) ? requested : legacyVersions[0],
                "capabilities": ["tools": [:]], "serverInfo": serverInfo, "instructions": instructions]
    case "ping":
        return [:]
    case "tools/list":
        return cacheable(["tools": offering.map(\.definition)])
    case "tools/call":
        return try call(params, offering, guarded)
    default:
        throw RPCError(code: -32601, message: "method not found: \(method)")
    }
}

/// Since 2026-07-28 a discovery or list result must say how long it may be cached; the tools
/// never change while the process runs. Older clients ignore the two fields.
private func cacheable(_ result: [String: Any]) -> [String: Any] {
    result.merging(["ttlMs": 3_600_000, "cacheScope": "public"]) { result, _ in result }
}

private func failure(id: Any, code: Int, message: String, data: [String: Any]? = nil) -> [String: Any] {
    var error: [String: Any] = ["code": code, "message": message]
    if let data { error["data"] = data }
    return ["jsonrpc": "2.0", "id": id, "error": error]
}

/// The server answers one request at a time, so a call that never ends (a permission dialog nobody
/// answers, an app that does not respond) would silence it. The notes commands give Notes 30 seconds
/// per request and then fail with a clearer message, so this sits above that; legitimate calls take seconds.
private let toolDeadline = 60

private let argumentsTooLong = "the arguments are too long for one call"

/// Tool processes running now, so a server on its way out can stop them; once stopped, none starts.
private let toolProcessesLock = NSLock()
private var toolProcesses: Set<Process> = []
private var toolCallsStopped = false

/// Stops new tool calls and ends the ones running, so a server on its way out leaves none behind: each
/// is in a process group of its own, out of reach of a signal aimed at the server's group. Each gets
/// SIGTERM; one still running 2 seconds later gets SIGKILL, and after 2 more seconds this returns, so
/// it takes 4 seconds at most. Best effort at the edges: only a process still running is signalled,
/// since the pid of one that has exited may belong to another process, but that check and the signal
/// are two steps; and a process that survives SIGKILL for 2 seconds is left.
func stopToolCalls() {
    toolProcessesLock.lock()
    toolCallsStopped = true
    let running = toolProcesses
    toolProcessesLock.unlock()
    for process in running where process.isRunning { process.terminate() }
    waitForExit(running, seconds: 2)
    for process in running where process.isRunning { kill(process.processIdentifier, SIGKILL) }
    waitForExit(running, seconds: 2)
}

private func waitForExit(_ processes: Set<Process>, seconds: Double) {
    let deadline = DispatchTime.now() + seconds
    while processes.contains(where: \.isRunning) && DispatchTime.now() < deadline { usleep(10_000) }
}

/// A tool call runs this same binary with the matching command line, so a tool does exactly
/// what the command does. Bad input is a tool error the model can fix; an unknown tool is not.
private func call(_ params: [String: Any], _ offering: [Tool], _ guarded: ToolCallGuard?) throws -> [String: Any] {
    let name = params["name"] as? String ?? ""
    guard let tool = offering.first(where: { $0.name == name }) else {
        throw RPCError(code: -32602, message: "unknown tool: \(name)")
    }
    let arguments = params["arguments"] ?? [String: Any]()
    guard let arguments = arguments as? [String: Any] else {
        throw RPCError(code: -32602, message: "arguments must be an object")
    }
    let run = { try runTool(tool, arguments) }
    guard let guarded else { return try run().result }
    return try guarded(tool, arguments, run)
}

private func runTool(_ tool: Tool, _ arguments: [String: Any]) throws -> ToolCall {
    let name = tool.name
    let argv: [String]
    do {
        argv = try tool.argv(arguments)
    } catch {
        return ToolCall(result: toolResult("\(error)", isError: true))
    }

    guard let path = executablePath() else { throw RPCError(code: -32603, message: "cannot find the iris binary") }
    // Past 4096 arguments Process raises an exception Swift cannot catch and the server dies. Past the
    // system's limit on their bytes it throws E2BIG instead, caught below.
    guard argv.count <= 4096 else { return ToolCall(result: toolResult(argumentsTooLong, isError: true)) }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = argv
    process.standardInput = FileHandle.nullDevice
    let output = Pipe()
    let errors = Pipe()
    process.standardOutput = output
    process.standardError = errors
    let exited = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in exited.signal() }
    // Started and registered under one lock, so stopToolCalls cannot miss a process that is starting.
    toolProcessesLock.lock()
    if toolCallsStopped {
        toolProcessesLock.unlock()
        throw RPCError(code: -32603, message: "the server is stopping")
    }
    do {
        try process.run()
    } catch {
        toolProcessesLock.unlock()
        let failure = error as NSError
        if failure.domain == NSPOSIXErrorDomain && failure.code == Int(E2BIG) {
            return ToolCall(result: toolResult(argumentsTooLong, isError: true))
        }
        throw error
    }
    toolProcesses.insert(process)
    toolProcessesLock.unlock()
    // Every way out below waits for the exit first, so a process leaves the set only once it is gone.
    defer {
        toolProcessesLock.lock()
        toolProcesses.remove(process)
        toolProcessesLock.unlock()
    }
    guard let finished = collect(process, output, errors, exited: exited, within: toolDeadline) else {
        // No "try again": a write may have been saved before the child was stopped, and repeating it would double it.
        return ToolCall(result: toolResult("\(name) did not finish within \(toolDeadline) seconds and was stopped; "
            + "whether it took effect is not known. Before repeating a change, check that it was not made: with events "
            + "for a calendar change, with reminders for a reminder. If a permission dialog is open on this Mac, answer "
            + "it; if Calendar, Notes or Reminders is not responding, open it.",
            isError: true), started: true)
    }
    let out = String(decoding: finished.output, as: UTF8.self)
    let err = String(decoding: finished.errors, as: UTF8.self)

    if process.terminationStatus == 0 {
        return ToolCall(result: toolResult(out.trimmingCharacters(in: .whitespacesAndNewlines)), started: true)
    }
    // ArgumentParser follows a validation message with usage lines; those describe flags, not tool parameters.
    let message = err.split(separator: "\n").prefix { !$0.hasPrefix("Usage:") }.joined(separator: "\n")
    return ToolCall(result: toolResult(message.trimmingCharacters(in: .whitespacesAndNewlines), isError: true),
                    started: true, signalled: process.terminationReason == .uncaughtSignal)
}

/// What a started child of this binary wrote, once it exits; `exited` is signalled by its termination handler.
/// A child still running after `seconds` gets SIGTERM, and SIGKILL 2 seconds later; then this answers nil.
func collect(_ process: Process, _ output: Pipe, _ errors: Pipe, exited: DispatchSemaphore,
             within seconds: Int) -> (output: Data, errors: Data)? {
    // Both pipes are drained at once: either one can outgrow its buffer, and a full pipe
    // would stop the child before it closes the other.
    var outputBytes = Data()
    var errorBytes = Data()
    let draining = DispatchGroup()
    DispatchQueue.global().async(group: draining) { outputBytes = output.fileHandleForReading.readDataToEndOfFile() }
    DispatchQueue.global().async(group: draining) { errorBytes = errors.fileHandleForReading.readDataToEndOfFile() }
    if exited.wait(timeout: .now() + .seconds(seconds)) == .timedOut {
        process.terminate()
        if exited.wait(timeout: .now() + .seconds(2)) == .timedOut {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            exited.wait()
        }
        // The child is the whole tree: the re-launch in becomeResponsible keeps its pid, and no
        // command starts a process of its own, so its exit closes both pipes.
        draining.wait()
        return nil
    }
    draining.wait()
    return (outputBytes, errorBytes)
}

func toolResult(_ text: String, isError: Bool = false) -> [String: Any] {
    var result: [String: Any] = ["content": [["type": "text", "text": text]]]
    if isError { result["isError"] = true }
    return result
}
