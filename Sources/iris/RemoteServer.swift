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

struct RemoteServerStatus: Equatable {
    var phase = RemoteServerPhase.off
    var pid: pid_t?               // the server running now
    var ours: Set<pid_t> = []     // every server this Iris started or stopped as left from an earlier run
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
    private var leftover: pid_t?
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
    var port: Int { defaults.object(forKey: RemoteAccessKey.port) as? Int ?? defaultHTTPPort }

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

    /// At quit: stops the server and waits for it, SIGKILL after the grace period. The choice stays.
    func quit() {
        quitting = true
        next?.cancel()
        guard let child, child.process.isRunning else { return }
        let pid = child.process.processIdentifier
        child.process.terminate()
        let deadline = Date().addingTimeInterval(timing.stopGrace)
        while child.process.isRunning && Date() < deadline { usleep(10_000) }
        if child.process.isRunning { kill(pid, SIGKILL) }
        forget(pid)
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
        if let old = running.first(where: { isLeftover($0, parent: processStart($0.pid)?.parent, record: record) }) {
            stopLeftover(old)
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

    private var record: (pid: Int, started: Double)? {
        guard let pid = defaults.object(forKey: RemoteAccessKey.childPid) as? Int,
              let started = defaults.object(forKey: RemoteAccessKey.childStarted) as? Double else { return nil }
        return (pid, started)
    }

    private func forget(_ pid: pid_t) {
        guard record?.pid == Int(pid) else { return }
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
        let logFile: FileHandle
        do {
            try createIfMissing(expanded(tokenFile ?? defaultTokenFile), Data((newToken() + "\n").utf8))
            try createIfMissing(expanded(scopeFile ?? defaultScopeFile), Data((sharesNothing + "\n").utf8))
            logFile = try openLog(log)
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
        process.terminationHandler = { _ in child.done.leave() }
        do {
            try process.run()
        } catch {
            child.done.leave()
            fail("cannot start \(executable): \(error.localizedDescription)")
            return
        }
        starts += 1
        let pid = process.processIdentifier
        if let started = processStart(pid)?.started {
            defaults.set(Int(pid), forKey: RemoteAccessKey.childPid)
            defaults.set(started, forKey: RemoteAccessKey.childStarted)
        }
        self.child = child
        status = RemoteServerStatus(phase: .starting, pid: pid, ours: status.ours.union([pid]))

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
        DispatchQueue.global().async(group: child.done) {
            let handle = errors.fileHandleForReading
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                try? logFile.write(contentsOf: chunk)
                child.keepIfEarly(chunk)
            }
        }
        child.done.notify(queue: .main) { [weak self] in
            try? logFile.close()
            MainActor.assumeIsolated { self?.exited(child) }
        }
    }

    private func ready(_ child: Child) {
        guard child === self.child, !child.stopping else { return }
        child.readyAt = Date()
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
        forget(process.processIdentifier)
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

    /// SIGTERM, SIGKILL after the grace period; looked at every tenth of a second until it is gone.
    private func stopLeftover(_ listener: Listener) {
        let pid = listener.pid
        leftover = pid
        status = RemoteServerStatus(phase: isOn ? .starting : .off, pid: nil, ours: status.ours.union([pid]))
        kill(pid, SIGTERM)
        let started = listener.started.timeIntervalSince1970
        let deadline = Date().addingTimeInterval(timing.stopGrace)
        func look() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let now = processStart(pid), abs(now.started - started) < 0.001 {
                        if Date() > deadline { kill(pid, SIGKILL) }
                        look()
                        return
                    }
                    self.forget(pid)
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
    var stopping = false           // on the main thread only, as readyAt
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

/// A listener is one this Iris started in an earlier run when it is the server last recorded, by pid and start
/// time, and that run is over: its parent is launchd. Another copy of Iris shares the defaults, and its server's
/// parent is that copy, so it is never taken for a leftover.
func isLeftover(_ listener: Listener, parent: pid_t?, record: (pid: Int, started: Double)?) -> Bool {
    guard let record, Int(listener.pid) == record.pid, parent == 1 else { return false }
    return abs(listener.started.timeIntervalSince1970 - record.started) < 0.001
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
/// replaced. Written whole beside it first and then linked into place, so the path never shows a part.
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

/// The log, appended to and never cut; created owner-only with its folder when missing.
private func openLog(_ path: String) throws -> FileHandle {
    let directory = (path as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    let descriptor = open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw IrisError("cannot write the log \(path): \(String(cString: strerror(errno)))") }
    return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
}

private func expanded(_ path: String) -> String {
    (path as NSString).expandingTildeInPath
}
