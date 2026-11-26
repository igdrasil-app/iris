import XCTest
@testable import iris

/// The switch's server with a stand-in for iris: a script that prints a ready line and waits, or fails as a
/// server that cannot start does. No port is opened.
final class RemoteServerTests: XCTestCase {
    private var folder = ""
    private var defaults: UserDefaults!
    private let suite = "iris-switch-tests"  // one name, emptied around each test, so runs leave no domains behind

    override func setUpWithError() throws {
        folder = NSTemporaryDirectory() + "iris-switch-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
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

    @MainActor
    func testStartsStopsAndRemembers() throws {
        let serving = try script(#"echo '{"port": 1}'; echo "a request" >&2; exec sleep 600"#)
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
        XCTAssertNil(defaults.object(forKey: RemoteAccessKey.childPid))
        XCTAssertEqual(switched.starts, 1)
    }

    @MainActor
    func testFilesAreNeverReplaced() throws {
        try FileManager.default.createDirectory(atPath: folder + "/state", withIntermediateDirectories: true)
        try Data("not a scope".utf8).write(to: URL(fileURLWithPath: folder + "/state/scope"))
        try createIfMissing(folder + "/state/scope", Data(sharesNothing.utf8))
        XCTAssertEqual(try String(contentsOfFile: folder + "/state/scope"), "not a scope")
        try createIfMissing(folder + "/state/token", Data("first".utf8))
        try createIfMissing(folder + "/state/token", Data("second".utf8))
        XCTAssertEqual(try String(contentsOfFile: folder + "/state/token"), "first")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder + "/state").sorted(), ["scope", "token"])
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
        kill(first, SIGKILL)
        wait(5) { switched.status.pid == nil }
        XCTAssertEqual(switched.status.phase, .starting)
        wait(10) { switched.status.phase == .on(port: defaultHTTPPort) }
        let second = try XCTUnwrap(switched.status.pid)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(switched.status.ours, [first, second])
        // The second crash in a row waits the next delay.
        kill(second, SIGKILL)
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
        let started = Date(timeIntervalSince1970: 1_800_000_000.25)
        let listener = Listener(pid: 500, port: 8788, scopeFile: "/x/scope", started: started)
        let record = (pid: 500, started: 1_800_000_000.25)
        XCTAssertTrue(isLeftover(listener, parent: 1, record: record))
        // Another copy of Iris runs it; or launchd, or a shell; or the pid was given to a later process.
        XCTAssertFalse(isLeftover(listener, parent: 700, record: record))
        XCTAssertFalse(isLeftover(listener, parent: 1, record: nil))
        XCTAssertFalse(isLeftover(listener, parent: 1, record: (pid: 501, started: 1_800_000_000.25)))
        XCTAssertFalse(isLeftover(listener, parent: 1, record: (pid: 500, started: 1_800_000_001.25)))
        XCTAssertFalse(isLeftover(listener, parent: nil, record: record))
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
