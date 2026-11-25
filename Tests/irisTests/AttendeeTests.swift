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
}
