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
final class MenuBar: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let store = EKEventStore()
    // Checks the appcast in Info.plist once a day and offers the update; the CLI never starts it.
    private let updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    private let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    private var status = EKEventStore.authorizationStatus(for: .event)
    // What the last probe answered; the menu shows this, at most one timer tick old.
    private var notes = "unknown"
    private var probingNotes = false
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
        let now = EKEventStore.authorizationStatus(for: .event)
        guard now != status else { return }
        status = now
        showStatus()
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
    }

    private func showStatus() {
        item.button?.image = botGlyph(badge: status != .fullAccess || notes == "denied")
        item.button?.toolTip = "Iris: Calendar \(describe(status)), Notes \(notes)"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refresh()
        menu.removeAllItems()
        menu.addItem(withTitle: "Calendar: \(describe(status))", action: nil, keyEquivalent: "")
        switch status {
        case .notDetermined:
            menu.addItem(action("Allow Calendar Access…", #selector(allowAccess)))
        case .denied, .writeOnly:
            menu.addItem(action("Open Privacy Settings…", #selector(openPrivacySettings)))
        default:
            break
        }
        menu.addItem(withTitle: "Notes: \(notes)", action: nil, keyEquivalent: "")
        switch notes {
        case "not determined":
            menu.addItem(action("Allow Notes Access…", #selector(allowNotesAccess)))
        case "denied":
            menu.addItem(action("Open Automation Settings…", #selector(openAutomationSettings)))
        default:
            break
        }

        menu.addItem(.separator())
        menu.addItem(withTitle: "Iris \(version ?? "unknown")", action: nil, keyEquivalent: "")
        let check = NSMenuItem(title: "Check for Updates…", action: #selector(SPUStandardUpdaterController.checkForUpdates), keyEquivalent: "")
        check.target = updater
        menu.addItem(check)
        let login = action("Open at Login", #selector(toggleOpenAtLogin))
        switch SMAppService.mainApp.status {
        case .enabled: login.state = .on
        case .requiresApproval: login.state = .mixed
        default: login.state = .off
        }
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Iris", action: #selector(NSApplication.terminate), keyEquivalent: "q")
    }

    private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func allowAccess() {
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
    @objc private func allowNotesAccess() {
        NSApp.activate()
        probeNotes(ask: true)
    }

    @objc private func openPrivacySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
    }

    @objc private func openAutomationSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
    }

    @objc private func toggleOpenAtLogin() {
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
