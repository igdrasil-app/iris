import EventKit
import XCTest
@testable import iris

final class AvailabilityTests: XCTestCase {
    func testSupportedValues() {
        XCTAssertEqual(availabilities(in: []), [])
        XCTAssertEqual(availabilities(in: .busy), [.busy])
        XCTAssertEqual(availabilities(in: .free), [.free])
        XCTAssertEqual(availabilities(in: [.busy, .free]), [.busy, .free])
        XCTAssertEqual(availabilities(in: .tentative), [.tentative])
        XCTAssertEqual(availabilities(in: .unavailable), [.unavailable])
        XCTAssertEqual(availabilities(in: [.busy, .free, .tentative, .unavailable]),
                       [.busy, .free, .tentative, .unavailable])
    }

    func testEveryValueIsDescribedAsItIsParsed() throws {
        for text in ["busy", "free", "tentative", "unavailable"] {
            XCTAssertEqual(describe(try parseAvailability(text)), text)
        }
        XCTAssertEqual(describe(EKEventAvailability.notSupported), "not supported")
    }
}
