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
                        lookup: @escaping (pid_t) -> (started: Double, parent: pid_t)? = processStart,
                        seen: @escaping (RemoteServerStatus) -> Void = { _ in }) -> RemoteServer {
        RemoteServer(executable: executable, log: folder + "/logs/http.log", defaults: defaults,
                     tokenFile: folder + "/state/token", scopeFile: folder + "/state/scope", stateDir: folder + "/state",
                     listeners: { listeners }, lookup: lookup, timing: timing, changed: seen)
    }

    @MainActor
    private func wait(_ seconds: Double, until done: () -> Bool) {
        let deadline = DispatchTime.now() + seconds
        while !done() && DispatchTime.now() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    private func seconds(since start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
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

    /// The server's activity lines, asked for by the environment, are kept in memory and never logged; the request log
    /// gets every other byte. Activity outlives a restart and is cleared when the switch is turned off.
    @MainActor
    func testActivity() throws {
        let serving = try script(#"""
            echo '{"port": 1}'
            [ "$IRIS_REPORT_ACTIVITY" = 1 ] || exec sleep 600
            now=$(date +%Y-%m-%dT%H:%M:%S%z)
            printf '@activity %s Hark\n2026-11-26T10:00:00+01:00 POST initialize - 200 0.001s\n@activ' "$now" >&2
            sleep 0.2
            printf 'ity %s\n' "$now" >&2
            exec sleep 600
            """#)
        var actives = 0
        let switched = RemoteServer(executable: serving, log: folder + "/logs/http.log", defaults: defaults,
                                    tokenFile: folder + "/state/token", scopeFile: folder + "/state/scope",
                                    stateDir: folder + "/state", listeners: { [] }, active: { actives += 1 }) { _ in }
        switched.turn(on: true)
        wait(10) { actives >= 2 }
        XCTAssertEqual(actives, 2)
        XCTAssertEqual(switched.activity.named.map(\.name), ["Hark"])
        XCTAssertNil(switched.activity.unnamed)  // Hark's, by the 5-minute rule
        XCTAssertEqual(try String(contentsOfFile: folder + "/logs/http.log"), "2026-11-26T10:00:00+01:00 POST initialize - 200 0.001s\n")
        let first = switched.status.pid
        switched.restart()
        wait(20) { switched.status.phase == .on(port: defaultHTTPPort) && switched.status.pid != first }
        XCTAssertEqual(switched.activity.named.map(\.name), ["Hark"])
        switched.turn(on: false)
        XCTAssertNil(switched.activity.lastUsed)
        wait(10) { switched.status.pid == nil }
        XCTAssertNil(switched.activity.lastUsed)
    }

    /// A line the old server sent before Off, still waiting for the main thread, is not kept after On.
    @MainActor
    func testActivityQueuedBeforeOffIsDropped() throws {
        let marker = folder + "/reported"
        let serving = try script(#"""
            echo '{"port": 1}'
            [ -e "\#(marker)" ] && exec sleep 600
            touch "\#(marker)"
            sleep 0.3
            printf '@activity %s Hark\n' "$(date +%Y-%m-%dT%H:%M:%S%z)" >&2
            exec sleep 600
            """#)
        var actives = 0
        let switched = RemoteServer(executable: serving, log: folder + "/logs/http.log", defaults: defaults,
                                    tokenFile: folder + "/state/token", scopeFile: folder + "/state/scope",
                                    stateDir: folder + "/state", listeners: { [] }, active: { actives += 1 }) { _ in }
        switched.turn(on: true)
        wait(10) { switched.status.phase == .on(port: defaultHTTPPort) }
        // The main thread held while the line is read and queued for it.
        Thread.sleep(forTimeInterval: 1.5)
        switched.turn(on: false)
        switched.turn(on: true)
        wait(10) { switched.status.phase == .on(port: defaultHTTPPort) && FileManager.default.fileExists(atPath: marker) }
        wait(1) { false }
        XCTAssertEqual(actives, 0)
        XCTAssertNil(switched.activity.lastUsed)
        switched.turn(on: false)
        wait(10) { switched.status.pid == nil }
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

    /// A restart stops the server and starts another; after a failed start it tries at once; with the switch off, or
    /// another server running, it does nothing.
    @MainActor
    func testRestart() throws {
        let serving = try script(#"echo '{"port": 1}'; exec sleep 600"#)
        var phases: [RemoteServerPhase] = []
        let switched = server(serving, seen: { phases.append($0.phase) })
        switched.restart()
        XCTAssertEqual(switched.starts, 0)
        switched.turn(on: true)
        wait(10) { switched.status.phase == .on(port: defaultHTTPPort) }
        let first = try XCTUnwrap(switched.status.pid)
        phases = []
        switched.restart()
        switched.restart()
        XCTAssertEqual(switched.status.phase, .starting)
        wait(20) { switched.status.phase == .on(port: defaultHTTPPort) }
        XCTAssertFalse(running(first))
        XCTAssertNotEqual(switched.status.pid, first)
        XCTAssertEqual(switched.starts, 2)
        // Starting while the first stops and while the second starts, then on.
        let changes = phases.reduce(into: [RemoteServerPhase]()) { if $0.last != $1 { $0.append($1) } }
        XCTAssertEqual(changes, [.starting, .on(port: defaultHTTPPort)])
        switched.turn(on: false)
        wait(10) { switched.status.pid == nil }

        let failing = try script(#"echo "Error: no" >&2; exit 1"#)
        let failed = server(failing)
        failed.turn(on: true)
        wait(5) { failed.status.phase != .starting }
        XCTAssertEqual(failed.starts, 1)
        failed.restart()
        XCTAssertEqual(failed.starts, 2)
        failed.turn(on: false)

        let outside = server(serving, listeners: [Listener(pid: 1, port: 8788, scopeFile: "/x/scope", started: Date())])
        outside.turn(on: true)
        outside.restart()
        XCTAssertEqual(outside.status.phase, .outside([8788]))
        XCTAssertEqual(outside.starts, 0)
        outside.turn(on: false)
    }

    /// Quick ticks: each is in the file as it answers, and one restart follows the last. The restart waits for ticks
    /// still being made, even when the quiet time has passed: a slow listing holds it off.
    @MainActor
    func testTicksRestartOnce() throws {
        var restarts = 0
        let items = (1...5).map { Named(id: "c\($0)", name: "Calendar \($0)") }
        let changes = ScopeChanges(path: folder + "/state/scope", quiet: 0.3, listing: { _ in
            usleep(40_000)
            return items
        }) { restarts += 1 }
        var expected = ScopeFile(calendars: [], folders: [])
        var answers: [ScopeFile] = []
        var restartsSeen: [Int] = []
        for index in 0..<20 {
            let tick = ScopeTick.item(.calendars, "c\(index % 5 + 1)", index % 3 != 2)
            expected = applying(tick, to: expected, items: items).file
            let wanted = expected
            changes.submit(tick) { result in
                answers.append((try? result.get()) ?? ScopeFile(calendars: ["failed"], folders: nil))
                XCTAssertEqual(try? readScopeFile(self.folder + "/state/scope"), wanted)
                restartsSeen.append(restarts)
            }
        }
        // 20 listings of 40 ms: well past the quiet time before the last tick is written.
        wait(10) { answers.count == 20 }
        XCTAssertEqual(answers.last, expected)
        XCTAssertEqual(restartsSeen, Array(repeating: 0, count: 20))
        wait(2) { restarts > 0 }
        wait(0.5) { false }
        XCTAssertEqual(restarts, 1)
        // A tick that changes nothing writes nothing and restarts nothing.
        var same: ScopeFile?
        changes.submit(.sharedEvents(true)) { same = try? $0.get() }
        wait(2) { same != nil }
        XCTAssertEqual(same, expected)
        wait(0.6) { false }
        XCTAssertEqual(restarts, 1)
    }

    /// A listing that never answers: after the deadline the tick fails with nothing changed, the queue moves on, and
    /// the answer when it comes is not applied.
    @MainActor
    func testListingDeadline() throws {
        let release = DispatchSemaphore(value: 0)
        let items = [Named(id: "c1", name: "Work")]
        let changes = ScopeChanges(path: folder + "/state/scope", listingDeadline: 0.5, listing: { _ in
            release.wait()
            return items
        }) {}
        var answers: [String] = []
        changes.submit(.item(.calendars, "c1", true)) { result in
            switch result {
            case .success(let file): answers.append("\(file.calendars ?? [])")
            case .failure(let error): answers.append("\(error)")
            }
        }
        changes.submit(.access(.calendars, .readOnly)) { answers.append((try? $0.get()).map { "calendars \($0.calendars == nil ? "all" : "some")" } ?? "failed") }
        changes.submit(.all(.lists)) { answers.append((try? $0.get()).map { "lists \($0.lists == nil ? "all" : "some")" } ?? "failed") }
        wait(0.3) { false }
        XCTAssertEqual(answers, [])
        XCTAssertTrue(changes.isBusy)
        wait(5) { answers.count == 3 }
        XCTAssertEqual(answers, ["Iris could not read your calendars just now, so nothing was changed.", "calendars all", "lists all"])
        // The late answer comes and changes nothing.
        release.signal()
        wait(0.5) { false }
        XCTAssertEqual(answers.count, 3)
        XCTAssertEqual(try readScopeFile(folder + "/state/scope"), ScopeFile(calendars: nil, folders: [], lists: nil))
        XCTAssertFalse(changes.isBusy)
    }

    /// What Quit waits for: called once every queued change has answered, at once when none is queued.
    @MainActor
    func testDrain() throws {
        let items = [Named(id: "c1", name: "Work")]
        let changes = ScopeChanges(path: folder + "/state/scope", listing: { _ in
            usleep(200_000)
            return items
        }) {}
        var drained = 0
        changes.whenDrained { drained += 1 }
        XCTAssertEqual(drained, 1)
        var answered = 0
        for tick in [ScopeTick.item(.calendars, "c1", true), .access(.calendars, .readWrite), .item(.calendars, "c1", false)] {
            changes.submit(tick) { _ in answered += 1 }
        }
        changes.whenDrained { drained += 1 }
        XCTAssertEqual(drained, 1)
        wait(5) { drained == 2 }
        XCTAssertEqual(answered, 3)
        XCTAssertEqual(try readScopeFile(folder + "/state/scope"), ScopeFile(calendars: [], folders: []))

        // Reset through the same queue: done when the file is broken, nothing when it reads well.
        var resets: [Bool] = []
        changes.reset { resets.append((try? $0.get()) ?? false) }
        wait(5) { resets.count == 1 }
        try Data("broken".utf8).write(to: URL(fileURLWithPath: folder + "/state/scope"))
        changes.reset { resets.append((try? $0.get()) ?? false) }
        wait(5) { resets.count == 2 }
        XCTAssertEqual(resets, [false, true])
        XCTAssertEqual(loadScopeFile(folder + "/state/scope"), .file(ScopeFile(calendars: [], folders: [])))
    }

    /// Ticks made while one waits for its listing queue behind it: each is applied in the order made, against the
    /// listing made for it, and each answers, a failed listing with nothing changed.
    @MainActor
    func testTicksWaitForTheirListing() throws {
        final class Listings: @unchecked Sendable {
            let lock = NSLock()
            var calls = 0
        }
        let listings = Listings()
        let items = (1...3).map { Named(id: "c\($0)", name: "Calendar \($0)") }
        let changes = ScopeChanges(path: folder + "/state/scope", listing: { _ in
            let call = listings.lock.withLock {
                listings.calls += 1
                return listings.calls
            }
            usleep(UInt32(150_000 - 40_000 * min(call, 3)))
            // The third listing fails, as Calendar not answering does.
            return call == 3 ? nil : items
        }) {}
        let ticks: [ScopeTick] = [.item(.calendars, "c1", true), .access(.calendars, .readWrite), .item(.calendars, "c2", true),
                                  .item(.calendars, "c3", true), .all(.folders), .item(.calendars, "c1", false),
                                  .sharedEvents(true)]
        var answers: [(Int, String)] = []
        for (index, tick) in ticks.enumerated() {
            changes.submit(tick) { result in
                switch result {
                case .success(let file): answers.append((index, "\(file.calendars ?? []) \(file.writes) \(file.sharedEvents)"))
                case .failure(let error): answers.append((index, "\(error)"))
                }
            }
        }
        wait(10) { answers.count == ticks.count }
        XCTAssertEqual(answers.map(\.0), Array(ticks.indices))
        XCTAssertEqual(answers.map(\.1), [
            #"["c1"] false false"#, #"["c1"] true false"#, #"["c1", "c2"] true false"#,
            "Iris could not read your calendars just now, so nothing was changed.",
            #"["c1", "c2"] true false"#, #"["c2"] true false"#, #"["c2"] true true"#,
        ])
        XCTAssertEqual(listings.lock.withLock { listings.calls }, 4)
        XCTAssertEqual(try readScopeFile(folder + "/state/scope"),
                       ScopeFile(calendars: ["c2"], folders: nil, writes: true, sharedEvents: true))
    }

    /// Off and then Read Only, clicked before Off has answered: Read Only finds Off's memory under the lock, so it lists
    /// and shares again what Off remembered, not everything. The memory is the file beside the scope file.
    @MainActor
    func testOffThenOnQueued() throws {
        final class Listings: @unchecked Sendable {
            let lock = NSLock()
            var calls = 0
        }
        let listings = Listings()
        let scope = folder + "/state/scope"
        let items = (1...3).map { Named(id: "c\($0)", name: "Calendar \($0)") }
        try writeScopeFile(ScopeFile(calendars: ["c2"], folders: [], writes: true), to: scope)
        let changes = ScopeChanges(path: scope, listing: { _ in
            listings.lock.withLock { listings.calls += 1 }
            return items
        }) {}
        var answers: [ScopeFile] = []
        for tick in [ScopeTick.access(.calendars, .off), .access(.calendars, .readOnly)] {
            changes.submit(tick) { answers.append((try? $0.get()) ?? ScopeFile(calendars: ["failed"], folders: nil)) }
        }
        wait(5) { answers.count == 2 }
        XCTAssertEqual(answers, [ScopeFile(calendars: [], folders: []), ScopeFile(calendars: ["c2"], folders: [])])
        XCTAssertEqual(listings.lock.withLock { listings.calls }, 1)
        XCTAssertEqual(loadSharedBefore(scope + ".shared-before"), [:])
        // Off again: remembered.
        changes.submit(.access(.calendars, .off)) { answers.append((try? $0.get()) ?? ScopeFile(calendars: ["failed"], folders: nil)) }
        wait(5) { answers.count == 3 }
        XCTAssertEqual(loadSharedBefore(scope + ".shared-before"), [.calendars: .entries(["c2"])])

        // Notes closed: folders remembered cannot be shared again, so nothing changes and the answer says why.
        try writeScopeFile(ScopeFile(calendars: [], folders: ["f1"]), to: scope)
        let closed = ScopeChanges(path: scope, listing: { _ in nil }) {}
        var failures: [String] = []
        for tick in [ScopeTick.access(.folders, .off), .access(.folders, .readOnly)] {
            closed.submit(tick) { if case .failure(let error) = $0 { failures.append("\(error)") } }
        }
        wait(5) { !closed.isBusy }
        XCTAssertEqual(failures, ["Iris could not read your note folders just now, so nothing was changed. Open Notes and try again."])
        XCTAssertEqual(try readScopeFile(scope), ScopeFile(calendars: [], folders: []))
        XCTAssertEqual(loadSharedBefore(scope + ".shared-before"), [.calendars: .entries(["c2"]), .folders: .entries(["f1"])])
    }

    /// Two copies of Iris on one scope file. A's Read & Write would need no listing while Calendar shares; B turns
    /// Calendar off first. A decides under the lock, finds B's memory, lists, and shares again what B remembered, never
    /// everything. Not listed is never taken for listed and empty.
    @MainActor
    func testTwoCopies() throws {
        let scope = folder + "/state/scope"
        let items = (1...3).map { Named(id: "c\($0)", name: "Calendar \($0)") }
        try writeScopeFile(ScopeFile(calendars: ["c1"], folders: []), to: scope)
        // Straight under the lock: not listed, it asks for a listing; listed and empty, it stays off.
        _ = try changeScopeFile(scope, .access(.calendars, .off), items: nil)
        XCTAssertThrowsError(try changeScopeFile(scope, .access(.calendars, .readWrite), items: nil)) {
            XCTAssertEqual(($0 as? ScopeListingNeeded)?.kind, .calendars)
        }
        XCTAssertThrowsError(try changeScopeFile(scope, .access(.calendars, .readWrite), items: []))
        XCTAssertEqual(try readScopeFile(scope), ScopeFile(calendars: [], folders: []))
        try writeScopeFile(ScopeFile(calendars: ["c1"], folders: []), to: scope)

        let release = DispatchSemaphore(value: 0)
        let a = ScopeChanges(path: scope, listing: { _ in items }) {}
        let b = ScopeChanges(path: scope, listing: { _ in
            release.wait()
            return items
        }) {}
        var answers: [String] = []
        // B's item tick holds its queue on a listing; its Off waits behind it.
        b.submit(.item(.calendars, "c3", true)) { answers.append("B item " + ((try? $0.get()).map { "\($0.calendars ?? [])" } ?? "failed")) }
        b.submit(.access(.calendars, .off)) { answers.append("B off " + ((try? $0.get()).map { "\($0.calendars ?? [])" } ?? "failed")) }
        wait(0.3) { false }
        release.signal()
        wait(5) { answers.count == 2 }
        a.submit(.access(.calendars, .readWrite)) { result in
            answers.append("A " + ((try? result.get()).map { "\($0.calendars.map { "\($0)" } ?? "all") \($0.writes)" } ?? "failed"))
        }
        wait(5) { answers.count == 3 }
        XCTAssertEqual(answers, [#"B item ["c1", "c3"]"#, "B off []", #"A ["c1", "c3"] true"#])
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
        // The same microsecond, not merely close: a microsecond apart is another process.
        XCTAssertFalse(isLeftover(pid: 500, now: (1_800_000_000.250001, 1), record: record))
        // A start time through Date and back, as a listener's is, still matches.
        let time = Date(timeIntervalSince1970: 1_800_000_000.123457).timeIntervalSince1970
        XCTAssertTrue(isLeftover(pid: 500, now: (time, 1), record: ServerIdentity(pid: 500, started: 1_800_000_000.123457)))
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
        let deadline = DispatchTime.now() + 5
        while processStart(pid)?.parent != 1 && DispatchTime.now() < deadline { usleep(10_000) }
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
        let quit = DispatchTime.now()
        switched.quit()
        XCTAssertNil(processStart(old.pid))
        XCTAssertLessThan(seconds(since: quit), 2.5)
        // The record stays; it names no process now.
        XCTAssertEqual(defaults.object(forKey: RemoteAccessKey.childPid) as? Int, Int(old.pid))
    }

    /// A supervisor released while it polls a leftover goes away, and sends nothing more: past the deadline the
    /// leftover, which ignores SIGTERM, is still there.
    @MainActor
    func testReleasedWhilePolling() throws {
        let old = try orphanIgnoringTerm()
        defer { if isLeftover(pid: old.pid, now: processStart(old.pid), record: old) { kill(old.pid, SIGKILL) } }
        record(old)
        weak var gone: RemoteServer?
        do {
            let switched = server("/nonexistent", listeners: [listener(old)], timing: RemoteServerTiming(stopGrace: 0.3))
            switched.start()
            XCTAssertEqual(switched.status.ours, [old])
            gone = switched
        }
        XCTAssertNil(gone)
        wait(1) { false }
        XCTAssertTrue(isLeftover(pid: old.pid, now: processStart(old.pid), record: old))
    }

    /// The child's identity is looked up at launch; one lookup that fails is made again when it is ready.
    @MainActor
    func testIdentityLookedUpAgain() throws {
        let serving = try script(#"sleep 0.3; echo '{"port": 1}'; exec sleep 600"#)
        var calls = 0
        let switched = server(serving, lookup: { pid in
            calls += 1
            return calls == 1 ? nil : processStart(pid)
        })
        switched.turn(on: true)
        XCTAssertEqual(switched.status.ours, [])
        wait(10) { switched.status.phase == .on(port: defaultHTTPPort) }
        let pid = try XCTUnwrap(switched.status.pid)
        XCTAssertEqual(switched.status.ours.map(\.pid), [pid])
        XCTAssertEqual(defaults.object(forKey: RemoteAccessKey.childPid) as? Int, Int(pid))
        switched.turn(on: false)
        wait(10) { !running(pid) }
        XCTAssertFalse(running(pid))
    }

    /// A child whose identity cannot be looked up at all is not accepted: it is stopped and counts as a failed
    /// start, tried again after the usual delay.
    @MainActor
    func testUnidentifiedServerIsStopped() throws {
        let serving = try script(#"echo '{"port": 1}'; exec sleep 600"#)
        let switched = server(serving, lookup: { _ in nil })
        switched.turn(on: true)
        let pid = try XCTUnwrap(switched.status.pid)
        wait(10) { !running(pid) && switched.status.pid == nil }
        XCTAssertFalse(running(pid))
        XCTAssertEqual(switched.status.phase, .failed(unidentifiedServer))
        XCTAssertNil(defaults.object(forKey: RemoteAccessKey.childPid))
        wait(1) { switched.starts > 1 }
        XCTAssertEqual(switched.starts, 1)
        switched.turn(on: false)
    }

    /// One that could not be identified and does not stop on SIGTERM keeps the failure through off and on, with no
    /// second start beside it; once it has exited, the usual try follows.
    @MainActor
    func testUnidentifiedServerThatWillNotStop() throws {
        let stubborn = try script(#"trap "" TERM; echo '{"port": 1}'; exec sleep 600"#)
        let switched = server(stubborn, timing: RemoteServerTiming(retry: 0.5), lookup: { _ in nil })
        switched.turn(on: true)
        let pid = try XCTUnwrap(switched.status.pid)
        let identity = ServerIdentity(pid: pid, started: try XCTUnwrap(processStart(pid)).started)
        defer { killStill(identity) }
        wait(10) { switched.status.phase != .starting }
        XCTAssertEqual(switched.status.phase, .failed(unidentifiedServer))
        switched.turn(on: false)
        XCTAssertEqual(switched.status.phase, .failed(unidentifiedServer))
        switched.turn(on: true)
        XCTAssertEqual(switched.status.phase, .failed(unidentifiedServer))
        wait(1) { false }
        XCTAssertTrue(running(pid))
        XCTAssertEqual(switched.status.pid, pid)
        XCTAssertEqual(switched.starts, 1)
        killStill(identity)
        wait(5) { switched.starts > 1 }
        XCTAssertEqual(switched.starts, 2)
        let second = try XCTUnwrap(switched.status.pid)
        let secondIdentity = ServerIdentity(pid: second, started: try XCTUnwrap(processStart(second)).started)
        defer { killStill(secondIdentity) }
        switched.turn(on: false)
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
