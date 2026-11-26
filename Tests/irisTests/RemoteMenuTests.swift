import AppKit
import XCTest
@testable import iris

final class RemoteMenuTests: XCTestCase {
    private let scope = "/Users/someone/Library/Application Support/Iris/http-scope"

    private func state(usable: Bool? = true, calendar: AppAccess? = AppAccess(access: "read and write", items: .all),
                       notes: AppAccess? = AppAccess(access: "read", items: .all),
                       reminders: AppAccess? = AppAccess(access: "none", items: .named([])),
                       listeners: [(Int, ListenerState)]) -> RemoteState {
        RemoteState(scopePath: scope, modified: Date(), usable: usable, problem: nil, calendar: calendar, notes: notes,
                    reminders: reminders, eventsWithOtherPeople: false, writesCounted: nil, tools: nil, tokenPath: "/t",
                    tokenExists: true, tokenProblem: nil,
                    listeners: listeners.enumerated().map { index, listener in
                        (Listener(pid: pid_t(100 + index), port: listener.0, scopeFile: scope, started: Date()), listener.1)
                    })
    }

    private func titles(_ state: RemoteState) -> [String] {
        remoteMenuLines(state).map { ($0.indented ? "  " : "") + $0.title }
    }

    private let usual = ["  Calendar: read and write, all calendars", "  Notes: read, all folders", "  Reminders: off"]

    func testNoServer() {
        XCTAssertEqual(titles(state(listeners: [])), ["Remote access: off"])
        // What a start would allow is not shown, nor a problem the file has.
        XCTAssertEqual(titles(state(usable: false, calendar: nil, notes: nil, reminders: nil, listeners: [])), ["Remote access: off"])
        XCTAssertEqual(titles(state(usable: nil, listeners: [])), ["Remote access: off"])
    }

    func testOneServer() {
        XCTAssertEqual(titles(state(listeners: [(8788, .current)])), ["Remote access: on, port 8788"] + usual)
        XCTAssertEqual(titles(state(listeners: [(8788, .changed)])), ["Remote access: on, port 8788 — restart to apply changes"] + usual)
        // A name that matches nothing: the access stands, the count is not known.
        XCTAssertEqual(titles(state(usable: false, calendar: AppAccess(access: "read", items: .unknown), listeners: [(8788, .current)])),
                       ["Remote access: on, port 8788 — settings have a problem", "  Calendar: read"] + usual.dropFirst())
        // A problem outweighs a change: a restart would not start.
        XCTAssertEqual(titles(state(usable: false, calendar: nil, notes: nil, reminders: nil, listeners: [(8788, .changed)])),
                       ["Remote access: on, port 8788 — settings have a problem"])
        XCTAssertEqual(titles(state(usable: false, calendar: nil, notes: nil, reminders: nil, listeners: [(8788, .unknown)])),
                       ["Remote access: on, port 8788 — settings have a problem"])
        // Not checked, since checking would ask for a permission: no problem known, no counts.
        XCTAssertEqual(titles(state(usable: nil, calendar: AppAccess(access: "read", items: .unknown),
                                    notes: AppAccess(access: "read", items: .unknown), listeners: [(8788, .current)])),
                       ["Remote access: on, port 8788", "  Calendar: read", "  Notes: read", "  Reminders: off"])
        // A server on another file: what this file allows is not what it allows.
        XCTAssertEqual(titles(state(listeners: [(8770, .otherFile)])), ["Remote access: on, port 8770 — started with other settings"])
    }

    func testSeveralServers() {
        XCTAssertEqual(titles(state(listeners: [(8765, .current), (8788, .current)])),
                       ["Remote access: on, 2 servers, ports 8765 and 8788"] + usual)
        XCTAssertEqual(titles(state(listeners: [(8765, .current), (8766, .changed), (8788, .otherFile)])),
                       ["Remote access: on, 3 servers, ports 8765, 8766 and 8788 — restart to apply changes"] + usual
                           + ["  Other settings on port 8788"])
        XCTAssertEqual(titles(state(listeners: [(8765, .otherFile), (8788, .otherFile)])),
                       ["Remote access: on, 2 servers, ports 8765 and 8788 — started with other settings"])
    }

    func testAccessAndCounts() {
        let lines = titles(state(calendar: AppAccess(access: "read", items: .named(["A", "B"])),
                                 notes: AppAccess(access: "read", items: .named(["A"])),
                                 reminders: AppAccess(access: "read and write", items: .named(["A"])),
                                 listeners: [(8788, .current)]))
        XCTAssertEqual(lines, ["Remote access: on, port 8788", "  Calendar: read, 2 calendars", "  Notes: read, 1 folder",
                               "  Reminders: read and write, 1 list"])
        let more = titles(state(calendar: AppAccess(access: "read and write", items: .named(["A"])),
                                notes: AppAccess(access: "read", items: .named(["A", "B", "C"])),
                                reminders: AppAccess(access: "read", items: .all),
                                listeners: [(8788, .current)]))
        XCTAssertEqual(more.dropFirst(), ["  Calendar: read and write, 1 calendar", "  Notes: read, 3 folders", "  Reminders: read, all lists"])
        let none = titles(state(calendar: AppAccess(access: "none", items: .named([])), notes: AppAccess(access: "none", items: .named([])),
                                reminders: AppAccess(access: "read and write", items: .named(["A", "B"])), listeners: [(8788, .current)]))
        XCTAssertEqual(none.dropFirst(), ["  Calendar: off", "  Notes: off", "  Reminders: read and write, 2 lists"])
    }

    /// The section as the menu bar puts it in, between the permission lines and the version.
    @MainActor
    func testMenuSection() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Reminders: full access", action: nil, keyEquivalent: "")
        var section = placeRemoteSection([RemoteMenuLine(title: "Remote access: checking…")], in: menu, replacing: [])
        menu.addItem(.separator())
        menu.addItem(withTitle: "Iris 1.0", action: nil, keyEquivalent: "")

        func shown() -> [String] {
            menu.update()
            return menu.items.map { item in
                if item.isSeparatorItem { return "---" }
                XCTAssertNil(item.action, item.title)
                XCTAssertFalse(item.isEnabled, item.title)
                return String(repeating: "  ", count: item.indentationLevel) + item.title
            }
        }
        XCTAssertEqual(shown(), ["Reminders: full access", "---", "Remote access: checking…", "---", "Iris 1.0"])

        // The answer lands with the menu as it is: the section changes in place.
        let states = [
            state(listeners: [(8788, .current)]),
            state(listeners: [(8788, .changed)]),
            state(usable: false, calendar: nil, notes: nil, reminders: nil, listeners: [(8788, .current)]),
            state(listeners: [(8765, .current), (8788, .current)]),
            state(listeners: [(8770, .otherFile)]),
            state(usable: false, calendar: AppAccess(access: "read", items: .unknown), listeners: [(8788, .current)]),
            state(usable: nil, notes: AppAccess(access: "read", items: .unknown), listeners: [(8788, .current)]),
            state(calendar: AppAccess(access: "read", items: .named(["A", "B"])), notes: AppAccess(access: "read", items: .named(["A"])),
                  reminders: AppAccess(access: "read and write", items: .named(["A"])), listeners: [(8788, .current)]),
            state(calendar: AppAccess(access: "none", items: .named([])), notes: AppAccess(access: "none", items: .named([])),
                  reminders: AppAccess(access: "read", items: .all), listeners: [(8788, .changed)]),
            state(usable: false, calendar: nil, notes: nil, reminders: nil, listeners: []),
            state(listeners: []),
        ]
        for state in states {
            let lines = remoteMenuLines(state)
            section = placeRemoteSection(lines, in: menu, replacing: section)
            XCTAssertEqual(shown(), ["Reminders: full access", "---"] + titles(state) + ["---", "Iris 1.0"])
            XCTAssertEqual(section.count, lines.count + 1)
        }
    }

    /// The work runs off the main thread, one at a time, and its answer lands on the main thread while the run
    /// loop is in the mode an open menu tracks in.
    @MainActor
    func testCheckRunsOnceOffMain() {
        final class Probe: @unchecked Sendable {
            let lock = NSLock()
            var calls = 0
            var onMain: [Bool] = []
            let entered = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)
        }
        // In the app NSApplication makes event tracking a common mode, where the main queue is served; a test has no
        // NSApplication, and making one here would touch the window server.
        CFRunLoopAddCommonMode(CFRunLoopGetMain(), CFRunLoopMode(RunLoop.Mode.eventTracking.rawValue as CFString))
        let probe = Probe()
        var shown: [[RemoteMenuLine]] = []
        let check = RemoteCheck(compute: {
            probe.lock.withLock {
                probe.calls += 1
                probe.onMain.append(Thread.isMainThread)
            }
            probe.entered.signal()
            probe.release.wait()
            return [RemoteMenuLine(title: "Remote access: off")]
        }, show: { lines in
            XCTAssertTrue(Thread.isMainThread)
            shown.append(lines)
        })

        check.start()
        XCTAssertEqual(probe.entered.wait(timeout: .now() + 10), .success)
        check.start()
        check.start()
        probe.release.signal()
        let deadline = Date().addingTimeInterval(10)
        while shown.isEmpty && Date() < deadline {
            RunLoop.main.run(mode: .eventTracking, before: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(shown, [[RemoteMenuLine(title: "Remote access: off")]])
        XCTAssertEqual(probe.lock.withLock { probe.calls }, 1)

        // Once the answer is in, the next start runs again.
        check.start()
        XCTAssertEqual(probe.entered.wait(timeout: .now() + 10), .success)
        probe.release.signal()
        while shown.count < 2 && Date() < deadline.addingTimeInterval(10) {
            RunLoop.main.run(mode: .eventTracking, before: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(shown.count, 2)
        XCTAssertEqual(probe.lock.withLock { probe.onMain }, [false, false])
    }
}
