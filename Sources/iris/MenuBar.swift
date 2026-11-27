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
    private var remembered: SharedBefore = [:]  // what the apps turned off shared before, as last read
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
            shareMenu(kind, scopeFile, shareSource(kind, permissions, listed[kind]), remembered: remembered[kind])
        }, sharedEvents: sharedEventsEntry(scopeFile))
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
        readScopeFile()
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
            case .success:
                readScopeFile()
            case .failure(let error):
                readScopeFile()
                showProblem("Couldn't change what is shared", "\(error)")
            }
            showMenu()
            remoteCheck.start()
        }
    }

    /// The scope file and what is remembered beside it, as the submenus show them.
    private func readScopeFile() {
        scopeFile = loadScopeFile(scopeChanges.path)
        remembered = loadSharedBefore(sharedBeforePath(scopeChanges.path)) ?? unreadableSharedBefore
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
            readScopeFile()
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

    func toggleRemoteAccess(_ sender: MenuSwitch) {
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
    case separator
    case loading
}

/// A row's submenu: Off, Read Only and, for Calendar and Reminders, Read & Write, one of them ticked; then a line
/// that says which items, opening `items`: while the app shares something, and while it is off with entries it
/// shared before remembered, which Read Only may find it cannot share again. A file that cannot be read offers only its
/// problem, never a tick that would write over it.
struct ShareMenu: Equatable {
    let choices: [ShareEntry]
    let which: String?  // the items line: All Calendars, 3 of 7 Calendars, Choose Calendars; nil when there is none
    let items: [ShareEntry]
}

/// The submenu for one app. Its items submenu has All, ticked while the file says "all", then each item in the
/// order of `shareItems`, with its account after its name where another item has the same name, ticked when shared;
/// then each entry of the file that names nothing now, ticked, to be unticked. `remembered` is what the app shared
/// before it was turned off.
func shareMenu(_ kind: ScopeKind, _ state: ScopeFileState, _ source: ShareSource, remembered: Remembered? = nil) -> ShareMenu {
    let file: ScopeFile
    switch state {
    case .broken: return ShareMenu(choices: [.choice("Settings File Has a Problem…", on: false, .fixFile)], which: nil, items: [])
    case .missing: file = ScopeFile(calendars: [], folders: [])
    case .file(let read): file = read
    }
    let entries = file[kind]
    let shared = entries != []
    let writes = switch kind {
    case .calendars: file.writes
    case .lists: file.reminderWrites
    case .folders: false
    }
    // As the system's radio items: choosing the one ticked changes nothing.
    let levels: [ShareLevel] = kind == .folders ? [.off, .readOnly] : [.off, .readOnly, .readWrite]
    let choices = levels.map { level in
        let on = switch level {
        case .off: !shared
        case .readOnly: shared && !writes
        case .readWrite: shared && writes
        }
        return ShareEntry.choice(level.title, on: on, .tick(.access(kind, level)))
    }
    let noun = switch kind {
    case .calendars: "Calendars"
    case .lists: "Lists"
    case .folders: "Folders"
    }
    var which = entries == nil ? "All \(noun)" : "Some \(noun)"
    var items: [ShareEntry] = [.choice("All \(noun)", on: entries == nil, .tick(.all(kind))), .separator]
    switch source {
    case .loading:
        items.append(.loading)
    case .ask(let action):
        items.append(.choice(kind == .lists ? "Allow Reminders Access…" : "Allow Notes Access…", on: false, .ask(action)))
    case .openNotes:
        items.append(.choice("Open Notes to Choose Folders", on: false, .openNotes))
    case .listed(let listed):
        let named = listed.map { Named(id: $0.id, name: $0.name) }
        var sharedIds = Set(listed.map(\.id))
        var missing: [String] = []
        if let entries {
            sharedIds = []
            for entry in entries {
                let found = pick([entry], from: named, allowed: nil, id: \.id, name: \.name).found ?? []
                if found.isEmpty { missing.append(entry) } else { sharedIds.formUnion(found.map(\.id)) }
            }
            which = "\(sharedIds.count) of \(listed.count) \(noun)"
        }
        let names = Dictionary(listed.map { ($0.name, 1) }, uniquingKeysWith: +)
        for item in listed {
            let title = names[item.name, default: 0] > 1 && !item.group.isEmpty ? "\(item.name) (\(item.group))" : item.name
            let on = sharedIds.contains(item.id)
            items.append(.choice(title, on: on, level: item.level, .tick(.item(kind, item.id, !on))))
        }
        if !missing.isEmpty { items.append(.separator) }
        for entry in missing {
            items.append(.choice("Missing: \(entry)", on: true, .tick(.remove(kind, entry))))
        }
    }
    // Whether Read Only can turn the app on is known only once it is listed under the lock.
    var choose: String?
    if !shared, case .entries = remembered { choose = "Choose \(noun)" }
    return ShareMenu(choices: choices, which: shared ? which : choose, items: items)
}

let sharedEventsTitle = "Let Assistants Change Events With Other People"

/// Settings' tick for events with other people: ticked while the file allows it, and enabled while Calendar is
/// Read & Write, or while it is ticked, to be unticked.
func sharedEventsEntry(_ state: ScopeFileState) -> ShareEntry {
    guard case .file(let file) = state else {
        return .choice(sharedEventsTitle, on: false, enabled: false, .tick(.sharedEvents(true)))
    }
    let readWrite = file.calendars != [] && file.writes
    return .choice(sharedEventsTitle, on: file.sharedEvents, enabled: readWrite || file.sharedEvents,
                   .tick(.sharedEvents(!file.sharedEvents)))
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
        if let fix { return AppRow(title: title, detail: needsAccess, problem: true, action: fix) }
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

/// What each server running that the switch did not start uses of the scope file: as the last check found them,
/// else, with nothing known of the file, as the switch's own look before it would have started one.
private func otherServers(_ remote: RemoteAnswer, _ server: RemoteServerStatus) -> [ListenerState?] {
    if case .known(let state) = remote {
        let others = state.listeners.filter { !server.started($0.listener) }.map { Optional($0.state) }
        if !others.isEmpty { return others }
    }
    if case .outside(let ports) = server.phase { return ports.map { _ in nil } }
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

let needsAccess = "Needs Access"

/// The words of the submenu's choice that is ticked; `iris remote status` keeps its own.
private func accessWords(_ access: AppAccess) -> String {
    switch access.access {
    case "none": ShareLevel.off.title
    case "read": ShareLevel.readOnly.title
    default: ShareLevel.readWrite.title
    }
}

/// One short line: on or off, how many servers when more than one, and the one thing most worth knowing. No port:
/// the menu shows none.
func remoteStatusLine(_ remote: RemoteAnswer, _ server: RemoteServerStatus) -> String {
    let others = otherServers(remote, server)
    if server.pid == nil && !others.isEmpty {
        return "On · " + (others.count == 1 ? "run outside Iris" : "\(others.count) servers run outside Iris")
            + settingsWarning(remote, others)
    }
    switch server.phase {
    case .starting:
        return "Starting…"
    case .failed:
        return "Couldn't start"
    case .on:
        guard others.isEmpty else {
            // The warning is for every server on this scope file running now, the switch's own included.
            // An earlier server of the switch's, still in a check made before it was replaced, does not count.
            let all: [ListenerState?] = if case .known(let state) = remote {
                state.listeners.filter { $0.listener.pid == server.pid || !server.started($0.listener) }.map(\.state)
            } else { [] }
            return "On · \(others.count + 1) servers · \(others.count) run outside Iris" + settingsWarning(remote, all)
        }
        guard case .known(let state) = remote, let mine = state.listeners.first(where: { $0.listener.pid == server.pid }) else {
            return "Remote access on"
        }
        return "Remote access on" + settingsWarning(remote, [mine.state])
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
    func toggleRemoteAccess(_ sender: MenuSwitch)
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
    let sharedEvents = NSMenuItem(title: sharedEventsTitle, action: nil, keyEquivalent: "")
    let shares: [NSMenu]       // the rows' submenus, Calendar, Reminders and Notes
    let which: [NSMenuItem]    // in each, the line that opens its items
    let itemMenus: [NSMenu]    // and the items
    private let target: MenuActions
    private var shown: MenuModel?
    private var sharesShown: [ShareMenu]?

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
        sharedEvents.target = target
        rows = (0..<3).map { _ in
            let item = NSMenuItem(title: "", action: #selector(MenuActions.chooseRow), keyEquivalent: "")
            item.target = target
            return item
        }
        func menu() -> NSMenu {
            let menu = NSMenu()
            menu.autoenablesItems = false
            return menu
        }
        shares = (0..<3).map { _ in menu() }
        itemMenus = (0..<3).map { _ in menu() }
        which = itemMenus.map { items in
            let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            item.submenu = items
            return item
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
        // As wide as the menu will be: at least its minimum, or the header's line.
        let stop = max(menuWidth, headerView.frame.width) - rowTitleEnd()
        for (index, row) in model.rows.enumerated() {
            let item = rows[index]
            item.attributedTitle = rowTitle(row.title, row.detail, stop: stop)
            item.representedObject = row.action
            // A row that needs access has no submenu: its click asks for it, or opens its pane.
            item.submenu = row.action == nil ? shares[index] : nil
        }
        notesAccess.isHidden = !model.offersNotesAccess
    }

    /// The rows' submenus: the choices, then a separator and the items line, both hidden while the app is off. The
    /// same items each time, but for a file that cannot be read, which has only its problem; the items submenu is
    /// changed in place while it keeps its shape (the same separators in the same places), else filled again.
    func show(shares menus: [ShareMenu], sharedEvents entry: ShareEntry) {
        show(entry, in: sharedEvents)
        // In Settings, which enables its items as AppKit validates them: an item without an action is disabled.
        if !sharedEvents.isEnabled { sharedEvents.action = nil }
        guard menus != sharesShown else { return }
        sharesShown = menus
        for (index, share) in menus.enumerated() {
            let menu = shares[index]
            let count = share.choices.count
            if menu.items.count != count + 2 {
                menu.removeAllItems()
                for _ in share.choices { menu.addItem(NSMenuItem()) }
                menu.addItem(.separator())
                menu.addItem(which[index])
            }
            for (item, entry) in zip(menu.items, share.choices) { show(entry, in: item) }
            menu.items[count].isHidden = share.which == nil
            which[index].isHidden = share.which == nil
            which[index].title = share.which ?? ""
            fill(itemMenus[index], share.items)
        }
    }

    private func fill(_ menu: NSMenu, _ entries: [ShareEntry]) {
        let same = menu.items.count == entries.count
            && zip(menu.items, entries).allSatisfy { item, entry in item.isSeparatorItem == (entry == .separator) }
        if !same {
            menu.removeAllItems()
            for entry in entries { menu.addItem(entry == .separator ? .separator() : NSMenuItem()) }
        }
        for (item, entry) in zip(menu.items, entries) { show(entry, in: item) }
    }

    private func show(_ entry: ShareEntry, in item: NSMenuItem) {
        switch entry {
        case .separator:
            break
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

/// The main menu's least width, so the rows' words at the right have a known place.
let menuWidth: CGFloat = 240

/// A row's title: the app, then at the right, ending where AppKit leaves room for the submenu's arrow, what it
/// allows in grey, at a right tab stop `stop` from where the title begins. Plain text, not a badge, which draws a
/// capsule; AppKit draws it as any title, with the system's highlight.
@MainActor
func rowTitle(_ title: String, _ detail: String?, stop: CGFloat) -> NSAttributedString {
    let font = NSFont.menuFont(ofSize: 0)
    let style = NSMutableParagraphStyle()
    style.tabStops = [NSTextTab(textAlignment: .right, location: stop)]
    let text = NSMutableAttributedString(string: title, attributes: [.font: font, .paragraphStyle: style])
    if let detail {
        text.append(NSAttributedString(string: "\t" + detail, attributes: [.font: font, .paragraphStyle: style,
                                                                          .foregroundColor: NSColor.secondaryLabelColor]))
    }
    return text
}

/// How much wider than its title's tab stop AppKit makes a menu for an item with a submenu: the title's start, and
/// the room after it for the arrow, the least AppKit leaves. AppKit does not say; this measures it.
@MainActor
func rowTitleEnd() -> CGFloat {
    let menu = NSMenu()
    menu.showsStateColumn = false
    let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    item.attributedTitle = rowTitle("M", "M", stop: 100)
    item.submenu = NSMenu()
    menu.addItem(item)
    return menu.size.width - 100
}

/// Fills the menu: the header, the apps, Settings and Quit. Every row is enabled whether or not its click
/// does something, so none reads as grey information; a click on a row with nothing to fix just closes the menu.
@MainActor
func fill(_ menu: NSMenu, with items: MenuItems, version: String?, openAtLogin: NSControl.StateValue,
          target: MenuActions, updater: AnyObject?) {
    menu.removeAllItems()
    menu.autoenablesItems = false
    menu.showsStateColumn = false
    menu.minimumWidth = menuWidth
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
    settings.addItem(.separator())
    settings.addItem(items.sharedEvents)
    let settingsItem = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
    settingsItem.submenu = settings
    menu.addItem(settingsItem)

    menu.addItem(.separator())
    menu.addItem(withTitle: "Quit Iris", action: #selector(NSApplication.terminate), keyEquivalent: "")
    // While the menu is open, ⌘Q quits from an item that is not shown, as the shown one did: one shown would make
    // every row keep room for its key, which pushes the rows' words away from their arrows.
    let quit = NSMenuItem(title: "Quit Iris", action: #selector(NSApplication.terminate), keyEquivalent: "q")
    quit.isHidden = true
    quit.allowsKeyEquivalentWhenHidden = true
    menu.addItem(quit)
}

/// The header's on and off switch, drawn here in the system switch's size and colours. NSSwitch draws its inactive
/// look, a grey track, in any window that is not key, and a menu's window never is; AppKit has no way to ask for the
/// active look. On, the track is the accent colour; off, the system's light fill; disabled, both dimmed. A click
/// turns it and sends the action, and the menu stays open. VoiceOver reads it as NSSwitch reads: a switch, by its
/// label, with its value.
@MainActor
final class MenuSwitch: NSControl {
    var state: NSControl.StateValue = .off {
        didSet {
            guard state != oldValue else { return }
            // A state set while the knob moves wins over where it was going.
            moving?.invalidate()
            moving = nil
            knob = state == .on ? 1 : 0
            NSAccessibility.post(element: self, notification: .valueChanged)
        }
    }
    // Where the knob is, 0 at the left and 1 at the right; between the two while it moves.
    private var knob: CGFloat = 0 { didSet { needsDisplay = true } }
    private var moving: Timer?

    deinit { moving?.invalidate() }

    // As NSSwitch: the first click into a window that is not key turns it.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window == nil else { return }
        moving?.invalidate()
        moving = nil
        knob = state == .on ? 1 : 0
    }

    override var isEnabled: Bool { didSet { needsDisplay = true } }

    /// The size of the system's small switch on this macOS.
    override var intrinsicContentSize: NSSize {
        let system = NSSwitch()
        system.controlSize = .small
        return system.intrinsicContentSize
    }

    override func draw(_ dirtyRect: NSRect) {
        let bounds = self.bounds
        let inset = (bounds.height / 12).rounded(.toNearestOrAwayFromZero) / 2  // 1.5 at the system's 24 points high
        let track = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        let knobHeight = bounds.height - 2 * inset
        // macOS 26 draws the knob as a capsule more than half the track's width; earlier ones as a circle.
        let knobWidth: CGFloat = if #available(macOS 26, *) { (bounds.width * 0.58).rounded() } else { knobHeight }
        let knobRect = NSRect(x: inset + knob * (bounds.width - 2 * inset - knobWidth), y: inset, width: knobWidth, height: knobHeight)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        // Disabled, the whole control at half opacity, not each fill on its own.
        let context = NSGraphicsContext.current?.cgContext
        if !isEnabled {
            context?.setAlpha(0.5)
            context?.beginTransparencyLayer(auxiliaryInfo: nil)
        }
        defer { if !isEnabled { context?.endTransparencyLayer() } }
        NSColor.quaternaryLabelColor.setFill()
        track.fill()
        // The accent colour fades in as the knob moves right.
        NSColor.controlAccentColor.withAlphaComponent(knob).setFill()
        track.fill()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
        shadow.shadowOffset = NSSize(width: 0, height: -0.5)
        shadow.shadowBlurRadius = 1
        shadow.set()
        NSColor.white.setFill()
        NSBezierPath(roundedRect: knobRect, xRadius: knobHeight / 2, yRadius: knobHeight / 2).fill()
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard isEnabled, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        turn()
    }

    /// The knob moves over a sixth of a second, by a timer in the common modes, which run while a menu is open.
    private func turn() {
        let from = knob
        state = state == .on ? .off : .on
        let to = knob
        knob = from
        moving?.invalidate()
        let start = Date()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { return timer.invalidate() }
                let done = min(Date().timeIntervalSince(start) / 0.17, 1)
                self.knob = from + (to - from) * CGFloat(done)
                if done == 1 { timer.invalidate() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        moving = timer
        sendAction(action, to: target)
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilitySubrole() -> NSAccessibility.Subrole? { .switch }
    override func accessibilityValue() -> Any? { NSNumber(value: state == .on ? 1 : 0) }
    override func isAccessibilityEnabled() -> Bool { isEnabled }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        turn()
        return true
    }
}

/// The menu's first item, not a row: Iris, and under it the state of remote access in grey, with the remote
/// access switch at the right. Never highlighted. A click on the switch leaves the menu open, as the switches in
/// the system's menus do, and the line under Iris follows as the server starts.
@MainActor
final class MenuHeader: NSView {
    private let name = NSTextField(labelWithString: "Iris")
    private let state = NSTextField(labelWithString: "")
    let toggle = MenuSwitch()

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
