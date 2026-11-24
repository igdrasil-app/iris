import ArgumentParser
import Foundation

struct MCP: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: "Serve the calendar and notes commands as MCP tools over stdio, or the read tools over HTTP.",
        // Lines stay under 80 columns: help wraps at 80 when piped, and a wrapped command no longer pastes.
        discussion: """
            Hosts start this, not people. Tools: calendars, events, add_event, update_event, delete_event, note_folders, notes, search_notes, show_note, with the fields of the commands. A call still running after 60 seconds is stopped and returns an error, so the server keeps answering. Each host adds iris with its own line; Claude Code, Codex and Grok CLI:

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

            Over HTTP, for a host that cannot start a process on this Mac:

              iris mcp --http

            serves only the read tools (calendars, events, note_folders, notes, search_notes, show_note) at http://127.0.0.1:8765/mcp, with no sessions: a request gets one JSON reply and a notification an empty 202; a request with an Expect header is refused (417). At most 16 connections and 4 tool calls at a time, and 60 seconds for a request to arrive. It prints one JSON line on stdout once it listens, then one line per request on stderr: time, methods, tool, status, duration; never arguments, results or the token. It listens on 127.0.0.1 only. Iris never makes it reachable from another machine; a proxy of your own can, and then your calendar and notes are reachable from wherever that proxy is, behind one token.

            Every request needs the header Authorization: Bearer <token>. The token is read once at start from --token-file, by default ~/Library/Application Support/Iris/http-token: a file of yours that only you can read (mode 600), holding at least 32 characters. Iris never creates it; this does:

              mkdir -p ~/Library/Application\\ Support/Iris
              (umask 077; openssl rand -base64 32 \\
                > ~/Library/Application\\ Support/Iris/http-token)

            Who can call it: a web page in your browser is stopped by the token, and by the refusal of every request that carries an Origin header. Another user of this Mac, and anything that arrives through your own proxy, is stopped by the token. A process running as you on this Mac is not stopped: it can read the token file, or run iris itself.

            A host adds it by URL and header; for Claude Code:

              claude mcp add --transport http iris-http \\
                http://127.0.0.1:8765/mcp \\
                --header "Authorization: Bearer <token>"
            """
    )

    @Flag(help: "Serve the read tools over HTTP on 127.0.0.1 instead of stdio.")
    var http = false

    @Option(help: "With --http: the port. Default: 8765.")
    var port: Int?

    @Option(help: "With --http: the file that holds the token. Default: ~/Library/Application Support/Iris/http-token.")
    var tokenFile: String?

    func validate() throws {
        if !http && (port != nil || tokenFile != nil) { throw ValidationError("--port and --token-file need --http") }
        if let port, !(1...65535).contains(port) { throw ValidationError("--port must be between 1 and 65535") }
    }

    func run() throws {
        if http { return try serveHTTP(port: port ?? defaultHTTPPort, tokenFile: tokenFile ?? defaultTokenFile) }
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
    "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev",
]

private let instructions = """
    Apple Calendar and Apple Notes on this Mac. Use these tools for anything in Calendar or Notes, not the \
    apps' windows, AppleScript or screen control; use those only when none of these tools covers the task. \
    Notes are read only: search_notes or notes finds a note and its id; show_note gives its text unless \
    the note is password protected. \
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

/// The reply to one message, or nil when none is due: a notification, or a stray response.
/// `offering` is every tool this caller may list or call: one outside it is not listed, and a call
/// to it is an unknown tool, answered before any process starts. The instructions and the tools'
/// own descriptions are not narrowed; a caller that offers fewer tools has to see to those itself.
func respond(to line: String, offering: [Tool]) -> [String: Any]? {
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
        var result = try handle(method, params, offering)
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

private func handle(_ method: String, _ params: [String: Any], _ offering: [Tool]) throws -> [String: Any] {
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
        return try call(params, offering)
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
private func call(_ params: [String: Any], _ offering: [Tool]) throws -> [String: Any] {
    let name = params["name"] as? String ?? ""
    guard let tool = offering.first(where: { $0.name == name }) else {
        throw RPCError(code: -32602, message: "unknown tool: \(name)")
    }
    let arguments = params["arguments"] ?? [String: Any]()
    guard let arguments = arguments as? [String: Any] else {
        throw RPCError(code: -32602, message: "arguments must be an object")
    }
    let argv: [String]
    do {
        argv = try tool.argv(arguments)
    } catch {
        return toolResult("\(error)", isError: true)
    }

    guard let path = executablePath() else { throw RPCError(code: -32603, message: "cannot find the iris binary") }
    // Past 4096 arguments Process raises an exception Swift cannot catch and the server dies. Past the
    // system's limit on their bytes it throws E2BIG instead, caught below.
    guard argv.count <= 4096 else { return toolResult(argumentsTooLong, isError: true) }
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
        if failure.domain == NSPOSIXErrorDomain && failure.code == Int(E2BIG) { return toolResult(argumentsTooLong, isError: true) }
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
    // Both pipes are drained at once: either one can outgrow its buffer, and a full pipe
    // would stop the child before it closes the other.
    var outputBytes = Data()
    var errorBytes = Data()
    let draining = DispatchGroup()
    DispatchQueue.global().async(group: draining) { outputBytes = output.fileHandleForReading.readDataToEndOfFile() }
    DispatchQueue.global().async(group: draining) { errorBytes = errors.fileHandleForReading.readDataToEndOfFile() }
    if exited.wait(timeout: .now() + .seconds(toolDeadline)) == .timedOut {
        process.terminate()
        if exited.wait(timeout: .now() + .seconds(2)) == .timedOut {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            exited.wait()
        }
        // The child is the whole tree: the re-launch in becomeResponsible keeps its pid, and no
        // command starts a process of its own, so its exit closes both pipes.
        draining.wait()
        // No "try again": a write may have been saved before the child was stopped, and repeating it would double it.
        return toolResult("\(name) did not finish within \(toolDeadline) seconds and was stopped; whether it took "
            + "effect is not known. Before repeating a change, check with events that it was not made. If a permission "
            + "dialog is open on this Mac, answer it; if Calendar or Notes is not responding, open it.",
            isError: true)
    }
    draining.wait()
    let out = String(decoding: outputBytes, as: UTF8.self)
    let err = String(decoding: errorBytes, as: UTF8.self)

    if process.terminationStatus == 0 { return toolResult(out.trimmingCharacters(in: .whitespacesAndNewlines)) }
    // ArgumentParser follows a validation message with usage lines; those describe flags, not tool parameters.
    let message = err.split(separator: "\n").prefix { !$0.hasPrefix("Usage:") }.joined(separator: "\n")
    return toolResult(message.trimmingCharacters(in: .whitespacesAndNewlines), isError: true)
}

private func toolResult(_ text: String, isError: Bool = false) -> [String: Any] {
    var result: [String: Any] = ["content": [["type": "text", "text": text]]]
    if isError { result["isError"] = true }
    return result
}
