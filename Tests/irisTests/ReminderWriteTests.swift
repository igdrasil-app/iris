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

    private func addRefusal(_ args: [String]) -> String? {
        do {
            _ = try AddReminder.parse(["--list", "unused", "--title", "x"] + args)
            return nil
        } catch {
            return AddReminder.message(for: error)
        }
    }

    func testAddTakesTheRepeatOptionsOnlyTogether() {
        let refused: [([String], String)] = [
            (["--repeat", "daily"], "--repeat needs --due"),
            (["--due", "2030-03-04", "--every", "2"], "need --repeat"),
            (["--due", "2030-03-04", "--on", "mo"], "need --repeat"),
            (["--due", "2030-03-04", "--until", "2030-04-01"], "need --repeat"),
            (["--due", "2030-03-04", "--count", "2"], "need --repeat"),
            (["--due", "2030-03-04", "--repeat", "daily", "--on", "mo"], "--on only works with --repeat weekly"),
            (["--due", "2030-03-04", "--repeat", "daily", "--until", "2030-04-01", "--count", "2"], "not both"),
            (["--due", "2030-03-04", "--repeat", "daily", "--every", "0"], "--every must be 1 or more"),
            (["--due", "2030-03-04", "--repeat", "daily", "--count", "0"], "--count must be 1 or more"),
            (["--due", "2030-03-04", "--repeat", "hourly"], "--repeat must be"),
            (["--due", "2030-03-04", "--repeat", "weekly", "--on", "mo,xx"], "--on takes"),
            (["--due", "2030-03-04", "--repeat", "daily", "--until", "soon"], "unrecognised date"),
        ]
        for (args, words) in refused {
            let message = addRefusal(args)
            XCTAssertTrue(message?.contains(words) == true, "\(args): \(message ?? "accepted")")
        }
        let accepted = [
            ["--due", "2030-03-04", "--repeat", "daily"],
            ["--due", "2030-03-04T09:30", "--repeat", "weekly", "--every", "2", "--on", "we,fr", "--count", "3"],
            ["--due", "2030-03-04", "--repeat", "monthly", "--until", "2030-12-31"],
            ["--due", "2030-03-04", "--repeat", "yearly", "--count", "1"],
        ]
        for args in accepted { XCTAssertNil(addRefusal(args), "\(args)") }
    }

    // Measured on a Mac: an end date is compared with a date-only occurrence as the start of its day, and with
    // a timed one as its moment, the end itself included.
    func testUntilMayNotEndBeforeTheFirstOccurrence() {
        let before = "--until must not be before --due"
        XCTAssertEqual(addRefusal(["--due", "2030-03-04", "--repeat", "daily", "--until", "2030-03-03"]), before)
        XCTAssertEqual(addRefusal(["--due", "2030-03-04", "--repeat", "daily", "--until", "2030-03-03T23:59"]), before)
        XCTAssertNil(addRefusal(["--due", "2030-03-04", "--repeat", "daily", "--until", "2030-03-04"]))
        XCTAssertNil(addRefusal(["--due", "2030-03-04", "--repeat", "daily", "--until", "2030-03-04T00:00"]))
        XCTAssertEqual(addRefusal(["--due", "2030-03-04T09:30", "--repeat", "daily", "--until", "2030-03-04T09:29"]), before)
        XCTAssertNil(addRefusal(["--due", "2030-03-04T09:30", "--repeat", "daily", "--until", "2030-03-04T09:30"]))
    }

    func testTheFirstOccurrenceOfADue() throws {
        let day = firstOccurrence(try dueComponents("2030-03-04", mac: mac), mac: mac)
        XCTAssertEqual(day, instant("2030-03-04T06:00:00Z"))
        let timed = firstOccurrence(try dueComponents("2030-03-04T09:30-06:00", mac: mac), mac: mac)
        XCTAssertEqual(timed, instant("2030-03-04T15:30:00Z"))
    }

    func testTheRuleTheRepeatOptionsMake() throws {
        let end = instant("2030-12-31T23:59:59Z")
        let rule = try recurrenceRule("weekly", every: 2, on: "we,fr", until: end, count: nil)
        XCTAssertEqual(rule.frequency, .weekly)
        XCTAssertEqual(rule.interval, 2)
        XCTAssertEqual(rule.daysOfTheWeek?.map(\.dayOfTheWeek), [.wednesday, .friday])
        XCTAssertEqual(rule.recurrenceEnd?.endDate, end)
        let counted = try recurrenceRule("daily", every: nil, on: nil, until: nil, count: 3)
        XCTAssertEqual(counted.interval, 1)
        XCTAssertNil(counted.daysOfTheWeek)
        XCTAssertEqual(counted.recurrenceEnd?.occurrenceCount, 3)
        XCTAssertNil(try recurrenceRule("monthly", every: nil, on: nil, until: nil, count: nil).recurrenceEnd)
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

    func testCompletingAReminderThatDoesNotRepeat() {
        func step(completed: Bool, undo: Bool) -> CompletionStep {
            completionStep(repeats: false, completed: completed, undo: undo, occurrence: nil, due: "2030-03-04")
        }
        XCTAssertEqual(step(completed: false, undo: false), .mark(completed: true))
        XCTAssertEqual(step(completed: true, undo: false), .nothing)
        XCTAssertEqual(step(completed: true, undo: true), .mark(completed: false))
        XCTAssertEqual(step(completed: false, undo: true), .nothing)
        guard case .refuse(let reason) = completionStep(repeats: false, completed: false, undo: false,
                                                        occurrence: "2030-03-04", due: "2030-03-04") else {
            return XCTFail("an occurrence on a reminder that does not repeat must be refused")
        }
        XCTAssertTrue(reason.contains("does not repeat"))
    }

    func testCompletingARepeatingReminder() {
        func step(completed: Bool = false, undo: Bool = false, occurrence: String?, due: String? = "2030-03-04") -> CompletionStep {
            completionStep(repeats: true, completed: completed, undo: undo, occurrence: occurrence, due: due)
        }
        XCTAssertEqual(step(occurrence: "2030-03-04"), .mark(completed: true))
        // A series that has ended is the reminder itself, completed: again changes nothing, undo opens it.
        XCTAssertEqual(step(completed: true, occurrence: "2030-03-04"), .nothing)
        XCTAssertEqual(step(completed: true, occurrence: nil), .nothing)
        XCTAssertEqual(step(completed: true, occurrence: "2030-03-03"), .nothing)
        XCTAssertEqual(step(completed: true, undo: true, occurrence: nil), .mark(completed: false))
        // The same without a due date: an ended series is left as it is before anything is asked of its due.
        for occurrence in [nil, "2030-03-04", "2030-03-03"] as [String?] {
            XCTAssertEqual(step(completed: true, occurrence: occurrence, due: nil), .nothing)
        }
        XCTAssertEqual(step(completed: true, undo: true, occurrence: nil, due: nil), .mark(completed: false))

        let refusals: [(CompletionStep, String)] = [
            (step(occurrence: nil), "--occurrence 2030-03-04"),
            (step(occurrence: "2030-03-03"), "due 2030-03-04, not 2030-03-03"),
            (step(undo: true, occurrence: nil), "nothing to undo"),
            (step(occurrence: "2030-03-04", due: nil), "no due date"),
        ]
        for (result, words) in refusals {
            guard case .refuse(let reason) = result else { XCTFail("\(words): not refused"); continue }
            XCTAssertTrue(reason.contains(words), reason)
            XCTAssertTrue(reason.contains("nothing") , reason)
        }
    }

    private func reminder(_ id: String, due: String?) -> Reminder {
        Reminder(id: id, title: "t", list: "l", listId: "L", notes: nil,
                 due: due.flatMap { reminderDue(try? dueComponents($0, mac: mac), mac: mac) }, priority: "none",
                 completed: true, completedAt: nil, created: nil, modified: nil, recurring: false)
    }

    func testTheOccurrenceCompletedIsTheOneNewCompletedReminder() {
        let before: Set<String> = ["old"]
        let old = reminder("old", due: "2030-03-01")
        let copy = reminder("copy", due: "2030-03-04")
        XCTAssertEqual(completedOccurrence(before: before, after: [old, copy], saved: "series", occurrence: "2030-03-04")?.id, "copy")
        // None, two, one on another date, or the reminder saved itself: not told apart for certain.
        XCTAssertNil(completedOccurrence(before: before, after: [old], saved: "series", occurrence: "2030-03-04"))
        XCTAssertNil(completedOccurrence(before: before, after: [old, copy, reminder("other", due: "2030-03-04")],
                                         saved: "series", occurrence: "2030-03-04"))
        XCTAssertNil(completedOccurrence(before: before, after: [copy], saved: "series", occurrence: "2030-03-05"))
        XCTAssertNil(completedOccurrence(before: before, after: [reminder("series", due: "2030-03-04")],
                                         saved: "series", occurrence: "2030-03-04"))
    }

    func testCompleteTakesAnOccurrenceOnlyAsADate() {
        XCTAssertNoThrow(try CompleteReminder.parse(["some-id"]))
        XCTAssertNoThrow(try CompleteReminder.parse(["some-id", "--undo"]))
        XCTAssertNoThrow(try CompleteReminder.parse(["some-id", "--occurrence", "2030-03-04"]))
        for bad in ["2030-3-4", "2030-03-04T09:00", "2030-02-30", "tomorrow", "", "10000-03-04"] {
            XCTAssertThrowsError(try CompleteReminder.parse(["some-id", "--occurrence", bad]), bad)
        }
        XCTAssertThrowsError(try CompleteReminder.parse(["some-id", "--undo", "--occurrence", "2030-03-04"]))
    }

    func testCompletePrintsTheKeysOfListAndTheOccurrence() throws {
        let encoder = JSONEncoder()
        func keys(_ value: CompletedReminder) throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: encoder.encode(value)) as! [String: Any]
        }
        let plain = try keys(CompletedReminder(reminder: reminder("a", due: nil), completedOccurrence: nil))
        XCTAssertEqual(Set(plain.keys), ["id", "title", "list", "listId", "notes", "due", "priority", "completed",
                                         "completedAt", "created", "modified", "recurring", "completedOccurrence"])
        XCTAssertTrue(plain["completedOccurrence"] is NSNull)
        let done = try keys(CompletedReminder(reminder: reminder("a", due: nil), completedOccurrence: reminder("b", due: nil)))
        let nested = try XCTUnwrap(done["completedOccurrence"] as? [String: Any])
        XCTAssertEqual(nested["id"] as? String, "b")
        XCTAssertEqual(Set(nested.keys), Set(plain.keys).subtracting(["completedOccurrence"]))
        XCTAssertEqual(done.count, 13)
    }

    func testTitle() {
        XCTAssertTrue(isValidTitle("Buy milk"))
        XCTAssertTrue(isValidTitle(" x "))
        XCTAssertFalse(isValidTitle(""))
        XCTAssertFalse(isValidTitle("   "))
        XCTAssertFalse(isValidTitle(" \n\t "))
    }
}
