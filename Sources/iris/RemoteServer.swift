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

    /// The same pid and the same start time to the microsecond, the kernel's resolution. Compared as whole
    /// microseconds, not as Doubles: a listener's start time passes through Date, and this stays right whatever
    /// that does to the last bits (measured: nothing). A pid can in principle be given to a process started in
    /// the same microsecond; nothing here rules that out, only makes it as unlikely as the kernel does.
    func names(pid other: pid_t, started time: Double) -> Bool {
        other == pid && (time * 1e6).rounded() == (started * 1e6).rounded()
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
    private let lookup: (pid_t) -> (started: Double, parent: pid_t)?
    private let timing: RemoteServerTiming
    private let changed: (RemoteServerStatus) -> Void
    private let active: () -> Void

    /// Who has used the switch's server since it was turned on, across its restarts; in memory only.
    private(set) var activity = RemoteActivity()
    private(set) var status = RemoteServerStatus() {
        didSet { if status != oldValue { changed(status) } }
    }
    private(set) var starts = 0
    private var child: Child?
    private var leftover: (identity: ServerIdentity, deadline: DispatchTime)?
    private var next: DispatchWorkItem?
    private var crashes = 0
    private var quitting = false

    /// nil paths are the server's defaults, and are not passed to it.
    init(executable: String, log: String = defaultHTTPLog, defaults: UserDefaults, tokenFile: String? = nil,
         scopeFile: String? = nil, stateDir: String? = nil, listeners: @escaping () throws -> [Listener] = runningListeners,
         lookup: @escaping (pid_t) -> (started: Double, parent: pid_t)? = processStart,
         timing: RemoteServerTiming = RemoteServerTiming(), active: @escaping () -> Void = {},
         changed: @escaping (RemoteServerStatus) -> Void) {
        self.executable = executable
        self.log = (log as NSString).expandingTildeInPath
        self.defaults = defaults
        self.tokenFile = tokenFile
        self.scopeFile = scopeFile
        self.stateDir = stateDir
        self.listeners = listeners
        self.lookup = lookup
        self.timing = timing
        self.changed = changed
        self.active = active
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
        if !on { activity = RemoteActivity() }
        next?.cancel()
        next = nil
        crashes = 0
        reconcile()
    }

    /// Starts the switch's server again, so it reads the scope file as it is now: the one running or starting is
    /// stopped and then started, and after a start that failed the next try is now. Nothing while the switch is
    /// off, while another server runs, or while one is already stopping, as its next start reads the file then.
    func restart() {
        guard isOn, !quitting, leftover == nil else { return }
        if let child {
            guard !child.stopping else { return }
            stop(child)
            reconcile()
        } else if case .failed = status.phase {
            next?.cancel()
            next = nil
            reconcile()
        }
    }

    /// At quit: finishes stopping a leftover and stops the server, each within the grace period, then SIGKILL.
    /// The choice stays, and so does the record: a server not seen to exit is stopped at the next launch.
    func quit() {
        quitting = true
        next?.cancel()
        if let leftover {
            let identity = leftover.identity
            while stillLeftover(identity) && DispatchTime.now() < leftover.deadline { usleep(10_000) }
            if stillLeftover(identity) { kill(identity.pid, SIGKILL) }
            let killed = DispatchTime.now() + 1
            while stillLeftover(identity) && DispatchTime.now() < killed { usleep(10_000) }
        }
        guard let child, child.process.isRunning else { return }
        child.process.terminate()
        let deadline = DispatchTime.now() + timing.stopGrace
        while child.process.isRunning && DispatchTime.now() < deadline { usleep(10_000) }
        send(SIGKILL, to: child)
        let killed = DispatchTime.now() + 1
        while child.process.isRunning && DispatchTime.now() < killed { usleep(10_000) }
    }

    /// Signals the child only while it is still that process, checked immediately before: running, by
    /// Foundation's account, and with the pid and start time it had at launch, so not a pid reaped and given to
    /// another process before the check. The check and the signal are two calls, not one: a pid freed and given
    /// away between them would get it.
    private func send(_ signal: Int32, to child: Child) {
        let pid = child.process.processIdentifier
        guard child.process.isRunning, let identity = child.identity, let now = lookup(pid),
              identity.names(pid: pid, started: now.started) else { return }
        kill(pid, signal)
    }

    private func reconcile() {
        guard !quitting, leftover == nil else { return }
        if let child {
            if !isOn && !child.stopping { stop(child) }
            // One that could not be identified keeps saying so until it has exited: it may still be serving.
            if child.stopping && !child.unidentified { status.phase = isOn ? .starting : .off }
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
        if let record, running.contains(where: { isLeftover(pid: $0.pid, now: lookup($0.pid), record: record) }) {
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
    /// Never cleared, only replaced: a record whose server has gone names no process, since none other has its
    /// start time, and clearing it could clear a record another copy of Iris has just written.
    private func remember(_ identity: ServerIdentity) {
        defaults.set(Int(identity.pid), forKey: RemoteAccessKey.childPid)
        defaults.set(identity.started, forKey: RemoteAccessKey.childStarted)
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
        environment[reportActivityVariable] = "1"
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
            child.done.leave()
            for handle in [output.fileHandleForReading, output.fileHandleForWriting,
                           errors.fileHandleForReading, errors.fileHandleForWriting] {
                try? handle.close()
            }
            fail("cannot start \(executable): \(error.localizedDescription)")
            return
        }
        starts += 1
        let pid = process.processIdentifier
        child.identity = identify(pid)
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
        DispatchQueue.global().async(group: child.done) { [log, weak self] in
            // Opened here, off the main thread. Without it the server runs all the same, its request log lost.
            let logFile = try? openLog(log)
            defer { try? logFile?.close() }
            let handle = errors.fileHandleForReading
            var splitter = ActivitySplitter()
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                let (log, lines) = splitter.split(chunk)
                if !log.isEmpty {
                    try? logFile?.write(contentsOf: log)
                    child.keepIfEarly(log)
                }
                let reports = lines.compactMap(parseActivityLine)
                if !reports.isEmpty {
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.record(reports) } }
                }
            }
            let rest = splitter.finish()
            if !rest.isEmpty {
                try? logFile?.write(contentsOf: rest)
                child.keepIfEarly(rest)
            }
        }
        child.done.notify(queue: .main) { [weak self] in
            MainActor.assumeIsolated { self?.exited(child) }
        }
    }

    /// Lines from a server still answering after the switch was turned off are not kept.
    private func record(_ reports: [ActivityReport]) {
        guard isOn else { return }
        reports.forEach { activity.record($0) }
        active()
    }

    /// Its pid and start time, looked up while it is this process's child; nil when the lookup fails.
    private func identify(_ pid: pid_t) -> ServerIdentity? {
        guard let now = lookup(pid), now.parent == getpid() else { return nil }
        return ServerIdentity(pid: pid, started: now.started)
    }

    /// A server whose process cannot be identified is one Iris cannot promise to stop (SIGKILL needs its
    /// identity), so it is not accepted: it is asked to stop and counts as a start that failed.
    private func ready(_ child: Child) {
        guard child === self.child, !child.stopping else { return }
        if child.identity == nil, child.process.isRunning, let identity = identify(child.process.processIdentifier) {
            child.identity = identity
            status.ours.append(identity)
        }
        guard let identity = child.identity else {
            child.unidentified = true
            child.process.terminate()
            // Said now, not only once it has exited: one that does not stop on SIGTERM shows it too.
            status.phase = .failed(unidentifiedServer)
            return
        }
        child.readyAt = .now()
        remember(identity)
        status.phase = .on(port: child.port)
    }

    private func stop(_ child: Child) {
        child.stopping = true
        child.process.terminate()
        DispatchQueue.main.asyncAfter(deadline: .now() + timing.stopGrace) { [weak self] in
            MainActor.assumeIsolated { self?.send(SIGKILL, to: child) }
        }
    }

    private func exited(_ child: Child) {
        guard child === self.child else { return }
        self.child = nil
        let process = child.process
        status.pid = nil
        if child.unidentified && isOn && !quitting {
            fail(unidentifiedServer)
        } else if quitting || child.stopping || child.unidentified {
            reconcile()
        } else if let readyAt = child.readyAt {
            if DispatchTime.now() >= readyAt + timing.stable { crashes = 0 }
            let delay = timing.restart[min(crashes, timing.restart.count - 1)]
            crashes += 1
            status.phase = .starting
            schedule(delay)
        } else {
            fail(startFailure(child.early, status: process.terminationStatus,
                              signalled: process.terminationReason == .uncaughtSignal))
        }
    }

    /// Whether the recorded leftover is still that process, left by its run: the same pid, the same start time
    /// to the microsecond, and launchd as its parent. Checked immediately before each signal; the check and the
    /// signal are two calls, not one, so a pid freed and given away between them would get it.
    private func stillLeftover(_ identity: ServerIdentity) -> Bool {
        isLeftover(pid: identity.pid, now: lookup(identity.pid), record: identity)
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
        leftover = (identity, .now() + timing.stopGrace)
        status = RemoteServerStatus(phase: isOn ? .starting : .off, pid: nil, ours: status.ours + [identity])
        pollLeftover(identity)
    }

    /// A tenth of a second on: gone, then on to a start; else SIGKILL once the deadline has passed, and again.
    /// Holds the supervisor weakly: one released meanwhile sends nothing more.
    private func pollLeftover(_ identity: ServerIdentity) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.quitting, let leftover = self.leftover else { return }
                if self.stillLeftover(identity) {
                    if DispatchTime.now() > leftover.deadline { kill(identity.pid, SIGKILL) }
                    self.pollLeftover(identity)
                    return
                }
                self.leftover = nil
                self.reconcile()
            }
        }
    }
}

/// The menu's ticks and resets, one at a time in the order made, none of it on the main thread but the answers. Each
/// change is made to the scope file as it is on disk then, under the lock every copy of Iris takes, and written at
/// once. A tick that needs its app's items as they are now, as that change finds the files under the lock, changes
/// nothing then: its app is listed and the change made again with that answer, never an older one, and once only.
/// A listing that fails or takes longer than `listingDeadline` changes nothing and says so, and an answer after that
/// is ignored. The switch's server is restarted once the changes have stopped for `quiet` seconds and none is
/// waiting: so once, after the last of them has been written, and the server reads it.
@MainActor
final class ScopeChanges {
    let path: String
    private let quiet: Double
    private let listingDeadline: Double
    private let listing: @Sendable (ScopeKind) -> [Named]?
    private let restart: () -> Void
    private var pending: DispatchWorkItem?
    private var queue: [Job] = []
    private var busy = false
    private var waiting: UUID?  // the listing whose answer is still taken
    private var drained: [() -> Void] = []

    private struct Job {
        let change: @Sendable ([Named]?) throws -> (file: ScopeFile?, written: Bool)  // under the lock
        let done: (Result<ScopeFile?, Error>) -> Void
    }

    /// `listing` lists one app's items now, nil when it cannot without asking for a permission or opening Notes.
    init(path: String, quiet: Double = 0.5, listingDeadline: Double = 15,
         listing: @escaping @Sendable (ScopeKind) -> [Named]?, restart: @escaping () -> Void) {
        self.path = path
        self.quiet = quiet
        self.listingDeadline = listingDeadline
        self.listing = listing
        self.restart = restart
    }

    /// Whether a change is waiting or being made.
    var isBusy: Bool { busy }

    /// Queues the tick; `done` gets the file after it, or why nothing changed.
    func submit(_ tick: ScopeTick, done: @escaping (Result<ScopeFile, Error>) -> Void) {
        let path = self.path
        enqueue(Job(change: { items in
                        let (file, written) = try changeScopeFile(path, tick, items: items)
                        return (file, written)
                    },
                    done: { done($0.map { $0! }) }))
    }

    /// Queues a reset of a file that cannot be read: kept beside it, and one sharing nothing in its place. `done`
    /// gets whether it was done; not when the file was fixed meanwhile.
    func reset(done: @escaping (Result<Bool, Error>) -> Void) {
        let path = self.path
        enqueue(Job(change: { _ in
                        try withScopeLock(path) {
                            guard case .broken = loadScopeFile(path) else { return (nil, false) }
                            _ = try resetScopeFile(path)
                            return (ScopeFile(calendars: [], folders: []), true)
                        }
                    },
                    done: { done($0.map { $0 != nil }) }))
    }

    /// Calls `then` once nothing is waiting or being made: now, or when the last change has answered.
    func whenDrained(_ then: @escaping () -> Void) {
        if busy { drained.append(then) } else { then() }
    }

    private func enqueue(_ job: Job) {
        queue.append(job)
        if !busy { next() }
    }

    private func next() {
        guard !queue.isEmpty else {
            busy = false
            let calls = drained
            drained = []
            calls.forEach { $0() }
            return
        }
        busy = true
        run(queue.removeFirst(), items: nil)
    }

    private func list(_ kind: ScopeKind, _ job: Job) {
        let request = UUID()
        waiting = request
        Task.detached { [weak self, listing] in
            let items = listing(kind)
            await self?.listed(items, kind, job, request)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + listingDeadline) { [weak self] in
            MainActor.assumeIsolated { self?.listed(nil, kind, job, request) }
        }
    }

    /// The first of the answer and the deadline; the other finds the request taken and does nothing.
    private func listed(_ items: [Named]?, _ kind: ScopeKind, _ job: Job, _ request: UUID) {
        guard waiting == request else { return }
        waiting = nil
        guard let items else {
            // Notes folders are listed only while Notes is open, Reminders lists only once Iris may read them.
            let problem = switch kind {
            case .lists: "Iris could not read your reminder lists just now, so nothing was changed. If Iris has never "
                + "asked for Reminders, run `iris reminders lists` once and allow it."
            case .folders: "Iris could not read your note folders just now, so nothing was changed. Open Notes and try again."
            default: "Iris could not read your calendars just now, so nothing was changed."
            }
            job.done(.failure(IrisError(problem)))
            return next()
        }
        run(job, items: items)
    }

    private func run(_ job: Job, items: [Named]?) {
        let change = job.change
        Task.detached { [weak self] in
            let result = Result { try change(items) }
            await self?.ran(result, job, listed: items != nil)
        }
    }

    private func ran(_ result: Result<(file: ScopeFile?, written: Bool), Error>, _ job: Job, listed: Bool) {
        if case .failure(let error) = result, let needed = error as? ScopeListingNeeded, !listed {
            return list(needed.kind, job)
        }
        if case .success(let outcome) = result, outcome.written { restartSoon() }
        job.done(result.map(\.file))
        next()
    }

    private func restartSoon() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pending = nil
                // A change still to be written: the restart waits for it.
                if self.busy { self.restartSoon() } else { self.restart() }
            }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + quiet, execute: work)
    }
}

let unidentifiedServer = "could not confirm the server's process, so it was asked to stop; a server Iris cannot "
    + "identify is one it cannot promise to stop"

/// One server process, and what its output has said.
private final class Child: @unchecked Sendable {
    let process: Process
    let port: Int
    let done = DispatchGroup()     // its exit, and the end of both of its outputs
    var identity: ServerIdentity?  // on the main thread only, as the three below
    var unidentified = false        // ready, but its identity could not be looked up, so it was stopped
    var stopping = false
    var readyAt: DispatchTime?
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

/// A process is the server this Iris recorded in an earlier run, and that run is over, when its pid and start
/// time (to the microsecond) are the record's and its parent is launchd. Another copy of Iris shares the defaults, and its server's parent is
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
