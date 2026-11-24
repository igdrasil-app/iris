import XCTest
@testable import iris

final class MCPHTTPWritesTests: XCTestCase {
    func testDeleteReachesOneOccurrenceAtMost() throws {
        for passes: Any? in [nil, NSNull(), "this"] {
            var arguments: [String: Any] = ["id": "e1"]
            arguments["span"] = passes
            XCTAssertFalse(deletesPastOne(arguments), "\(String(describing: passes))")
        }
        let refused: [Any] = ["future", "Future", "FUTURE", " future", "future ", "this ", "This", "", "thi\u{0455}",
                              "this\u{0301}", "futur\u{0435}", ["future"], ["this"], 1, 0, true, false, ["span": "this"]]
        for value in refused {
            XCTAssertTrue(deletesPastOne(["id": "e1", "span": value]), "\(value)")
        }
        // Whatever passes is the default or "this", and the command reads only "future" as more than one.
        XCTAssertEqual(try DeleteEvent.parse(["e1"]).span, "this")
        for spelling in ["Future", " future", "future\n", "fu\u{0074}ure\u{200B}", "this "] {
            XCTAssertThrowsError(try parseSpan(spelling), spelling)
        }
    }

    func testSeeding() {
        let now = 1_800_000_000.0
        // Real ages, oldest first; one an hour old or older is gone.
        XCTAssertEqual(recentWriteAges("\(now - 3600)\n\(now - 3599)\n\(now - 10)\n", now: now), [3599, 10])
        // A time in the future counts as just made; garbage, infinities and blank lines are skipped.
        XCTAssertEqual(recentWriteAges("\(now + 500)\nnot a time\ninf\nnan\n\n-\n\(now - 5)\r\n", now: now), [5, 0])
        XCTAssertEqual(recentWriteAges("", now: now), [])
        // At most the limit, the newest kept.
        let many = (0..<30).map { "\(now - Double($0))" }.joined(separator: "\n")
        XCTAssertEqual(recentWriteAges(many, now: now), (0..<20).reversed().map(Double.init))
    }

    func testMinutesUntilNextWrite() {
        let full = Array(repeating: 1000.0, count: 20)
        XCTAssertNil(minutesUntilNextWrite(Array(full.dropFirst()), now: 1000))
        XCTAssertEqual(minutesUntilNextWrite(full, now: 1000), 60)
        XCTAssertEqual(minutesUntilNextWrite(full, now: 1000 + 3540), 1)      // exactly a minute left
        XCTAssertEqual(minutesUntilNextWrite(full, now: 1000 + 3599.9), 1)    // never zero
        XCTAssertNil(minutesUntilNextWrite(full, now: 1000 + 3600))
        // The write that has to age out is the 20th newest, not the oldest.
        XCTAssertEqual(minutesUntilNextWrite([0] + full, now: 1000), 60)
    }

    func testRecordedText() {
        XCTAssertTrue(recordedText(toolResult("{\"id\": \"e1\"}")) == (false, "{\"id\": \"e1\"}"))
        XCTAssertTrue(recordedText(toolResult("no event with id e1", isError: true)) == (true, "no event with id e1"))
        // Anything else is kept whole and marked an error.
        let odd: [[String: Any]] = [
            [:], ["content": "text"], ["content": [[:]]], ["content": [["type": "image", "data": "x"]]],
            ["content": [["type": "text", "text": 1]]], ["content": [["type": "text", "text": "x"]], "isError": "no"],
            ["content": [["type": "text", "text": "x"]], "isError": 0],
        ]
        for result in odd {
            let (error, text) = recordedText(result)
            XCTAssertTrue(error && text.hasPrefix("unexpected result: "), "\(result)")
        }
    }

    func testNewestLines() {
        let lines = Data("aaaa\nbbbb\ncccc\n".utf8)
        XCTAssertEqual(newestLines(lines, within: 10), Data("bbbb\ncccc\n".utf8))
        XCTAssertEqual(newestLines(lines, within: 100), lines)
        // The newest is kept whole even when it alone is larger.
        XCTAssertEqual(newestLines(Data("a\n0123456789\n".utf8), within: 4), Data("0123456789\n".utf8))
    }
}
