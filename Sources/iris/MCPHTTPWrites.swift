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

/// The counted writes a saved times file holds, on the monotonic clock, oldest first: only those of the last
/// window, at most `limit`. Its first line names the boot session the times were taken in. Times of this
/// boot are used as they are. From another boot, or in a file that is not all readable, every entry counts
/// as just made: the monotonic clock starts again at each boot, so after a reboot the ages are not known,
/// and the wall clock is never used, because setting it must not reopen the allowance.
func savedWriteTimes(_ text: String, boot: String, now: Double, window: Double = writeWindow,
                     limit: Int = writesPerHour) -> [Double] {
    var lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
    let saidBoot = lines.first.flatMap { UUID(uuidString: $0) } != nil
    let sameBoot = saidBoot && lines.first == boot
    if saidBoot { lines.removeFirst() }
    let times = lines.map { Double($0) }
    guard sameBoot, times.allSatisfy({ $0?.isFinite == true }) else {
        return Array(repeating: now, count: min(lines.count, limit))
    }
    return Array(times.compactMap { $0 }.map { min($0, now) }.filter { $0 > now - window }.sorted().suffix(limit))
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
    /// Writes whose reply has not been sent yet: the server waits for them before it exits.
    let replies = DispatchGroup()
    private let folder: FileHandle           // holds the lock on the state folder for the guard's lifetime
    private let timesPath: String
    private let recordPath: String
    private var times: [Double] = []         // the counted writes, oldest first, on `monotonicNow`; under `turn`

    /// The folder is created owner-only when it is missing. It must be this user's, writable by no one else,
    /// and not in use by another server: two servers on one folder would each replace the other's count.
    init(stateDir: String) throws {
        let directory = (stateDir as NSString).expandingTildeInPath
        do {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            throw IrisError("cannot use \(directory) as the state folder: \(error.localizedDescription)")
        }
        let descriptor = open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw failure(directory) }
        folder = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o022 == 0 else {
            throw IrisError("the state folder \(directory) must be yours and writable by you only: chmod go-w \"\(directory)\"")
        }
        if try aclAllows(descriptor, directory) {
            throw IrisError("the state folder \(directory) has an access control list that lets others in; "
                + "remove it: chmod -N \"\(directory)\"")
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw IrisError("the state folder \(directory) is in use by another iris mcp --http with writes on; "
                + "give each its own --state-dir")
        }
        timesPath = directory + "/http-write-times"
        recordPath = directory + "/http-writes.log"
    }

    /// Counts the writes the times file holds from the last hour, so a restart does not open a fresh allowance,
    /// and saves them back. A missing file is an empty one; one that exists but cannot be read, or is not this
    /// user's, counts as a full hour of writes. Call it once the port is held.
    func seed() {
        let now = monotonicNow()
        times = savedTimes().map { savedWriteTimes($0, boot: bootSession, now: now) }
            ?? Array(repeating: now, count: writesPerHour)
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

    /// The times file's text; "" when there is none, nil when it exists but cannot be read or is not this user's.
    private func savedTimes() -> String? {
        let descriptor = open(timesPath, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return errno == ENOENT ? "" : nil }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_size <= timesFileLimit, let data = try? file.readToEnd() ?? Data() else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Replaces the times file with this boot session, then the counted writes' monotonic times, one per line.
    private func saveTimes() throws {
        let text = bootSession + "\n" + times.map { String(format: "%.6f\n", $0) }.joined()
        try replaceFile(timesPath, with: Data(text.utf8))
    }

    /// Appends one JSON line for a write that reached its command: the time, the tool, whether it is an error,
    /// and the text the command returned. Unlike the request log this file DOES hold calendar content, by
    /// design: for a success the text is the event as iris printed it, which is what makes a wrong change
    /// undoable by hand. Owner-only, with no access control list; when this line would take it past
    /// `recordCap` it keeps its newest whole lines, the newest always. Called holding `turn`.
    private func record(_ tool: String, _ result: [String: Any]) throws {
        let (error, text) = recordedText(result)
        let entry: [String: Any] = ["time": iso(Date()), "tool": tool, "error": error, "text": text]
        let line = try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys, .withoutEscapingSlashes])
            + Data("\n".utf8)
        // Non-blocking, so a FIFO in its place cannot hold the open; the check below refuses it.
        let descriptor = open(recordPath, O_RDWR | O_APPEND | O_CREAT | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw failure(recordPath) }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() else {
            throw IrisError("\(recordPath) is not a file of this user's")
        }
        try makePrivate(descriptor, recordPath)
        if Int(info.st_size) + line.count > recordCap {
            try replaceFile(recordPath, with: newestLines((try file.readToEnd() ?? Data()) + line, within: recordCap / 2))
        } else {
            try file.write(contentsOf: line)
        }
    }
}

/// Seconds on a clock that counts sleep and never jumps, so a write's age is its real age. It starts again
/// at each boot.
private func monotonicNow() -> Double {
    Double(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1e9
}

/// This boot's session id; "" if it cannot be read, which no saved file matches.
private let bootSession: String = {
    var size = 0
    guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 0 else { return "" }
    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0 else { return "" }
    return String(cString: buffer)
}()

/// Writes `data` to a new owner-only file beside `path`, flushes it and renames it over `path`, so a crash
/// leaves the old file or the new one, whole. The new file's name is unique and created exclusively, so
/// nothing already there, a FIFO or a stale file, can hold or break the save.
private func replaceFile(_ path: String, with data: Data) throws {
    let temporary = path + "." + UUID().uuidString + ".new"
    let descriptor = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw failure(temporary) }
    let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    do {
        try makePrivate(descriptor, temporary)
        try file.write(contentsOf: data)
        guard fsync(descriptor) == 0, rename(temporary, path) == 0 else { throw failure(path) }
    } catch {
        unlink(temporary)
        throw error
    }
}

/// Mode 600 and an empty access control list: mode alone is not owner-only when an ACL, set or inherited,
/// grants others access.
private func makePrivate(_ descriptor: Int32, _ path: String) throws {
    guard let empty = acl_init(0) else { throw failure(path) }
    defer { acl_free(UnsafeMutableRawPointer(empty)) }
    guard acl_set_fd_np(descriptor, empty, ACL_TYPE_EXTENDED) == 0, fchmod(descriptor, 0o600) == 0 else {
        throw failure(path)
    }
}

/// True when the access control list on this descriptor has an entry that allows anything. A deny entry,
/// like the one macOS puts on home folders, takes nothing from the owner-only rule.
private func aclAllows(_ descriptor: Int32, _ path: String) throws -> Bool {
    errno = 0
    guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
        if errno == ENOENT { return false }
        throw failure(path)
    }
    defer { acl_free(UnsafeMutableRawPointer(acl)) }
    var entry: acl_entry_t?
    var which = ACL_FIRST_ENTRY.rawValue
    while acl_get_entry(acl, which, &entry) == 0, let current = entry {
        var tag = ACL_UNDEFINED_TAG
        if acl_get_tag_type(current, &tag) == 0 && tag == ACL_EXTENDED_ALLOW { return true }
        which = ACL_NEXT_ENTRY.rawValue
    }
    return false
}

private func failure(_ path: String) -> IrisError {
    IrisError("\(path): \(String(cString: strerror(errno)))")
}
