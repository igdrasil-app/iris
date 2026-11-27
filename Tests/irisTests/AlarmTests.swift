import EventKit
import XCTest
@testable import iris

final class AlarmTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testMinutesBeforeTheStart() {
        let alarms = [
            EKAlarm(relativeOffset: -15 * 60),
            EKAlarm(relativeOffset: 0),
            EKAlarm(relativeOffset: -24 * 60 * 60),
            EKAlarm(relativeOffset: -15 * 60),
            EKAlarm(relativeOffset: 9 * 60 * 60),                     // after the start, as all-day alerts often are
        ]
        XCTAssertEqual(alarmMinutes(alarms, start: start), [1440, 15, 15, 0, -540])
        XCTAssertEqual(alarmMinutes([], start: start), [])
    }

    func testAlarmAtATime() {
        let alarms = [
            EKAlarm(absoluteDate: start.addingTimeInterval(-30 * 60)),
            EKAlarm(absoluteDate: start.addingTimeInterval(10 * 60)),
            EKAlarm(absoluteDate: start),
        ]
        XCTAssertEqual(alarmMinutes(alarms, start: start), [30, 0, -10])
    }

    func testSecondsRoundToTheNearestMinute() {
        let alarms = [
            EKAlarm(relativeOffset: -89),
            EKAlarm(relativeOffset: -91),
            EKAlarm(absoluteDate: start.addingTimeInterval(-29)),
            EKAlarm(absoluteDate: start.addingTimeInterval(100)),
        ]
        XCTAssertEqual(alarmMinutes(alarms, start: start), [2, 1, 0, -2])
        // Half a minute rounds away from zero.
        let halves = [EKAlarm(relativeOffset: 30), EKAlarm(relativeOffset: -30), EKAlarm(relativeOffset: -90)]
        XCTAssertEqual(alarmMinutes(halves, start: start), [2, 1, -1])
    }

    func testAlarmWithNoUsableTimeIsLeftOut() {
        let alarms = [EKAlarm(relativeOffset: .nan), EKAlarm(relativeOffset: .infinity), EKAlarm(relativeOffset: -600)]
        XCTAssertEqual(alarmMinutes(alarms, start: start), [10])
    }

    func testLocationAlarmIsLeftOut() {
        let location = EKAlarm(relativeOffset: 0)
        location.structuredLocation = EKStructuredLocation(title: "Home")
        location.proximity = .enter
        // A place without a proximity trigger, as a travel-time alert has, still fires at its time.
        let timed = EKAlarm(relativeOffset: -300)
        timed.structuredLocation = EKStructuredLocation(title: "Office")
        XCTAssertEqual(alarmMinutes([location, timed], start: start), [5])
        location.proximity = .leave
        XCTAssertEqual(alarmMinutes([location, timed], start: start), [5])
    }

    func testReminderAlarmsCountFromTheDueInTheirOwnOrder() {
        let alarms = [
            EKAlarm(absoluteDate: start),
            EKAlarm(absoluteDate: start.addingTimeInterval(-10 * 60 - 29)),
            EKAlarm(absoluteDate: start.addingTimeInterval(5 * 60)),   // after the due
            EKAlarm(relativeOffset: -15 * 60),
        ]
        // A fixed alarm reads back relativeOffset 0 too: only absoluteDate tells it from one at the due.
        XCTAssertEqual(reminderAlarmMinutes(alarms, due: start), [0, 10, -5, 15])
        // No moment to count from: a fixed alarm is left out, a relative one is not.
        XCTAssertEqual(reminderAlarmMinutes(alarms, due: nil), [15])
        XCTAssertEqual(reminderAlarmMinutes([], due: start), [])
    }

    func testReminderLocationAlarmIsLeftOut() {
        let arriving = EKAlarm(relativeOffset: 0)
        arriving.structuredLocation = EKStructuredLocation(title: "Home")
        arriving.proximity = .enter
        let placeOnly = EKAlarm(absoluteDate: start)
        placeOnly.structuredLocation = EKStructuredLocation(title: "Office")
        let proximityOnly = EKAlarm(relativeOffset: 0)
        proximityOnly.proximity = .leave
        XCTAssertEqual(reminderAlarmMinutes([arriving, placeOnly, proximityOnly, EKAlarm(absoluteDate: start)], due: start), [0])
    }
}
