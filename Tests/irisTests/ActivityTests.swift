import XCTest
@testable import iris

/// Who has been active, from the server's activity lines to the header's words and the icon's mark.
final class ActivityTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func at(_ seconds: Double) -> Date { start.addingTimeInterval(seconds) }

    func testLabel() {
        XCTAssertEqual(activityLabel("Hark"), "Hark")
        XCTAssertEqual(activityLabel("claude-code 2.1_beta"), "claude-code 2.1_beta")
        // Control characters, newlines, tabs and emoji are dropped; spaces collapse and are trimmed.
        XCTAssertEqual(activityLabel("Ha\u{0}r\u{1B}[31mk\r\n"), "Har31mk")
        XCTAssertEqual(activityLabel("  Hark \t\n  and   🤖 Claude  "), "Hark and Claude")
        XCTAssertEqual(activityLabel("Ünïcode Клод 名前 e\u{301}"), "ncode e")
        XCTAssertEqual(activityLabel("\u{202E}Hark\u{200B}"), "Hark")
        XCTAssertEqual(activityLabel(String(repeating: "a", count: 200)), String(repeating: "a", count: 32))
        XCTAssertEqual(activityLabel(String(repeating: "a", count: 31) + "  b"), String(repeating: "a", count: 31))
        for empty: Any? in ["", "   ", "\n\u{7}", "🤖", nil, 42, ["name": "x"]] {
            XCTAssertNil(activityLabel(empty), "\(String(describing: empty))")
        }
        // A name made to look like a log line or an activity line stays one line, without its newline or @.
        XCTAssertEqual(activityLabel("x\n2026-11-26T10:00:00+01:00 POST tools/call - 200 0.1s"),
                       "x2026-11-26T1000000100 POST tool")
        XCTAssertEqual(activityLabel("x\n@activity 2026-11-26T10:00:00Z Evil"), "xactivity 2026-11-26T100000Z Evi")
    }

    func testClientLabel() {
        XCTAssertEqual(clientLabel(method: "initialize", params: ["clientInfo": ["name": "Hark", "version": "1"]]), "Hark")
        XCTAssertNil(clientLabel(method: "tools/list", params: ["clientInfo": ["name": "Hark"]]))
        let modern: [String: Any] = ["_meta": [clientInfoKey: ["name": "Claude\n"], versionKey: modernVersion]]
        XCTAssertEqual(clientLabel(method: "tools/call", params: modern), "Claude")
        XCTAssertNil(clientLabel(method: "initialize", params: [:]))
        XCTAssertNil(clientLabel(method: "initialize", params: ["clientInfo": "Hark"]))
    }

    func testLine() {
        for report in [ActivityReport(time: start, name: nil), ActivityReport(time: start, name: "Hark and Claude"),
                       ActivityReport(time: start, name: "a.b-c_d 9")] {
            let line = activityLine(report)
            XCTAssertTrue(line.hasPrefix("@activity "))
            XCTAssertFalse(line.contains("\n"))
            XCTAssertEqual(parseActivityLine(line), report)
        }
        // The time with the Mac's offset, as the request log has it.
        XCTAssertEqual(activityLine(ActivityReport(time: start, name: "Hark")), "@activity \(iso(start)) Hark")
        // A request log line is never one, nor is anything malformed or a name that is not a label.
        for line in ["\(iso(start)) POST initialize - 200 0.002s", "\(iso(start)) - - - 401 0.000s",
                     "@activity", "@activity ", "@activity yesterday Hark", "@activity\(iso(start))",
                     " @activity \(iso(start))", "@activity \(iso(start)) Ha\u{1}rk", "@activity \(iso(start))  Hark",
                     "@activity \(iso(start)) " + String(repeating: "a", count: 33), "Error: port 8765 is in use"] {
            XCTAssertNil(parseActivityLine(line), line)
        }
        // And an activity line never starts as a request log line does, with its time.
        XCTAssertFalse(activityLine(ActivityReport(time: start, name: nil)).first!.isNumber)
    }

    func testSplitter() {
        let log1 = "\(iso(start)) POST initialize - 200 0.002s\n"
        let log2 = "\(iso(start)) POST tools/call calendars 200 0.120s\n"
        let named = activityLine(ActivityReport(time: start, name: "Hark")) + "\n"
        let plain = activityLine(ActivityReport(time: start, name: nil)) + "\n"
        let all = named + log1 + plain + log2 + "@act" + "\n" + "@\n" + "\n"
        let expectedLog = log1 + log2 + "@act\n@\n\n"
        // Whatever the chunks, the log gets the same bytes and the lines come whole.
        for size in [1, 2, 3, 7, 10, 64, all.utf8.count] {
            var splitter = ActivitySplitter()
            var log = Data()
            var lines: [String] = []
            let bytes = Array(all.utf8)
            for offset in stride(from: 0, to: bytes.count, by: size) {
                let (part, found) = splitter.split(Data(bytes[offset..<min(offset + size, bytes.count)]))
                log += part
                lines += found
            }
            log += splitter.finish()
            XCTAssertEqual(String(decoding: log, as: UTF8.self), expectedLog, "\(size)")
            XCTAssertEqual(lines, [String(named.dropLast()), String(plain.dropLast())], "\(size)")
        }
        // A line that is not one goes to the log at once, before its end; one that might be is held.
        var splitter = ActivitySplitter()
        XCTAssertEqual(splitter.split(Data("2026-11".utf8)).log, Data("2026-11".utf8))
        XCTAssertEqual(splitter.split(Data("-26\n@activ".utf8)).log, Data("-26\n".utf8))
        XCTAssertEqual(splitter.split(Data("ity".utf8)).log, Data())
        XCTAssertEqual(splitter.split(Data("X more\n".utf8)).log, Data("@activityX more\n".utf8))
        // A last line cut short goes to the log unless it started as an activity line.
        _ = splitter.split(Data("@activity 2026".utf8))
        XCTAssertEqual(splitter.finish(), Data())
        var cut = ActivitySplitter()
        _ = cut.split(Data("@ac".utf8))
        XCTAssertEqual(cut.finish(), Data("@ac".utf8))
        // One that starts as one and runs on is dropped up to its end, never held without bound, and never logged.
        var long = ActivitySplitter()
        let (logged, lines) = long.split(Data(("@activity " + String(repeating: "x", count: 100_000) + "\n" + log1).utf8))
        XCTAssertEqual(String(decoding: logged, as: UTF8.self), log1)
        XCTAssertEqual(lines, [])
    }

    func testAttribution() {
        // One client: its initialize names it, and what follows is its.
        var one = RemoteActivity()
        one.record(ActivityReport(time: at(0), name: "Hark"))
        one.record(ActivityReport(time: at(1), name: nil))
        one.record(ActivityReport(time: at(2), name: nil))
        XCTAssertEqual(one.named, [RemoteActivity.Seen(name: "Hark", last: at(2))])
        XCTAssertNil(one.unnamed)
        // Working on: each request keeps the name, well past 5 minutes from the initialize.
        for minute in 1...20 { one.record(ActivityReport(time: at(Double(minute) * 240), name: nil)) }
        XCTAssertEqual(one.named, [RemoteActivity.Seen(name: "Hark", last: at(4800))])
        // Quiet for more than 5 minutes: the next request without a name is no one's.
        one.record(ActivityReport(time: at(4800 + 301), name: nil))
        XCTAssertEqual(one.unnamed, at(5101))
        XCTAssertEqual(one.named.map(\.last), [at(4800)])
        XCTAssertEqual(one.lastUsed, at(5101))

        // Two interleaved: each named request is its own; one without a name goes to the last named.
        var two = RemoteActivity()
        two.record(ActivityReport(time: at(0), name: "Hark"))
        two.record(ActivityReport(time: at(1), name: "Claude"))
        two.record(ActivityReport(time: at(2), name: nil))
        two.record(ActivityReport(time: at(3), name: "Hark"))
        XCTAssertEqual(two.named, [RemoteActivity.Seen(name: "Hark", last: at(3)), RemoteActivity.Seen(name: "Claude", last: at(2))])
        // The same name twice is one.
        two.record(ActivityReport(time: at(4), name: "Claude"))
        XCTAssertEqual(two.named.map(\.name), ["Hark", "Claude"])

        // Unnamed only.
        var unnamed = RemoteActivity()
        unnamed.record(ActivityReport(time: at(0), name: nil))
        unnamed.record(ActivityReport(time: at(5), name: nil))
        XCTAssertEqual(unnamed.named, [])
        XCTAssertEqual(unnamed.unnamed, at(5))

        // A named initialize older than 5 minutes names nothing after it.
        var old = RemoteActivity()
        old.record(ActivityReport(time: at(0), name: "Hark"))
        old.record(ActivityReport(time: at(300), name: nil))
        old.record(ActivityReport(time: at(900), name: nil))
        XCTAssertEqual(old.named, [])  // kept 10 minutes after its last request
        XCTAssertEqual(old.unnamed, at(900))

        // Names are kept for 10 minutes, and never more than 16.
        var many = RemoteActivity()
        for index in 0..<40 { many.record(ActivityReport(time: at(Double(index)), name: "n\(index)")) }
        XCTAssertEqual(many.named.map(\.name), (24..<40).map { "n\($0)" })
        // Names gone quiet make room before a new one comes, so one active a moment ago is never pushed out.
        var full = RemoteActivity()
        for index in 0..<16 { full.record(ActivityReport(time: at(Double(index)), name: "n\(index)")) }
        full.record(ActivityReport(time: at(590), name: "n0"))
        full.record(ActivityReport(time: at(616), name: "new"))
        XCTAssertEqual(full.named.map(\.name), ["n0", "new"])
    }

    func testStatus() {
        let fits: (String) -> Bool = { $0.count <= 44 }
        func status(_ reports: [(Double, String?)], now: Double) -> String {
            var activity = RemoteActivity()
            for (time, name) in reports { activity.record(ActivityReport(time: at(time), name: name)) }
            return activityStatus(activity, now: at(now), fits: fits)
        }
        XCTAssertEqual(activityStatus(RemoteActivity(), now: start, fits: fits), "On · no activity yet")
        XCTAssertEqual(status([(0, "Hark")], now: 0), "Hark · active just now")
        XCTAssertEqual(status([(0, "Hark")], now: 59), "Hark · active just now")
        XCTAssertEqual(status([(0, "Hark")], now: 60), "Hark · active 1 min ago")
        XCTAssertEqual(status([(0, "Hark")], now: 3 * 60 + 30), "Hark · active 3 min ago")
        XCTAssertEqual(status([(0, "Hark")], now: 599), "Hark · active 9 min ago")
        XCTAssertEqual(status([(0, "Hark")], now: 600), "On · last used 10 min ago")
        XCTAssertEqual(status([(0, "Hark")], now: 25 * 60), "On · last used 25 min ago")
        XCTAssertEqual(status([(0, "Hark")], now: 3600), "On · last used 1 hour ago")
        XCTAssertEqual(status([(0, "Hark")], now: 2 * 3600 + 1800), "On · last used 2 hours ago")
        XCTAssertEqual(status([(0, "Hark")], now: 24 * 3600), "On · last used yesterday")
        XCTAssertEqual(status([(0, "Hark")], now: 47 * 3600), "On · last used yesterday")
        XCTAssertEqual(status([(0, "Hark")], now: 3 * 24 * 3600), "On · last used 3 days ago")
        // Several, in the order first seen, the time the latest's.
        XCTAssertEqual(status([(0, "Hark"), (30, "Claude")], now: 100), "Hark and Claude · active 1 min ago")
        XCTAssertEqual(status([(0, "Hark"), (1, "Claude"), (2, "Cursor")], now: 2), "Hark, Claude and Cursor · active just now")
        XCTAssertEqual(status([(0, "Hark"), (1, "Claude"), (2, "Cursor"), (3, "Codex")], now: 3), "4 assistants · active just now")
        // Only the names of the last 10 minutes.
        XCTAssertEqual(status([(0, "Hark"), (500, "Claude")], now: 700), "Claude · active 3 min ago")
        // Unnamed only, and unnamed beside a name.
        XCTAssertEqual(status([(0, nil)], now: 120), "An assistant · active 2 min ago")
        XCTAssertEqual(status([(0, "Hark"), (400, nil)], now: 400), "Hark and an assistant · active just now")
        XCTAssertEqual(status([(0, nil), (400, "Hark")], now: 400), "Hark and an assistant · active just now")
        // Each name as the client wrote it.
        XCTAssertEqual(status([(0, "iTerm"), (1, "Hark")], now: 1), "iTerm and Hark · active just now")
        XCTAssertEqual(status([(0, "hark"), (400, nil)], now: 400), "hark and an assistant · active just now")
        XCTAssertEqual(status([(0, "iTerm")], now: 0), "iTerm · active just now")
        // One long name that does not fit is shortened, never counted.
        let long = String(repeating: "W", count: 32)
        let shortened = status([(0, long)], now: 0)
        XCTAssertEqual(shortened, String(repeating: "W", count: 24) + "… · active just now")
        XCTAssertTrue(fits(shortened))
    }

    /// Activity shows only for the switch's own server running alone with settings that need nothing.
    func testStatusPrecedence() {
        var activity = RemoteActivity()
        activity.record(ActivityReport(time: start, name: "Hark"))
        let scope = "/x/scope"
        func state(_ listeners: [(pid_t, ListenerState)], usable: Bool? = true) -> RemoteAnswer {
            .known(RemoteState(scopePath: scope, modified: Date(), usable: usable, problem: nil, calendar: nil, notes: nil,
                               reminders: nil, eventsWithOtherPeople: false, writesCounted: nil, tools: nil, tokenPath: "/t",
                               tokenExists: true, tokenProblem: nil,
                               listeners: listeners.map { (Listener(pid: $0.0, port: 8765, scopeFile: scope,
                                                                    started: Date(timeIntervalSince1970: Double($0.0))), $0.1) }))
        }
        let mine = RemoteServerStatus(phase: .on(port: 8765), pid: 100, ours: [ServerIdentity(pid: 100, started: 100)])
        func line(_ remote: RemoteAnswer, _ server: RemoteServerStatus) -> String {
            remoteStatusLine(remote, server, activity: activity, now: start.addingTimeInterval(5))
        }
        XCTAssertEqual(line(state([(100, .current)]), mine), "Hark · active just now")
        XCTAssertEqual(line(.checking, mine), "Hark · active just now")
        XCTAssertEqual(line(state([(100, .changed)]), mine), "Remote access on · restart to apply changes")
        XCTAssertEqual(line(state([(100, .current)], usable: false), mine), "Remote access on · settings have a problem")
        XCTAssertEqual(line(state([(100, .current)]), RemoteServerStatus(phase: .starting, pid: 100)), "Starting…")
        XCTAssertEqual(line(state([]), RemoteServerStatus(phase: .failed("no"))), "Couldn't start")
        XCTAssertEqual(line(state([(200, .current)]), RemoteServerStatus(phase: .outside([8765]))), "On · run outside Iris")
        XCTAssertEqual(line(state([(100, .current), (200, .current)]), mine), "On · 2 servers · 1 run outside Iris")
        XCTAssertEqual(line(state([]), RemoteServerStatus()), "Remote access off")
    }

    func testMark() {
        var mark = ActivityMark()
        XCTAssertFalse(mark.shown(at: at(0)))
        mark.record(at: at(0))
        XCTAssertTrue(mark.shown(at: at(0)))
        XCTAssertTrue(mark.shown(at: at(2.9)))
        // A burst keeps it: each request moves the end.
        for tenth in 1...50 { mark.record(at: at(2 + Double(tenth) / 10)) }
        XCTAssertTrue(mark.shown(at: at(9.9)))
        XCTAssertEqual(mark.until, at(10))
        XCTAssertFalse(mark.shown(at: at(10)))
        // A line that comes late, with an earlier time, never shortens it.
        mark.record(at: at(20))
        mark.record(at: at(19))
        XCTAssertEqual(mark.until, at(23))
    }
}
