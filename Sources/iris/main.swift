import Darwin
import EventKit
import Foundation

// macOS attributes a permission request to the "responsible process", normally the app
// that spawned us: Terminal, Cursor, Claude. Cursor and Claude carry no calendar usage
// string, so from them the request is denied without a prompt. Terminal and iTerm avoid
// this for their children with a private spawn attribute; we apply it to ourselves by
// re-executing in place, so the grant belongs to iris and is shared by every host.
func becomeResponsible() {
    if getenv("IRIS_RESPONSIBLE") != nil { return }

    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim") else { return }
    typealias Disclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32
    let disclaim = unsafeBitCast(symbol, to: Disclaim.self)

    var attr: posix_spawnattr_t? = nil
    posix_spawnattr_init(&attr)
    defer { posix_spawnattr_destroy(&attr) }
    let rc = disclaim(&attr, 1)
    guard rc == 0 else { setenv("IRIS_DISCLAIM_FAILED", String(rc), 1); return }
    // SETEXEC replaces this process instead of forking: same pid, same stdin/stdout.
    posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETEXEC))

    var size = UInt32(PATH_MAX)
    var path = [CChar](repeating: 0, count: Int(size))
    guard _NSGetExecutablePath(&path, &size) == 0 else { return }

    setenv("IRIS_RESPONSIBLE", "1", 1)
    var argv: [UnsafeMutablePointer<CChar>?] = CommandLine.arguments.map { strdup($0) }
    argv.append(nil)
    posix_spawn(nil, path, nil, &attr, argv, environ)
    // Only reached if the spawn failed; carry on as an ordinary child process.
}

func describe(_ status: EKAuthorizationStatus) -> String {
    switch status {
    case .notDetermined: return "not determined"
    case .restricted: return "restricted"
    case .denied: return "denied"
    case .fullAccess: return "full access"
    case .writeOnly: return "write only"
    @unknown default: return "unknown (\(status.rawValue))"
    }
}

becomeResponsible()

// What the process asked for, not what macOS decided; the Privacy pane is the ground truth.
if getenv("IRIS_RESPONSIBLE") != nil {
    print("responsible: iris (disclaim requested)")
} else if let rc = getenv("IRIS_DISCLAIM_FAILED") {
    print("responsible: host process (disclaim failed, code \(String(cString: rc)))")
} else {
    print("responsible: host process")
}
print("status: \(describe(EKEventStore.authorizationStatus(for: .event)))")
if CommandLine.arguments.dropFirst().first == "status" { exit(0) }

let store = EKEventStore()
do {
    let granted = try await store.requestFullAccessToEvents()
    print("granted: \(granted)")
} catch {
    print("error: \(error.localizedDescription)")
    exit(1)
}
for calendar in store.calendars(for: .event) {
    print("calendar: \(calendar.title)")
}
