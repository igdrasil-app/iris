import XCTest
@testable import iris

/// The real prompt cannot be left unanswered in a test, so the request is a closure here.
final class ReminderAccessTests: XCTestCase {
    func testAnUnansweredPromptEndsTheCallAtTheLimit() async {
        // A request that does not stop when its caller is cancelled, as the real one does not: waiting for
        // it to end, as a task group would, takes the full 10 seconds and fails the limit below.
        let reply = Task.detached {
            try await Task.sleep(for: .seconds(10))
            return true
        }
        defer { reply.cancel() }
        let start = Date()
        do {
            _ = try await reminderAccess(within: 0.2) { try await reply.value }
            XCTFail("an unanswered request must not answer")
        } catch {
            XCTAssertTrue("\(error)".contains("waiting on this Mac's screen"), "\(error)")
            XCTAssertTrue("\(error)".contains("repeat the call"), "\(error)")
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertGreaterThanOrEqual(elapsed, 0.2)
        XCTAssertLessThan(elapsed, 5)
    }

    func testAnAnswerIsPassedOn() async throws {
        let granted = try await reminderAccess(within: 5) { true }
        XCTAssertTrue(granted)
        let refused = try await reminderAccess(within: 5) { false }
        XCTAssertFalse(refused)
    }
}
