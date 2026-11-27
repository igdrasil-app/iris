import AppKit
import EventKit
import Sparkle
import XCTest
@testable import iris

final class MenuTests: XCTestCase {
    private let scope = "/Users/someone/Library/Application Support/Iris/http-scope"
    private let fine = Permissions(calendar: .fullAccess, reminders: .fullAccess, notes: "granted")

    private func state(usable: Bool? = true, calendar: AppAccess? = AppAccess(access: "read and write", items: .all),
                       notes: AppAccess? = AppAccess(access: "read", items: .all),
                       reminders: AppAccess? = AppAccess(access: "none", items: .named([])),
                       listeners: [(Int, ListenerState)]) -> RemoteState {
        RemoteState(scopePath: scope, modified: Date(), usable: usable, problem: nil, calendar: calendar, notes: notes,
                    reminders: reminders, eventsWithOtherPeople: false, writesCounted: nil, tools: nil, tokenPath: "/t",
                    tokenExists: true, tokenProblem: nil,
                    listeners: listeners.enumerated().map { index, listener in
                        (Listener(pid: pid_t(100 + index), port: listener.0, scopeFile: scope, started: started(100 + index)), listener.1)
                    })
    }

    /// The listeners `state` makes are pids 100, 101 and on, each started at its own second.
    private func started(_ pid: Int) -> Date { Date(timeIntervalSince1970: Double(1000 + pid)) }
    private func id(_ pid: pid_t) -> ServerIdentity { ServerIdentity(pid: pid, started: Double(1000 + Int(pid))) }

    /// The switch's server, as pid 100, the first listener `state` makes.
    private var mine: RemoteServerStatus { RemoteServerStatus(phase: .on(port: 8788), pid: 100, ours: [id(100)]) }

    /// The model as text: the header's line, then each row as title, the text at the right, ! for a problem.
    private func shown(_ remote: RemoteAnswer, _ permissions: Permissions? = nil, _ server: RemoteServerStatus = RemoteServerStatus()) -> [String] {
        let model = menuModel(remote, permissions ?? fine, server)
        return [model.status] + model.rows.map { "\($0.title): \($0.detail ?? "-")\($0.problem ? " !" : "")" }
    }

    private let usual = ["Calendar: Read & write", "Reminders: Off", "Notes: Read only"]
    private let blank = ["Calendar: -", "Reminders: -", "Notes: -"]

    func testBeforeAnAnswer() {
        XCTAssertEqual(shown(.checking), ["Checking…"] + blank)
        XCTAssertEqual(shown(.unknown), ["Remote access unknown"] + blank)
    }

    func testNoServer() {
        // The rows say what turning remote access on would allow.
        XCTAssertEqual(shown(.known(state(listeners: []))), ["Remote access off"] + usual)
        // A file that cannot be read allows nothing; a problem the file has is not shown while off.
        XCTAssertEqual(shown(.known(state(usable: false, calendar: nil, notes: nil, reminders: nil, listeners: []))),
                       ["Remote access off", "Calendar: Off", "Reminders: Off", "Notes: Off"])
        XCTAssertEqual(shown(.known(state(usable: nil, listeners: []))), ["Remote access off"] + usual)
    }

    func testOneServer() {
        XCTAssertEqual(shown(.known(state(listeners: [(8788, .current)])), nil, mine), ["Remote access · port 8788"] + usual)
        XCTAssertEqual(shown(.known(state(listeners: [(8788, .changed)])), nil, mine),
                       ["Remote access · port 8788 · restart to apply changes"] + usual)
        // A name that matches nothing: the access stands.
        XCTAssertEqual(shown(.known(state(usable: false, calendar: AppAccess(access: "read", items: .unknown), listeners: [(8788, .current)])), nil, mine),
                       ["Remote access · port 8788 · settings have a problem", "Calendar: Read only", "Reminders: Off", "Notes: Read only"])
        // A problem outweighs a change: a restart would not start. A file that cannot be read says nothing of what runs.
        XCTAssertEqual(shown(.known(state(usable: false, calendar: nil, notes: nil, reminders: nil, listeners: [(8788, .changed)])), nil, mine),
                       ["Remote access · port 8788 · settings have a problem"] + blank)
        XCTAssertEqual(shown(.known(state(usable: false, calendar: nil, notes: nil, reminders: nil, listeners: [(8788, .unknown)])), nil, mine),
                       ["Remote access · port 8788 · settings have a problem"] + blank)
        // Not checked, since checking would ask for a permission: no problem known.
        XCTAssertEqual(shown(.known(state(usable: nil, calendar: AppAccess(access: "read", items: .unknown), listeners: [(8788, .current)])), nil, mine),
                       ["Remote access · port 8788", "Calendar: Read only", "Reminders: Off", "Notes: Read only"])
        // The last check has not seen the server yet, or not since it started again: the port is the switch's.
        XCTAssertEqual(shown(.known(state(listeners: [])), nil, mine), ["Remote access · port 8788"] + usual)
        XCTAssertEqual(shown(.checking, nil, mine), ["Remote access · port 8788"] + blank)
        let again = RemoteServerStatus(phase: .on(port: 8788), pid: 101, ours: [id(100), id(101)])
        XCTAssertEqual(shown(.known(state(listeners: [(8788, .changed)])), nil, again), ["Remote access · port 8788"] + usual)
    }

    func testOutside() {
        XCTAssertEqual(shown(.known(state(listeners: [(8788, .current)]))), ["Remote access · port 8788 · run outside Iris"] + usual)
        // What its settings need is still said, as for the switch's own server.
        XCTAssertEqual(shown(.known(state(listeners: [(8788, .changed)]))),
                       ["Remote access · port 8788 · run outside Iris · restart to apply changes"] + usual)
        XCTAssertEqual(shown(.known(state(usable: false, listeners: [(8788, .changed)]))),
                       ["Remote access · port 8788 · run outside Iris · settings have a problem"] + usual)
        XCTAssertEqual(shown(.known(state(usable: false, calendar: nil, notes: nil, reminders: nil, listeners: [(8788, .unknown)]))),
                       ["Remote access · port 8788 · run outside Iris · settings have a problem"] + blank)
        // A server on another file: what this file allows is not what it allows, and its problems are not its.
        XCTAssertEqual(shown(.known(state(listeners: [(8770, .otherFile)]))), ["Remote access · port 8770 · run outside Iris"] + blank)
        XCTAssertEqual(shown(.known(state(usable: false, listeners: [(8770, .otherFile)]))),
                       ["Remote access · port 8770 · run outside Iris"] + blank)
        XCTAssertEqual(shown(.known(state(listeners: [(8765, .otherFile), (8788, .current)]))),
                       ["Remote access · 2 servers · run outside Iris"] + usual)
        XCTAssertEqual(shown(.known(state(listeners: [(8765, .otherFile), (8788, .changed)]))),
                       ["Remote access · 2 servers · run outside Iris · restart to apply changes"] + usual)
        XCTAssertEqual(shown(.known(state(usable: false, listeners: [(8765, .current), (8788, .changed)]))),
                       ["Remote access · 2 servers · run outside Iris · settings have a problem"] + usual)
        // The switch found them before the check did.
        let found = RemoteServerStatus(phase: .outside([8788]))
        XCTAssertEqual(shown(.checking, nil, found), ["Remote access · port 8788 · run outside Iris"] + blank)
        XCTAssertEqual(shown(.known(state(listeners: [])), nil, found), ["Remote access · port 8788 · run outside Iris"] + usual)
    }

    func testSeveralServers() {
        XCTAssertEqual(shown(.known(state(listeners: [(8788, .current), (8765, .current)])), nil, mine),
                       ["Remote access · 2 servers · 1 run outside Iris"] + usual)
        // The warning is for every server on this file, the switch's own included.
        XCTAssertEqual(shown(.known(state(listeners: [(8788, .changed), (8765, .current), (8766, .otherFile)])), nil, mine),
                       ["Remote access · 3 servers · 2 run outside Iris · restart to apply changes"] + usual)
        XCTAssertEqual(shown(.known(state(listeners: [(8788, .changed), (8765, .current)])), nil, mine),
                       ["Remote access · 2 servers · 1 run outside Iris · restart to apply changes"] + usual)
        // A check made before the switch's server was replaced still lists the earlier one (100, changed): it does
        // not count. The current one (102) is not in that check yet.
        let replaced = RemoteServerStatus(phase: .on(port: 8788), pid: 102, ours: [id(100), id(102)])
        XCTAssertEqual(shown(.known(state(listeners: [(8788, .changed), (8765, .current)])), nil, replaced),
                       ["Remote access · 2 servers · 1 run outside Iris"] + usual)
        // The others' settings warning stays beside the switch's own server.
        XCTAssertEqual(shown(.known(state(listeners: [(8788, .current), (8765, .changed)])), nil, mine),
                       ["Remote access · 2 servers · 1 run outside Iris · restart to apply changes"] + usual)
        XCTAssertEqual(shown(.known(state(usable: false, listeners: [(8788, .current), (8765, .current)])), nil, mine),
                       ["Remote access · 2 servers · 1 run outside Iris · settings have a problem"] + usual)
        XCTAssertEqual(shown(.known(state(usable: false, listeners: [(8788, .current), (8765, .otherFile)])), nil, mine),
                       ["Remote access · 2 servers · 1 run outside Iris · settings have a problem"] + usual)
        // No server on this file, the switch's own on another (as only a test sets up): no warning.
        XCTAssertEqual(shown(.known(state(usable: false, listeners: [(8788, .otherFile), (8765, .otherFile)])), nil, mine),
                       ["Remote access · 2 servers · 1 run outside Iris"] + blank)
    }

    /// The header's line, the switch (on or off, then - when it cannot be used) and the reason behind the item
    /// under the header, for each state of the switch's server and the servers running.
    func testSwitch() {
        func header(_ remote: RemoteAnswer, _ server: RemoteServerStatus) -> [String] {
            let model = menuModel(remote, fine, server)
            return [model.status, (model.switchOn ? "on" : "off") + (model.switchEnabled ? "" : " -"), model.failure ?? "-"]
        }
        let none = RemoteAnswer.known(state(listeners: []))
        let foreign = RemoteAnswer.known(state(listeners: [(8788, .current)]))
        let reason = "/x/http-scope: not a JSON object"
        XCTAssertEqual(header(.checking, RemoteServerStatus()), ["Checking…", "off", "-"])
        XCTAssertEqual(header(.unknown, RemoteServerStatus()), ["Remote access unknown", "off", "-"])
        XCTAssertEqual(header(none, RemoteServerStatus()), ["Remote access off", "off", "-"])
        for remote in [RemoteAnswer.checking, none] {
            XCTAssertEqual(header(remote, RemoteServerStatus(phase: .starting, pid: 100, ours: [id(100)])), ["Remote access · starting…", "on", "-"])
            XCTAssertEqual(header(remote, RemoteServerStatus(phase: .failed(reason))), ["Remote access · couldn't start", "on", reason])
            XCTAssertEqual(header(remote, RemoteServerStatus(phase: .on(port: 8765), pid: 100, ours: [id(100)])), ["Remote access · port 8765", "on", "-"])
        }
        // Not started by this Iris: on, and it cannot be turned off here, whether the choice is off or on.
        XCTAssertEqual(header(foreign, RemoteServerStatus()), ["Remote access · port 8788 · run outside Iris", "on -", "-"])
        XCTAssertEqual(header(foreign, RemoteServerStatus(phase: .outside([8788]))), ["Remote access · port 8788 · run outside Iris", "on -", "-"])
        // While left from an earlier run and being stopped, it is not someone else's.
        XCTAssertEqual(header(foreign, RemoteServerStatus(phase: .starting, ours: [id(100)])), ["Remote access · starting…", "on", "-"])
        XCTAssertEqual(header(foreign, RemoteServerStatus(phase: .off, ours: [id(100)])), ["Remote access off", "off", "-"])
        // With none of its own running (could not start, waiting to start again), another server is what shows.
        XCTAssertEqual(header(foreign, RemoteServerStatus(phase: .failed(reason))), ["Remote access · port 8788 · run outside Iris", "on -", "-"])
        XCTAssertEqual(header(foreign, RemoteServerStatus(phase: .starting, ours: [id(105)])),
                       ["Remote access · port 8788 · run outside Iris", "on -", "-"])
        XCTAssertEqual(header(foreign, RemoteServerStatus(phase: .on(port: 8765), pid: 105, ours: [id(105)])),
                       ["Remote access · 2 servers · 1 run outside Iris", "on", "-"])
        // A pid the switch once had, now another process's: that server is someone else's.
        XCTAssertEqual(header(foreign, RemoteServerStatus(phase: .off, ours: [ServerIdentity(pid: 100, started: 5)])),
                       ["Remote access · port 8788 · run outside Iris", "on -", "-"])
        // Beside the switch's own server, the switch turns that one off.
        XCTAssertEqual(header(.known(state(listeners: [(8765, .current), (8788, .current)])),
                              RemoteServerStatus(phase: .on(port: 8765), pid: 100, ours: [id(100)])),
                       ["Remote access · 2 servers · 1 run outside Iris", "on", "-"])
    }

    func testAccessWords() {
        let rows = shown(.known(state(calendar: AppAccess(access: "read", items: .named(["A", "B"])),
                                      notes: AppAccess(access: "none", items: .named([])),
                                      reminders: AppAccess(access: "read and write", items: .named(["A"])),
                                      listeners: [(8788, .current)])))
        XCTAssertEqual(rows.dropFirst(), ["Calendar: Read only", "Reminders: Read & write", "Notes: Off"])
    }

    func testPermissions() {
        let on = RemoteAnswer.known(state(listeners: [(8788, .current)]))
        let off = RemoteAnswer.known(state(listeners: []))
        func rows(_ permissions: Permissions, _ remote: RemoteAnswer) -> [AppRow] { menuModel(remote, permissions).rows }
        func needs(_ title: String, _ action: RowAction) -> AppRow {
            AppRow(title: title, detail: "Needs access", problem: true, action: action)
        }

        let others: [RemoteAnswer] = [.known(state(listeners: [(8788, .changed)])),
                                      .known(state(usable: false, calendar: nil, notes: nil, reminders: nil, listeners: [(8788, .current)])),
                                      .known(state(listeners: [(8765, .current), (8788, .current)])),
                                      .known(state(listeners: [(8770, .otherFile)]))]
        for remote in [on, off, .checking, .unknown] + others {
            XCTAssertEqual(rows(fine, remote).map(\.problem), [false, false, false])
            XCTAssertEqual(rows(fine, remote).map(\.action), [nil, nil, nil])
            // Not determined asks, at a click, as the menu always has; the rest open their pane.
            for (status, action) in [(EKAuthorizationStatus.notDetermined, RowAction.askCalendar), (.denied, .open(.calendars)),
                                     (.writeOnly, .open(.calendars)), (.restricted, .open(.calendars))] {
                let permissions = Permissions(calendar: status, reminders: .fullAccess, notes: "granted")
                XCTAssertEqual(rows(permissions, remote), [needs("Calendar", action)] + rows(fine, remote).dropFirst())
            }
            for status in [EKAuthorizationStatus.denied, .writeOnly, .restricted] {
                let permissions = Permissions(calendar: .fullAccess, reminders: status, notes: "granted")
                XCTAssertEqual(rows(permissions, remote)[1], needs("Reminders", .open(.reminders)))
            }
            let notesDenied = Permissions(calendar: .fullAccess, reminders: .fullAccess, notes: "denied")
            XCTAssertEqual(rows(notesDenied, remote)[2], needs("Notes", .open(.automation)))
            // Not determined is no problem for Reminders or Notes, and their rows do nothing: Settings offers to ask Notes.
            let undecided = Permissions(calendar: .fullAccess, reminders: .notDetermined, notes: "not determined")
            XCTAssertEqual(rows(undecided, remote), rows(fine, remote))
            XCTAssertTrue(menuModel(remote, undecided).offersNotesAccess)
            XCTAssertFalse(menuModel(remote, fine).offersNotesAccess)
            XCTAssertFalse(menuModel(remote, notesDenied).offersNotesAccess)
        }

        let undecided = Permissions(calendar: .fullAccess, reminders: .notDetermined, notes: "not determined")
        XCTAssertEqual(rows(undecided, on), [AppRow(title: "Calendar", detail: "Read & write", problem: false, action: nil),
                                             AppRow(title: "Reminders", detail: "Off", problem: false, action: nil),
                                             AppRow(title: "Notes", detail: "Read only", problem: false, action: nil)])
        for notes in ["unknown (Notes not running)", "unknown (-1)"] {
            XCTAssertEqual(rows(Permissions(calendar: .fullAccess, reminders: .fullAccess, notes: notes), on), rows(fine, on))
        }
        // Each app's problem shows on its own row only.
        let none = Permissions(calendar: .denied, reminders: .denied, notes: "denied")
        XCTAssertEqual(shown(on, none, mine), ["Remote access · port 8788", "Calendar: Needs access !", "Reminders: Needs access !",
                                               "Notes: Needs access !"])
    }

    func testPanes() {
        XCTAssertEqual(SettingsPane.calendars.url.absoluteString, "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")
        XCTAssertEqual(SettingsPane.reminders.url.absoluteString, "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders")
        XCTAssertEqual(SettingsPane.automation.url.absoluteString, "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
    }

    @MainActor
    private final class Actions: NSObject, MenuActions {
        var switched: [NSControl.StateValue] = []
        var failuresShown = 0
        var shared: [ShareAction] = []
        func chooseRow(_ sender: NSMenuItem) {}
        func chooseShare(_ sender: NSMenuItem) { shared.append(sender.representedObject as! ShareAction) }
        func toggleRemoteAccess(_ sender: NSSwitch) { switched.append(sender.state) }
        func showRemoteFailure() { failuresShown += 1 }
        func toggleOpenAtLogin() {}
    }

    private func labels(_ view: NSView) -> [String] {
        view.subviews.flatMap { ($0 as? NSTextField).map { [$0.stringValue] } ?? labels($0) }
    }

    /// The menu as the menu bar fills it, and its rows and header changed in place as answers come in.
    @MainActor
    func testItems() {
        let actions = Actions()
        let menu = NSMenu()
        menu.addItem(withTitle: "left from the last opening", action: nil, keyEquivalent: "")
        let items = MenuItems(target: actions)
        fill(menu, with: items, version: "1.0", openAtLogin: .on, target: actions, updater: nil)

        func described(_ menu: NSMenu) -> [String] {
            menu.update()
            return menu.items.filter { !$0.isHidden }.map { item in
                if item.isSeparatorItem { return "---" }
                var text = item.view.map { labels($0).joined(separator: " / ") } ?? item.title
                if let badge = item.badge { text += " [\(badge.stringValue ?? "")]" }
                if item.submenu != nil { text += " >" }
                if !item.keyEquivalent.isEmpty { text += " ⌘\(item.keyEquivalent.uppercased())" }
                if item.state == .on { text = "✓ " + text }
                return item.isEnabled ? text : "(\(text))"
            }
        }

        let off = RemoteServerStatus()
        let failed = RemoteServerStatus(phase: .failed("/x/http-scope: not a JSON object"))
        let states: [(RemoteAnswer, Permissions, RemoteServerStatus, [String])] = [
            (.checking, fine, off, ["(Iris / Checking…)", "Calendar >", "Reminders >", "Notes >"]),
            (.known(state(listeners: [(8788, .current)])), fine, mine,
             ["(Iris / Remote access · port 8788)", "Calendar [Read & write] >", "Reminders [Off] >", "Notes [Read only] >"]),
            (.known(state(listeners: [])), fine, off,
             ["(Iris / Remote access off)", "Calendar [Read & write] >", "Reminders [Off] >", "Notes [Read only] >"]),
            (.known(state(listeners: [(8788, .current)])), Permissions(calendar: .denied, reminders: .fullAccess, notes: "granted"), mine,
             ["(Iris / Remote access · port 8788)", "Calendar [Needs access]", "Reminders [Off] >", "Notes [Read only] >"]),
            (.unknown, fine, off, ["(Iris / Remote access unknown)", "Calendar >", "Reminders >", "Notes >"]),
            (.known(state(listeners: [])), fine, failed,
             ["(Iris / Remote access · couldn't start)", "Why It Couldn't Start…", "Calendar [Read & write] >", "Reminders [Off] >",
              "Notes [Read only] >"]),
            (.known(state(listeners: [(8788, .current)])), fine, off,
             ["(Iris / Remote access · port 8788 · run outside Iris)", "Calendar [Read & write] >", "Reminders [Off] >", "Notes [Read only] >"]),
        ]
        let header = menu.items[0]
        let rows = Array(menu.items[3...5])
        let toggle = items.headerView.toggle
        for (remote, permissions, server, top) in states {
            let model = menuModel(remote, permissions, server)
            items.show(model)
            let under = top.count == 5 ? 2 : 1
            XCTAssertEqual(described(menu), Array(top.prefix(under)) + ["---"] + top.dropFirst(under)
                           + ["---", "Settings >", "---", "Quit Iris ⌘Q"])
            XCTAssertEqual(toggle.state, model.switchOn ? .on : .off)
            XCTAssertEqual(toggle.isEnabled, model.switchEnabled)
            // The same items, changed in place.
            XCTAssertTrue(menu.items[0] === header)
            XCTAssertTrue(menu.items[1] === items.failure)
            XCTAssertTrue(zip(menu.items[3...5], rows).allSatisfy { $0 === $1 })
            for (item, row) in zip(rows, model.rows) {
                XCTAssertTrue(item.target === actions)
                XCTAssertEqual(item.action, #selector(MenuActions.chooseRow))
                XCTAssertEqual(item.representedObject as? RowAction, row.action)
            }
        }
        XCTAssertFalse(header.view?.frame.isEmpty ?? true)

        // The switch: named for VoiceOver, and its action and the failure item's reach the target.
        XCTAssertEqual(toggle.accessibilityLabel(), "Remote access")
        XCTAssertTrue(toggle.isDescendant(of: items.headerView))
        XCTAssertTrue(toggle.target === actions)
        XCTAssertEqual(toggle.action, #selector(MenuActions.toggleRemoteAccess))
        items.show(menuModel(.known(state(listeners: [])), fine, off))
        toggle.state = .on
        _ = (toggle.target as? NSObject)?.perform(toggle.action, with: toggle)
        XCTAssertEqual(actions.switched, [.on])
        // A click the model does not follow is put back at the next showing, though the model did not change.
        items.show(menuModel(.known(state(listeners: [])), fine, off))
        XCTAssertEqual(toggle.state, .off)
        XCTAssertTrue(items.failure.target === actions)
        XCTAssertEqual(items.failure.action, #selector(MenuActions.showRemoteFailure))
        _ = (items.failure.target as? NSObject)?.perform(items.failure.action)
        XCTAssertEqual(actions.failuresShown, 1)

        // The submenu enables its items as AppKit validates them, which a test without NSApplication cannot; the
        // version has no action, so it shows as information.
        let settings = menu.items[7].submenu!
        XCTAssertTrue(settings.autoenablesItems)
        XCTAssertEqual(settings.items.map(\.title), ["Iris 1.0", "Check for Updates…", "Open at Login", "Allow Notes Access…"])
        // Offered only while Notes was never asked.
        XCTAssertTrue(settings.items[3].isHidden)
        items.show(menuModel(.checking, Permissions(calendar: .fullAccess, reminders: .fullAccess, notes: "not determined")))
        XCTAssertFalse(settings.items[3].isHidden)
        XCTAssertEqual(settings.items[3].representedObject as? RowAction, .askNotes)
        XCTAssertNil(settings.items[0].action)
        XCTAssertEqual(settings.items[2].state, .on)
        XCTAssertTrue(settings.items[2].target === actions)
        XCTAssertEqual(settings.items[2].action, #selector(MenuActions.toggleOpenAtLogin))
        XCTAssertEqual(settings.items[1].action, #selector(SPUStandardUpdaterController.checkForUpdates))
    }

    /// A menu already measured grows for a longer header line. Not a test of a menu that is open.
    @MainActor
    func testHeaderWidthBeforeOpening() {
        let actions = Actions()
        let long = menuModel(.known(state(listeners: [(8788, .current), (8765, .current), (8766, .current)])), fine, mine)
        for first in [long, menuModel(.known(state(listeners: [])), fine)] {
            let menu = NSMenu()
            let items = MenuItems(target: actions)
            fill(menu, with: items, version: "1.0", openAtLogin: .off, target: actions, updater: nil)
            items.show(first)
            _ = menu.size
            items.show(long)
            XCTAssertGreaterThanOrEqual(menu.size.width, items.headerView.fittingSize.width, first.status)
            // The line ends before the switch begins.
            items.headerView.frame.size.width = menu.size.width
            items.headerView.layoutSubtreeIfNeeded()
            let line = items.headerView.subviews.compactMap { $0 as? NSStackView }.first!.views.last!
            XCTAssertLessThanOrEqual(line.convert(line.bounds, to: items.headerView).maxX, items.headerView.toggle.frame.minX, first.status)
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
        var shown: [String] = []
        let check = BackgroundCheck(compute: { () -> RemoteAnswer in
            probe.lock.withLock {
                probe.calls += 1
                probe.onMain.append(Thread.isMainThread)
            }
            probe.entered.signal()
            probe.release.wait()
            return .unknown
        }, show: { answer in
            XCTAssertTrue(Thread.isMainThread)
            shown.append(menuModel(answer, self.fine).status)
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
        XCTAssertEqual(shown, ["Remote access unknown"])

        // The two starts made while it ran make one more run, once it has answered.
        XCTAssertEqual(probe.entered.wait(timeout: .now() + 10), .success)
        probe.release.signal()
        while shown.count < 2 && Date() < deadline.addingTimeInterval(10) {
            RunLoop.main.run(mode: .eventTracking, before: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(shown.count, 2)
        RunLoop.main.run(mode: .eventTracking, before: Date().addingTimeInterval(0.3))
        XCTAssertEqual(probe.lock.withLock { probe.calls }, 2)

        // Once the answer is in, the next start runs again.
        check.start()
        XCTAssertEqual(probe.entered.wait(timeout: .now() + 10), .success)
        probe.release.signal()
        while shown.count < 3 && Date() < deadline.addingTimeInterval(20) {
            RunLoop.main.run(mode: .eventTracking, before: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(shown.count, 3)
        XCTAssertEqual(probe.lock.withLock { probe.onMain }, [false, false, false])
    }

    private let calendars = [ShareItem(id: "c1", name: "Work", group: "iCloud"), ShareItem(id: "c2", name: "Family", group: "iCloud"),
                             ShareItem(id: "c3", name: "Birthdays", group: "Other")]

    /// The listings' JSON as submenus order it: accounts by name, a folder right after the one it sits in.
    func testShareItems() throws {
        let calendars = #"[{"id": "c1", "title": "Work", "source": "iCloud", "writable": true},"#
            + #" {"id": "c3", "title": "Birthdays", "source": "Other", "writable": false},"#
            + #" {"id": "c2", "title": "Family", "source": "iCloud", "writable": true}]"#
        XCTAssertEqual(shareItems(.calendars, Data(calendars.utf8)), self.calendars)
        let lists = #"[{"id": "l1", "title": "Errands", "source": "iCloud", "writable": true, "open": 2}]"#
        XCTAssertEqual(shareItems(.lists, Data(lists.utf8)), [ShareItem(id: "l1", name: "Errands", group: "iCloud")])
        let folders = #"[{"id": "f3", "name": "Paris", "account": "iCloud", "parent": "f2", "noteCount": 1},"#
            + #" {"id": "f1", "name": "Recipes", "account": "iCloud", "parent": null, "noteCount": 1},"#
            + #" {"id": "f2", "name": "Travel", "account": "iCloud", "parent": null, "noteCount": 1},"#
            + #" {"id": "f4", "name": "Notes", "account": "On My Mac", "parent": null, "noteCount": 1},"#
            + #" {"id": "f5", "name": "Lyon", "account": "iCloud", "parent": "f3", "noteCount": 1}]"#
        XCTAssertEqual(try XCTUnwrap(shareItems(.folders, Data(folders.utf8))).map { "\($0.group) \(String(repeating: "  ", count: $0.level))\($0.name)" },
                       ["iCloud Recipes", "iCloud Travel", "iCloud   Paris", "iCloud     Lyon", "On My Mac Notes"])
        XCTAssertNil(shareItems(.calendars, Data("not json".utf8)))
    }

    /// Where a submenu's items come from: never a lookup that would ask, or open Notes.
    func testShareSource() {
        let listed = [ShareItem(id: "l1", name: "Errands", group: "iCloud")]
        XCTAssertEqual(shareSource(.lists, fine, listed), .listed(listed))
        XCTAssertEqual(shareSource(.lists, fine, nil), .loading)
        XCTAssertEqual(shareSource(.lists, Permissions(calendar: .fullAccess, reminders: .notDetermined, notes: "granted"), listed),
                       .ask(.askReminders))
        XCTAssertEqual(shareSource(.folders, Permissions(calendar: .fullAccess, reminders: .fullAccess, notes: "not determined"), nil),
                       .ask(.askNotes))
        XCTAssertEqual(shareSource(.folders, Permissions(calendar: .fullAccess, reminders: .fullAccess, notes: "unknown (Notes not running)"), listed),
                       .openNotes)
        XCTAssertEqual(shareSource(.calendars, Permissions(calendar: .fullAccess, reminders: .notDetermined, notes: "not determined"), nil), .loading)
    }

    /// A submenu as text: ✓ for a tick, () for disabled, -- for a section header, an indent per level.
    private func lines(_ entries: [ShareEntry]) -> [String] {
        entries.map { entry in
            switch entry {
            case .separator: "---"
            case .section(let title): "-- \(title)"
            case .loading: "(Loading…)"
            case .choice(let title, let on, let enabled, let level, _):
                (enabled ? "" : "(") + (on ? "✓ " : "  ") + String(repeating: "  ", count: level) + title + (enabled ? "" : ")")
            }
        }
    }

    func testShareEntries() {
        let listed = ShareSource.listed(calendars)
        let some = ScopeFileState.file(ScopeFile(calendars: ["Work", "c3"], folders: [], writes: true))
        XCTAssertEqual(lines(shareEntries(.calendars, some, listed)),
                       ["  All Calendars", "  No Calendars", "---", "-- iCloud", "✓ Work", "  Family", "-- Other", "✓ Birthdays", "---",
                        "✓ Allow Changes", "  Include Events With Other People"])
        // Each choice is the tick that turns it the other way.
        let actions = shareEntries(.calendars, some, listed).compactMap { entry -> ShareAction? in
            if case .choice(_, _, _, _, let action) = entry { action } else { nil }
        }
        XCTAssertEqual(actions, [.tick(.all(.calendars, true)), .tick(.all(.calendars, false)), .tick(.item(.calendars, "c1", false)), .tick(.item(.calendars, "c2", true)),
                                 .tick(.item(.calendars, "c3", false)), .tick(.writes(false)), .tick(.sharedEvents(true))])
        // "all": every item ticked; one account: no section headers.
        let one = ShareSource.listed(Array(calendars.prefix(2)))
        XCTAssertEqual(lines(shareEntries(.calendars, .file(ScopeFile(calendars: nil, folders: nil)), one)),
                       ["✓ All Calendars", "  No Calendars", "---", "✓ Work", "✓ Family", "---", "  Allow Changes", "(  Include Events With Other People)"])
        // Nothing shared, or no file yet: changes cannot be turned on.
        for state in [ScopeFileState.missing, .file(ScopeFile(calendars: [], folders: []))] {
            XCTAssertEqual(lines(shareEntries(.calendars, state, one)),
                           ["  All Calendars", "✓ No Calendars", "---", "  Work", "  Family", "---", "(  Allow Changes)", "(  Include Events With Other People)"])
        }
        // An entry that names nothing now, ticked at the end, to be unticked.
        let missing = shareEntries(.calendars, .file(ScopeFile(calendars: ["Old", "c1"], folders: [])), one)
        XCTAssertEqual(lines(missing), ["  All Calendars", "  No Calendars", "---", "✓ Work", "  Family", "---", "✓ Missing: Old", "---",
                                        "  Allow Changes", "(  Include Events With Other People)"])
        XCTAssertTrue(missing.contains(.choice("Missing: Old", on: true, .tick(.remove(.calendars, "Old")))))
        // Not listed yet, or not to be listed without asking.
        XCTAssertEqual(lines(shareEntries(.calendars, some, .loading)),
                       ["  All Calendars", "  No Calendars", "---", "(Loading…)", "---", "✓ Allow Changes", "  Include Events With Other People"])
        let lists = ScopeFileState.file(ScopeFile(calendars: [], folders: [], lists: nil, reminderWrites: true))
        XCTAssertEqual(lines(shareEntries(.lists, lists, .ask(.askReminders))),
                       ["✓ All Lists", "  No Lists", "---", "  Allow Reminders Access…", "---", "✓ Allow Changes"])
        XCTAssertEqual(lines(shareEntries(.lists, .file(ScopeFile(calendars: [], folders: [])), .listed([]))),
                       ["  All Lists", "✓ No Lists", "---", "(  Allow Changes)"])
        // Notes: folders by level, and no changes.
        let folders = [ShareItem(id: "f1", name: "Recipes", group: "iCloud"), ShareItem(id: "f2", name: "Travel", group: "iCloud"),
                       ShareItem(id: "f3", name: "Paris", group: "iCloud", level: 1)]
        XCTAssertEqual(lines(shareEntries(.folders, .file(ScopeFile(calendars: [], folders: ["f3"])), .listed(folders))),
                       ["  All Folders", "  No Folders", "---", "  Recipes", "  Travel", "✓   Paris"])
        XCTAssertEqual(lines(shareEntries(.folders, .file(ScopeFile(calendars: [], folders: nil)), .openNotes)),
                       ["✓ All Folders", "  No Folders", "---", "  Open Notes to Choose Folders"])
        XCTAssertEqual(lines(shareEntries(.folders, .missing, .ask(.askNotes))), ["  All Folders", "✓ No Folders", "---", "  Allow Notes Access…"])
        // A file that cannot be read offers only its problem.
        for kind in [ScopeKind.calendars, .lists, .folders] {
            XCTAssertEqual(shareEntries(kind, .broken("not a JSON object"), listed),
                           [.choice("Settings File Has a Problem…", on: false, .fixFile)])
        }
    }

    /// The rows' submenus as AppKit items, changed in place while their shape holds, and none on a row that needs access.
    @MainActor
    func testShareMenus() {
        let actions = Actions()
        let menu = NSMenu()
        let items = MenuItems(target: actions)
        fill(menu, with: items, version: "1.0", openAtLogin: .off, target: actions, updater: nil)
        items.show(menuModel(.checking, fine))
        func shares(_ calendars: [ShareEntry]) -> [[ShareEntry]] {
            [calendars, shareEntries(.lists, .missing, .loading), shareEntries(.folders, .missing, .openNotes)]
        }
        func described(_ menu: NSMenu) -> [String] {
            menu.items.map { item in
                if item.isSeparatorItem { return "---" }
                if item.isSectionHeader { return "-- \(item.title)" }
                let text = (item.state == .on ? "✓ " : "  ") + String(repeating: "  ", count: item.indentationLevel) + item.title
                return item.isEnabled ? text : "(\(text))"
            }
        }
        let file = ScopeFileState.file(ScopeFile(calendars: ["c1"], folders: [], writes: true))
        items.show(shares: shares(shareEntries(.calendars, file, .loading)))
        XCTAssertTrue(items.rows[0].submenu === items.shares[0])
        XCTAssertFalse(items.shares[0].autoenablesItems)
        XCTAssertTrue(items.shares[0].showsStateColumn)
        XCTAssertEqual(described(items.shares[0]), ["  All Calendars", "  No Calendars", "---", "(  Loading…)", "---", "✓ Allow Changes", "  Include Events With Other People"])
        XCTAssertEqual(described(items.shares[1]), ["  All Lists", "✓ No Lists", "---", "(  Loading…)", "---", "(  Allow Changes)"])
        XCTAssertEqual(described(items.shares[2]), ["  All Folders", "✓ No Folders", "---", "  Open Notes to Choose Folders"])

        // The listing comes in: a new shape, filled again.
        items.show(shares: shares(shareEntries(.calendars, file, .listed(calendars))))
        XCTAssertEqual(described(items.shares[0]), ["  All Calendars", "  No Calendars", "---", "-- iCloud", "✓ Work", "  Family", "-- Other", "  Birthdays",
                                                    "---", "✓ Allow Changes", "  Include Events With Other People"])
        // A tick keeps the shape: the same items, changed in place.
        let before = items.shares[0].items
        items.show(shares: shares(shareEntries(.calendars, .file(ScopeFile(calendars: ["c1", "c2"], folders: [])), .listed(calendars))))
        XCTAssertTrue(zip(before, items.shares[0].items).allSatisfy { $0 === $1 })
        XCTAssertEqual(described(items.shares[0]), ["  All Calendars", "  No Calendars", "---", "-- iCloud", "✓ Work", "✓ Family", "-- Other", "  Birthdays",
                                                    "---", "  Allow Changes", "(  Include Events With Other People)"])
        // A click reaches the target with its tick.
        let family = items.shares[0].items[5]
        XCTAssertTrue(family.target === actions)
        _ = (family.target as? NSObject)?.perform(family.action, with: family)
        XCTAssertEqual(actions.shared, [.tick(.item(.calendars, "c2", false))])

        // A row that needs access has no submenu; given access, it has it again.
        items.show(menuModel(.checking, Permissions(calendar: .denied, reminders: .fullAccess, notes: "granted")))
        XCTAssertNil(items.rows[0].submenu)
        XCTAssertTrue(items.rows[1].submenu === items.shares[1])
        items.show(menuModel(.checking, fine))
        XCTAssertTrue(items.rows[0].submenu === items.shares[0])
    }
}
