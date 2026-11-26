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
final class MenuBar: NSObject, NSMenuDelegate, MenuActions {
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
    private lazy var remoteCheck = RemoteCheck(compute: { checkRemote() }) { [weak self] in self?.show(remote: $0) }
    private var timer: Timer?

    override init() {
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        showStatus()
        probeNotes()
        // The grant changes in System Settings, which tells no one; asking is cheap.
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    private func refresh() {
        probeNotes()
        shown?.show(model())
        let now = EKEventStore.authorizationStatus(for: .event)
        guard now != status else { return }
        status = now
        showStatus()
    }

    private func model() -> MenuModel {
        menuModel(remote, Permissions(calendar: EKEventStore.authorizationStatus(for: .event),
                                      reminders: EKEventStore.authorizationStatus(for: .reminder), notes: notes))
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
        shown?.show(model())
    }

    // The menu may be open: its items change in place.
    private func show(remote answer: RemoteAnswer) {
        remote = answer
        shown?.show(model())
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
        let items = MenuItems(target: self)
        fill(menu, with: items, version: version, openAtLogin: login, target: self, updater: updater)
        items.show(model())
        shown = items
        remoteCheck.start()
    }

    func chooseRow(_ sender: NSMenuItem) {
        switch sender.representedObject as? RowAction {
        case .askCalendar: allowAccess()
        case .askNotes: allowNotesAccess()
        case .open(let pane): NSWorkspace.shared.open(pane.url)
        case nil: break
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
}

/// What `iris remote status` would answer. Reads only: it starts no server, writes no file and takes no lock,
/// and looks nothing up that could show a permission dialog.
private func checkRemote() -> RemoteAnswer {
    let state = try? remoteState(scopePath: (defaultScopeFile as NSString).expandingTildeInPath,
                                 tokenPath: (defaultTokenFile as NSString).expandingTildeInPath)
    return state.map(RemoteAnswer.known) ?? .unknown
}

/// Works out remote access off the main thread, since a scope naming calendars or lists is looked up by child
/// processes and can take seconds. One at a time: a start while one runs does nothing.
@MainActor
final class RemoteCheck {
    private let compute: @Sendable () -> RemoteAnswer
    private let show: (RemoteAnswer) -> Void
    private var running = false

    init(compute: @escaping @Sendable () -> RemoteAnswer, show: @escaping (RemoteAnswer) -> Void) {
        self.compute = compute
        self.show = show
    }

    func start() {
        guard !running else { return }
        running = true
        Task.detached { [weak self, compute] in
            let answer = compute()
            await self?.finish(answer)
        }
    }

    private func finish(_ answer: RemoteAnswer) {
        running = false
        show(answer)
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
    case open(SettingsPane)
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
}

/// The menu for a remote access answer and the permissions. The rows show what the scope file allows, also
/// while no server runs: what turning remote access on would allow. They show nothing they cannot know: no
/// answer yet, or every server started with another file. A missing permission takes a row's place: Calendar
/// short of full access, Reminders denied or write only, Notes denied. Not determined is no problem for
/// Reminders or Notes, as for the icon's dot: many people never use them with Iris, and `iris reminders lists`
/// or a click on the Notes row asks.
func menuModel(_ remote: RemoteAnswer, _ permissions: Permissions) -> MenuModel {
    var status = "Checking…"
    var allows: (AppAccess?) -> String? = { _ in nil }
    switch remote {
    case .checking:
        break
    case .unknown:
        status = "Remote access unknown"
    case .known(let state):
        status = remoteStatusLine(state)
        let listeners = state.listeners
        if listeners.isEmpty || listeners.contains(where: { $0.state != .otherFile }) {
            // A file that cannot be read allows nothing; while a server runs, it allows what it read at start.
            allows = { access in access.map(accessWords) ?? (listeners.isEmpty ? "Off" : nil) }
        }
    }

    func row(_ title: String, _ access: AppAccess?, problem fix: RowAction?, otherwise action: RowAction? = nil) -> AppRow {
        if let fix { return AppRow(title: title, detail: "Needs access", problem: true, action: fix) }
        return AppRow(title: title, detail: allows(access), problem: false, action: action)
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
    return MenuModel(status: status, rows: [
        row("Calendar", state?.calendar, problem: calendarFix),
        row("Reminders", state?.reminders, problem: remindersFix),
        row("Notes", state?.notes, problem: permissions.notes == "denied" ? .open(.automation) : nil,
            otherwise: permissions.notes == "not determined" ? .askNotes : nil),
    ])
}

private func accessWords(_ access: AppAccess) -> String {
    switch access.access {
    case "none": "Off"
    case "read": "Read only"
    default: "Read & write"
    }
}

/// One short line: on or off, the port or how many servers, and the one thing most worth knowing.
func remoteStatusLine(_ state: RemoteState) -> String {
    let listeners = state.listeners
    guard !listeners.isEmpty else { return "Remote access off" }
    var line = "Remote access · " + (listeners.count == 1 ? "port \(listeners[0].listener.port)" : "\(listeners.count) servers")
    let others = listeners.filter { $0.state == .otherFile }.count
    if others == listeners.count {
        line += " · started with other settings"
    } else if state.usable == false {
        // Outweighs a change: a restart would not start.
        line += " · settings have a problem"
    } else if listeners.contains(where: { $0.state == .changed }) {
        line += " · restart to apply changes"
    } else if others > 0 {
        line += " · \(others) started with other settings"
    }
    return line
}

@MainActor @objc protocol MenuActions {
    func chooseRow(_ sender: NSMenuItem)
    func toggleOpenAtLogin()
}

/// The items that show a model, made at each opening and changed in place while the menu is open, so the
/// highlight and keyboard position stay.
@MainActor
final class MenuItems {
    let header = NSMenuItem()
    let headerView = MenuHeader()
    let rows: [NSMenuItem]
    private var shown: MenuModel?

    init(target: MenuActions) {
        header.view = headerView
        header.isEnabled = false
        rows = (0..<3).map { _ in
            let item = NSMenuItem(title: "", action: #selector(MenuActions.chooseRow), keyEquivalent: "")
            item.target = target
            return item
        }
    }

    func show(_ model: MenuModel) {
        guard model != shown else { return }
        shown = model
        headerView.status = model.status
        for (item, row) in zip(rows, model.rows) {
            item.title = row.title
            item.badge = row.detail.map { NSMenuItemBadge(string: $0) }
            item.representedObject = row.action
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
    let settingsItem = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
    settingsItem.submenu = settings
    menu.addItem(settingsItem)

    menu.addItem(.separator())
    menu.addItem(withTitle: "Quit Iris", action: #selector(NSApplication.terminate), keyEquivalent: "q")
}

/// The menu's first item, not a row: Iris, and under it the state of remote access in grey. Never highlighted;
/// its right side is free for a control.
@MainActor
final class MenuHeader: NSView {
    private let name = NSTextField(labelWithString: "Iris")
    private let state = NSTextField(labelWithString: "")

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
        let inset = menuTitleInset()
        NSLayoutConstraint.activate([
            lines.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            lines.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -inset),
            lines.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            lines.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
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
