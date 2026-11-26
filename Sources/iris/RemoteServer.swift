import Foundation

// The menu bar's remote access switch: Iris runs `iris mcp --http` itself, as a child process with the default
// token, scope and state paths, and keeps it running while the switch is on. No AppKit here; the menu asks it.

/// Where the switch keeps the user's choice and the server it last started, in the app's defaults.
enum RemoteAccessKey {
    static let on = "remoteAccessOn"
    static let port = "remoteAccessPort"
    static let childPid = "remoteAccessChildPid"
    static let childStarted = "remoteAccessChildStarted"
}

let defaultHTTPLog = "~/Library/Logs/iris-http.log"
let sharesNothing = #"{"calendars": [], "folders": []}"#

struct RemoteServerTiming {
    var restart: [Double] = [1, 2, 5, 30]  // seconds before a start after the server ended on its own, by times in a row
    var retry: Double = 30                 // after it could not start
    var recheck: Double = 5                // while a server Iris did not start runs
    // From SIGTERM to SIGKILL: a stopping server takes up to 4 seconds to end its tool calls and 10 for write replies.
    var stopGrace: Double = 15
    var stable: Double = 60                // a server up this long has its restart delays start over
}

enum RemoteServerPhase: Equatable {
    case off
    case starting
    case on(port: Int)
    case failed(String)   // could not start, in the server's words; tried again later
    case outside([Int])   // the choice is on, but servers Iris did not start run on these ports, so it starts none
}

/// A process by pid and start time: a pid alone may be given to another process once this one has gone.
struct ServerIdentity: Equatable {
    let pid: pid_t
    let started: Double

    func names(pid other: pid_t, started time: Double) -> Bool {
        other == pid && abs(time - started) < 0.001
    }
}

struct RemoteServerStatus: Equatable {
    var phase = RemoteServerPhase.off
    var pid: pid_t?                     // the server running now
    var ours: [ServerIdentity] = []     // every server this Iris started or stopped as left from an earlier run

    func started(_ listener: Listener) -> Bool {
        ours.contains { $0.names(pid: listener.pid, started: listener.started.timeIntervalSince1970) }
    }
}

/// Starts, watches and stops the one server of the switch. Before each start it looks at the servers running:
/// one it started in an earlier run that outlived it (a crash, a force quit) is stopped first, and while any
/// other runs it starts none.
@MainActor
final class RemoteServer {
    private let executable: String
    private let log: String
    private let defaults: UserDefaults
    private let tokenFile: String?
    private let scopeFile: String?
    private let stateDir: String?
    private let listeners: () throws -> [Listener]
    private let timing: RemoteServerTiming
    private let changed: (RemoteServerStatus) -> Void

    private(set) var status = RemoteServerStatus() {
        didSet { if status != oldValue { changed(status) } }
    }
    private(set) var starts = 0
    private var child: Child?
    private var leftover: (identity: ServerIdentity, deadline: Date)?
    private var next: DispatchWorkItem?
    private var crashes = 0
    private var quitting = false

    /// nil paths are the server's defaults, and are not passed to it.
    init(executable: String, log: String = defaultHTTPLog, defaults: UserDefaults, tokenFile: String? = nil,
         scopeFile: String? = nil, stateDir: String? = nil, listeners: @escaping () throws -> [Listener] = runningListeners,
         timing: RemoteServerTiming = RemoteServerTiming(), changed: @escaping (RemoteServerStatus) -> Void) {
        self.executable = executable
        self.log = (log as NSString).expandingTildeInPath
        self.defaults = defaults
        self.tokenFile = tokenFile
        self.scopeFile = scopeFile
        self.stateDir = stateDir
        self.listeners = listeners
        self.timing = timing
        self.changed = changed
    }

    var isOn: Bool { defaults.bool(forKey: RemoteAccessKey.on) }

    /// The port set in defaults, or the server's default when none is set or it is no port.
    var port: Int {
        let port = defaults.object(forKey: RemoteAccessKey.port) as? Int ?? defaultHTTPPort
        return (1...65535).contains(port) ? port : defaultHTTPPort
    }

    /// At launch: starts the server if the choice is on, after stopping one left from an earlier run.
    func start() {
        reconcile()
    }

    func turn(on: Bool) {
        defaults.set(on, forKey: RemoteAccessKey.on)
        next?.cancel()
        next = nil
        crashes = 0
        reconcile()
    }

    /// At quit: finishes stopping a leftover and stops the server, each within the grace period, then SIGKILL.
    /// The choice stays, and so does the record of a server not seen to exit, for the next launch to stop.
    func quit() {
        quitting = true
        next?.cancel()
        if let leftover {
            let identity = leftover.identity
            while stillLeftover(identity) && Date() < leftover.deadline { usleep(10_000) }
            if stillLeftover(identity) { kill(identity.pid, SIGKILL) }
            let killed = Date().addingTimeInterval(1)
            while stillLeftover(identity) && Date() < killed { usleep(10_000) }
            if !stillLeftover(identity) { forget(identity) }
        }
        guard let child, child.process.isRunning else { return }
        child.process.terminate()
        var deadline = Date().addingTimeInterval(timing.stopGrace)
        while child.process.isRunning && Date() < deadline { usleep(10_000) }
        if child.process.isRunning { kill(child.process.processIdentifier, SIGKILL) }
        deadline = Date().addingTimeInterval(1)
        while child.process.isRunning && Date() < deadline { usleep(10_000) }
        if !child.process.isRunning, let identity = child.identity { forget(identity) }
    }

    private func reconcile() {
        guard !quitting, leftover == nil else { return }
        if let child {
            if !isOn && !child.stopping { stop(child) }
            if child.stopping { status.phase = isOn ? .starting : .off }
            return
        }
        let running: [Listener]
        do {
            running = try listeners()
        } catch {
            fail("\(error)")
            return
        }
        // Left from an earlier run: stopped whatever the choice, since that run is over.
        if let record, running.contains(where: { isLeftover(pid: $0.pid, now: processStart($0.pid), record: record) }) {
            stopLeftover(record)
            return
        }
        guard isOn else {
            next?.cancel()
            next = nil
            status = RemoteServerStatus(phase: .off, pid: nil, ours: status.ours)
            return
        }
        guard next == nil else { return }
        if !running.isEmpty {
            status = RemoteServerStatus(phase: .outside(running.map(\.port)), pid: nil, ours: status.ours)
            schedule(timing.recheck)
            return
        }
        launch()
    }

    private var record: ServerIdentity? {
        guard let pid = defaults.object(forKey: RemoteAccessKey.childPid) as? Int,
              let started = defaults.object(forKey: RemoteAccessKey.childStarted) as? Double else { return nil }
        return ServerIdentity(pid: pid_t(clamping: pid), started: started)
    }

    /// Only by a server that has said it is ready: one that lost the port to another copy's never takes its record.
    private func remember(_ identity: ServerIdentity) {
        defaults.set(Int(identity.pid), forKey: RemoteAccessKey.childPid)
        defaults.set(identity.started, forKey: RemoteAccessKey.childStarted)
    }

    /// Clears the record only while it still names this server.
    private func forget(_ identity: ServerIdentity) {
        guard let record, identity.names(pid: record.pid, started: record.started) else { return }
        defaults.removeObject(forKey: RemoteAccessKey.childPid)
        defaults.removeObject(forKey: RemoteAccessKey.childStarted)
    }

    private func schedule(_ seconds: Double) {
        next?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.next = nil
                self?.reconcile()
            }
        }
        next = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func fail(_ reason: String) {
        status = RemoteServerStatus(phase: .failed(reason), pid: nil, ours: status.ours)
        schedule(timing.retry)
    }

    private func launch() {
        let port = self.port
        do {
            try createIfMissing(expanded(tokenFile ?? defaultTokenFile), Data((newToken() + "\n").utf8))
            try createIfMissing(expanded(scopeFile ?? defaultScopeFile), Data((sharesNothing + "\n").utf8))
        } catch {
            fail("\(error)")
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["mcp", "--http", "--port", String(port)]
            + (tokenFile.map { ["--token-file", $0] } ?? []) + (scopeFile.map { ["--scope-file", $0] } ?? [])
            + (stateDir.map { ["--state-dir", $0] } ?? [])
        process.currentDirectoryURL = URL(fileURLWithPath: "/")
        var environment = ProcessInfo.processInfo.environment
        environment["IRIS_MENU_BAR"] = nil
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let child = Child(process: process, port: port)
        child.done.enter()
        // Not the child itself: the process keeps its handler after a launch that failed.
        process.terminationHandler = { [done = child.done] _ in done.leave() }
        do {
            try process.run()
        } catch {
            for handle in [output.fileHandleForReading, output.fileHandleForWriting,
                           errors.fileHandleForReading, errors.fileHandleForWriting] {
                try? handle.close()
            }
            fail("cannot start \(executable): \(error.localizedDescription)")
            return
        }
        starts += 1
        let pid = process.processIdentifier
        child.identity = processStart(pid).map { ServerIdentity(pid: pid, started: $0.started) }
        self.child = child
        status = RemoteServerStatus(phase: .starting, pid: pid, ours: status.ours + (child.identity.map { [$0] } ?? []))

        DispatchQueue.global().async(group: child.done) { [weak self] in
            let handle = output.fileHandleForReading
            var line = Data()
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                guard !child.isReady else { continue }
                line += chunk
                if line.contains(UInt8(ascii: "\n")) {
                    child.markReady()
                    // Before the end of output, so before exited: the main queue keeps the order.
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.ready(child) } }
                }
            }
        }
        DispatchQueue.global().async(group: child.done) { [log] in
            // Opened here, off the main thread. Without it the server runs all the same, its request log lost.
            let logFile = try? openLog(log)
            defer { try? logFile?.close() }
            let handle = errors.fileHandleForReading
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                try? logFile?.write(contentsOf: chunk)
                child.keepIfEarly(chunk)
            }
        }
        child.done.notify(queue: .main) { [weak self] in
            MainActor.assumeIsolated { self?.exited(child) }
        }
    }

    private func ready(_ child: Child) {
        guard child === self.child, !child.stopping else { return }
        child.readyAt = Date()
        if let identity = child.identity { remember(identity) }
        status.phase = .on(port: child.port)
    }

    private func stop(_ child: Child) {
        child.stopping = true
        child.process.terminate()
        let pid = child.process.processIdentifier
        DispatchQueue.main.asyncAfter(deadline: .now() + timing.stopGrace) {
            if child.process.isRunning { kill(pid, SIGKILL) }
        }
    }

    private func exited(_ child: Child) {
        guard child === self.child else { return }
        self.child = nil
        let process = child.process
        if let identity = child.identity { forget(identity) }
        status.pid = nil
        if quitting || child.stopping {
            reconcile()
        } else if let readyAt = child.readyAt {
            if Date().timeIntervalSince(readyAt) >= timing.stable { crashes = 0 }
            let delay = timing.restart[min(crashes, timing.restart.count - 1)]
            crashes += 1
            status.phase = .starting
            schedule(delay)
        } else {
            fail(startFailure(child.early, status: process.terminationStatus,
                              signalled: process.terminationReason == .uncaughtSignal))
        }
    }

    /// Whether the recorded leftover is still that process, left by its run; checked right before each signal,
    /// so none reaches a process that was given its pid since.
    private func stillLeftover(_ identity: ServerIdentity) -> Bool {
        isLeftover(pid: identity.pid, now: processStart(identity.pid), record: identity)
    }

    /// SIGTERM, SIGKILL after the grace period; looked at every tenth of a second until it is gone.
    private func stopLeftover(_ identity: ServerIdentity) {
        // Gone, or no longer that process, since the listing: nothing to stop. A record naming a gone process
        // can name no other, as start times differ.
        guard stillLeftover(identity) else {
            reconcile()
            return
        }
        kill(identity.pid, SIGTERM)
        leftover = (identity, Date().addingTimeInterval(timing.stopGrace))
        status = RemoteServerStatus(phase: isOn ? .starting : .off, pid: nil, ours: status.ours + [identity])
        func look() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, !self.quitting, let leftover = self.leftover else { return }
                    if self.stillLeftover(identity) {
                        if Date() > leftover.deadline { kill(identity.pid, SIGKILL) }
                        look()
                        return
                    }
                    self.forget(identity)
                    self.leftover = nil
                    self.reconcile()
                }
            }
        }
        look()
    }
}

/// One server process, and what its output has said.
private final class Child: @unchecked Sendable {
    let process: Process
    let port: Int
    let done = DispatchGroup()     // its exit, and the end of both of its outputs
    var identity: ServerIdentity?  // on the main thread only, as stopping and readyAt
    var stopping = false
    var readyAt: Date?
    private let lock = NSLock()
    private var readyLine = false
    private var errorsBeforeReady = Data()

    init(process: Process, port: Int) {
        self.process = process
        self.port = port
    }

    var isReady: Bool { lock.withLock { readyLine } }
    var early: String { lock.withLock { String(decoding: errorsBeforeReady, as: UTF8.self) } }

    func markReady() {
        lock.withLock { readyLine = true }
    }

    /// What it writes before its ready line is why it could not start; after it, the request log.
    func keepIfEarly(_ chunk: Data) {
        lock.withLock {
            if !readyLine && errorsBeforeReady.count < 65536 { errorsBeforeReady += chunk }
        }
    }
}

/// A process is the server this Iris recorded in an earlier run, and that run is over, when its start time is
/// the record's and its parent is launchd. Another copy of Iris shares the defaults, and its server's parent is
/// that copy, so it is never taken for a leftover. Never pid 1 or below.
func isLeftover(pid: pid_t, now: (started: Double, parent: pid_t)?, record: ServerIdentity?) -> Bool {
    guard pid > 1, let now, let record, now.parent == 1 else { return false }
    return record.names(pid: pid, started: now.started)
}

/// Why a server that exited before its ready line could not start: its error message without ArgumentParser's
/// "Error: " and usage lines, or how it ended.
func startFailure(_ errors: String, status: Int32, signalled: Bool) -> String {
    let lines = errors.split(separator: "\n").prefix { !$0.hasPrefix("Usage:") }
        .map { $0.hasPrefix("Error: ") ? $0.dropFirst(7) : $0 }
    let reason = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    if !reason.isEmpty { return reason }
    return signalled ? "the server was ended by signal \(status) before it was ready"
        : "the server stopped before it was ready, with exit status \(status)"
}

/// When a process started, as `runningListeners` reads it, and its parent; nil when it is gone.
func processStart(_ pid: pid_t) -> (started: Double, parent: pid_t)? {
    var request = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    guard sysctl(&request, 4, &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_stat != SZOMB else { return nil }
    let start = info.kp_proc.p_un.__p_starttime
    return (Double(start.tv_sec) + Double(start.tv_usec) / 1e6, info.kp_eproc.e_ppid)
}

/// 32 random bytes in hex: 64 characters a token file accepts.
func newToken() -> String {
    var generator = SystemRandomNumberGenerator()
    return (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }.joined()
}

/// Makes the file, owner-only, with these bytes, unless something is at the path already, which is never
/// replaced. Its folder must be open to this user only, as checked before anything is made in it: then no one
/// else can reach the file while it is written. Written whole beside it first and then linked into place, so
/// the path never shows a part.
func createIfMissing(_ path: String, _ contents: Data) throws {
    var info = stat()
    if lstat(path, &info) == 0 { return }
    let directory = (path as NSString).deletingLastPathComponent
    do {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    } catch {
        throw IrisError("cannot create \(directory): \(error.localizedDescription)")
    }
    let folder = open(directory, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard folder >= 0 else { throw IrisError("cannot open \(directory): \(String(cString: strerror(errno)))") }
    defer { close(folder) }
    try checkFolder(folder, directory, "the folder", forbidden: 0o077, only: "open to you only", fix: "chmod go-rwx")
    let temporary = path + "." + UUID().uuidString + ".new"
    let descriptor = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw IrisError("cannot create \(path): \(String(cString: strerror(errno)))") }
    let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { unlink(temporary) }
    try makePrivate(descriptor, temporary)
    try file.write(contentsOf: contents)
    guard fsync(descriptor) == 0, link(temporary, path) == 0 || errno == EEXIST else {
        throw IrisError("cannot create \(path): \(String(cString: strerror(errno)))")
    }
}

/// The log, appended to and never cut; created owner-only with its folder when missing. Only a regular file:
/// non-blocking, so a FIFO in its place cannot hold the open.
private func openLog(_ path: String) throws -> FileHandle {
    let directory = (path as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    let descriptor = open(path, O_WRONLY | O_APPEND | O_CREAT | O_NONBLOCK | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw IrisError("cannot write the log \(path): \(String(cString: strerror(errno)))") }
    let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
        throw IrisError("the log \(path) is not a regular file")
    }
    return file
}

private func expanded(_ path: String) -> String {
    (path as NSString).expandingTildeInPath
}
