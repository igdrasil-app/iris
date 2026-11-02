import AppKit
import EventKit
import ServiceManagement

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

/// The menu bar icon: the mascot's bot head, with a dot while Iris lacks full Calendar access.
@MainActor
final class MenuBar: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let store = EKEventStore()
    private let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    private var status = EKEventStore.authorizationStatus(for: .event)
    private var timer: Timer?

    override init() {
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        showStatus()
        // The grant changes in System Settings, which tells no one; asking is cheap.
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    private func refresh() {
        let now = EKEventStore.authorizationStatus(for: .event)
        guard now != status else { return }
        status = now
        showStatus()
    }

    private func showStatus() {
        item.button?.image = botGlyph(badge: status != .fullAccess)
        item.button?.toolTip = "Iris: Calendar \(describe(status))"
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

        menu.addItem(.separator())
        menu.addItem(withTitle: "Iris \(version ?? "unknown")", action: nil, keyEquivalent: "")
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
            _ = try? await store.requestFullAccessToEvents()
            refresh()
        }
    }

    @objc private func openPrivacySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
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
            NSApp.activate()
            NSAlert(error: error).runModal()
        }
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
