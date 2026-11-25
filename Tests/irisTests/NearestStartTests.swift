import XCTest
@testable import iris

// --occurrence with a time takes the occurrence nearest it that day; when that is not one, nothing is taken.
final class NearestStartTests: XCTestCase {
    private func at(_ hour: Double) -> Date { Date(timeIntervalSince1970: 1_800_000_000 + hour * 3600) }

    func testNone() {
        XCTAssertEqual(nearestStart([], to: at(11)), .none)
    }

    func testOneCandidate() {
        XCTAssertEqual(nearestStart([at(10)], to: at(11)), .unique(0))
        XCTAssertEqual(nearestStart([at(10)], to: at(10)), .unique(0))
    }

    func testUniqueNearestBeforeOrAfter() {
        XCTAssertEqual(nearestStart([at(10), at(12)], to: at(10.5)), .unique(0))
        XCTAssertEqual(nearestStart([at(10), at(12)], to: at(11.5)), .unique(1))
        XCTAssertEqual(nearestStart([at(12), at(10)], to: at(11.5)), .unique(0))
    }

    func testExactMatchBesideAFartherOne() {
        XCTAssertEqual(nearestStart([at(10), at(12)], to: at(12)), .unique(1))
    }

    func testEquallyNearOnEitherSide() {
        XCTAssertEqual(nearestStart([at(10), at(12)], to: at(11)), .tie)
        XCTAssertEqual(nearestStart([at(12), at(10)], to: at(11)), .tie)
    }

    func testSameStart() {
        XCTAssertEqual(nearestStart([at(10), at(10)], to: at(10)), .tie)
        XCTAssertEqual(nearestStart([at(10), at(10)], to: at(9)), .tie)
    }

    func testThreeWithTwoTiedForNearest() {
        XCTAssertEqual(nearestStart([at(15), at(10), at(12)], to: at(11)), .tie)
    }

    func testThreeWithUniqueNearestAndTwoTiedFarther() {
        XCTAssertEqual(nearestStart([at(9), at(13), at(11.5)], to: at(11)), .unique(2))
    }

    func testThreeTiedForNearest() {
        XCTAssertEqual(nearestStart([at(10), at(12), at(12)], to: at(11)), .tie)
    }
}
