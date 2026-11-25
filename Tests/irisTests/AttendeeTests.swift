import EventKit
import XCTest
@testable import iris

final class AttendeeTests: XCTestCase {
    func testStatusWords() {
        XCTAssertEqual(describe(EKParticipantStatus.accepted), "accepted")
        XCTAssertEqual(describe(EKParticipantStatus.declined), "declined")
        XCTAssertEqual(describe(EKParticipantStatus.tentative), "tentative")
        XCTAssertEqual(describe(EKParticipantStatus.pending), "pending")
        XCTAssertEqual(describe(EKParticipantStatus.delegated), "delegated")
        XCTAssertEqual(describe(EKParticipantStatus.completed), "completed")
        XCTAssertEqual(describe(EKParticipantStatus.inProcess), "in process")
        XCTAssertEqual(describe(EKParticipantStatus.unknown), "unknown")
        XCTAssertEqual(describe(EKParticipantStatus(rawValue: 99)!), "unknown")   // a case added later
    }

    func testRoleWords() {
        XCTAssertEqual(describe(EKParticipantRole.required), "required")
        XCTAssertEqual(describe(EKParticipantRole.optional), "optional")
        XCTAssertEqual(describe(EKParticipantRole.chair), "chair")
        XCTAssertEqual(describe(EKParticipantRole.nonParticipant), "non-participant")
        XCTAssertEqual(describe(EKParticipantRole.unknown), "unknown")
        XCTAssertEqual(describe(EKParticipantRole(rawValue: 99)!), "unknown")
    }

    func testTypeWords() {
        XCTAssertEqual(describe(EKParticipantType.person), "person")
        XCTAssertEqual(describe(EKParticipantType.room), "room")
        XCTAssertEqual(describe(EKParticipantType.resource), "resource")
        XCTAssertEqual(describe(EKParticipantType.group), "group")
        XCTAssertEqual(describe(EKParticipantType.unknown), "unknown")
        XCTAssertEqual(describe(EKParticipantType(rawValue: 99)!), "unknown")
    }

    func testEmailOnlyFromAMailtoURL() {
        XCTAssertEqual(emailAddress(URL(string: "mailto:ada@example.com")), "ada@example.com")
        XCTAssertEqual(emailAddress(URL(string: "mailto:ada%2Blists@example.com")), "ada+lists@example.com")
        XCTAssertEqual(emailAddress(URL(string: "mailto:Ada%20Room@example.com")), "Ada Room@example.com")
        XCTAssertEqual(emailAddress(URL(string: "MAILTO:ada@example.com")), "ada@example.com")
        XCTAssertEqual(emailAddress(URL(string: "mailto:ada@example.com?subject=Hi")), "ada@example.com")
        XCTAssertNil(emailAddress(URL(string: "mailto:")))
        XCTAssertNil(emailAddress(URL(string: "https://example.com/principals/ada@example.com")))
        XCTAssertNil(emailAddress(URL(string: "urn:uuid:00000000-0000-0000-0000-000000000000")))
        XCTAssertNil(emailAddress(URL(string: "/principals/ada@example.com")))
        XCTAssertNil(emailAddress(nil))
    }

    func testStringValueOnlyWhenTheObjectHasAString() {
        XCTAssertNil(stringValue(of: NSObject(), forKey: "emailAddress"))
        XCTAssertNil(stringValue(of: NumberHolder(), forKey: "emailAddress"))
        XCTAssertEqual(stringValue(of: StringHolder(), forKey: "emailAddress"), "ada@example.com")
    }

    // Reading either of these by key would raise an Objective-C exception and stop the process.
    func testStringValueRefusesAGetterThatReturnsNoObject() {
        XCTAssertTrue(PointerHolder().responds(to: NSSelectorFromString("emailAddress")))
        XCTAssertNil(stringValue(of: PointerHolder(), forKey: "emailAddress"))
    }

    func testStringValueRefusesAMethodThatTakesAnArgument() {
        // A method named emailAddress whose signature says it takes an argument, as only the runtime can make.
        let body: @convention(block) (AnyObject, AnyObject?) -> AnyObject? = { _, _ in "ada@example.com" as NSString }
        class_addMethod(ArgumentHolder.self, NSSelectorFromString("emailAddress"),
                        imp_implementationWithBlock(body), "@@:@")
        XCTAssertTrue(ArgumentHolder().responds(to: NSSelectorFromString("emailAddress")))
        XCTAssertNil(stringValue(of: ArgumentHolder(), forKey: "emailAddress"))
    }

    func testMailtoWinsThenAWellShapedProperty() {
        XCTAssertEqual(participantEmail(mailto: "ada@example.com", property: "bob@example.com"), "ada@example.com")
        XCTAssertEqual(participantEmail(mailto: "ada@example.com", property: "not an address"), "ada@example.com")
        XCTAssertEqual(participantEmail(mailto: nil, property: "bob@example.com"), "bob@example.com")
        XCTAssertNil(participantEmail(mailto: nil, property: "Bob <bob@example.com>"))
        XCTAssertNil(participantEmail(mailto: nil, property: nil))
    }

    func testPlainAddressAccepts() {
        for address in ["ada@example.com", "Ada@Example.COM", "ada+lists@example.com", "ada.l.k@mail.example.com",
                        "adé@exämple.com", "ada@x"] {
            XCTAssertEqual(plainAddress(address), address)
        }
    }

    func testPlainAddressRefuses() {
        for text in [
            "", "ada.example.com", "ada@@example.com", "ada@b@example.com", "@example.com", "ada@",
            "a@\u{301}b@example.com",                                                         // a second "@"
            "ada @example.com", "ada@example.com\n", "ada\t@example.com", "ada@exa\u{7}mple.com",
            "ada@exa\u{0}mple.com", "ada\u{200B}@example.com", "ada\u{202E}@example.com", "\u{FEFF}ada@example.com",
            "mailto:ada@example.com", "a:\u{301}@example.com", "Ada <ada@example.com>", "<ada@example.com>",
            "Ada<ada@example.com>", "a,b@example.com", "a;b@example.com", "//host/path@x", "a\\b@example.com",
            "\"ada\"@example.com", "ada@example.com.", "ada@.example.com",
        ] {
            XCTAssertNil(plainAddress(text), text.debugDescription)
        }
    }

    // The shape every caller reads: the two keys are always there, organizer null and attendees [] when
    // there are none, and location and notes are still left out when empty.
    func testEventWithoutParticipantsKeepsItsShape() throws {
        let store = EKEventStore()
        let event = EKEvent(eventStore: store)
        event.calendar = EKCalendar(for: .event, eventStore: store)
        event.calendar.title = "Fixture"
        event.title = "Fixture"
        event.startDate = Date(timeIntervalSince1970: 1_800_000_000)
        event.endDate = event.startDate.addingTimeInterval(3600)
        event.location = ""
        event.notes = ""

        let data = try JSONEncoder().encode(EventInfo(event))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertTrue(json["organizer"] is NSNull)
        XCTAssertEqual((json["attendees"] as? [Any])?.count, 0)
        XCTAssertEqual(Set(json.keys), [
            "id", "title", "start", "end", "allDay", "calendar", "calendarId", "recurring", "detached",
            "availability", "alarms", "organizer", "attendees",
        ])
    }

    func testAttendeesSortByEmailThenNameWithMissingOnesLast() {
        let people: [(String?, String?)] = [
            (nil, "Zed"), ("b@example.com", nil), ("B@example.com", "Ann"), (nil, nil), ("a@example.com", "Zed"),
            (nil, "Ann"),
        ]
        let attendees = people.map { attendee(email: $0.0, name: $0.1) }
        let expected = ["a@example.com Zed", "B@example.com Ann", "b@example.com -", "- Ann", "- Zed", "- -"]
        XCTAssertEqual(sortedAttendees(attendees).map(label), expected)
        XCTAssertEqual(sortedAttendees(attendees.reversed()).map(label), expected)
    }

    // Equal in email and name, different in status: the order must not depend on the order read.
    func testAttendeesOrderDoesNotDependOnTheInput() {
        let attendees = [
            attendee(email: "ada@example.com", name: "Ada", status: "declined"),
            attendee(email: "ada@example.com", name: "Ada", status: "accepted"),
            attendee(email: "ADA@example.com", name: "Ada", status: "accepted"),
        ]
        let forward = sortedAttendees(attendees).map { "\($0.email ?? "-") \($0.status)" }
        XCTAssertEqual(forward, sortedAttendees(attendees.reversed()).map { "\($0.email ?? "-") \($0.status)" })
        XCTAssertEqual(forward, ["ADA@example.com accepted", "ada@example.com accepted", "ada@example.com declined"])
    }

    // Case folding makes these one email, so the name decides; lowercasing alone would not.
    func testAttendeesEmailIgnoresCaseByFolding() {
        let attendees = [attendee(email: "STRASSE@example.com", name: "Zed"), attendee(email: "straße@example.com", name: "Ann")]
        XCTAssertEqual(sortedAttendees(attendees).map(label), ["straße@example.com Ann", "STRASSE@example.com Zed"])
    }

    private func attendee(email: String?, name: String?, status: String = "accepted") -> Attendee {
        Attendee(name: name, email: email, status: status, role: "required", type: "person", isCurrentUser: false)
    }

    private func label(_ attendee: Attendee) -> String {
        "\(attendee.email ?? "-") \(attendee.name ?? "-")"
    }
}

private final class PointerHolder: NSObject {
    @objc var emailAddress: UnsafeRawPointer? { nil }
}

private final class ArgumentHolder: NSObject {}

private final class StringHolder: NSObject {
    @objc let emailAddress = "ada@example.com"
}

private final class NumberHolder: NSObject {
    @objc let emailAddress = NSNumber(value: 1)
}
