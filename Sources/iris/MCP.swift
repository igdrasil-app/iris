import ArgumentParser
import Foundation

struct MCP: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: "Serve the calendar and notes commands as MCP tools over stdio.",
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
            """
    )

    func run() throws {
        // One JSON-RPC message per line in, one per line out. EOF is the host saying goodbye.
        while let line = readLine() {
            if line.allSatisfy(\.isWhitespace) { continue }
            guard let response = respond(to: line) else { continue }
            let data = try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys, .withoutEscapingSlashes])
            FileHandle.standardOutput.write(data + Data("\n".utf8))
        }
    }
}

// Two generations of the protocol are in use. Since 2026-07-28 every request carries its
// version in `_meta` and there is no handshake; before that a client sends `initialize`
// once. Claude Code probes with the new form and falls back to the old one, so we answer both.
private let modernVersion = "2026-07-28"
private let legacyVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
private let versionKey = "io.modelcontextprotocol/protocolVersion"

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

/// The reply to one line, or nil when none is due: a notification, or a stray response.
private func respond(to line: String) -> [String: Any]? {
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
        var result = try handle(method, params)
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

private func handle(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
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
        return cacheable(["tools": tools.map(\.definition)])
    case "tools/call":
        return try call(params)
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

/// A tool call runs this same binary with the matching command line, so a tool does exactly
/// what the command does. Bad input is a tool error the model can fix; an unknown tool is not.
private func call(_ params: [String: Any]) throws -> [String: Any] {
    let name = params["name"] as? String ?? ""
    guard let tool = tools.first(where: { $0.name == name }) else {
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
    try process.run()
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
        return toolResult("\(name) did not finish within \(toolDeadline) seconds and was stopped. If a permission "
            + "dialog is open on this Mac, answer it; if Calendar or Notes is not responding, open it; then try again.",
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
