import Foundation

// The calendar writes of `iris mcp --http`, offered only when the scope file says "writes": true, and
// the guards around them: delete_event reaches one occurrence at most, one write runs at a time, at most
// `writesPerHour` write calls reach their command in any rolling hour, counted across restarts, and every
// write that reached its command is recorded. The calendar scope itself is enforced by the commands.

let httpWriteToolNames = ["add_event", "update_event", "delete_event"]

let writesPerHour = 20
let writeWindow = 3600.0                     // seconds
let defaultStateDir = "~/Library/Application Support/Iris"
private let recordCap = 4 * 1024 * 1024      // bytes; past this the record keeps its newest half
private let timesFileLimit = 65536           // bytes; a larger times file is not ours, and counts as unreadable

/// True when a delete_event with these arguments could remove more than one occurrence. An allowlist:
/// span passes only absent, null (a tool call reads null as absent) or exactly "this", so no other spelling
/// needs foreseeing. The command itself takes only the exact string "future" for more (parseSpan).
func deletesPastOne(_ arguments: [String: Any]) -> Bool {
    guard let span = arguments["span"], !(span is NSNull) else { return false }
    return span as? String != "this"
}

/// The ages in seconds of the writes a saved times file holds from the last window, oldest first, at most
/// `limit` of them: past that the older ones do not change when the next write is allowed. A time in the
/// future counts as just made; a line that is not a time is skipped.
func recentWriteAges(_ text: String, now: Double, window: Double = writeWindow, limit: Int = writesPerHour) -> [Double] {
    let ages = text.split(whereSeparator: \.isNewline).compactMap { line -> Double? in
        guard let made = Double(line.trimmingCharacters(in: .whitespaces)), made.isFinite else { return nil }
        let age = max(0, now - made)
        return age < window ? age : nil
    }
    return Array(ages.sorted(by: >).suffix(limit))
}

/// Whole minutes until one more write call may be made, never 0; nil when one may be made now. `times`
/// are the counted writes, oldest first, on the clock `now` is read from.
func minutesUntilNextWrite(_ times: [Double], now: Double, window: Double = writeWindow, limit: Int = writesPerHour) -> Int? {
    let recent = times.filter { $0 > now - window }
    guard recent.count >= limit else { return nil }
    // The write that has to age out before the count drops below the limit.
    let wait = recent[recent.count - limit] + window - now
    return max(1, Int((wait / 60).rounded(.up)))
}

/// What the record keeps of a write's result: whether it is an error, and its text. A result not shaped as
/// a tool result is kept whole and marked an error.
func recordedText(_ result: [String: Any]) -> (error: Bool, text: String) {
    let isError = result["isError"]
    let parts = (result["content"] as? [Any])?.map { part -> String? in
        guard let part = part as? [String: Any], part["type"] as? String == "text" else { return nil }
        return part["text"] as? String
    }
    if let parts, !parts.contains(where: { $0 == nil }),
       isError == nil || CFGetTypeID(isError as CFTypeRef) == CFBooleanGetTypeID() {
        return (isError as? Bool ?? false, parts.compactMap { $0 }.joined(separator: "\n"))
    }
    let whole = JSONSerialization.isValidJSONObject(result)
        ? (try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) }
        : nil
    return (true, "unexpected result: " + (whole ?? "\(result)"))
}

/// The newest whole lines of `data` that fit in `limit` bytes; the newest is kept even when it alone is larger.
func newestLines(_ data: Data, within limit: Int) -> Data {
    var kept: [Data] = []
    var size = 0
    for line in data.split(separator: UInt8(ascii: "\n")).reversed() {
        let entry = Data(line) + Data("\n".utf8)
        if !kept.isEmpty && size + entry.count > limit { break }
        kept.append(entry)
        size += entry.count
    }
    return Data(kept.reversed().joined())
}

final class WriteGuard {
    /// One write at a time. Taken before a tool-call slot, so writes waiting for one another never hold the
    /// slots reads need; given back when the reply begins.
    let turn = DispatchSemaphore(value: 1)
    private let timesPath: String
    private let recordPath: String
    private var times: [Double] = []         // the counted writes, oldest first, on `monotonicNow`; under `turn`

    /// The folder is created owner-only when it is missing; one that exists is used as it is.
    init(stateDir: String) throws {
        let directory = (stateDir as NSString).expandingTildeInPath
        do {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            throw IrisError("cannot use \(directory) as the state folder: \(error.localizedDescription)")
        }
        timesPath = directory + "/http-write-times"
        recordPath = directory + "/http-writes.log"
    }

    /// Counts the writes the times file holds from the last hour, at their real ages, so a restart does not
    /// open a fresh allowance, and saves them back. A missing file is an empty one; one that exists but cannot
    /// be read counts as a full hour of writes. Call it once the port is held: a second launch that cannot
    /// listen must leave a running server's count alone.
    func seed() {
        let ages = savedTimes().map { recentWriteAges($0, now: Date().timeIntervalSince1970) }
            ?? Array(repeating: 0, count: writesPerHour)
        let now = monotonicNow()
        times = ages.map { now - $0 }
        try? saveTimes()                     // if it fails, the next write tries again and is refused
    }

    /// A tool call through the guards when it is a write; any other runs as it is. A write is called holding
    /// `turn`; `marks` collects the request log's markers.
    func call(_ tool: Tool, _ arguments: [String: Any], _ run: () throws -> ToolCall,
              marks: inout [String]) throws -> [String: Any] {
        guard httpWriteToolNames.contains(tool.name) else { return try run().result }
        if tool.name == "delete_event" && deletesPastOne(arguments) {
            marks.append("span-refused")
            return toolResult("Deleting all future occurrences of a recurring event (span future) is not available "
                + "through this endpoint and must be done on the Mac. Nothing was deleted. To delete one occurrence, "
                + "pass occurrence and leave span out or set it to this.", isError: true)
        }
        let now = monotonicNow()
        times.removeAll { $0 <= now - writeWindow }
        if let minutes = minutesUntilNextWrite(times, now: now) {
            marks.append("write-limit")
            return toolResult("The limit of \(writesPerHour) calendar write calls an hour through this endpoint is "
                + "reached, so nothing was changed. The next write call is possible in about \(minutes) "
                + "minute\(minutes == 1 ? "" : "s").", isError: true)
        }
        // Counted and saved before the command runs, so a crash cannot forget it. A call the command refuses
        // counts too: a model looping on bad arguments meets the limit as well.
        times.append(now)
        do {
            try saveTimes()
        } catch {
            times.removeLast()
            marks.append("times-failed")
            return toolResult("This calendar write call could not be counted toward the hourly limit (the server "
                + "could not save its count of recent writes), so it was not made and nothing was changed. "
                + "Reads still work.", isError: true)
        }

        var call = try run()
        guard call.started else { return call.result }
        if call.signalled {
            call.result = toolResult("\(tool.name) was stopped before it finished; whether it took effect is not "
                + "known. Before repeating a change, check with events that it was not made.", isError: true)
        }
        do {
            try record(tool.name, call.result)
        } catch {
            marks.append("record-failed")
        }
        return call.result
    }

    /// The times file's text; "" when there is none, nil when it exists but cannot be read.
    private func savedTimes() -> String? {
        let descriptor = open(timesPath, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return errno == ENOENT ? "" : nil }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= timesFileLimit,
              let data = try? file.readToEnd() ?? Data() else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Replaces the times file with the counted writes as wall-clock times, one per line, nothing else.
    private func saveTimes() throws {
        let now = monotonicNow()
        let wall = Date().timeIntervalSince1970
        let text = times.map { String(format: "%.6f\n", wall - (now - $0)) }.joined()
        try replaceFile(timesPath, with: Data(text.utf8))
    }

    /// Appends one JSON line for a write that reached its command: the time, the tool, whether it is an error,
    /// and the text the command returned. Unlike the request log this file DOES hold calendar content, by
    /// design: for a success the text is the event as iris printed it, which is what makes a wrong change
    /// undoable by hand. Owner-only; past `recordCap` it keeps its newest whole lines. Called holding `turn`.
    private func record(_ tool: String, _ result: [String: Any]) throws {
        let (error, text) = recordedText(result)
        let entry: [String: Any] = ["time": iso(Date()), "tool": tool, "error": error, "text": text]
        let line = try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys, .withoutEscapingSlashes])
            + Data("\n".utf8)
        let descriptor = open(recordPath, O_RDWR | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw failure(recordPath) }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() else {
            throw IrisError("\(recordPath) is not a file of this user's")
        }
        if info.st_mode & 0o077 != 0 && fchmod(descriptor, 0o600) != 0 { throw failure(recordPath) }
        if info.st_size > recordCap {
            try replaceFile(recordPath, with: newestLines((try file.readToEnd() ?? Data()) + line, within: recordCap / 2))
        } else {
            try file.write(contentsOf: line)
        }
    }
}

/// Seconds on a clock that counts sleep and never jumps, so a write's age is its real age.
private func monotonicNow() -> Double {
    Double(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1e9
}

/// Writes `data` to a new owner-only file beside `path`, flushes it and renames it over `path`, so a crash
/// leaves the old file or the new one, whole.
private func replaceFile(_ path: String, with data: Data) throws {
    let temporary = path + ".new"
    let descriptor = open(temporary, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw failure(temporary) }
    let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    guard fchmod(descriptor, 0o600) == 0 else { throw failure(temporary) }
    try file.write(contentsOf: data)
    guard fsync(descriptor) == 0, rename(temporary, path) == 0 else { throw failure(path) }
}

private func failure(_ path: String) -> IrisError {
    IrisError("\(path): \(String(cString: strerror(errno)))")
}
