import Foundation

// Who has used remote access lately, for the menu. A server the menu app started writes one line on stderr for
// each request a client made with the token; the app reads it from the pipe it drains for the request log, never
// puts it in the log, and keeps what it says in memory only. No AppKit here.

/// Set by the menu app on the server it starts; a server started any other way writes no activity line.
let reportActivityVariable = "IRIS_REPORT_ACTIVITY"

/// Every activity line starts with this. A request log line starts with its time, a digit.
let activityPrefix = "@activity "

/// The key under which a client of the 2026-07-28 protocol names itself on each request, as `clientInfo` does
/// once in `initialize` before it.
let clientInfoKey = "io.modelcontextprotocol/clientInfo"

private let labelLength = 32

/// A client's name reduced to a label that is safe to show: ASCII letters and digits, space, `.`, `-` and `_`,
/// nothing else, spaces collapsed, at most 32 characters; nil when nothing is left. ASCII only, so a name cannot
/// carry look-alike letters, right-to-left text or combining marks into the menu.
func activityLabel(_ value: Any?) -> String? {
    guard let text = value as? String else { return nil }
    var kept = ""
    for scalar in text.unicodeScalars.prefix(4096) {
        guard scalar.isASCII else { continue }
        let character = Character(scalar)
        if character.isLetter || character.isNumber || ".-_".contains(character) {
            kept.append(character)
        } else if character == " " && !kept.isEmpty && kept.last != " " {
            kept.append(character)
        }
        if kept.count == labelLength { break }
    }
    let label = kept.trimmingCharacters(in: .whitespaces)
    return label.isEmpty ? nil : label
}

/// The name a request carries: `clientInfo.name` in an initialize, or the 2026-07-28 key in `_meta`; as a label.
func clientLabel(method: String, params: [String: Any]) -> String? {
    if method == "initialize", let name = activityLabel((params["clientInfo"] as? [String: Any])?["name"]) { return name }
    return activityLabel(((params["_meta"] as? [String: Any])?[clientInfoKey] as? [String: Any])?["name"])
}

struct ActivityReport: Equatable {
    let time: Date
    let name: String?
}

private let activityTime: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = .current
    return formatter
}()

/// `@activity <time>`, then the name when the request carried one.
func activityLine(_ report: ActivityReport) -> String {
    activityPrefix + activityTime.string(from: report.time) + (report.name.map { " " + $0 } ?? "")
}

/// The report in an activity line, or nil for any other line. The name is taken only if it is a label as
/// `activityLabel` makes one.
func parseActivityLine(_ line: String) -> ActivityReport? {
    guard line.hasPrefix(activityPrefix) else { return nil }
    let rest = line.dropFirst(activityPrefix.count)
    let parts = rest.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
    guard let time = activityTime.date(from: String(parts[0])) else { return nil }
    guard parts.count == 2 else { return ActivityReport(time: time, name: nil) }
    let name = String(parts[1])
    guard activityLabel(name) == name else { return nil }
    return ActivityReport(time: time, name: name)
}

/// Splits the server's stderr into the request log and the activity lines, as the bytes come. A line that is not an
/// activity line goes to the log as soon as its first bytes show it is not, so the log gets the same bytes at the same
/// time as before; only a line that starts as an activity line could is held until its end.
struct ActivitySplitter {
    private let prefix = Data(activityPrefix.utf8)
    private var held = Data()       // the start of a line that is, or may yet be, an activity line
    private var passing = false     // inside a line that is not one
    private var dropping = false    // inside a line that starts as one but is too long to be one

    mutating func split(_ chunk: Data) -> (log: Data, lines: [String]) {
        var log = Data()
        var lines: [String] = []
        for byte in chunk {
            let end = byte == UInt8(ascii: "\n")
            if passing {
                log.append(byte)
                if end { passing = false }
                continue
            }
            if dropping {
                if end { dropping = false }
                continue
            }
            held.append(byte)
            let isActivity = held.starts(with: prefix)
            if end {
                if isActivity {
                    lines.append(String(decoding: held.dropLast(), as: UTF8.self))
                } else {
                    log += held
                }
                held = Data()
            } else if !isActivity && !prefix.starts(with: held) {
                log += held
                held = Data()
                passing = true
            } else if held.count > 256 {
                held = Data()
                dropping = true
            }
        }
        return (log, lines)
    }

    /// At the end of the output: a last line without its newline, for the log unless it started as an activity line.
    mutating func finish() -> Data {
        defer { held = Data() }
        return held.starts(with: prefix) ? Data() : held
    }
}

/// The app's time for activity: a `Date` that moves with a clock that only goes forward, so setting the Mac's clock
/// back does not make old activity new. Reports are stamped with it as they arrive; the time in a line is not used.
func activityNow() -> Date {
    let elapsed = activityEpoch.instant.duration(to: ContinuousClock.now).components
    return activityEpoch.date.addingTimeInterval(Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
}

private let activityEpoch = (date: Date(), instant: ContinuousClock.now)

/// Activity gathered off the main thread, taken by it one snapshot at a time.
final class ActivityInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var activity = RemoteActivity()
    private var waiting = false

    /// Records the reports, stamped now; true when the main thread has no snapshot coming and should take one.
    func add(_ reports: [ActivityReport]) -> Bool {
        guard !reports.isEmpty else { return false }
        let now = activityNow()
        return lock.withLock {
            reports.forEach { activity.record(ActivityReport(time: now, name: $0.name)) }
            defer { waiting = true }
            return !waiting
        }
    }

    func take() -> RemoteActivity {
        lock.withLock {
            waiting = false
            return activity
        }
    }
}

/// Who has been active, from the activity lines in the order they came. There is no session: a request without a
/// name is taken to be from the last name seen, while that name has been active within the last 5 minutes, else from
/// an unnamed assistant. Names are kept for 10 minutes after their last request, the time the menu shows them for.
struct RemoteActivity: Equatable {
    struct Seen: Equatable {
        let name: String
        var last: Date
    }

    static let attribution: TimeInterval = 5 * 60
    static let recent: TimeInterval = 10 * 60
    private static let mostNames = 16

    private(set) var named: [Seen] = []  // in the order first seen
    private(set) var unnamed: Date?
    private(set) var lastUsed: Date?
    private var current: String?

    mutating func record(_ report: ActivityReport) {
        let time = report.time
        named.removeAll { time.timeIntervalSince($0.last) >= Self.recent }
        lastUsed = max(lastUsed ?? time, time)
        if let name = report.name {
            current = name
            touch(name, time)
        } else if let current, let seen = named.first(where: { $0.name == current }),
                  time.timeIntervalSince(seen.last) <= Self.attribution {
            touch(current, time)
        } else {
            unnamed = max(unnamed ?? time, time)
        }
        if let since = unnamed, time.timeIntervalSince(since) >= Self.recent { unnamed = nil }
    }

    private mutating func touch(_ name: String, _ time: Date) {
        if let index = named.firstIndex(where: { $0.name == name }) {
            named[index].last = max(named[index].last, time)
            return
        }
        named.append(Seen(name: name, last: time))
        if named.count > Self.mostNames { named.removeFirst() }
    }
}

/// The header's line for the switch's server while it runs and its settings need nothing: who has been active in the
/// last 10 minutes and when, or when it was last used. `fits` says whether a line fits in the header: several names
/// that do not are counted instead, and one that does not is shortened. Measured with the widest time the line can
/// show, so it does not change from names to a count as the minutes pass.
func activityStatus(_ activity: RemoteActivity, now: Date, fits: (String) -> Bool) -> String {
    guard let lastUsed = activity.lastUsed else { return "On · no activity yet" }
    let recent = activity.named.filter { now.timeIntervalSince($0.last) < RemoteActivity.recent }
    let unnamed = activity.unnamed.flatMap { now.timeIntervalSince($0) < RemoteActivity.recent ? $0 : nil }
    let times = recent.map(\.last) + (unnamed.map { [$0] } ?? [])
    guard let latest = times.max() else { return "On · last used " + ago(now.timeIntervalSince(lastUsed)) }
    let age = now.timeIntervalSince(latest)
    let when = age < 60 ? "active just now" : "active \(Int(age / 60)) min ago"
    let widest = " · active 9 min ago"
    let who = recent.map(\.name) + (unnamed == nil ? [] : ["an assistant"])
    if who.count == 1 {
        guard var name = recent.first?.name else { return "An assistant · " + when }
        while !fits(name + widest) && name.count > 8 {
            name = String(name.dropLast(name.hasSuffix("…") ? 2 : 1)).trimmingCharacters(in: .whitespaces) + "…"
        }
        return name + " · " + when
    }
    let joined = who.dropLast().joined(separator: ", ") + " and " + who.last!
    // Each label as the client wrote it; the unnamed assistant always comes last, so never starts the line.
    let line = joined + " · " + when
    return fits(joined + widest) ? line : "\(who.count) assistants · " + when
}

/// How long ago, in whole minutes, hours or days; never seconds. Only for 10 minutes or more.
private func ago(_ seconds: TimeInterval) -> String {
    let minutes = Int(seconds / 60)
    if minutes < 60 { return "\(minutes) min ago" }
    let hours = minutes / 60
    if hours < 24 { return hours == 1 ? "1 hour ago" : "\(hours) hours ago" }
    let days = hours / 24
    return days == 1 ? "yesterday" : "\(days) days ago"
}

/// The menu bar icon's mark: shown from an activity line until 3 seconds after the last, so a burst keeps it on.
struct ActivityMark: Equatable {
    static let quiet: TimeInterval = 3
    private(set) var until: Date?

    mutating func record(at time: Date) {
        until = max(until ?? time, time + Self.quiet)
    }

    func shown(at time: Date) -> Bool {
        until.map { time < $0 } ?? false
    }
}
