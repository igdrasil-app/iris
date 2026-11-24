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
        let boot = "11111111-2222-3333-4444-555555555555"
        let now = 10_000.0
        func saved(_ lines: [String]) -> [Double] { savedWriteTimes(lines.joined(separator: "\n"), boot: boot, now: now) }
        // This boot: the times as they are, oldest first; one a window old or older is gone, one ahead is now.
        XCTAssertEqual(saved([boot, "\(now - 3600)", "\(now - 10)", "\(now - 3599)", "\(now + 5)"]),
                       [now - 3599, now - 10, now])
        XCTAssertEqual(saved([]), [])
        XCTAssertEqual(saved([boot]), [])
        XCTAssertEqual(saved((0..<30).map { "\(now - Double($0))" }), Array(repeating: now, count: 20), "no boot line")
        XCTAssertEqual(saved([boot] + (0..<30).map { "\(now - Double($0))" }), (0..<20).reversed().map { now - Double($0) })
        // Another boot, no boot line, or anything unreadable: every entry counts as just made.
        let justMade = [now, now]
        XCTAssertEqual(saved(["99999999-2222-3333-4444-555555555555", "\(now - 3000)", "\(now - 4000)"]), justMade)
        XCTAssertEqual(saved(["\(now - 3000)", "\(now - 4000)"]), justMade)
        XCTAssertEqual(saved(["junk", "\(now - 3000)"]), justMade)
        XCTAssertEqual(saved([boot, "\(now - 3000)", "nan"]), justMade)
        XCTAssertEqual(saved([boot, "\(now - 3000)", "x"]), justMade)
        // A blank line is a line that is not a time; the file's own last newline, also as CRLF, is not a line.
        XCTAssertEqual(saved([boot, "", "\(now - 3000)"]), justMade)
        XCTAssertEqual(saved(["", boot, "\(now - 3000)"]).count, 3)
        XCTAssertEqual(savedWriteTimes("\(boot)\r\n\(now - 10)\r\n", boot: boot, now: now), [now - 10])
    }

    // WriteGuard itself, in a folder of its own, with a stand-in for the command: no Calendar.
    private func guarded() throws -> (WriteGuard, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("iris-test-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let guarding = try WriteGuard(stateDir: folder.path)
        guarding.seed()
        return (guarding, folder)
    }

    private func counted(_ folder: URL) throws -> Int {
        let text = try String(contentsOf: folder.appendingPathComponent("http-write-times"), encoding: .utf8)
        return text.split(separator: "\n").count - 1        // the first line is the boot session
    }

    private func tool(_ name: String) throws -> Tool { try XCTUnwrap(tools.first { $0.name == name }) }

    func testCountIsSavedBeforeTheCommandRuns() throws {
        let (guarding, folder) = try guarded()
        var marks: [String] = []
        var ran = false
        _ = try guarding.call(try tool("add_event"), [:], {
            ran = true
            XCTAssertEqual(try self.counted(folder), 1)
            return ToolCall(result: toolResult("{}"), started: true)
        }, marks: &marks)
        XCTAssertTrue(ran)
    }

    func testRefusalsNeverRunTheCommand() throws {
        let (guarding, folder) = try guarded()
        var marks: [String] = []
        let never: () throws -> ToolCall = { XCTFail("the command ran"); return ToolCall(result: [:]) }
        let result = try guarding.call(try tool("delete_event"), ["id": "e1", "span": "future"], never, marks: &marks)
        XCTAssertEqual(result["isError"] as? Bool, true)
        XCTAssertEqual(try counted(folder), 0, "a refused span is not counted")
        for _ in 0..<writesPerHour {
            _ = try guarding.call(try tool("update_event"), [:], { ToolCall(result: toolResult("no", isError: true), started: true) },
                                  marks: &marks)
        }
        let limited = try guarding.call(try tool("add_event"), [:], never, marks: &marks)
        XCTAssertTrue(recordedText(limited).text.contains("limit of \(writesPerHour)"))
        XCTAssertEqual(marks, ["span-refused", "write-limit"])
    }

    func testFailedSaveRefusesWithoutCounting() throws {
        let (guarding, folder) = try guarded()
        let times = folder.appendingPathComponent("http-write-times")
        try FileManager.default.removeItem(at: times)
        try FileManager.default.createDirectory(at: times.appendingPathComponent("full"), withIntermediateDirectories: true)
        var marks: [String] = []
        let result = try guarding.call(try tool("add_event"), [:], { XCTFail("the command ran"); return ToolCall(result: [:]) },
                                       marks: &marks)
        XCTAssertTrue(recordedText(result).text.contains("could not be counted"))
        XCTAssertEqual(marks, ["times-failed"])
        // Nothing left behind: the temporary file is removed when the save fails.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted(), ["http-write-times"])
        // Not counted: once the file can be saved again, the next write is the first one.
        try FileManager.default.removeItem(at: times)
        var ran = false
        _ = try guarding.call(try tool("add_event"), [:], {
            ran = true
            XCTAssertEqual(try self.counted(folder), 1)
            return ToolCall(result: toolResult("{}"), started: true)
        }, marks: &marks)
        XCTAssertTrue(ran)
    }

    func testOneGuardPerFolder() throws {
        let (guarding, folder) = try guarded()
        XCTAssertThrowsError(try WriteGuard(stateDir: folder.path)) { error in
            XCTAssertTrue("\(error)".contains("in use by another"))
        }
        withExtendedLifetime(guarding) {}
    }

    func testUnexpectedResultIsRecordedWhole() throws {
        let (guarding, folder) = try guarded()
        var marks: [String] = []
        let odd: [String: Any] = ["content": [["type": "image", "data": "x"]], "extra": [1, 2]]
        _ = try guarding.call(try tool("add_event"), [:], { ToolCall(result: odd, started: true) }, marks: &marks)
        let line = try String(contentsOf: folder.appendingPathComponent("http-writes.log"), encoding: .utf8)
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertEqual(record["error"] as? Bool, true)
        let text = try XCTUnwrap(record["text"] as? String)
        XCTAssertTrue(text.hasPrefix("unexpected result: "))
        let kept = try JSONSerialization.jsonObject(with: Data(text.dropFirst("unexpected result: ".count).utf8))
        XCTAssertEqual(kept as? NSDictionary, odd as NSDictionary)
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
