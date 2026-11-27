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

    private let usual = ["Calendar: Read & Write", "Reminders: Off", "Notes: Read Only"]
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
        XCTAssertEqual(shown(.known(state(listeners: [(8788, .current)])), nil, mine), ["Remote access on"] + usual)
        XCTAssertEqual(shown(.known(state(listeners: [(8788, .changed)])), nil, mine),
                       ["Remote access on · restart to apply changes"] + usual)
        // A name that matches nothing: the access stands.
        XCTAssertEqual(shown(.known(state(usable: false, calendar: AppAccess(access: "read", items: .unknown), listeners: [(8788, .current)])), nil, mine),
                       ["Remote access on · settings have a problem", "Calendar: Read Only", "Reminders: Off", "Notes: Read Only"])
        // A problem outweighs a change: a restart would not start. A file that cannot be read says nothing of what runs.
        XCTAssertEqual(shown(.known(state(usable: false, calendar: nil, notes: nil, reminders: nil, listeners: [(8788, .changed)])), nil, mine),
                       ["Remote access on · settings have a problem"] + blank)
        XCTAssertEqual(shown(.known(state(usable: false, calendar: nil, notes: nil, reminders: nil, listeners: [(8788, .unknown)])), nil, mine),
                       ["Remote access on · settings have a problem"] + blank)
        // Not checked, since checking would ask for a permission: no problem known.
        XCTAssertEqual(shown(.known(state(usable: nil, calendar: AppAccess(access: "read", items: .unknown), listeners: [(8788, .current)])), nil, mine),
                       ["Remote access on", "Calendar: Read Only", "Reminders: Off", "Notes: Read Only"])
        // The last check has not seen the server yet, or not since it started again: the switch's server is on.
        XCTAssertEqual(shown(.known(state(listeners: [])), nil, mine), ["Remote access on"] + usual)
        XCTAssertEqual(shown(.checking, nil, mine), ["Remote access on"] + blank)
        let again = RemoteServerStatus(phase: .on(port: 8788), pid: 101, ours: [id(100), id(101)])
        XCTAssertEqual(shown(.known(state(listeners: [(8788, .changed)])), nil, again), ["Remote access on"] + usual)
    }

    func testOutside() {
        XCTAssertEqual(shown(.known(state(listeners: [(8788, .current)]))), ["On · run outside Iris"] + usual)
        // What its settings need is still said, as for the switch's own server.
        XCTAssertEqual(shown(.known(state(listeners: [(8788, .changed)]))),
                       ["On · run outside Iris · restart to apply changes"] + usual)
        XCTAssertEqual(shown(.known(state(usable: false, listeners: [(8788, .changed)]))),
                       ["On · run outside Iris · settings have a problem"] + usual)
        XCTAssertEqual(shown(.known(state(usable: false, calendar: nil, notes: nil, reminders: nil, listeners: [(8788, .unknown)]))),
                       ["On · run outside Iris · settings have a problem"] + blank)
        // A server on another file: what this file allows is not what it allows, and its problems are not its.
        XCTAssertEqual(shown(.known(state(listeners: [(8770, .otherFile)]))), ["On · run outside Iris"] + blank)
        XCTAssertEqual(shown(.known(state(usable: false, listeners: [(8770, .otherFile)]))),
                       ["On · run outside Iris"] + blank)
        XCTAssertEqual(shown(.known(state(listeners: [(8765, .otherFile), (8788, .current)]))),
                       ["On · 2 servers run outside Iris"] + usual)
        XCTAssertEqual(shown(.known(state(listeners: [(8765, .otherFile), (8788, .changed)]))),
                       ["On · 2 servers run outside Iris · restart to apply changes"] + usual)
        XCTAssertEqual(shown(.known(state(usable: false, listeners: [(8765, .current), (8788, .changed)]))),
                       ["On · 2 servers run outside Iris · settings have a problem"] + usual)
        // The switch found them before the check did.
        let found = RemoteServerStatus(phase: .outside([8788]))
        XCTAssertEqual(shown(.checking, nil, found), ["On · run outside Iris"] + blank)
        XCTAssertEqual(shown(.known(state(listeners: [])), nil, found), ["On · run outside Iris"] + usual)
    }

    func testSeveralServers() {
        XCTAssertEqual(shown(.known(state(listeners: [(8788, .current), (8765, .current)])), nil, mine),
                       ["On · 2 servers · 1 run outside Iris"] + usual)
        // The warning is for every server on this file, the switch's own included.
        XCTAssertEqual(shown(.known(state(listeners: [(8788, .changed), (8765, .current), (8766, .otherFile)])), nil, mine),
                       ["On · 3 servers · 2 run outside Iris · restart to apply changes"] + usual)
        XCTAssertEqual(shown(.known(state(listeners: [(8788, .changed), (8765, .current)])), nil, mine),
                       ["On · 2 servers · 1 run outside Iris · restart to apply changes"] + usual)
        // A check made before the switch's server was replaced still lists the earlier one (100, changed): it does
        // not count. The current one (102) is not in that check yet.
        let replaced = RemoteServerStatus(phase: .on(port: 8788), pid: 102, ours: [id(100), id(102)])
        XCTAssertEqual(shown(.known(state(listeners: [(8788, .changed), (8765, .current)])), nil, replaced),
                       ["On · 2 servers · 1 run outside Iris"] + usual)
        // The others' settings warning stays beside the switch's own server.
        XCTAssertEqual(shown(.known(state(listeners: [(8788, .current), (8765, .changed)])), nil, mine),
                       ["On · 2 servers · 1 run outside Iris · restart to apply changes"] + usual)
        XCTAssertEqual(shown(.known(state(usable: false, listeners: [(8788, .current), (8765, .current)])), nil, mine),
                       ["On · 2 servers · 1 run outside Iris · settings have a problem"] + usual)
        XCTAssertEqual(shown(.known(state(usable: false, listeners: [(8788, .current), (8765, .otherFile)])), nil, mine),
                       ["On · 2 servers · 1 run outside Iris · settings have a problem"] + usual)
        // No server on this file, the switch's own on another (as only a test sets up): no warning.
        XCTAssertEqual(shown(.known(state(usable: false, listeners: [(8788, .otherFile), (8765, .otherFile)])), nil, mine),
                       ["On · 2 servers · 1 run outside Iris"] + blank)
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
            XCTAssertEqual(header(remote, RemoteServerStatus(phase: .starting, pid: 100, ours: [id(100)])), ["Starting…", "on", "-"])
            XCTAssertEqual(header(remote, RemoteServerStatus(phase: .failed(reason))), ["Couldn't start", "on", reason])
            XCTAssertEqual(header(remote, RemoteServerStatus(phase: .on(port: 8765), pid: 100, ours: [id(100)])), ["Remote access on", "on", "-"])
        }
        // Not started by this Iris: on, and it cannot be turned off here, whether the choice is off or on.
        XCTAssertEqual(header(foreign, RemoteServerStatus()), ["On · run outside Iris", "on -", "-"])
        XCTAssertEqual(header(foreign, RemoteServerStatus(phase: .outside([8788]))), ["On · run outside Iris", "on -", "-"])
        // While left from an earlier run and being stopped, it is not someone else's.
        XCTAssertEqual(header(foreign, RemoteServerStatus(phase: .starting, ours: [id(100)])), ["Starting…", "on", "-"])
        XCTAssertEqual(header(foreign, RemoteServerStatus(phase: .off, ours: [id(100)])), ["Remote access off", "off", "-"])
        // With none of its own running (could not start, waiting to start again), another server is what shows.
        XCTAssertEqual(header(foreign, RemoteServerStatus(phase: .failed(reason))), ["On · run outside Iris", "on -", "-"])
        XCTAssertEqual(header(foreign, RemoteServerStatus(phase: .starting, ours: [id(105)])),
                       ["On · run outside Iris", "on -", "-"])
        XCTAssertEqual(header(foreign, RemoteServerStatus(phase: .on(port: 8765), pid: 105, ours: [id(105)])),
                       ["On · 2 servers · 1 run outside Iris", "on", "-"])
        // A pid the switch once had, now another process's: that server is someone else's.
        XCTAssertEqual(header(foreign, RemoteServerStatus(phase: .off, ours: [ServerIdentity(pid: 100, started: 5)])),
                       ["On · run outside Iris", "on -", "-"])
        // Beside the switch's own server, the switch turns that one off.
        XCTAssertEqual(header(.known(state(listeners: [(8765, .current), (8788, .current)])),
                              RemoteServerStatus(phase: .on(port: 8765), pid: 100, ours: [id(100)])),
                       ["On · 2 servers · 1 run outside Iris", "on", "-"])
    }

    func testAccessWords() {
        let rows = shown(.known(state(calendar: AppAccess(access: "read", items: .named(["A", "B"])),
                                      notes: AppAccess(access: "none", items: .named([])),
                                      reminders: AppAccess(access: "read and write", items: .named(["A"])),
                                      listeners: [(8788, .current)])))
        XCTAssertEqual(rows.dropFirst(), ["Calendar: Read Only", "Reminders: Read & Write", "Notes: Off"])
    }

    func testPermissions() {
        let on = RemoteAnswer.known(state(listeners: [(8788, .current)]))
        let off = RemoteAnswer.known(state(listeners: []))
        func rows(_ permissions: Permissions, _ remote: RemoteAnswer) -> [AppRow] { menuModel(remote, permissions).rows }
        func needs(_ title: String, _ action: RowAction) -> AppRow {
            AppRow(title: title, detail: "Needs Access", problem: true, action: action)
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
        XCTAssertEqual(rows(undecided, on), [AppRow(title: "Calendar", detail: "Read & Write", problem: false, action: nil),
                                             AppRow(title: "Reminders", detail: "Off", problem: false, action: nil),
                                             AppRow(title: "Notes", detail: "Read Only", problem: false, action: nil)])
        for notes in ["unknown (Notes not running)", "unknown (-1)"] {
            XCTAssertEqual(rows(Permissions(calendar: .fullAccess, reminders: .fullAccess, notes: notes), on), rows(fine, on))
        }
        // Each app's problem shows on its own row only.
        let none = Permissions(calendar: .denied, reminders: .denied, notes: "denied")
        XCTAssertEqual(shown(on, none, mine), ["Remote access on", "Calendar: Needs Access !", "Reminders: Needs Access !",
                                               "Notes: Needs Access !"])
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
                // A row's word at the right, after its tab, in brackets.
                let title = item.title.split(separator: "\t").enumerated().map { $0 == 0 ? String($1) : "[\($1)]" }.joined(separator: " ")
                var text = item.view.map { labels($0).joined(separator: " / ") } ?? title
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
             ["(Iris / Remote access on)", "Calendar [Read & Write] >", "Reminders [Off] >", "Notes [Read Only] >"]),
            (.known(state(listeners: [])), fine, off,
             ["(Iris / Remote access off)", "Calendar [Read & Write] >", "Reminders [Off] >", "Notes [Read Only] >"]),
            (.known(state(listeners: [(8788, .current)])), Permissions(calendar: .denied, reminders: .fullAccess, notes: "granted"), mine,
             ["(Iris / Remote access on)", "Calendar [Needs Access]", "Reminders [Off] >", "Notes [Read Only] >"]),
            (.unknown, fine, off, ["(Iris / Remote access unknown)", "Calendar >", "Reminders >", "Notes >"]),
            (.known(state(listeners: [])), fine, failed,
             ["(Iris / Couldn't start)", "Why It Couldn't Start…", "Calendar [Read & Write] >", "Reminders [Off] >",
              "Notes [Read Only] >"]),
            (.known(state(listeners: [(8788, .current)])), fine, off,
             ["(Iris / On · run outside Iris)", "Calendar [Read & Write] >", "Reminders [Off] >", "Notes [Read Only] >"]),
        ]
        let header = menu.items[0]
        let rows = Array(menu.items[3...5])
        let toggle = items.headerView.toggle
        for (remote, permissions, server, top) in states {
            let model = menuModel(remote, permissions, server)
            items.show(model)
            let under = top.count == 5 ? 2 : 1
            XCTAssertEqual(described(menu), Array(top.prefix(under)) + ["---"] + top.dropFirst(under)
                           + ["---", "Settings >", "---", "Quit Iris"])
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
        XCTAssertEqual(settings.items.map(\.title), ["Iris 1.0", "Check for Updates…", "Open at Login", "Allow Notes Access…", "",
                                                     "Let Assistants Change Events With Other People"])
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

    /// A submenu as text: ✓ for a tick, () for disabled, an indent per level.
    private func lines(_ entries: [ShareEntry]) -> [String] {
        entries.map { entry in
            switch entry {
            case .separator: "---"
            case .loading: "(Loading…)"
            case .choice(let title, let on, let enabled, let level, _):
                (enabled ? "" : "(") + (on ? "✓ " : "  ") + String(repeating: "  ", count: level) + title + (enabled ? "" : ")")
            }
        }
    }

    private func actions(_ entries: [ShareEntry]) -> [ShareAction] {
        entries.compactMap { entry -> ShareAction? in
            if case .choice(_, _, _, _, let action) = entry { action } else { nil }
        }
    }

    func testShareMenu() {
        let listed = ShareSource.listed(calendars)
        let some = ScopeFileState.file(ScopeFile(calendars: ["Work", "c3"], folders: [], writes: true))
        let menu = shareMenu(.calendars, some, listed)
        XCTAssertEqual(lines(menu.choices), ["  Off", "  Read Only", "✓ Read & Write"])
        XCTAssertEqual(menu.which, "2 of 3 Calendars")
        XCTAssertEqual(lines(menu.items), ["  All Calendars", "---", "✓ Work", "  Family", "✓ Birthdays"])
        // Each choice is its level; each item the tick that turns it the other way.
        XCTAssertEqual(actions(menu.choices), [.tick(.access(.calendars, .off)), .tick(.access(.calendars, .readOnly)),
                                               .tick(.access(.calendars, .readWrite))])
        XCTAssertEqual(actions(menu.items), [.tick(.all(.calendars)), .tick(.item(.calendars, "c1", false)),
                                             .tick(.item(.calendars, "c2", true)), .tick(.item(.calendars, "c3", false))])
        // "all": every item ticked.
        let all = shareMenu(.calendars, .file(ScopeFile(calendars: nil, folders: nil)), listed)
        XCTAssertEqual(lines(all.choices), ["  Off", "✓ Read Only", "  Read & Write"])
        XCTAssertEqual(all.which, "All Calendars")
        XCTAssertEqual(lines(all.items), ["✓ All Calendars", "---", "✓ Work", "✓ Family", "✓ Birthdays"])
        // Every one named is not all: a calendar made later is not shared.
        let every = shareMenu(.calendars, .file(ScopeFile(calendars: ["c1", "c2", "c3"], folders: [])), listed)
        XCTAssertEqual(every.which, "3 of 3 Calendars")
        XCTAssertEqual(lines(every.items).first, "  All Calendars")
        // Off: no items line. Also with no file yet, and with writes on and no calendars, which the file allows.
        for state in [ScopeFileState.missing, .file(ScopeFile(calendars: [], folders: [])), .file(ScopeFile(calendars: [], folders: [], writes: true))] {
            let off = shareMenu(.calendars, state, listed)
            XCTAssertEqual(lines(off.choices), ["✓ Off", "  Read Only", "  Read & Write"])
            XCTAssertNil(off.which)
        }
        // Off, and nothing remembered can be shared again (deleted, or not listed yet to tell, or a memory that cannot
        // be read): the items are offered to choose from, none ticked. Not while Read Only can turn it on.
        let none = ScopeFileState.file(ScopeFile(calendars: [], folders: []))
        let gone = shareMenu(.calendars, none, listed, remembered: .entries(["c9"]))
        XCTAssertEqual(lines(gone.choices), ["✓ Off", "  Read Only", "  Read & Write"])
        XCTAssertEqual(gone.which, "Choose Calendars")
        XCTAssertEqual(lines(gone.items), ["  All Calendars", "---", "  Work", "  Family", "  Birthdays"])
        XCTAssertEqual(shareMenu(.calendars, none, .loading, remembered: .entries(["c1"])).which, "Choose Calendars")
        XCTAssertEqual(shareMenu(.folders, .missing, .openNotes, remembered: .entries([])).which, "Choose Folders")
        XCTAssertNil(shareMenu(.calendars, none, listed, remembered: .entries(["c1", "c9"])).which)
        XCTAssertNil(shareMenu(.calendars, none, listed, remembered: .all).which)
        XCTAssertNil(shareMenu(.calendars, none, listed).which)
        XCTAssertEqual(shareMenu(.calendars, some, listed, remembered: .entries(["c9"])).which, "2 of 3 Calendars")
        // Two with one name: each with its account.
        let twins = calendars + [ShareItem(id: "c4", name: "Work", group: "Other")]
        XCTAssertEqual(lines(shareMenu(.calendars, .file(ScopeFile(calendars: ["c4"], folders: [])), .listed(twins)).items),
                       ["  All Calendars", "---", "  Work (iCloud)", "  Family", "  Birthdays", "✓ Work (Other)"])
        // An entry that names nothing now, ticked at the end, to be unticked.
        let missing = shareMenu(.calendars, .file(ScopeFile(calendars: ["Old", "c1"], folders: [])), listed)
        XCTAssertEqual(missing.which, "1 of 3 Calendars")
        XCTAssertEqual(lines(missing.items), ["  All Calendars", "---", "✓ Work", "  Family", "  Birthdays", "---", "✓ Missing: Old"])
        XCTAssertEqual(actions(missing.items).last, .tick(.remove(.calendars, "Old")))
        // Not listed yet, or not to be listed without asking.
        let loading = shareMenu(.calendars, some, .loading)
        XCTAssertEqual(loading.which, "Some Calendars")
        XCTAssertEqual(lines(loading.items), ["  All Calendars", "---", "(Loading…)"])
        let lists = shareMenu(.lists, .file(ScopeFile(calendars: [], folders: [], lists: nil, reminderWrites: true)), .ask(.askReminders))
        XCTAssertEqual(lines(lists.choices), ["  Off", "  Read Only", "✓ Read & Write"])
        XCTAssertEqual(lists.which, "All Lists")
        XCTAssertEqual(lines(lists.items), ["✓ All Lists", "---", "  Allow Reminders Access…"])
        XCTAssertEqual(actions(lists.choices).last, .tick(.access(.lists, .readWrite)))
        // Notes: Off and Read Only, folders by level.
        let folders = [ShareItem(id: "f1", name: "Recipes", group: "iCloud"), ShareItem(id: "f2", name: "Travel", group: "iCloud"),
                       ShareItem(id: "f3", name: "Paris", group: "iCloud", level: 1)]
        let notes = shareMenu(.folders, .file(ScopeFile(calendars: [], folders: ["f3"])), .listed(folders))
        XCTAssertEqual(lines(notes.choices), ["  Off", "✓ Read Only"])
        XCTAssertEqual(notes.which, "1 of 3 Folders")
        XCTAssertEqual(lines(notes.items), ["  All Folders", "---", "  Recipes", "  Travel", "✓   Paris"])
        let closed = shareMenu(.folders, .file(ScopeFile(calendars: [], folders: nil)), .openNotes)
        XCTAssertEqual(closed.which, "All Folders")
        XCTAssertEqual(lines(closed.items), ["✓ All Folders", "---", "  Open Notes to Choose Folders"])
        let unasked = shareMenu(.folders, .missing, .ask(.askNotes))
        XCTAssertEqual(lines(unasked.choices), ["✓ Off", "  Read Only"])
        XCTAssertNil(unasked.which)
        // A file that cannot be read offers only its problem.
        for kind in [ScopeKind.calendars, .lists, .folders] {
            XCTAssertEqual(shareMenu(kind, .broken("not a JSON object"), listed),
                           ShareMenu(choices: [.choice("Settings File Has a Problem…", on: false, .fixFile)], which: nil, items: []))
        }
    }

    /// Events with other people, in Settings: enabled while Calendar is Read & Write, or while ticked.
    func testSharedEventsEntry() {
        func shown(_ state: ScopeFileState) -> String {
            guard case .choice(let title, let on, let enabled, _, let action) = sharedEventsEntry(state) else { return "?" }
            XCTAssertEqual(title, "Let Assistants Change Events With Other People")
            return (on ? "on" : "off") + (enabled ? "" : " disabled") + (action == .tick(.sharedEvents(!on)) ? "" : " wrong tick")
        }
        XCTAssertEqual(shown(.file(ScopeFile(calendars: ["c1"], folders: [], writes: true))), "off")
        XCTAssertEqual(shown(.file(ScopeFile(calendars: nil, folders: [], writes: true, sharedEvents: true))), "on")
        XCTAssertEqual(shown(.file(ScopeFile(calendars: ["c1"], folders: []))), "off disabled")
        XCTAssertEqual(shown(.file(ScopeFile(calendars: [], folders: [], writes: true))), "off disabled")
        XCTAssertEqual(shown(.file(ScopeFile(calendars: [], folders: [], writes: true, sharedEvents: true))), "on")
        XCTAssertEqual(shown(.missing), "off disabled")
        XCTAssertEqual(shown(.broken("not a JSON object")), "off disabled")
    }

    /// The rows' submenus as AppKit items, changed in place, and none on a row that needs access; the items line and
    /// its submenu; the Settings item for events with other people.
    @MainActor
    func testShareMenus() {
        let actions = Actions()
        let menu = NSMenu()
        let items = MenuItems(target: actions)
        fill(menu, with: items, version: "1.0", openAtLogin: .off, target: actions, updater: nil)
        items.show(menuModel(.checking, fine))
        func show(_ calendars: ScopeFileState, _ source: ShareSource) {
            items.show(shares: [shareMenu(.calendars, calendars, source), shareMenu(.lists, .missing, .loading),
                                shareMenu(.folders, .missing, .openNotes)], sharedEvents: sharedEventsEntry(calendars))
        }
        func described(_ menu: NSMenu) -> [String] {
            menu.items.filter { !$0.isHidden }.map { item in
                if item.isSeparatorItem { return "---" }
                let text = (item.state == .on ? "✓ " : "  ") + String(repeating: "  ", count: item.indentationLevel) + item.title
                    + (item.submenu == nil ? "" : " >")
                return item.isEnabled ? text : "(\(text))"
            }
        }
        let file = ScopeFileState.file(ScopeFile(calendars: ["c1"], folders: [], writes: true))
        show(file, .loading)
        XCTAssertTrue(items.rows[0].submenu === items.shares[0])
        XCTAssertFalse(items.shares[0].autoenablesItems)
        XCTAssertTrue(items.shares[0].showsStateColumn)
        XCTAssertEqual(described(items.shares[0]), ["  Off", "  Read Only", "✓ Read & Write", "---", "  Some Calendars >"])
        XCTAssertTrue(items.shares[0].items[4] === items.which[0])
        XCTAssertTrue(items.which[0].submenu === items.itemMenus[0])
        XCTAssertEqual(described(items.itemMenus[0]), ["  All Calendars", "---", "(  Loading…)"])
        XCTAssertEqual(described(items.shares[1]), ["✓ Off", "  Read Only", "  Read & Write"])
        XCTAssertEqual(described(items.shares[2]), ["✓ Off", "  Read Only"])

        // The listing comes in: the same items, the line's title changed; its submenu filled again for its new shape.
        let before = items.shares[0].items
        show(file, .listed(calendars))
        XCTAssertTrue(zip(before, items.shares[0].items).allSatisfy { $0 === $1 })
        XCTAssertEqual(described(items.shares[0]).last, "  1 of 3 Calendars >")
        XCTAssertEqual(described(items.itemMenus[0]), ["  All Calendars", "---", "✓ Work", "  Family", "  Birthdays"])
        // A tick keeps the shape: the same items, changed in place.
        let listedItems = items.itemMenus[0].items
        show(.file(ScopeFile(calendars: ["c1", "c2"], folders: [])), .listed(calendars))
        XCTAssertTrue(zip(listedItems, items.itemMenus[0].items).allSatisfy { $0 === $1 })
        XCTAssertEqual(described(items.shares[0]), ["  Off", "✓ Read Only", "  Read & Write", "---", "  2 of 3 Calendars >"])
        XCTAssertEqual(described(items.itemMenus[0]), ["  All Calendars", "---", "✓ Work", "✓ Family", "  Birthdays"])
        // A click reaches the target with its tick.
        let family = items.itemMenus[0].items[3]
        XCTAssertTrue(family.target === actions)
        _ = (family.target as? NSObject)?.perform(family.action, with: family)
        let readWrite = items.shares[0].items[2]
        _ = (readWrite.target as? NSObject)?.perform(readWrite.action, with: readWrite)
        XCTAssertEqual(actions.shared, [.tick(.item(.calendars, "c2", false)), .tick(.access(.calendars, .readWrite))])
        // Off: the line is hidden, the items the same.
        show(.file(ScopeFile(calendars: [], folders: [])), .listed(calendars))
        XCTAssertEqual(described(items.shares[0]), ["✓ Off", "  Read Only", "  Read & Write"])
        XCTAssertTrue(zip(before, items.shares[0].items).allSatisfy { $0 === $1 })
        // Off with nothing to share again: the line is back, to choose from, the same items.
        items.show(shares: [shareMenu(.calendars, .file(ScopeFile(calendars: [], folders: [])), .listed(calendars), remembered: .entries(["c9"])),
                            shareMenu(.lists, .missing, .loading), shareMenu(.folders, .missing, .openNotes)],
                   sharedEvents: sharedEventsEntry(.missing))
        XCTAssertEqual(described(items.shares[0]), ["✓ Off", "  Read Only", "  Read & Write", "---", "  Choose Calendars >"])
        XCTAssertTrue(zip(before, items.shares[0].items).allSatisfy { $0 === $1 })
        XCTAssertEqual(described(items.itemMenus[0]), ["  All Calendars", "---", "  Work", "  Family", "  Birthdays"])
        // A file that cannot be read: its problem only; read again, the choices and the line are back.
        show(.broken("not a JSON object"), .listed(calendars))
        XCTAssertEqual(described(items.shares[0]), ["  Settings File Has a Problem…"])
        show(.file(ScopeFile(calendars: nil, folders: [])), .listed(calendars))
        XCTAssertEqual(described(items.shares[0]), ["  Off", "✓ Read Only", "  Read & Write", "---", "  All Calendars >"])
        XCTAssertTrue(items.shares[0].items[4] === items.which[0])

        // Settings: events with other people, enabled only while Calendar is Read & Write. Settings enables its items
        // as AppKit validates them: one without an action is disabled.
        let settings = menu.items[7].submenu!
        XCTAssertTrue(settings.items.last === items.sharedEvents)
        XCTAssertEqual(described(settings).suffix(2), ["---", "(  Let Assistants Change Events With Other People)"])
        show(.file(ScopeFile(calendars: ["c1"], folders: [], writes: true, sharedEvents: true)), .listed(calendars))
        XCTAssertEqual(items.sharedEvents.state, .on)
        XCTAssertTrue(items.sharedEvents.target === actions)
        XCTAssertEqual(items.sharedEvents.action, #selector(MenuActions.chooseShare))
        XCTAssertEqual(items.sharedEvents.representedObject as? ShareAction, .tick(.sharedEvents(false)))
        show(.file(ScopeFile(calendars: ["c1"], folders: [])), .listed(calendars))
        XCTAssertEqual(items.sharedEvents.state, .off)
        XCTAssertNil(items.sharedEvents.action)
        show(.file(ScopeFile(calendars: ["c1"], folders: [], writes: true)), .listed(calendars))
        XCTAssertEqual(items.sharedEvents.action, #selector(MenuActions.chooseShare))

        // A row that needs access has no submenu; given access, it has it again.
        items.show(menuModel(.checking, Permissions(calendar: .denied, reminders: .fullAccess, notes: "granted")))
        XCTAssertNil(items.rows[0].submenu)
        XCTAssertTrue(items.rows[1].submenu === items.shares[1])
        items.show(menuModel(.checking, fine))
        XCTAssertTrue(items.rows[0].submenu === items.shares[0])
    }

    /// The rows' words at the right: plain grey text at a right tab stop that ends where the arrow's room begins, so
    /// the rows never make the menu wider; with a longer header line, the stop follows the menu's width.
    @MainActor
    func testRowWords() throws {
        let actions = Actions()
        let menu = NSMenu()
        let items = MenuItems(target: actions)
        fill(menu, with: items, version: "1.0", openAtLogin: .off, target: actions, updater: nil)
        items.show(menuModel(.known(state(listeners: [])), fine))
        XCTAssertEqual(menu.minimumWidth, menuWidth)
        // ⌘Q from an item not shown, so no row keeps room for a key.
        let quit = try XCTUnwrap(menu.items.last)
        XCTAssertTrue(quit.isHidden && quit.allowsKeyEquivalentWhenHidden)
        XCTAssertEqual(quit.keyEquivalent, "q")
        XCTAssertEqual(quit.action, #selector(NSApplication.terminate))
        XCTAssertTrue(menu.items.filter { !$0.isHidden }.allSatisfy { $0.keyEquivalent.isEmpty })
        XCTAssertEqual(menu.size.width, menuWidth, accuracy: 1)
        let title = try XCTUnwrap(items.rows[0].attributedTitle)
        XCTAssertEqual(title.string, "Calendar\tRead & Write")
        XCTAssertNil(items.rows[0].badge)
        XCTAssertNil(title.attribute(.foregroundColor, at: 0, effectiveRange: nil))
        XCTAssertEqual(title.attribute(.foregroundColor, at: 9, effectiveRange: nil) as? NSColor, .secondaryLabelColor)
        let stop = try XCTUnwrap((title.attribute(.paragraphStyle, at: 9, effectiveRange: nil) as? NSParagraphStyle)?.tabStops.first)
        XCTAssertEqual(stop.alignment, .right)
        // The longest header line there is: the menu as wide as the header, the stop moved with it.
        let long = menuModel(.known(state(usable: false, listeners: [(8788, .current), (8765, .current), (8766, .current)])), fine, mine)
        items.show(long)
        let wider = try XCTUnwrap((items.rows[0].attributedTitle?.attribute(.paragraphStyle, at: 9, effectiveRange: nil) as? NSParagraphStyle)?.tabStops.first)
        XCTAssertEqual(menu.size.width, max(menuWidth, items.headerView.frame.width), accuracy: 1)
        XCTAssertEqual(wider.location - stop.location, max(menuWidth, items.headerView.frame.width) - menuWidth, accuracy: 0.5)
        // Needs Access is in the same place, and a row with nothing known has no word.
        items.show(menuModel(.checking, Permissions(calendar: .denied, reminders: .fullAccess, notes: "granted")))
        XCTAssertEqual(items.rows[0].attributedTitle?.string, "Calendar\tNeeds Access")
        XCTAssertEqual(items.rows[1].attributedTitle?.string, "Reminders")
    }
}
