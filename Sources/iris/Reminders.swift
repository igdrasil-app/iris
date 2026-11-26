import ArgumentParser
import EventKit
import Foundation
import os

struct RemindersCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reminders",
        abstract: "Read Apple Reminders: the lists only, for now.",
        subcommands: [ReminderLists.self]
    )
}

struct ReminderLists: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "lists",
        abstract: "List reminder lists: id, title, writable, source, open.",
        discussion: """
            Sorted by title as calendars are. open is how many reminders in the list are not completed. \
            Reminders themselves cannot be read or changed yet. The first run asks for Reminders access; \
            a prompt not answered within \(reminderPromptSeconds) seconds is an error, and the call can be \
            repeated once it is answered. A denial is changed under System Settings › Privacy & Security › Reminders.
            """
    )

    func run() async throws {
        let store = try await grantedReminderStore()
        // EventKit objects read after their store is gone have shown wrong values: it lives until the end.
        defer { withExtendedLifetime(store) {} }
        let lists = store.calendars(for: .reminder)
        let open = openCounts(listIds: try await openReminderListIds(in: store, lists: lists))
        let infos = lists
            .sorted { calendarPrecedes(($0.title, $0.calendarIdentifier), ($1.title, $1.calendarIdentifier)) }
            .map { ReminderListInfo(id: $0.calendarIdentifier, title: $0.title, writable: $0.allowsContentModifications,
                                    source: $0.source.title, open: open[$0.calendarIdentifier] ?? 0) }
        try emit(infos)
    }
}

struct ReminderListInfo: Encodable {
    let id: String
    let title: String
    let writable: Bool
    let source: String
    let open: Int
}

/// How long a person at the Mac has to answer the Reminders prompt before the command gives up.
let reminderPromptSeconds = 30

func grantedReminderStore() async throws -> EKEventStore {
    let store = EKEventStore()
    switch EKEventStore.authorizationStatus(for: .reminder) {
    case .fullAccess:
        return store
    case .notDetermined:
        if try await reminderAccess(within: Double(reminderPromptSeconds), { try await store.requestFullAccessToReminders() }) {
            return store
        }
    default:
        break
    }
    throw IrisError("reminders access denied; allow Iris under System Settings › Privacy & Security › Reminders")
}

/// The answer to `request`, which asks for access. An unanswered prompt keeps the request waiting for as long
/// as it is on screen, so after `seconds` this gives up with an error and leaves the request behind.
func reminderAccess(within seconds: Double, _ request: @escaping @Sendable () async throws -> Bool) async throws -> Bool {
    let answered = OSAllocatedUnfairLock(initialState: false)
    return try await withCheckedThrowingContinuation { continuation in
        // Whichever comes first, the answer or the time limit, resumes; the other is ignored.
        @Sendable func finish(_ result: Result<Bool, Error>) {
            let first = answered.withLock { done in
                guard !done else { return false }
                done = true
                return true
            }
            if first { continuation.resume(with: result) }
        }
        Task {
            do { finish(.success(try await request())) } catch { finish(.failure(error)) }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
            finish(.failure(IrisError("Reminders access was not answered within \(Int(seconds)) seconds: a prompt "
                + "asking to give Iris access to Reminders is waiting on this Mac's screen; repeat the call once it is answered")))
        }
    }
}

/// The list id of every reminder not completed, in the given lists, copied out of EventKit.
func openReminderListIds(in store: EKEventStore, lists: [EKCalendar]) async throws -> [String] {
    // EventKit reads an empty list of lists as every list.
    if lists.isEmpty { return [] }
    let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: lists)
    return try await withCheckedThrowingContinuation { continuation in
        store.fetchReminders(matching: predicate) { reminders in
            guard let reminders else {
                return continuation.resume(throwing: IrisError("Reminders did not return the open reminders; try again"))
            }
            continuation.resume(returning: reminders.compactMap { $0.calendar?.calendarIdentifier })
        }
    }
}

func openCounts(listIds: [String]) -> [String: Int] {
    listIds.reduce(into: [:]) { counts, id in counts[id, default: 0] += 1 }
}
