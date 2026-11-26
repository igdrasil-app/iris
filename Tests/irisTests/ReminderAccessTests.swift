import XCTest
@testable import iris

/// The real prompt cannot be left unanswered in a test, so the request is a closure here.
final class ReminderAccessTests: XCTestCase {
    func testAnUnansweredPromptEndsTheCallAtTheLimit() async {
        let start = Date()
        do {
            _ = try await reminderAccess(within: 0.2) {
                try await Task.sleep(for: .seconds(3600))
                return true
            }
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
