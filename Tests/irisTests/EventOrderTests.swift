import XCTest
@testable import iris

final class EventOrderTests: XCTestCase {
    private let nine = Date(timeIntervalSince1970: 1_800_000_000)

    private func key(start: TimeInterval = 0, end: TimeInterval = 3600, title: String = "Standup",
                     calendarId: String = "cal-a", id: String = "ev-a") -> EventKey {
        EventKey(start: nine + start, end: nine + end, title: title, calendarId: calendarId, id: id)
    }

    private func order(_ keys: [EventKey]) -> [String] {
        keys.sorted { $0.precedes($1) }.map(\.id)
    }

    // Ids run backwards except in the last pair, so only the key named decides each step.
    func testEachKeyBreaksATie() {
        let expected = [
            key(start: -60, end: 7200, title: "Z", calendarId: "cal-z", id: "f"),
            key(end: 1800, title: "Z", calendarId: "cal-z", id: "e"),
            key(title: "Lunch", calendarId: "cal-z", id: "d"),
            key(calendarId: "cal-a", id: "c"),
            key(calendarId: "cal-b", id: "a1"),
            key(calendarId: "cal-b", id: "a2"),
        ]
        XCTAssertEqual(order(expected), expected.map(\.id))
        XCTAssertEqual(order(expected.reversed()), expected.map(\.id))
        XCTAssertEqual(order([expected[3], expected[0], expected[5], expected[2], expected[4], expected[1]]),
                       expected.map(\.id))
    }

    func testTitlesThatSwiftCallsEqualStillOrder() {
        let composed = key(title: "Caf\u{E9}", id: "same")
        let decomposed = key(title: "Cafe\u{301}", id: "same")
        XCTAssertEqual(composed.title, decomposed.title)   // Swift compares them as equal
        XCTAssertNotEqual(composed.precedes(decomposed), decomposed.precedes(composed))
    }

    func testAnEventDoesNotPrecedeItself() {
        XCTAssertFalse(key().precedes(key()))
    }
}
