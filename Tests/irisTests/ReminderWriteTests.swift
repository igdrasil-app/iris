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
        let parts = try dueComponents("2030-03-04T09:30:15.750000", mac: here)
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

    // In Chicago on 3 November 2030, 01:30 comes twice: 06:30Z and 07:30Z.
    func testTheSecondPassOfARepeatedHourIsRefused() throws {
        let first = try dueComponents("2030-11-03T06:30:00Z", mac: mac)
        XCTAssertEqual([first.hour, first.minute], [1, 30])
        XCTAssertEqual(reminderDue(first, mac: mac)!.at, instant("2030-11-03T06:30:00Z"))
        XCTAssertThrowsError(try dueComponents("2030-11-03T07:30:00Z", mac: mac))
        XCTAssertThrowsError(try dueComponents("2030-11-03T01:30:00-06:00", mac: mac))
        XCTAssertNoThrow(try dueComponents("2030-11-03T08:30:00Z", mac: mac))
    }

    // A date is a date even where the clocks skip its midnight; an impossible one is still refused.
    // Havana skips midnight on 10 March 2030, so the date does not parse there; read in UTC it does. On a
    // Mac in such a zone this was checked with the real command; here only the rule is pinned.
    func testABareDateNeedsNoMidnight() throws {
        let havana = try XCTUnwrap(TimeZone(identifier: "America/Havana"))
        XCTAssertNil(parseDay("2030-03-10", timeZone: havana))
        XCTAssertNotNil(parseDay("2030-03-10", timeZone: TimeZone(secondsFromGMT: 0)!))
        var there = Calendar(identifier: .gregorian)
        there.timeZone = havana
        XCTAssertEqual(try dueComponents("2030-03-10", mac: there).day, 10)
        let parts = try dueComponents("2030-03-10", mac: mac)
        XCTAssertEqual([parts.year, parts.month, parts.day], [2030, 3, 10])
        XCTAssertNil(parts.hour)
        XCTAssertNil(parts.timeZone)
        XCTAssertThrowsError(try dueComponents("2030-02-30", mac: mac))
    }

    func testAddRefusesABlankTitle() {
        for title in ["", " \n\t "] {
            XCTAssertThrowsError(try AddReminder.parse(["--list", "unused", "--title", title]))
        }
        XCTAssertNoThrow(try AddReminder.parse(["--list", "unused", "--title", "Buy milk"]))
    }

    // Measured on a Mac: a first save keeps the due as the start for a time, and 00:00 with no zone for a date.
    func testTheStartIsWhatAFirstSaveKeeps() throws {
        let timed = try dueComponents("2030-03-04T09:30:15", mac: mac)
        XCTAssertEqual(startComponents(timed), timed)
        let start = startComponents(try dueComponents("2030-03-04", mac: mac))
        XCTAssertEqual([start.year, start.month, start.day, start.hour, start.minute, start.second], [2030, 3, 4, 0, 0, 0])
        XCTAssertNil(start.timeZone)
    }

    // Which refusal is chosen. That a refused reminder stays as it was is checked on the device, not here.
    func testWhichRefusalADueChangeGets() {
        XCTAssertNil(dueChangeRefusal(hasAlarms: false, repeats: false))
        XCTAssertTrue(dueChangeRefusal(hasAlarms: true, repeats: false)!.contains("alarm"))
        XCTAssertTrue(dueChangeRefusal(hasAlarms: false, repeats: true)!.contains("repeats"))
        XCTAssertTrue(dueChangeRefusal(hasAlarms: true, repeats: true)!.contains("alarm"))
    }

    func testUpdateNeedsAnOptionAndAValidOne() {
        XCTAssertThrowsError(try UpdateReminder.parse(["some-id"]))
        for title in ["", " \n\t "] {
            XCTAssertThrowsError(try UpdateReminder.parse(["some-id", "--title", title]))
        }
        XCTAssertThrowsError(try UpdateReminder.parse(["some-id", "--due", "tomorrow"]))
        XCTAssertThrowsError(try UpdateReminder.parse(["some-id", "--priority", "urgent"]))
        for args in [["--notes", ""], ["--due", ""], ["--due", "2030-03-04"], ["--priority", "none"], ["--list", "x"]] {
            XCTAssertNoThrow(try UpdateReminder.parse(["some-id"] + args), "\(args)")
        }
    }

    func testTitle() {
        XCTAssertTrue(isValidTitle("Buy milk"))
        XCTAssertTrue(isValidTitle(" x "))
        XCTAssertFalse(isValidTitle(""))
        XCTAssertFalse(isValidTitle("   "))
        XCTAssertFalse(isValidTitle(" \n\t "))
    }
}
