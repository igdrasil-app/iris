import XCTest
@testable import iris

final class ReminderWriteTests: XCTestCase {
    private let chicago = TimeZone(identifier: "America/Chicago")!
    private var mac: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = chicago
        return calendar
    }

    private func instant(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text)!
    }

    func testABareDateIsDateOnlyWithNoZone() throws {
        let parts = try dueComponents("2030-03-04", mac: mac)
        XCTAssertEqual([parts.year, parts.month, parts.day], [2030, 3, 4])
        XCTAssertNil(parts.hour)
        XCTAssertNil(parts.minute)
        XCTAssertNil(parts.second)
        XCTAssertNil(parts.timeZone)
        let due = reminderDue(parts, mac: mac)!
        XCTAssertEqual(due.date, "2030-03-04")
        XCTAssertNil(due.time)
        XCTAssertNil(due.timeZone)
        XCTAssertNil(due.at)
    }

    // Without an offset the time is read in the current zone, which on a Mac is the Mac's zone.
    func testATimeWithoutAnOffsetIsThatClockTimeInTheMacsZone() throws {
        let here = macCalendar()
        let parts = try dueComponents("2030-03-04T09:30", mac: here)
        XCTAssertEqual([parts.year, parts.month, parts.day, parts.hour, parts.minute, parts.second], [2030, 3, 4, 9, 30, 0])
        XCTAssertEqual(parts.timeZone, here.timeZone)
        let due = reminderDue(parts, mac: here)!
        XCTAssertEqual(due.date, "2030-03-04")
        XCTAssertEqual(due.time, "09:30")
        XCTAssertEqual(due.timeZone, TimeZone.current.identifier)
        XCTAssertEqual(due.at, try parseDate("2030-03-04T09:30"))
    }

    func testSecondsAreKeptAndFractionsDropped() throws {
        let here = macCalendar()
        let parts = try dueComponents("2030-03-04T09:30:15.250000", mac: here)
        XCTAssertEqual([parts.hour, parts.minute, parts.second], [9, 30, 15])
        XCTAssertEqual(reminderDue(parts, mac: here)!.time, "09:30:15")
    }

    // 09:30 in Tokyo is 18:30 the day before in Chicago: kept as Chicago's clock time, the same moment.
    func testAnOffsetIsThatMomentAsTheMacsClockTime() throws {
        let parts = try dueComponents("2030-03-05T09:30+09:00", mac: mac)
        XCTAssertEqual([parts.year, parts.month, parts.day, parts.hour, parts.minute, parts.second], [2030, 3, 4, 18, 30, 0])
        XCTAssertEqual(parts.timeZone, chicago)
        let due = reminderDue(parts, mac: mac)!
        XCTAssertEqual(due.date, "2030-03-04")
        XCTAssertEqual(due.time, "18:30")
        XCTAssertEqual(due.timeZone, "America/Chicago")
        XCTAssertEqual(due.at, instant("2030-03-05T00:30:00Z"))
    }

    func testZIsThatMomentAsTheMacsClockTime() throws {
        let parts = try dueComponents("2030-03-04T15:30Z", mac: mac)
        XCTAssertEqual([parts.hour, parts.minute], [9, 30])
        XCTAssertEqual(parts.timeZone, chicago)
        let due = reminderDue(parts, mac: mac)!
        XCTAssertEqual(due.time, "09:30")
        XCTAssertEqual(due.at, instant("2030-03-04T15:30:00Z"))
    }

    func testABadDueIsRefused() {
        for text in ["", "tomorrow", "2030-13-01", "2030-03-04T25:00", "04/03/2030"] {
            XCTAssertThrowsError(try dueComponents(text, mac: mac), text)
        }
    }

    func testPriorityWordsAndValuesRoundTrip() {
        XCTAssertEqual(ReminderPriority.allCases.map(\.value), [0, 9, 5, 1])
        for priority in ReminderPriority.allCases {
            XCTAssertEqual(priorityWord(priority.value), priority.rawValue)
            XCTAssertEqual(ReminderPriority(argument: priority.rawValue), priority)
        }
        XCTAssertNil(ReminderPriority(argument: "urgent"))
        XCTAssertNil(ReminderPriority(argument: "High"))
    }

    func testTitle() {
        XCTAssertTrue(isValidTitle("Buy milk"))
        XCTAssertTrue(isValidTitle(" x "))
        XCTAssertFalse(isValidTitle(""))
        XCTAssertFalse(isValidTitle("   "))
        XCTAssertFalse(isValidTitle(" \n\t "))
    }
}
