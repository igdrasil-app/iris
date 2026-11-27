import AppKit
import EventKit
import ServiceManagement
import Sparkle

/// Finder, `open` and login items go through LaunchServices, which sets IRIS_MENU_BAR from
/// LSEnvironment in Info.plist. A shell or an agent runs the binary directly and never has it.
func launchedAsApp() -> Bool {
    CommandLine.arguments.count == 1 && getenv("IRIS_MENU_BAR") != nil
}

@MainActor
func runMenuBar() -> Never {
    let app = NSApplication.shared
    let menuBar = MenuBar()
    withExtendedLifetime(menuBar) { app.run() }
    exit(0)
}

/// The menu bar icon: the mascot's bot head, with a dot while Iris lacks full Calendar access or Notes
/// access is denied. Notes not determined is no dot: many people never use Notes with Iris.
@MainActor
final class MenuBar: NSObject, NSApplicationDelegate, NSMenuDelegate, MenuActions {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let store = EKEventStore()
    // Checks the appcast in Info.plist once a day and offers the update; the CLI never starts it.
    private let updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    private let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    private var status = EKEventStore.authorizationStatus(for: .event)
    // What the last probe answered; the menu shows this, at most one timer tick old.
    private var notes = "unknown"
    private var probingNotes = false
    // The last answer about remote access, shown while the next is worked out; and the items of the last opening.
    private var remote = RemoteAnswer.checking
    private var shown: MenuItems?
    private var menuOpen = false
    private lazy var remoteCheck = BackgroundCheck(compute: { checkRemote() }) { [weak self] in self?.show(remote: $0) }
    // The switch's server: this binary, with the server's default paths.
    private lazy var server = RemoteServer(executable: executablePath() ?? Bundle.main.executablePath ?? "iris",
                                           defaults: .standard) { [weak self] _ in self?.serverChanged() }
    // What the rows' submenus show: the scope file as last read, and each app's items as last listed. Only shown: a
    // tick lists its app again before it is applied.
    private lazy var scopeChanges = ScopeChanges(path: (defaultScopeFile as NSString).expandingTildeInPath,
                                                 listing: { listShareItems($0)?.map { Named(id: $0.id, name: $0.name) } }) {
        [weak self] in self?.server.restart()
    }
    private var scopeFile = ScopeFileState.missing
    private var listed: [ScopeKind: [ShareItem]] = [:]
    // One for each app, so a slow one (Notes) holds up only its own submenu.
    private lazy var listings = [ScopeKind.calendars, .lists, .folders].map { kind in
        BackgroundCheck(compute: { listShareItems(kind) }) { [weak self] in self?.show(listed: $0, kind) }
    }
    private var timer: Timer?

    override init() {
        super.init()
        NSApplication.shared.delegate = self
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        showStatus()
        probeNotes()
        // The grant changes in System Settings, which tells no one; asking is cheap.
        // In the common modes, so it also runs while the menu is open.
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        server.start()
        // Quit Iris, and logging out, end in terminate, which posts this; a server left by any other end is
        // stopped at the next launch.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.server.quit() }
        }
    }

    private func refresh() {
        probeNotes()
        showMenu()
        let now = EKEventStore.authorizationStatus(for: .event)
        guard now != status else { return }
        status = now
        showStatus()
    }

    private var permissions: Permissions {
        Permissions(calendar: EKEventStore.authorizationStatus(for: .event),
                    reminders: EKEventStore.authorizationStatus(for: .reminder), notes: notes)
    }

    private func model() -> MenuModel {
        menuModel(remote, permissions, server.status)
    }

    private func showMenu() {
        shown?.show(model())
        let permissions = self.permissions
        shown?.show(shares: [ScopeKind.calendars, .lists, .folders].map { kind in
            shareEntries(kind, scopeFile, shareSource(kind, permissions, listed[kind]))
        })
    }

    // A listing that failed keeps the last one.
    private func show(listed answer: [ShareItem]?, _ kind: ScopeKind) {
        guard let answer else { return }
        listed[kind] = answer
        showMenu()
    }

    // While the menu is open, what the rows allow is worked out again for the server now running, or not; a
    // closed menu has it worked out when it opens.
    private func serverChanged() {
        showMenu()
        if menuOpen { remoteCheck.start() }
    }

    /// Asks about Notes off the main thread: the call takes milliseconds and has been known to hang.
    /// One at a time, so an older answer never lands on top of a newer one.
    private func probeNotes(ask: Bool = false) {
        guard !probingNotes else { return }
        probingNotes = true
        Task.detached { [weak self] in
            let answer = notesPermission(ask: ask)
            await self?.show(notes: answer)
        }
    }

    private func show(notes answer: String) {
        probingNotes = false
        guard answer != notes else { return }
        notes = answer
        showStatus()
        showMenu()
    }

    // The menu may be open: its items change in place.
    private func show(remote answer: RemoteAnswer) {
        remote = answer
        showMenu()
    }

    private func showStatus() {
        item.button?.image = botGlyph(badge: status != .fullAccess || notes == "denied")
        item.button?.toolTip = "Iris: Calendar \(describe(status)), Notes \(notes)"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refresh()
        let login: NSControl.StateValue = switch SMAppService.mainApp.status {
        case .enabled: .on
        case .requiresApproval: .mixed
        default: .off
        }
        scopeFile = loadScopeFile(scopeChanges.path)
        let items = MenuItems(target: self)
        fill(menu, with: items, version: version, openAtLogin: login, target: self, updater: updater)
        shown = items
        showMenu()
        remoteCheck.start()
        listings.forEach { $0.start() }
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuOpen = true
    }

    func menuDidClose(_ menu: NSMenu) {
        menuOpen = false
    }

    func chooseRow(_ sender: NSMenuItem) {
        if let action = sender.representedObject as? RowAction { perform(action) }
    }

    private func perform(_ action: RowAction) {
        switch action {
        case .askCalendar: allowAccess()
        case .askNotes: allowNotesAccess()
        case .askReminders: allowRemindersAccess()
        case .open(let pane): NSWorkspace.shared.open(pane.url)
        }
    }

    func chooseShare(_ sender: NSMenuItem) {
        switch sender.representedObject as? ShareAction {
        case .tick(let tick): change(tick)
        case .fixFile: offerReset()
        case .ask(let action): perform(action)
        case .openNotes:
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Notes.app"),
                                               configuration: NSWorkspace.OpenConfiguration())
        case nil: break
        }
    }

    /// Writes the tick to the scope file; the rows say what it allows once the check has read it again.
    private func change(_ tick: ScopeTick) {
        scopeChanges.submit(tick) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let file):
                scopeFile = .file(file)
            case .failure(let error):
                scopeFile = loadScopeFile(scopeChanges.path)
                showProblem("Couldn't change what is shared", "\(error)")
            }
            showMenu()
            remoteCheck.start()
        }
    }

    /// The problem, and a choice: Reset, after keeping the file beside it, or leave it to be fixed by hand.
    private func offerReset() {
        guard case .broken(let problem) = scopeFile else { return }
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Iris's settings file has a problem"
        alert.informativeText = problem + "\n\nReset replaces it with settings that share nothing, and keeps the "
            + "file as it is now beside it, with .broken and the date added to its name."
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        // Fixed by hand while the alert was open: nothing is reset.
        scopeChanges.reset { [weak self] result in
            guard let self else { return }
            if case .failure(let error) = result { showProblem("Couldn't reset the settings file", "\(error)") }
            scopeFile = loadScopeFile(scopeChanges.path)
            showMenu()
            remoteCheck.start()
        }
    }

    /// Quit waits for the changes still waiting or being made, a few seconds at most; the file is then as the last
    /// one finished left it, since each is written whole or not at all. The server stops after, at willTerminate.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard scopeChanges.isBusy else { return .terminateNow }
        var replied = false
        let reply = {
            guard !replied else { return }
            replied = true
            sender.reply(toApplicationShouldTerminate: true)
        }
        scopeChanges.whenDrained(reply)
        // A timer in the common modes: it also fires while an alert about a failed tick is up.
        let timeout = Timer(timeInterval: 5, repeats: false) { _ in MainActor.assumeIsolated { reply() } }
        RunLoop.main.add(timeout, forMode: .common)
        return .terminateLater
    }

    private func allowRemindersAccess() {
        NSApp.activate()
        Task {
            do {
                _ = try await store.requestFullAccessToReminders()
            } catch {
                showError(error)
            }
            refresh()
        }
    }

    private func allowAccess() {
        NSApp.activate()
        Task {
            do {
                _ = try await store.requestFullAccessToEvents()
            } catch {
                showError(error)
            }
            refresh()
        }
    }

    // The dialog holds the probe until the person answers; the timer's probes wait behind it.
    private func allowNotesAccess() {
        NSApp.activate()
        probeNotes(ask: true)
    }

    func toggleRemoteAccess(_ sender: NSSwitch) {
        server.turn(on: sender.state == .on)
        showMenu()
    }

    func showRemoteFailure() {
        guard case .failed(let reason) = server.status.phase else { return }
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Remote access couldn't start"
        // A server that would not stop still runs: no try can be made until it has exited.
        let retry = server.status.pid == nil ? remoteRetryNote
            : "Iris must wait for the previous server to exit before it can try again."
        alert.informativeText = reason + "\n\n" + retry
        alert.runModal()
    }

    func toggleOpenAtLogin() {
        do {
            switch SMAppService.mainApp.status {
            case .enabled:
                try SMAppService.mainApp.unregister()
            case .requiresApproval:
                // Turned off in Login Items; registering again cannot undo that, the user can.
                SMAppService.openSystemSettingsLoginItems()
            default:
                try SMAppService.mainApp.register()
            }
        } catch {
            showError(error)
        }
    }

    private func showError(_ error: Error) {
        NSApp.activate()
        NSAlert(error: error).runModal()
    }

    private func showProblem(_ title: String, _ text: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }
}

/// What `iris remote status` would answer. Reads only: it starts no server, writes no file and takes no lock,
/// and looks nothing up that could show a permission dialog.
private func checkRemote() -> RemoteAnswer {
    let state = try? remoteState(scopePath: (defaultScopeFile as NSString).expandingTildeInPath,
                                 tokenPath: (defaultTokenFile as NSString).expandingTildeInPath)
    return state.map(RemoteAnswer.known) ?? .unknown
}

/// The calendars, reminder lists or note folders, looked up only where that cannot show a permission dialog or
/// open Notes; nil when they could not be listed.
private func listShareItems(_ kind: ScopeKind) -> [ShareItem]? {
    let arguments = switch kind {
    case .calendars: ["calendar", "calendars"]
    case .lists: ["reminders", "lists"]
    case .folders: ["notes", "folders"]
    }
    return (try? listWithoutAsking(arguments)).flatMap { shareItems(kind, $0) }
}

/// Works out an answer off the main thread, since remote access and the items to share are looked up by child
/// processes and can take seconds. One at a time: a start while one runs starts the next once it has answered,
/// so the last answer shown is never older than the last start.
@MainActor
final class BackgroundCheck<Answer> {
    private let compute: @Sendable () -> Answer
    private let show: (Answer) -> Void
    private var running = false
    private var again = false

    init(compute: @escaping @Sendable () -> Answer, show: @escaping (Answer) -> Void) {
        self.compute = compute
        self.show = show
    }

    func start() {
        guard !running else {
            again = true
            return
        }
        running = true
        Task.detached { [weak self, compute] in
            let answer = compute()
            await self?.finish(answer)
        }
    }

    private func finish(_ answer: Answer) {
        running = false
        show(answer)
        if again {
            again = false
            start()
        }
    }
}

enum RemoteAnswer {
    case checking
    case unknown  // remoteState failed: the running processes could not be read
    case known(RemoteState)
}

struct Permissions {
    let calendar: EKAuthorizationStatus
    let reminders: EKAuthorizationStatus
    let notes: String  // as notesPermission answers
}

enum SettingsPane: String {
    case calendars = "Privacy_Calendars"
    case reminders = "Privacy_Reminders"
    case automation = "Privacy_Automation"

    var url: URL { URL(string: "x-apple.systempreferences:com.apple.preference.security?\(rawValue)")! }
}

enum RowAction: Equatable {
    case askCalendar
    case askNotes
    case askReminders
    case open(SettingsPane)
}

/// A calendar, reminder list or note folder as a row's submenu shows it.
struct ShareItem: Equatable {
    let id: String
    let name: String
    let group: String  // its account
    var level = 0      // how many folders it sits in
}

/// The items in the JSON of `iris calendar calendars`, `reminders lists` or `notes folders`, in the order a submenu
/// shows them: by account, accounts by name, and within one as listed, a folder right after the folder it sits in.
func shareItems(_ kind: ScopeKind, _ data: Data) -> [ShareItem]? {
    guard let listed = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
    let (nameKey, groupKey) = kind == .folders ? ("name", "account") : ("title", "source")
    let items = listed.compactMap { entry -> (item: ShareItem, parent: String?)? in
        guard let id = entry["id"] as? String else { return nil }
        return (ShareItem(id: id, name: entry[nameKey] as? String ?? "", group: entry[groupKey] as? String ?? ""),
                entry["parent"] as? String)
    }
    let ids = Set(items.map(\.item.id))
    var ordered: [ShareItem] = []
    func add(in parent: String?, group: String, level: Int) {
        for (item, itemParent) in items where item.group == group && itemParent.flatMap({ ids.contains($0) ? $0 : nil }) == parent {
            var item = item
            item.level = level
            ordered.append(item)
            add(in: item.id, group: group, level: level + 1)
        }
    }
    let groups = Set(items.map(\.item.group)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    for group in groups { add(in: nil, group: group, level: 0) }
    return ordered
}

/// Where a submenu's items come from: a listing, or what stands in for one that cannot be made without asking.
enum ShareSource: Equatable {
    case listed([ShareItem])
    case loading
    case ask(RowAction)  // the app was never asked, and listing it would show a permission dialog
    case openNotes       // listing the folders would open Notes
}

func shareSource(_ kind: ScopeKind, _ permissions: Permissions, _ listed: [ShareItem]?) -> ShareSource {
    switch kind {
    case .lists where permissions.reminders == .notDetermined: return .ask(.askReminders)
    case .folders where permissions.notes == "not determined": return .ask(.askNotes)
    case .folders where permissions.notes == "unknown (Notes not running)": return .openNotes
    default: return listed.map(ShareSource.listed) ?? .loading
    }
}

enum ShareAction: Equatable {
    case tick(ScopeTick)
    case fixFile
    case ask(RowAction)
    case openNotes
}

enum ShareEntry: Equatable {
    case choice(String, on: Bool, enabled: Bool = true, level: Int = 0, ShareAction)
    case section(String)
    case separator
    case loading
}

/// A row's submenu: All and None, a way to every item or to none in one click whatever else the file holds, then
/// each item, ticked when shared, with an entry of the file that names nothing now ticked
/// at the end, to be unticked; then, for Calendar and Reminders, whether changes are allowed. Changes need something
/// shared, and events with other people need changes; each is enabled when it can be turned on, or is on. A file that
/// cannot be read offers only its problem, never a tick that would write over it.
func shareEntries(_ kind: ScopeKind, _ state: ScopeFileState, _ source: ShareSource) -> [ShareEntry] {
    let file: ScopeFile
    switch state {
    case .broken: return [.choice("Settings File Has a Problem…", on: false, .fixFile)]
    case .missing: file = ScopeFile(calendars: [], folders: [])
    case .file(let read): file = read
    }
    let entries = file[kind]
    let all = switch kind {
    case .calendars: "All Calendars"
    case .lists: "All Lists"
    case .folders: "All Folders"
    }
    let none = switch kind {
    case .calendars: "No Calendars"
    case .lists: "No Lists"
    case .folders: "No Folders"
    }
    // A pair to choose from, as the system's radio items: choosing the one ticked changes nothing.
    var menu: [ShareEntry] = [.choice(all, on: entries == nil, .tick(.all(kind, true))),
                              .choice(none, on: entries == [], .tick(.all(kind, false))), .separator]
    // One line between parts, also when a part is empty.
    func separate() { if menu.last != .separator { menu.append(.separator) } }
    switch source {
    case .loading:
        menu.append(.loading)
    case .ask(let action):
        menu.append(.choice(kind == .lists ? "Allow Reminders Access…" : "Allow Notes Access…", on: false, .ask(action)))
    case .openNotes:
        menu.append(.choice("Open Notes to Choose Folders", on: false, .openNotes))
    case .listed(let items):
        let named = items.map { Named(id: $0.id, name: $0.name) }
        var shared = Set(items.map(\.id))
        var missing: [String] = []
        if let entries {
            shared = []
            for entry in entries {
                let found = pick([entry], from: named, allowed: nil, id: \.id, name: \.name).found ?? []
                if found.isEmpty { missing.append(entry) } else { shared.formUnion(found.map(\.id)) }
            }
        }
        let sections = Set(items.map(\.group)).count > 1
        var group: String?
        for item in items {
            if sections && item.group != group {
                menu.append(.section(item.group))
                group = item.group
            }
            let on = shared.contains(item.id)
            menu.append(.choice(item.name, on: on, level: item.level, .tick(.item(kind, item.id, !on))))
        }
        if !missing.isEmpty { separate() }
        for entry in missing {
            menu.append(.choice("Missing: \(entry)", on: true, .tick(.remove(kind, entry))))
        }
    }
    switch kind {
    case .calendars:
        separate()
        menu += [.choice("Allow Changes", on: file.writes, enabled: file.calendars != [] || file.writes, .tick(.writes(!file.writes))),
                 .choice("Include Events With Other People", on: file.sharedEvents, enabled: file.writes || file.sharedEvents,
                         .tick(.sharedEvents(!file.sharedEvents)))]
    case .lists:
        separate()
        menu += [.choice("Allow Changes", on: file.reminderWrites, enabled: file.lists != [] || file.reminderWrites,
                         .tick(.reminderWrites(!file.reminderWrites)))]
    case .folders:
        if menu.last == .separator { menu.removeLast() }
    }
    return menu
}

/// One app's row: what a remote assistant may do there, or, when Iris lacks what it needs, that problem.
struct AppRow: Equatable {
    let title: String
    let detail: String?  // the text at the right
    let problem: Bool
    let action: RowAction?
}

struct MenuModel: Equatable {
    let status: String  // the header's grey line
    let rows: [AppRow]
    var offersNotesAccess = false  // Allow Notes Access… under Settings, while Notes was never asked
    var switchOn = false
    var switchEnabled = true
    var failure: String?  // why remote access could not start, behind an item under the header
}

let remoteRetryNote = "Iris tries again every \(Int(RemoteServerTiming().retry)) seconds. To try now, turn remote access off and on."

/// The menu for a remote access answer and the permissions. The rows show what the scope file allows, also
/// while no server runs: what turning remote access on would allow. They show nothing they cannot know: no
/// answer yet, or every server started with another file. A missing permission takes a row's place: Calendar
/// short of full access, Reminders denied or write only, Notes denied. Not determined is no problem for
/// Reminders or Notes, as for the icon's dot: many people never use them with Iris; `iris reminders lists`
/// asks for Reminders, and Allow Notes Access… under Settings for Notes. A row that looks well never asks.
///
/// The switch is on while the switch's server runs, starts or cannot start, and while any other server runs; it
/// cannot be turned off while only others run, since Iris does not stop what it did not start.
func menuModel(_ remote: RemoteAnswer, _ permissions: Permissions, _ server: RemoteServerStatus = RemoteServerStatus()) -> MenuModel {
    var allows: (AppAccess?) -> String? = { _ in nil }
    if case .known(let state) = remote {
        let listeners = state.listeners
        if listeners.isEmpty || listeners.contains(where: { $0.state != .otherFile }) {
            // A file that cannot be read allows nothing; while a server runs, it allows what it read at start.
            allows = { access in access.map(accessWords) ?? (listeners.isEmpty ? "Off" : nil) }
        }
    }

    func row(_ title: String, _ access: AppAccess?, problem fix: RowAction?) -> AppRow {
        if let fix { return AppRow(title: title, detail: "Needs access", problem: true, action: fix) }
        return AppRow(title: title, detail: allows(access), problem: false, action: nil)
    }
    let calendarFix: RowAction? = switch permissions.calendar {
    case .fullAccess: nil
    case .notDetermined: .askCalendar
    default: .open(.calendars)
    }
    let remindersFix: RowAction? = switch permissions.reminders {
    case .fullAccess, .notDetermined: nil
    default: .open(.reminders)
    }
    let state: RemoteState? = if case .known(let state) = remote { state } else { nil }
    // With no server of its own running, any other running is what the menu shows, a failure to start included.
    let outside = server.pid == nil && !otherServers(remote, server).isEmpty
    let failure: String? = if case .failed(let reason) = server.phase, !outside { reason } else { nil }
    return MenuModel(status: remoteStatusLine(remote, server), rows: [
        row("Calendar", state?.calendar, problem: calendarFix),
        row("Reminders", state?.reminders, problem: remindersFix),
        row("Notes", state?.notes, problem: permissions.notes == "denied" ? .open(.automation) : nil),
    ], offersNotesAccess: permissions.notes == "not determined",
       switchOn: server.phase != .off || outside, switchEnabled: !outside, failure: failure)
}

/// The servers running that the switch did not start, with what they use of the scope file: as the last check
/// found them, else, with nothing known of the file, as the switch's own look before it would have started one.
private func otherServers(_ remote: RemoteAnswer, _ server: RemoteServerStatus) -> [(port: Int, state: ListenerState?)] {
    if case .known(let state) = remote {
        let others = state.listeners.filter { !server.started($0.listener) }.map { ($0.listener.port, Optional($0.state)) }
        if !others.isEmpty { return others }
    }
    if case .outside(let ports) = server.phase { return ports.map { ($0, nil) } }
    return []
}

/// What these servers' settings need, from the last check: nothing, a restart for a changed scope file, or a
/// scope file that would now stop a start, which outweighs a change. Only servers on this scope file count.
private func settingsWarning(_ remote: RemoteAnswer, _ states: [ListenerState?]) -> String {
    guard case .known(let state) = remote else { return "" }
    let onThisFile = states.compactMap { $0 }.filter { $0 != .otherFile }
    if onThisFile.isEmpty { return "" }
    if state.usable == false { return " · settings have a problem" }
    return onThisFile.contains(.changed) ? " · restart to apply changes" : ""
}

private func accessWords(_ access: AppAccess) -> String {
    switch access.access {
    case "none": "Off"
    case "read": "Read only"
    default: "Read & write"
    }
}

/// One short line: on or off, the port or how many servers, and the one thing most worth knowing.
func remoteStatusLine(_ remote: RemoteAnswer, _ server: RemoteServerStatus) -> String {
    let others = otherServers(remote, server)
    if server.pid == nil && !others.isEmpty {
        return "Remote access · " + (others.count == 1 ? "port \(others[0].port)" : "\(others.count) servers")
            + " · run outside Iris" + settingsWarning(remote, others.map(\.state))
    }
    switch server.phase {
    case .starting:
        return "Remote access · starting…"
    case .failed:
        return "Remote access · couldn't start"
    case .on(let port):
        guard others.isEmpty else {
            // The warning is for every server on this scope file running now, the switch's own included.
            // An earlier server of the switch's, still in a check made before it was replaced, does not count.
            let all: [ListenerState?] = if case .known(let state) = remote {
                state.listeners.filter { $0.listener.pid == server.pid || !server.started($0.listener) }.map(\.state)
            } else { [] }
            return "Remote access · \(others.count + 1) servers · \(others.count) run outside Iris" + settingsWarning(remote, all)
        }
        guard case .known(let state) = remote, let mine = state.listeners.first(where: { $0.listener.pid == server.pid }) else {
            return "Remote access · port \(port)"
        }
        return "Remote access · port \(port)" + settingsWarning(remote, [mine.state])
    case .off, .outside:
        switch remote {
        case .checking: return "Checking…"
        case .unknown: return "Remote access unknown"
        case .known: return "Remote access off"
        }
    }
}

@MainActor @objc protocol MenuActions {
    func chooseRow(_ sender: NSMenuItem)
    func chooseShare(_ sender: NSMenuItem)
    func toggleRemoteAccess(_ sender: NSSwitch)
    func showRemoteFailure()
    func toggleOpenAtLogin()
}

/// The items that show a model, made at each opening and changed in place while the menu is open, so the
/// highlight and keyboard position stay.
@MainActor
final class MenuItems {
    let header = NSMenuItem()
    let headerView = MenuHeader()
    let failure = NSMenuItem(title: "Why It Couldn't Start…", action: #selector(MenuActions.showRemoteFailure), keyEquivalent: "")
    let rows: [NSMenuItem]
    let notesAccess = NSMenuItem(title: "Allow Notes Access…", action: #selector(MenuActions.chooseRow), keyEquivalent: "")
    let shares: [NSMenu]  // the rows' submenus, Calendar, Reminders and Notes
    private let target: MenuActions
    private var shown: MenuModel?
    private var sharesShown: [[ShareEntry]]?

    init(target: MenuActions) {
        self.target = target
        header.view = headerView
        header.isEnabled = false
        headerView.toggle.target = target
        headerView.toggle.action = #selector(MenuActions.toggleRemoteAccess)
        failure.target = target
        failure.isHidden = true
        notesAccess.target = target
        notesAccess.representedObject = RowAction.askNotes
        notesAccess.isHidden = true
        rows = (0..<3).map { _ in
            let item = NSMenuItem(title: "", action: #selector(MenuActions.chooseRow), keyEquivalent: "")
            item.target = target
            return item
        }
        shares = (0..<3).map { _ in
            let menu = NSMenu()
            menu.autoenablesItems = false
            return menu
        }
    }

    func show(_ model: MenuModel) {
        // Also when the model is the same: a click may have moved the switch to where the model does not have it.
        headerView.toggle.state = model.switchOn ? .on : .off
        guard model != shown else { return }
        shown = model
        headerView.toggle.isEnabled = model.switchEnabled
        failure.isHidden = model.failure == nil
        headerView.status = model.status
        for (index, row) in model.rows.enumerated() {
            let item = rows[index]
            item.title = row.title
            item.badge = row.detail.map { NSMenuItemBadge(string: $0) }
            item.representedObject = row.action
            // A row that needs access has no submenu: its click asks for it, or opens its pane.
            item.submenu = row.action == nil ? shares[index] : nil
        }
        notesAccess.isHidden = !model.offersNotesAccess
    }

    /// The rows' submenus, each changed in place while it keeps its shape (the same separators and section headers
    /// in the same places), else filled again.
    func show(shares entries: [[ShareEntry]]) {
        func shape(_ entry: ShareEntry) -> Int {
            switch entry {
            case .separator: 0
            case .section: 1
            default: 2
            }
        }
        guard entries != sharesShown else { return }
        sharesShown = entries
        for (menu, entries) in zip(shares, entries) {
            let same = menu.items.count == entries.count && zip(menu.items, entries).allSatisfy { item, entry in
                shape(entry) == (item.isSeparatorItem ? 0 : item.isSectionHeader ? 1 : 2)
            }
            if !same {
                menu.removeAllItems()
                for entry in entries {
                    switch entry {
                    case .separator: menu.addItem(.separator())
                    case .section(let title): menu.addItem(.sectionHeader(title: title))
                    default: menu.addItem(NSMenuItem())
                    }
                }
            }
            for (item, entry) in zip(menu.items, entries) {
                switch entry {
                case .separator:
                    break
                case .section(let title):
                    item.title = title
                case .loading:
                    item.title = "Loading…"
                    item.state = .off
                    item.isEnabled = false
                    item.indentationLevel = 0
                    item.action = nil
                    item.representedObject = nil
                case .choice(let title, let on, let enabled, let level, let action):
                    item.title = title
                    item.state = on ? .on : .off
                    item.isEnabled = enabled
                    item.indentationLevel = min(level, 15)  // AppKit's most
                    item.target = target
                    item.action = #selector(MenuActions.chooseShare)
                    item.representedObject = action
                }
            }
        }
    }
}

/// Fills the menu: the header, the apps, Settings and Quit. Every row is enabled whether or not its click
/// does something, so none reads as grey information; a click on a row with nothing to fix just closes the menu.
@MainActor
func fill(_ menu: NSMenu, with items: MenuItems, version: String?, openAtLogin: NSControl.StateValue,
          target: MenuActions, updater: AnyObject?) {
    menu.removeAllItems()
    menu.autoenablesItems = false
    menu.showsStateColumn = false
    menu.addItem(items.header)
    menu.addItem(items.failure)
    menu.addItem(.separator())
    items.rows.forEach(menu.addItem)
    menu.addItem(.separator())

    let settings = NSMenu()
    settings.addItem(withTitle: "Iris \(version ?? "unknown")", action: nil, keyEquivalent: "")
    let check = NSMenuItem(title: "Check for Updates…", action: #selector(SPUStandardUpdaterController.checkForUpdates), keyEquivalent: "")
    check.target = updater
    settings.addItem(check)
    let login = NSMenuItem(title: "Open at Login", action: #selector(MenuActions.toggleOpenAtLogin), keyEquivalent: "")
    login.target = target
    login.state = openAtLogin
    settings.addItem(login)
    settings.addItem(items.notesAccess)
    let settingsItem = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
    settingsItem.submenu = settings
    menu.addItem(settingsItem)

    menu.addItem(.separator())
    menu.addItem(withTitle: "Quit Iris", action: #selector(NSApplication.terminate), keyEquivalent: "q")
}

/// The menu's first item, not a row: Iris, and under it the state of remote access in grey, with the remote
/// access switch at the right. Never highlighted. A click on the switch leaves the menu open, as the switches in
/// the system's menus do, and the line under Iris follows as the server starts.
@MainActor
final class MenuHeader: NSView {
    private let name = NSTextField(labelWithString: "Iris")
    private let state = NSTextField(labelWithString: "")
    let toggle = NSSwitch()

    var status: String {
        get { state.stringValue }
        set {
            state.stringValue = newValue
            // Wide enough for the line; the menu makes it as wide as the menu.
            let fitting = fittingSize
            setFrameSize(NSSize(width: max(frame.size.width, fitting.width), height: fitting.height))
        }
    }

    init() {
        super.init(frame: .zero)
        name.font = .menuFont(ofSize: 0)
        name.textColor = .labelColor
        state.font = .menuFont(ofSize: NSFont.smallSystemFontSize)
        state.textColor = .secondaryLabelColor
        let lines = NSStackView(views: [name, state])
        lines.orientation = .vertical
        lines.alignment = .leading
        lines.spacing = 1
        lines.translatesAutoresizingMaskIntoConstraints = false
        addSubview(lines)
        toggle.controlSize = .small
        toggle.setAccessibilityLabel("Remote access")
        toggle.translatesAutoresizingMaskIntoConstraints = false
        addSubview(toggle)
        let inset = menuTitleInset()
        NSLayoutConstraint.activate([
            lines.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            lines.trailingAnchor.constraint(lessThanOrEqualTo: toggle.leadingAnchor, constant: -16),
            lines.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            lines.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
            toggle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            toggle.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        autoresizingMask = [.width]
    }

    required init?(coder: NSCoder) { fatalError("not from a nib") }
}

/// Where a menu item's title starts, so the header lines up with the rows. AppKit does not say; this takes the
/// padding it gives a plain item without a state column as the same on both sides.
@MainActor
private func menuTitleInset() -> CGFloat {
    let menu = NSMenu()
    menu.showsStateColumn = false
    menu.addItem(withTitle: "M", action: nil, keyEquivalent: "")
    let title = ("M" as NSString).size(withAttributes: [.font: NSFont.menuFont(ofSize: 0)]).width
    return ((menu.size.width - title) / 2).rounded()
}

/// Drawn in the 24-point grid of Assets/mascot.svg and scaled to the menu bar's 18.
/// A template image is alpha only, so the eyes and the gap around the dot are cut out.
func botGlyph(badge: Bool) -> NSImage {
    let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
        guard let context = NSGraphicsContext.current else { return false }
        let scale = NSAffineTransform()
        scale.scale(by: 0.75)
        scale.concat()
        NSColor.black.set()

        let antenna = NSBezierPath()
        antenna.move(to: NSPoint(x: 12, y: 8))
        antenna.line(to: NSPoint(x: 12, y: 4))
        antenna.line(to: NSPoint(x: 8, y: 4))
        stroke(antenna)
        let head = NSBezierPath(roundedRect: NSRect(x: 4, y: 8, width: 16, height: 12), xRadius: 2, yRadius: 2)
        head.fill()
        stroke(head)

        context.compositingOperation = .destinationOut
        let eye = NSBezierPath()
        eye.move(to: NSPoint(x: 9, y: 13))
        eye.line(to: NSPoint(x: 9, y: 15))
        stroke(eye)
        NSBezierPath(ovalIn: NSRect(x: 13.95, y: 12.95, width: 2.1, height: 2.1)).fill()

        if badge {
            NSBezierPath(ovalIn: NSRect(x: 16, y: 0, width: 8, height: 8)).fill()
            context.compositingOperation = .sourceOver
            NSBezierPath(ovalIn: NSRect(x: 17.5, y: 1.5, width: 5, height: 5)).fill()
        }
        return true
    }
    image.isTemplate = true
    image.accessibilityDescription = "Iris"
    return image
}

private func stroke(_ path: NSBezierPath) {
    path.lineWidth = 2.1
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    path.stroke()
}
