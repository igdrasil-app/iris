import XCTest
@testable import iris

/// The switch's server with a stand-in for iris: a script that prints a ready line and waits, or fails as a
/// server that cannot start does. No port is opened.
final class RemoteServerTests: XCTestCase {
    private var folder = ""
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        folder = NSTemporaryDirectory() + "iris-switch-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        // A suite named by a path is kept in that file: each test its own, in its own folder, and nothing in
        // ~/Library/Preferences. Runs side by side never share a choice or a record.
        defaults = UserDefaults(suiteName: folder + "/defaults")
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: folder + "/defaults")
        try? FileManager.default.removeItem(atPath: folder)
    }

    private func script(_ body: String) throws -> String {
        let path = folder + "/iris-" + UUID().uuidString
        try ("#!/bin/sh\n" + body + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        chmod(path, 0o700)
        return path
    }

    @MainActor
    private func server(_ executable: String, listeners: [Listener] = [], timing: RemoteServerTiming = RemoteServerTiming(),
                        seen: @escaping (RemoteServerStatus) -> Void = { _ in }) -> RemoteServer {
        RemoteServer(executable: executable, log: folder + "/logs/http.log", defaults: defaults,
                     tokenFile: folder + "/state/token", scopeFile: folder + "/state/scope", stateDir: folder + "/state",
                     listeners: { listeners }, timing: timing, changed: seen)
    }

    @MainActor
    private func wait(_ seconds: Double, until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while !done() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    private func running(_ pid: pid_t?) -> Bool {
        pid.map { processStart($0) != nil } ?? false
    }

    /// SIGKILL to a process only while it is still the one started then: never to a pid given to another since.
    private func killStill(_ identity: ServerIdentity) {
        if let now = processStart(identity.pid), identity.names(pid: identity.pid, started: now.started) {
            kill(identity.pid, SIGKILL)
        }
    }

    @MainActor
    func testStartsStopsAndRemembers() throws {
        let serving = try script(#"sleep 0.3; echo '{"port": 1}'; echo "a request" >&2; exec sleep 600"#)
        // A log that is there already is added to.
        try FileManager.default.createDirectory(atPath: folder + "/logs", withIntermediateDirectories: true)
        try Data("earlier\n".utf8).write(to: URL(fileURLWithPath: folder + "/logs/http.log"))
        var phases: [RemoteServerPhase] = []
        let switched = server(serving) { phases.append($0.phase) }
        switched.start()
        XCTAssertEqual(switched.status.phase, .off)
        XCTAssertEqual(switched.starts, 0)

        defaults.set(8766, forKey: RemoteAccessKey.port)
        switched.turn(on: true)
        XCTAssertTrue(defaults.bool(forKey: RemoteAccessKey.on))
        // Recorded only once ready.
        XCTAssertEqual(switched.status.phase, .starting)
        XCTAssertNil(defaults.object(forKey: RemoteAccessKey.childPid))
        wait(10) { switched.status.phase == .on(port: 8766) }
        XCTAssertEqual(phases, [.starting, .on(port: 8766)])
        let pid = try XCTUnwrap(switched.status.pid)
        XCTAssertEqual(defaults.object(forKey: RemoteAccessKey.childPid) as? Int, Int(pid))
        XCTAssertEqual(defaults.object(forKey: RemoteAccessKey.childStarted) as? Double, processStart(pid)?.started)
        // The first time, a token a server accepts and a scope that shares nothing, both owner-only.
        XCTAssertEqual(try readToken(folder + "/state/token").count, 64)
        XCTAssertEqual(try readScopeFile(folder + "/state/scope"), ScopeFile(calendars: [], folders: []))
        for file in ["/state/token", "/state/scope"] {
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: folder + file)[.posixPermissions] as? Int, 0o600)
        }
        wait(5) { (try? String(contentsOfFile: folder + "/logs/http.log")) == "earlier\na request\n" }
        XCTAssertEqual(try String(contentsOfFile: folder + "/logs/http.log"), "earlier\na request\n")

        switched.turn(on: false)
        XCTAssertEqual(switched.status.phase, .off)
        wait(10) { !running(pid) && switched.status.pid == nil }
        XCTAssertFalse(running(pid))
        XCTAssertFalse(defaults.bool(forKey: RemoteAccessKey.on))
        XCTAssertEqual(switched.starts, 1)
        // The record outlives its server and is only ever replaced. Naming no process now, it is never taken for a
        // leftover: the next launch stops nothing and starts its own.
        let stale = try XCTUnwrap(switched.status.ours.last)
        XCTAssertEqual(defaults.object(forKey: RemoteAccessKey.childPid) as? Int, Int(stale.pid))
        let next = server(serving)
        next.turn(on: true)
        XCTAssertEqual(next.status.phase, .starting)
        XCTAssertFalse(next.status.ours.contains(stale))
        wait(10) { next.status.phase == .on(port: 8766) }
        XCTAssertNotEqual(defaults.object(forKey: RemoteAccessKey.childPid) as? Int, Int(stale.pid))
        next.turn(on: false)
        wait(10) { next.status.pid == nil }
    }

    @MainActor
    func testFilesAreNeverReplaced() throws {
        try FileManager.default.createDirectory(atPath: folder + "/state", withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try Data("not a scope".utf8).write(to: URL(fileURLWithPath: folder + "/state/scope"))
        try createIfMissing(folder + "/state/scope", Data(sharesNothing.utf8))
        XCTAssertEqual(try String(contentsOfFile: folder + "/state/scope"), "not a scope")
        try createIfMissing(folder + "/state/token", Data("first".utf8))
        try createIfMissing(folder + "/state/token", Data("second".utf8))
        XCTAssertEqual(try String(contentsOfFile: folder + "/state/token"), "first")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder + "/state").sorted(), ["scope", "token"])
        // A folder others may read or write gets nothing made in it, and says how to fix it.
        try FileManager.default.createDirectory(atPath: folder + "/open", withIntermediateDirectories: true)
        chmod(folder + "/open", 0o755)
        XCTAssertThrowsError(try createIfMissing(folder + "/open/token", Data("x".utf8))) { error in
            XCTAssertEqual("\(error)", "the folder \(folder)/open must be yours and open to you only: chmod go-rwx \"\(folder)/open\"")
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder + "/open"), [])
        // One it makes is open to this user only.
        try createIfMissing(folder + "/new/token", Data("x".utf8))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: folder + "/new")[.posixPermissions] as? Int, 0o700)
    }

    @MainActor
    func testPort() {
        let switched = server("/nonexistent")
        XCTAssertEqual(switched.port, defaultHTTPPort)
        for (set, port) in [(8788, 8788), (1, 1), (65535, 65535), (0, defaultHTTPPort), (-1, defaultHTTPPort), (65536, defaultHTTPPort)] {
            defaults.set(set, forKey: RemoteAccessKey.port)
            XCTAssertEqual(switched.port, port, "\(set)")
        }
        defaults.set("8788", forKey: RemoteAccessKey.port)
        XCTAssertEqual(switched.port, defaultHTTPPort)
    }

    /// A launch that fails leaves no descriptor open: the pipes are closed, and nothing holds the child.
    @MainActor
    func testFailedLaunchesLeaveNothingOpen() throws {
        func open() -> Int { (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1 }
        let switched = server(folder + "/missing/iris")
        switched.turn(on: true)
        switched.turn(on: false)
        let before = open()
        for _ in 0..<20 {
            switched.turn(on: true)
            guard case .failed = switched.status.phase else { return XCTFail("\(switched.status.phase)") }
            switched.turn(on: false)
        }
        XCTAssertEqual(open(), before)
    }

    @MainActor
    func testCannotStart() throws {
        let failing = try script(#"echo "Error: /x/scope: not a JSON object" >&2; echo "Usage: iris mcp" >&2; exit 1"#)
        let switched = server(failing, timing: RemoteServerTiming(retry: 2))
        defaults.set(true, forKey: RemoteAccessKey.on)
        switched.start()
        wait(5) { switched.status.phase != .starting }
        XCTAssertEqual(switched.status.phase, .failed("/x/scope: not a JSON object"))
        XCTAssertEqual(switched.starts, 1)
        // Tried again after the retry delay, not before.
        wait(1) { switched.starts > 1 }
        XCTAssertEqual(switched.starts, 1)
        wait(5) { switched.starts > 1 }
        XCTAssertEqual(switched.starts, 2)
        wait(5) { switched.status.phase != .starting }
        // Turning it off and on tries at once.
        switched.turn(on: false)
        XCTAssertEqual(switched.status.phase, .off)
        switched.turn(on: true)
        XCTAssertEqual(switched.starts, 3)
        switched.turn(on: false)
    }

    @MainActor
    func testRestartsAfterACrash() throws {
        let serving = try script(#"echo '{"port": 1}'; exec sleep 600"#)
        let switched = server(serving, timing: RemoteServerTiming(restart: [0.5, 30]))
        defaults.set(true, forKey: RemoteAccessKey.on)
        switched.start()
        wait(10) { switched.status.phase == .on(port: defaultHTTPPort) }
        let first = try XCTUnwrap(switched.status.pid)
        killStill(try XCTUnwrap(switched.status.ours.last))
        wait(5) { switched.status.pid == nil }
        XCTAssertEqual(switched.status.phase, .starting)
        wait(10) { switched.status.phase == .on(port: defaultHTTPPort) }
        let second = try XCTUnwrap(switched.status.pid)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(switched.status.ours.map(\.pid), [first, second])
        // The second crash in a row waits the next delay.
        killStill(try XCTUnwrap(switched.status.ours.last))
        wait(2) { switched.starts > 2 }
        XCTAssertEqual(switched.starts, 2)
        XCTAssertEqual(switched.status.phase, .starting)
        switched.turn(on: false)
    }

    @MainActor
    func testAnotherServerRuns() throws {
        let serving = try script(#"echo '{"port": 1}'; exec sleep 600"#)
        let other = Listener(pid: 1, port: 8788, scopeFile: "/x/scope", started: Date())
        let switched = server(serving, listeners: [other])
        defaults.set(true, forKey: RemoteAccessKey.on)
        switched.start()
        XCTAssertEqual(switched.status.phase, .outside([8788]))
        XCTAssertEqual(switched.starts, 0)
        switched.turn(on: false)
        XCTAssertEqual(switched.status.phase, .off)
    }

    func testLeftover() {
        let record = ServerIdentity(pid: 500, started: 1_800_000_000.25)
        XCTAssertTrue(isLeftover(pid: 500, now: (1_800_000_000.25, 1), record: record))
        // Another copy of Iris runs it; or a shell; or the pid was given to a later process; or it is gone.
        XCTAssertFalse(isLeftover(pid: 500, now: (1_800_000_000.25, 700), record: record))
        XCTAssertFalse(isLeftover(pid: 500, now: (1_800_000_000.25, 1), record: nil))
        XCTAssertFalse(isLeftover(pid: 501, now: (1_800_000_000.25, 1), record: record))
        XCTAssertFalse(isLeftover(pid: 500, now: (1_800_000_001.25, 1), record: record))
        XCTAssertFalse(isLeftover(pid: 500, now: nil, record: record))
        // Never launchd itself, or the kernel.
        for pid: pid_t in [1, 0, -1] {
            XCTAssertFalse(isLeftover(pid: pid, now: (5, 1), record: ServerIdentity(pid: pid, started: 5)))
        }
    }

    /// A process whose parent is launchd and that ignores SIGTERM, as a stopped or stuck server left by a crash.
    private func orphanIgnoringTerm() throws -> ServerIdentity {
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", #"trap "" TERM; /bin/sleep 600 </dev/null >/dev/null 2>&1 & echo $!"#]
        let output = Pipe()
        shell.standardOutput = output
        try shell.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        shell.waitUntilExit()
        let pid = try XCTUnwrap(pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)))
        let deadline = Date().addingTimeInterval(5)
        while processStart(pid)?.parent != 1 && Date() < deadline { usleep(10_000) }
        let started = try XCTUnwrap(processStart(pid)).started
        XCTAssertEqual(processStart(pid)?.parent, 1)
        return ServerIdentity(pid: pid, started: started)
    }

    private func record(_ identity: ServerIdentity) {
        defaults.set(Int(identity.pid), forKey: RemoteAccessKey.childPid)
        defaults.set(identity.started, forKey: RemoteAccessKey.childStarted)
    }

    private func listener(_ identity: ServerIdentity) -> Listener {
        Listener(pid: identity.pid, port: 8788, scopeFile: "/x/scope", started: Date(timeIntervalSince1970: identity.started))
    }

    /// A leftover that ignores SIGTERM: Quit, during the stop, waits out the grace period and ends it with SIGKILL.
    @MainActor
    func testQuitFinishesStoppingALeftover() throws {
        let old = try orphanIgnoringTerm()
        defer { if isLeftover(pid: old.pid, now: processStart(old.pid), record: old) { kill(old.pid, SIGKILL) } }
        record(old)
        let switched = server("/nonexistent", listeners: [listener(old)], timing: RemoteServerTiming(stopGrace: 1))
        switched.start()
        XCTAssertEqual(switched.status.ours, [old])
        wait(0.3) { false }
        XCTAssertNotNil(processStart(old.pid))
        let quit = Date()
        switched.quit()
        XCTAssertNil(processStart(old.pid))
        XCTAssertLessThan(Date().timeIntervalSince(quit), 2.5)
        // The record stays; it names no process now.
        XCTAssertEqual(defaults.object(forKey: RemoteAccessKey.childPid) as? Int, Int(old.pid))
    }

    /// A recorded pid now with another start time is another process: it gets no signal, and Iris goes on.
    @MainActor
    func testNoSignalToAnotherProcess() throws {
        let other = try orphanIgnoringTerm()
        defer { if isLeftover(pid: other.pid, now: processStart(other.pid), record: other) { kill(other.pid, SIGKILL) } }
        let stale = ServerIdentity(pid: other.pid, started: other.started - 60)
        record(stale)
        let serving = try script(#"echo '{"port": 1}'; exec sleep 600"#)
        let switched = server(serving, listeners: [listener(stale)], timing: RemoteServerTiming(stopGrace: 0.2))
        switched.start()
        wait(1) { false }
        XCTAssertEqual(processStart(other.pid)?.started, other.started)
        XCTAssertEqual(switched.status.phase, .off)
        XCTAssertEqual(switched.starts, 0)
    }

    func testStartFailure() {
        XCTAssertEqual(startFailure("Error: port 8788 is in use on 127.0.0.1; stop what holds it\n", status: 1, signalled: false),
                       "port 8788 is in use on 127.0.0.1; stop what holds it")
        XCTAssertEqual(startFailure("Error: --port must be between 1 and 65535\nUsage: iris mcp [--http]\n  See 'iris mcp --help'.\n",
                                    status: 64, signalled: false), "--port must be between 1 and 65535")
        XCTAssertEqual(startFailure("", status: 1, signalled: false), "the server stopped before it was ready, with exit status 1")
        XCTAssertEqual(startFailure("", status: 9, signalled: true), "the server was ended by signal 9 before it was ready")
    }
}
