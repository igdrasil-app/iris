import XCTest
@testable import iris

final class ReminderTests: XCTestCase {
    // The Mac in these tests is in Chicago; nothing depends on the zone of the machine running them.
    private let chicago = TimeZone(identifier: "America/Chicago")!
    private var mac: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = chicago
        return calendar
    }

    private func instant(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text)!
    }

    private func components(_ year: Int, _ month: Int, _ day: Int, _ hour: Int? = nil, _ minute: Int? = nil,
                            _ second: Int? = nil, zone: String? = nil) -> DateComponents {
        DateComponents(timeZone: zone.map { TimeZone(identifier: $0)! }, year: year, month: month, day: day,
                       hour: hour, minute: minute, second: second)
    }

    // MARK: due

    func testNoDue() {
        XCTAssertNil(reminderDue(nil, mac: mac))
        XCTAssertNil(reminderDue(DateComponents(year: 2030, month: 3), mac: mac))
    }

    func testDateOnly() {
        let due = reminderDue(components(2030, 3, 4), mac: mac)!
        XCTAssertEqual(due.date, "2030-03-04")
        XCTAssertNil(due.time)
        XCTAssertNil(due.timeZone)
        XCTAssertNil(due.at)
        XCTAssertEqual(due.day, Day(year: 2030, month: 3, day: 4))
    }

    func testTimedInTheMacsZone() {
        let due = reminderDue(components(2030, 3, 4, 9, 30, zone: "America/Chicago"), mac: mac)!
        XCTAssertEqual(due.date, "2030-03-04")
        XCTAssertEqual(due.time, "09:30")
        XCTAssertEqual(due.timeZone, "America/Chicago")
        XCTAssertEqual(due.at, instant("2030-03-04T15:30:00Z"))
    }

    // 08:00 on the 5th in Tokyo is 17:00 on the 4th in Chicago: date and time stay as kept, at and day move.
    func testTimedInAnotherZone() {
        let due = reminderDue(components(2030, 3, 5, 8, 0, zone: "Asia/Tokyo"), mac: mac)!
        XCTAssertEqual(due.date, "2030-03-05")
        XCTAssertEqual(due.time, "08:00")
        XCTAssertEqual(due.timeZone, "Asia/Tokyo")
        XCTAssertEqual(due.at, instant("2030-03-04T23:00:00Z"))
        XCTAssertEqual(due.day, Day(year: 2030, month: 3, day: 4))
    }

    func testTimedInUTC() {
        let due = reminderDue(components(2030, 3, 4, 12, 0, zone: "UTC"), mac: mac)!
        XCTAssertEqual(due.time, "12:00")
        XCTAssertEqual(due.timeZone, "GMT")   // Foundation's name for the zone it reads as UTC
        XCTAssertEqual(due.at, instant("2030-03-04T12:00:00Z"))
    }

    func testFloatingIsTheClockTimeOfTheMac() {
        let due = reminderDue(components(2030, 3, 4, 9, 30), mac: mac)!
        XCTAssertEqual(due.time, "09:30")
        XCTAssertNil(due.timeZone)
        XCTAssertEqual(due.at, instant("2030-03-04T15:30:00Z"))
        var auckland = Calendar(identifier: .gregorian)
        auckland.timeZone = TimeZone(identifier: "Pacific/Auckland")!
        XCTAssertEqual(reminderDue(components(2030, 3, 4, 9, 30), mac: auckland)!.at, instant("2030-03-03T20:30:00Z"))
    }

    func testSecondsShowOnlyWhenNotZero() {
        XCTAssertEqual(reminderDue(components(2030, 3, 4, 9, 30, 15, zone: "UTC"), mac: mac)!.time, "09:30:15")
        XCTAssertEqual(reminderDue(components(2030, 3, 4, 9, 30, 15, zone: "UTC"), mac: mac)!.at,
                       instant("2030-03-04T09:30:15Z"))
        XCTAssertEqual(reminderDue(components(2030, 3, 4, 9, 30, 0, zone: "UTC"), mac: mac)!.time, "09:30")
    }

    func testHourWithoutMinute() {
        let due = reminderDue(components(2030, 3, 4, 9, zone: "UTC"), mac: mac)!
        XCTAssertEqual(due.time, "09:00")
        XCTAssertEqual(due.at, instant("2030-03-04T09:00:00Z"))
    }

    func testOtherComponentsAreIgnored() {
        var parts = components(2030, 3, 4, 9, 30, zone: "UTC")
        parts.era = 0
        parts.nanosecond = 500
        parts.weekday = 1
        XCTAssertEqual(reminderDue(parts, mac: mac)!.at, instant("2030-03-04T09:30:00Z"))
    }

    // Calendar would roll these into another day; the date stays as kept and there is no moment.
    func testComponentsThatNameNoMoment() {
        for parts in [components(2030, 2, 30, 9, 0, zone: "UTC"), components(2030, 13, 1, 9, 0, zone: "UTC"),
                      components(2030, 3, 4, 24, 0, zone: "UTC"), components(2030, 3, 4, 9, 60)] {
            let due = reminderDue(parts, mac: mac)!
            XCTAssertNil(due.at)
            XCTAssertNotNil(due.time)
            XCTAssertEqual(due.day, Day(year: parts.year!, month: parts.month!, day: parts.day!))
        }
        XCTAssertEqual(reminderDue(components(2030, 2, 30), mac: mac)!.date, "2030-02-30")
    }

    // 02:30 on the night Chicago's clocks go forward is skipped: the system reads it as 03:30, and so does at.
    func testAClockTimeTheZoneSkipsReadsAnHourLater() {
        let due = reminderDue(components(2030, 3, 10, 2, 30, zone: "America/Chicago"), mac: mac)!
        XCTAssertEqual(due.time, "02:30")
        XCTAssertEqual(due.at, instant("2030-03-10T08:30:00Z"))          // 03:30 at -05:00
        // The hour that comes twice in autumn names a moment as it is.
        XCTAssertNotNil(reminderDue(components(2030, 11, 3, 1, 30, zone: "America/Chicago"), mac: mac)!.at)
    }

    // MARK: priority

    func testPriorityWords() {
        XCTAssertEqual((0...9).map(priorityWord),
                       ["none", "high", "high", "high", "high", "medium", "low", "low", "low", "low"])
        XCTAssertEqual(priorityWord(-1), "none")
        XCTAssertEqual(priorityWord(10), "none")
    }

    // MARK: due filter

    private let dateOnly4 = Due(date: "2030-03-04", time: nil, timeZone: nil, at: nil,
                                day: Day(year: 2030, month: 3, day: 4))

    private func timed(_ at: String) -> Due {
        let date = instant(at)
        return Due(date: "", time: "00:00", timeZone: "UTC", at: date, day: Day(date, in: mac))
    }

    private func passes(_ due: Due?, _ from: String?, _ to: String?) -> Bool {
        dueInRange(due, from: from.map(instant), to: to.map(instant), mac: mac)
    }

    func testWithoutBoundsEveryReminderPasses() {
        XCTAssertTrue(passes(nil, nil, nil))
        XCTAssertTrue(passes(dateOnly4, nil, nil))
        XCTAssertTrue(passes(timed("2030-03-04T15:00:00Z"), nil, nil))
    }

    func testWithABoundAnUndatedReminderIsLeftOut() {
        XCTAssertFalse(passes(nil, "2030-03-04T06:00:00Z", nil))
        XCTAssertFalse(passes(nil, nil, "2030-03-04T06:00:00Z"))
    }

    func testATimedDueGoesByItsMomentBothEndsIncluded() {
        let from = "2030-03-04T15:00:00Z", to = "2030-03-04T16:00:00Z"
        XCTAssertTrue(passes(timed(from), from, to))
        XCTAssertTrue(passes(timed(to), from, to))
        XCTAssertFalse(passes(timed("2030-03-04T14:59:59Z"), from, to))
        XCTAssertFalse(passes(timed("2030-03-04T16:00:01Z"), from, to))
        XCTAssertTrue(passes(timed("2031-01-01T00:00:00Z"), from, nil))
        XCTAssertTrue(passes(timed("2029-01-01T00:00:00Z"), nil, to))
        // One bound alone still bounds.
        XCTAssertFalse(passes(timed("2030-03-04T14:59:59Z"), from, nil))
        XCTAssertTrue(passes(timed(from), from, nil))
        XCTAssertTrue(passes(timed(to), nil, to))
        XCTAssertFalse(passes(timed("2030-03-04T16:00:01Z"), nil, to))
    }

    // Chicago's 4 March runs from 06:00Z on the 4th to 06:00Z on the 5th.
    func testADateOnlyDueGoesByItsDayWhateverTimeTheBoundsHave() {
        XCTAssertTrue(passes(dateOnly4, "2030-03-04T22:00:00Z", "2030-03-04T22:00:00Z"))   // 16:00 that day
        XCTAssertTrue(passes(dateOnly4, "2030-03-05T05:59:59Z", nil))                      // 23:59:59 that day
        XCTAssertFalse(passes(dateOnly4, "2030-03-05T06:00:00Z", nil))                     // the next day
        XCTAssertTrue(passes(dateOnly4, nil, "2030-03-04T06:00:00Z"))                      // midnight that day
        XCTAssertFalse(passes(dateOnly4, nil, "2030-03-04T05:59:59Z"))                     // the day before
        XCTAssertTrue(passes(dateOnly4, "2030-03-01T06:00:00Z", "2030-03-09T06:00:00Z"))
    }

    func testABareEndDateIncludesThatWholeDay() throws {
        let to = try parseEnd("2030-03-04")
        let late = Calendar.current.date(bySettingHour: 23, minute: 59, second: 0, of: try parseDate("2030-03-04"))!
        let lateDue = Due(date: "", time: "23:59", timeZone: nil, at: late, day: Day(late, in: Calendar.current))
        XCTAssertTrue(dueInRange(lateDue, from: nil, to: to, mac: Calendar.current))
        let next = try parseDate("2030-03-05")
        let nextDue = Due(date: "", time: "00:00", timeZone: nil, at: next, day: Day(next, in: Calendar.current))
        XCTAssertFalse(dueInRange(nextDue, from: nil, to: to, mac: Calendar.current))
    }

    func testATimeWithNoMomentGoesByItsDate() {
        let noMoment = Due(date: "2030-03-04", time: "09:60", timeZone: nil, at: nil,
                           day: Day(year: 2030, month: 3, day: 4))
        XCTAssertTrue(passes(noMoment, "2030-03-04T22:00:00Z", "2030-03-04T22:00:00Z"))
        XCTAssertFalse(passes(noMoment, "2030-03-05T22:00:00Z", nil))
    }

    // MARK: order

    private func reminder(_ id: String, due: Due? = nil, created: String? = nil, title: String = "Pay rent",
                          listId: String = "list-a") -> Reminder {
        Reminder(id: id, title: title, list: "Home", listId: listId, notes: nil, due: due, priority: "none",
                 completed: false, completedAt: nil, created: created.map(instant), modified: nil, recurring: false)
    }

    private func assertOrder(_ expected: [Reminder], file: StaticString = #filePath, line: UInt = #line) {
        let ids = expected.map(\.id)
        XCTAssertEqual(expected.sorted(by: reminderPrecedes).map(\.id), ids, file: file, line: line)
        XCTAssertEqual(expected.reversed().sorted(by: reminderPrecedes).map(\.id), ids, file: file, line: line)
        var generator = SeededGenerator()
        for _ in 0..<20 {
            XCTAssertEqual(expected.shuffled(using: &generator).sorted(by: reminderPrecedes).map(\.id), ids,
                           file: file, line: line)
        }
    }

    // Ids run against the order, so only the rule named decides each step.
    func testOrder() {
        let noMoment = Due(date: "2030-03-04", time: "09:60", timeZone: nil, at: nil,
                           day: Day(year: 2030, month: 3, day: 4))
        assertOrder([
            reminder("k", due: timed("2030-03-03T23:00:00Z")),                 // 3 March in Chicago
            reminder("j", due: dateOnly4),                                     // date only before a time that day
            reminder("i", due: timed("2030-03-04T06:00:00Z")),                 // 00:00 on the 4th
            reminder("h", due: timed("2030-03-04T15:00:00Z"), title: "A"),
            reminder("g", due: timed("2030-03-04T15:00:00Z"), title: "B"),      // the same moment: title
            reminder("f", due: timed("2030-03-05T05:00:00Z")),                 // 23:00 on the 4th in Chicago
            reminder("e", due: noMoment),                                      // a time with no moment, last that day
            reminder("d", due: Due(date: "2030-03-05", time: nil, timeZone: nil, at: nil,
                                   day: Day(year: 2030, month: 3, day: 5))),
            reminder("c", created: "2030-02-01T00:00:00Z"),                    // undated, newest created first
            reminder("b", created: "2030-01-01T00:00:00Z"),
            reminder("a2", listId: "list-a"),                                  // no created date last
            reminder("a1", listId: "list-b"),                                  // a tie: list id
        ])
    }

    func testATieGoesToTitleThenListThenIdByBytes() {
        assertOrder([
            reminder("z", title: "Cafe\u{301}"),        // by bytes: "e" before the two bytes of é
            reminder("y", title: "Caf\u{E9}"),
            reminder("x", title: "f", listId: "list-a"),
            reminder("w", title: "f", listId: "list-b"),
            reminder("v1", title: "g"),
            reminder("v2", title: "g"),
        ])
    }

    // Times are printed to the second, so a fraction of one never decides the order: the title does.
    func testTimesAreOrderedToTheSecondAsPrinted() {
        func undated(_ id: String, _ title: String, created: Double) -> Reminder {
            Reminder(id: id, title: title, list: "Home", listId: "list-a", notes: nil, due: nil, priority: "none",
                     completed: false, completedAt: nil, created: Date(timeIntervalSince1970: created), modified: nil,
                     recurring: false)
        }
        // b was created later within the same second; a newer second still comes first.
        assertOrder([undated("c", "Zed", created: 1_800_000_001.1),
                     undated("a", "Ann", created: 1_800_000_000.2), undated("b", "Bob", created: 1_800_000_000.9)])
        func timed(_ id: String, _ title: String, at: Double) -> Reminder {
            let moment = Date(timeIntervalSince1970: at)
            let due = Due(date: "2027-01-15", time: "09:00", timeZone: nil, at: moment, day: Day(year: 2027, month: 1, day: 15))
            return Reminder(id: id, title: title, list: "Home", listId: "list-a", notes: nil, due: due, priority: "none",
                            completed: false, completedAt: nil, created: nil, modified: nil, recurring: false)
        }
        assertOrder([timed("a", "Ann", at: 1_800_000_000.9), timed("b", "Bob", at: 1_800_000_000.2),
                     timed("c", "Ann", at: 1_800_000_001.0)])
    }

    // What is printed is the second the time falls in, never the next one, so it agrees with the order.
    func testATimeIsPrintedAsTheSecondItFallsIn() {
        let late = Date(timeIntervalSince1970: 1_800_000_000.9999)
        XCTAssertEqual(reminderISO(late), reminderISO(Date(timeIntervalSince1970: 1_800_000_000)))
        XCTAssertNotEqual(reminderISO(late), reminderISO(Date(timeIntervalSince1970: 1_800_000_001)))
        XCTAssertEqual(wholeSecond(Date(timeIntervalSince1970: -0.5)), -1)
        XCTAssertEqual(reminderISO(Date(timeIntervalSince1970: -0.5)), reminderISO(Date(timeIntervalSince1970: -1)))
    }

    func testAReminderDoesNotPrecedeItself() {
        XCTAssertFalse(reminderPrecedes(reminder("a"), reminder("a")))
        XCTAssertFalse(reminderPrecedes(reminder("a", due: dateOnly4), reminder("a", due: dateOnly4)))
    }

    // MARK: JSON

    func testEveryKeyIsAlwaysThere() throws {
        let undated = try JSONSerialization.jsonObject(with: JSONEncoder().encode(reminder("a"))) as! [String: Any]
        XCTAssertEqual(Set(undated.keys), ["id", "title", "list", "listId", "notes", "due", "priority", "completed",
                                           "completedAt", "created", "modified", "recurring"])
        XCTAssertTrue(undated["due"] is NSNull)
        XCTAssertTrue(undated["notes"] is NSNull)
        XCTAssertTrue(undated["created"] is NSNull)
        let due = try JSONSerialization.jsonObject(with: JSONEncoder().encode(dateOnly4)) as! [String: Any]
        XCTAssertEqual(Set(due.keys), ["date", "time", "timeZone", "at"])
        XCTAssertTrue(due["at"] is NSNull)
    }
}

/// The same shuffles on every run.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64 = 0x2545F4914F6CDD1D

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}
