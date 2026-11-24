import Foundation
import Network

/// The tools offered over HTTP: the read tools, by name, and the calendar writes (`httpWriteToolNames`)
/// when the scope file turns them on. Allowlists, so a tool added to iris later stays off HTTP until it is
/// named in one.
let httpToolNames = ["calendars", "events", "note_folders", "notes", "search_notes", "show_note"]

let defaultHTTPPort = 8765
let defaultTokenFile = "~/Library/Application Support/Iris/http-token"

/// `respond` does not narrow the instructions; over HTTP these sentences do. They name no calendar or
/// folder of the scope.
private let scopeNote = " Only the calendars and note folders its owner chose are available here; any other "
    + "does not exist for this endpoint."
private let readOnlyNote = " This endpoint is read only: it offers \(httpToolNames.joined(separator: ", ")), "
    + "and cannot create, change or delete anything." + scopeNote

private func writableNote(_ offering: [Tool]) -> String {
    " This endpoint offers \(offering.map(\.name).joined(separator: ", ")). Calendar events can be created, "
        + "changed and deleted only in the calendars its owner chose, at most \(writesPerHour) write calls an hour; "
        + "deleting all future occurrences of a recurring event (delete_event with span future) is not available "
        + "here and must be done on the Mac. Notes are read only." + scopeNote
}

private let maxConnections = 16      // one more is closed as soon as it arrives
private let maxToolCalls = 4
private let slotWait = 5             // seconds a tool call waits for a free slot, then 503
private let requestDeadline = 60     // seconds to send the head and the body, however slowly
private let writeDeadline = 600      // seconds to take a reply: a note can run to megabytes
private let replyWait = 10           // seconds a stopping server waits for write replies to be sent
private let maxHead = (maxHeaders + 1) * (maxHeadLine + 2)

// Under 2026-07-28 these JSON-RPC errors also carry an HTTP status (Streamable HTTP, Request Metadata).
private let modernErrorStatus = [-32022: 400, -32020: 400, -32601: 404]

/// Serves the read tools, and the calendar writes when the scope file says so, on 127.0.0.1 until SIGTERM
/// or SIGINT, then stops any tool call still running. Every tool call is limited to the scope pinned here,
/// at start. `stateDir` holds the write record and the count of recent writes; with writes off it is not touched.
func serveHTTP(port: Int, tokenFile: String, scopeFile: String, stateDir: String) throws {
    let token = try readToken((tokenFile as NSString).expandingTildeInPath)
    let scope = try readScope((scopeFile as NSString).expandingTildeInPath)
    let names = httpToolNames + (scope.writes ? httpWriteToolNames : [])
    let offering = try tools.filter { names.contains($0.name) }.map { try $0.limited(to: scope) }
    let writes = scope.writes ? try WriteGuard(stateDir: stateDir) : nil
    // A client gone mid-reply is an error on that one write, not the end of the server.
    signal(SIGPIPE, SIG_IGN)
    let stop = DispatchSemaphore(value: 0)
    let signals = [SIGTERM, SIGINT].map { number in
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
        source.setEventHandler { stop.signal() }
        source.resume()
        return source
    }

    let server = HTTPServer(token: token, offering: offering, writes: writes,
                            note: writes == nil ? readOnlyNote : writableNote(offering))
    // Requests arrive as soon as the listener is up; a write waits until the count is read back. The turn
    // is always given back: a semaphore freed while taken stops the process.
    writes?.turn.wait()
    // A listener that dies while serving ends the server the way a signal does, then with an error.
    var listenerFailure: String?
    let listener: NWListener
    do {
        listener = try server.listen(on: port) { message in
            listenerFailure = message
            stop.signal()
        }
    } catch {
        writes?.turn.signal()
        throw error
    }
    writes?.seed()
    writes?.turn.signal()
    // How many calendars and folders are in scope, never which.
    let ready: [String: Any] = ["address": "127.0.0.1", "port": port, "tools": server.offering.map(\.name),
                                "calendars": scope.calendars.map { $0.count as Any } ?? "all",
                                "folders": scope.folders.map { $0.count as Any } ?? "all",
                                "writes": scope.writes]
    if let line = try? JSONSerialization.data(withJSONObject: ready, options: [.sortedKeys]) {
        try? FileHandle.standardOutput.write(contentsOf: line + Data("\n".utf8))
    }

    stop.wait()
    listener.cancel()
    stopToolCalls()
    // A write that started is recorded before its reply begins; its reply gets a bounded time to be sent.
    _ = writes?.replies.wait(timeout: .now() + .seconds(replyWait))
    signals.forEach { $0.cancel() }
    if let listenerFailure { throw IrisError(listenerFailure) }
}

/// The token, read once.
func readToken(_ path: String) throws -> String {
    let directory = (path as NSString).deletingLastPathComponent
    let recipe = "create one: mkdir -p \"\(directory)\" && (umask 077; openssl rand -base64 32 > \"\(path)\")"
    let data = try readPrivateFile(path, noun: "token file", recipe: recipe, limit: 4096)
    let token = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    guard token.count >= 32, token.utf8.allSatisfy({ (0x21...0x7E).contains($0) }) else {
        throw IrisError("\(path) must hold a token of at least 32 characters, ASCII without spaces; \(recipe)")
    }
    return token
}

/// A file of at most `limit` bytes that must be a regular file of this user's that no one else may read.
/// `noun` and `recipe` say in the errors what the file is and how to make one.
func readPrivateFile(_ path: String, noun: String, recipe: String, limit: Int) throws -> Data {
    // Non-blocking, so a FIFO without a writer cannot hold the open; the check below refuses it.
    let descriptor = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
    guard descriptor >= 0 else {
        if errno == ENOENT { throw IrisError("no \(noun) at \(path); \(recipe)") }
        throw IrisError("cannot read the \(noun) \(path): \(String(cString: strerror(errno)))")
    }
    let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    // Checked on the open file, so what is checked is what is read.
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= limit else {
        throw IrisError("\(path) is not a \(noun); \(recipe)")
    }
    guard info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
        throw IrisError("\(path) must be yours and readable by you only: chmod 600 \"\(path)\"")
    }
    // An extended ACL can let others read a file whatever its mode. No ACL is nil with ENOENT.
    errno = 0
    if let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) {
        var entry: acl_entry_t?
        let hasEntry = acl_get_entry(acl, ACL_FIRST_ENTRY.rawValue, &entry) == 0
        acl_free(UnsafeMutableRawPointer(acl))
        if hasEntry { throw IrisError("\(path) has an access control list, which can let others read it; remove it: chmod -N \"\(path)\"") }
    } else if errno != ENOENT {
        throw IrisError("cannot read the access control list of \(path): \(String(cString: strerror(errno)))")
    }
    return try file.readToEnd() ?? Data()
}

private final class HTTPServer {
    let token: String
    let offering: [Tool]
    let writes: WriteGuard?              // nil when writes are off
    let note: String                     // appended to the instructions
    private let queue = DispatchQueue(label: "iris.http")
    private var open = 0                 // connections, counted on `queue`
    private let slots = DispatchSemaphore(value: maxToolCalls)

    init(token: String, offering: [Tool], writes: WriteGuard?, note: String) {
        self.token = token
        self.offering = offering
        self.writes = writes
        self.note = note
    }

    /// Listening on 127.0.0.1 and nothing else, or an error that names the port. If the listener dies later,
    /// `stopped` gets the message.
    func listen(on port: Int, stopped: @escaping (String) -> Void) throws -> NWListener {
        guard let number = NWEndpoint.Port(rawValue: UInt16(port)) else { throw IrisError("no such port: \(port)") }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: number)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [self] connection in accept(connection) }

        let settled = DispatchSemaphore(value: 0)
        var failure: NWError?
        var listening = false
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                listening = true
                settled.signal()
            case .failed(let error), .waiting(let error):
                guard listening else { failure = error; settled.signal(); return }
                // The listener died while serving: nothing more can arrive, so the server ends.
                stopped("stopped listening on 127.0.0.1:\(port): \(error)")
            default:
                break
            }
        }
        listener.start(queue: queue)
        settled.wait()
        guard let failure else { return listener }
        listener.cancel()
        if case .posix(.EADDRINUSE) = failure {
            throw IrisError("port \(port) is in use on 127.0.0.1; stop what holds it or choose another with --port")
        }
        throw IrisError("cannot listen on 127.0.0.1:\(port): \(failure)")
    }

    private func accept(_ connection: NWConnection) {
        guard open < maxConnections else { connection.forceCancel(); return }
        open += 1
        connection.stateUpdateHandler = { [self] state in
            switch state {
            case .failed: connection.cancel()
            case .cancelled:
                open -= 1                        // the one place a connection is counted out
                connection.stateUpdateHandler = nil   // the handler holds the connection; let both go
            default: break
            }
        }
        connection.start(queue: queue)
        // Each connection gets a thread of its own: a tool call blocks it for up to a minute.
        let thread = Thread { [self] in serve(connection) }
        thread.stackSize = 8 << 20               // JSONSerialization recurses once per level of nesting
        thread.start()
    }

    // One request per connection: read it, answer with Connection: close, close.
    private func serve(_ connection: NWConnection) {
        let started = DispatchTime.now()
        var entry = LogEntry()
        guard let reply = handle(connection, &entry) else { connection.cancel(); return }
        // A write is over once its reply begins: a client reading it slowly must not hold up the next write.
        if reply.holdsWriteTurn { writes?.turn.signal() }
        let sent = DispatchSemaphore(value: 0)
        connection.send(content: reply.encoded, contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { _ in sent.signal() })
        let delivered = sent.wait(timeout: .now() + .seconds(writeDeadline)) == .success
        if reply.holdsWriteTurn { writes?.replies.leave() }
        if reply.holdsSlot { slots.signal() }
        let seconds = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1e9
        writeError(([iso(Date()), entry.httpMethod, entry.rpcMethod, entry.tool, String(reply.status),
                     String(format: "%.3fs", seconds)] + entry.marks + (delivered ? [] : ["write-timeout"]))
            .joined(separator: " "))
        guard delivered else { connection.forceCancel(); return }
        // Input left unread at close makes the kernel send a reset, which can destroy the reply before
        // the client reads it; so whatever else the client sends is read and dropped, for 2 seconds at most.
        let drain = DispatchTime.now() + .seconds(2)
        while case .data = receive(connection, atMost: 65536, by: drain) {}
        connection.cancel()
    }

    /// The reply to the request on this connection, or nil when the client sent nothing and left.
    private func handle(_ connection: NWConnection, _ entry: inout LogEntry) -> Reply? {
        let deadline = DispatchTime.now() + .seconds(requestDeadline)
        let blankLine = Data("\r\n\r\n".utf8)
        var buffer = Data()
        var headEnd: Range<Data.Index>?
        while headEnd == nil {
            if buffer.count > maxHead { return Reply(status: 431) }
            // Only the new bytes are searched, and the three before them: a blank line can straddle two reads.
            let searchFrom = max(0, buffer.count - 3)
            switch receive(connection, atMost: 65536, by: deadline) {
            case .data(let data): buffer += data
            case .closed: return buffer.isEmpty ? nil : Reply(status: 400)
            case .timedOut: return Reply(status: 408)
            }
            headEnd = buffer.range(of: blankLine, in: searchFrom..<buffer.count)
            // A bare LF line end would never reach a CRLF blank line; refuse it now, not at the deadline.
            if headEnd == nil && buffer.range(of: Data("\n\n".utf8), in: searchFrom..<buffer.count) != nil {
                return Reply(status: 400)
            }
        }
        // Until the head is whole and parsed its token cannot be seen, so the refusals above and this
        // 400 are the only answers given without one.
        guard let headEnd, let head = parseHead(Array(buffer[..<headEnd.lowerBound])) else { return Reply(status: 400) }
        entry.httpMethod = label(head.method, among: httpMethods)

        switch gate(head, token: token) {
        case .refuse(let status):
            return Reply(status: status)
        case .accept(let length):
            var body = Data(buffer[headEnd.upperBound...])
            while body.count < length {
                switch receive(connection, atMost: length - body.count, by: deadline) {
                case .data(let data): body += data
                case .closed: return Reply(status: 400)      // shorter than it said
                case .timedOut: return Reply(status: 408)
                }
            }
            return answer(Data(body.prefix(length)), head, &entry)
        }
    }

    private func answer(_ body: Data, _ head: RequestHead, _ entry: inout LogEntry) -> Reply {
        // The body is one JSON value, read as strict UTF-8, and respond gets that same text: raw newlines
        // in it are whitespace inside the value and cannot start a second message.
        guard let text = String(data: body, encoding: .utf8),
              let value = try? JSONSerialization.jsonObject(with: Data(text.utf8)) else {
            return failure(400, id: NSNull(), -32700, "parse error")
        }
        if value is [Any] { return failure(400, id: NSNull(), -32600, "batches are not supported; send one message per request") }
        guard let message = value as? [String: Any] else { return failure(400, id: NSNull(), -32600, "invalid request") }
        let method = message["method"] as? String
        let params = message["params"] as? [String: Any] ?? [:]
        entry.rpcMethod = label(message["method"], among: rpcMethods)
        if method == "tools/call" { entry.tool = label(params["name"], among: offering.map(\.name)) }
        // A notification or a client's response: accepted, and there is nothing to do.
        guard message["method"] != nil, let id = message["id"] else { return Reply(status: 202) }

        let modern = (params["_meta"] as? [String: Any])?[versionKey] != nil
        if let problem = headerProblem(head, method, params, modern: modern) {
            return failure(400, id: id, modern ? -32020 : -32600, problem)
        }
        // respond reads the same text the same way, so this is the tool it will call.
        guard method == "tools/call", let writes, let name = params["name"] as? String,
              httpWriteToolNames.contains(name) else {
            return reply(to: text, method, id: id, modern: modern, &entry)
        }
        // One write at a time, waited for before a tool-call slot.
        guard writes.turn.wait(timeout: .now() + .seconds(slotWait)) == .success else {
            entry.marks.append("write-busy")
            return failure(503, id: id, -32603, "busy: another calendar change is still running, and this one "
                + "was not made; try again shortly")
        }
        // Counted out in serve once the reply is sent; a stopping server waits for that.
        writes.replies.enter()
        var written = reply(to: text, method, id: id, modern: modern, &entry)
        written.holdsWriteTurn = true
        return written
    }

    private func reply(to text: String, _ method: String?, id: Any, modern: Bool, _ entry: inout LogEntry) -> Reply {
        // A slot is held until the reply is written, so clients that read slowly cannot pile up replies.
        let holdsSlot = method == "tools/call"
        if holdsSlot && slots.wait(timeout: .now() + .seconds(slotWait)) == .timedOut {
            return failure(503, id: id, -32603, "busy; try again shortly")
        }
        var marks: [String] = []
        var guarded: ToolCallGuard?
        if let writes {
            guarded = { tool, arguments, run in try writes.call(tool, arguments, run, marks: &marks) }
        }
        let answered = respond(to: text, offering: offering, guarded: guarded)
        entry.marks += marks
        guard var response = answered else { return Reply(status: 202, holdsSlot: holdsSlot) }

        if let method, ["initialize", "server/discover", "tools/list"].contains(method),
           var result = response["result"] as? [String: Any] {
            if let instructions = result["instructions"] as? String { result["instructions"] = instructions + note }
            // The list is this endpoint's, not every client's of iris.
            if result["cacheScope"] != nil { result["cacheScope"] = "private" }
            response["result"] = result
        }
        var status = 200
        if modern, let code = (response["error"] as? [String: Any])?["code"] as? Int {
            status = modernErrorStatus[code] ?? 200
        }
        return json(status, response, holdsSlot: holdsSlot)
    }

    private func failure(_ status: Int, id: Any, _ code: Int, _ message: String) -> Reply {
        json(status, ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    private func json(_ status: Int, _ object: [String: Any], holdsSlot: Bool = false) -> Reply {
        // data(withJSONObject:) raises an exception Swift cannot catch on what it cannot encode; check first.
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return Reply(status: 500, body: Data(#"{"error":{"code":-32603,"message":"internal error"},"id":null,"jsonrpc":"2.0"}"#.utf8),
                         holdsSlot: holdsSlot)
        }
        return Reply(status: status, body: data, holdsSlot: holdsSlot)
    }
}

/// Why the MCP headers disagree with the body, or nil. Since 2026-07-28 a request repeats its version,
/// method and tool name in headers, and they must match the body; an older request needs none of them.
private func headerProblem(_ head: RequestHead, _ method: String?, _ params: [String: Any], modern: Bool) -> String? {
    let versions = head.values("mcp-protocol-version")
    guard modern else {
        let known = legacyVersions + [modernVersion]
        return versions.allSatisfy(known.contains) ? nil : "unsupported MCP-Protocol-Version header"
    }
    let requested = (params["_meta"] as? [String: Any])?[versionKey] as? String
    guard let requested, versions == [requested] else {
        return "MCP-Protocol-Version header missing or not equal to the body's protocol version"
    }
    guard let method, head.values("mcp-method") == [method] else {
        return "Mcp-Method header missing or not equal to the body's method"
    }
    if method == "tools/call" {
        guard let name = params["name"] as? String, head.values("mcp-name").map(decodedName) == [name] else {
            return "Mcp-Name header missing or not equal to the body's tool name"
        }
    }
    return nil
}

/// Mcp-Name comes as =?base64?…?= when the name is not plain ASCII.
private func decodedName(_ value: String) -> String? {
    guard value.count >= 11, value.hasPrefix("=?base64?"), value.hasSuffix("?=") else { return value }
    guard let data = Data(base64Encoded: String(value.dropFirst(9).dropLast(2))) else { return nil }
    return String(data: data, encoding: .utf8)
}

private let reasons = [
    200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found",
    405: "Method Not Allowed", 406: "Not Acceptable", 408: "Request Timeout", 413: "Content Too Large",
    417: "Expectation Failed", 431: "Request Header Fields Too Large", 500: "Internal Server Error", 503: "Service Unavailable",
]

private struct Reply {
    var status: Int
    var body: Data? = nil
    var holdsSlot = false
    var holdsWriteTurn = false

    var encoded: Data {
        var head = "HTTP/1.1 \(status) \(reasons[status] ?? "")\r\n"
        if body != nil { head += "Content-Type: application/json\r\n" }
        head += "Content-Length: \(body?.count ?? 0)\r\n"
        if status == 401 { head += "WWW-Authenticate: Bearer\r\n" }
        if status == 405 { head += "Allow: POST\r\n" }
        head += "Connection: close\r\n\r\n"
        return Data(head.utf8) + (body ?? Data())
    }
}

/// What the request log says about one request. Never arguments, results, the token or the query.
private struct LogEntry {
    var httpMethod = "-"
    var rpcMethod = "-"
    var tool = "-"
    /// Fixed words for what the write guards did: write-busy, span-refused, write-limit, times-failed, record-failed.
    var marks: [String] = []
}

private let httpMethods = ["GET", "HEAD", "POST", "PUT", "DELETE", "CONNECT", "OPTIONS", "TRACE", "PATCH"]
private let rpcMethods = ["initialize", "server/discover", "ping", "tools/list", "tools/call"]

/// A name the client sent, logged only if it is one of the names this server knows: anything else,
/// a token pasted in the wrong place included, is "-".
private func label(_ value: Any?, among known: [String]) -> String {
    guard let text = value as? String else { return "-" }
    return known.first { $0 == text } ?? "-"
}

private enum Received {
    case data(Data)
    case closed
    case timedOut
}

private func receive(_ connection: NWConnection, atMost limit: Int, by deadline: DispatchTime) -> Received {
    let done = DispatchSemaphore(value: 0)
    var received = Received.closed
    connection.receive(minimumIncompleteLength: 1, maximumLength: limit) { data, _, _, _ in
        if let data, !data.isEmpty { received = .data(data) }
        done.signal()
    }
    return done.wait(timeout: deadline) == .timedOut ? .timedOut : received
}

private func writeError(_ line: String) {
    try? FileHandle.standardError.write(contentsOf: Data((line + "\n").utf8))
}
