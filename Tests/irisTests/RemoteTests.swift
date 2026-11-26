import XCTest
@testable import iris

final class RemoteTests: XCTestCase {
    func testAccessWord() {
        let named = ["A"]
        for writes in [false, true] {
            for calendars in [nil, [], named] as [[String]?] {
                let file = ScopeFile(calendars: calendars, folders: [], writes: writes)
                let expected = calendars == [] ? "none" : writes ? "read and write" : "read"
                XCTAssertEqual(accessWord(.calendars, file), expected, "\(String(describing: calendars)) writes \(writes)")
                // Calendar writes never reach notes or reminders.
                XCTAssertEqual(accessWord(.folders, file), "none")
                XCTAssertEqual(accessWord(.lists, file), "none")
            }
        }
        for folders in [nil, [], named] as [[String]?] {
            let file = ScopeFile(calendars: [], folders: folders, writes: true)
            XCTAssertEqual(accessWord(.folders, file), folders == [] ? "none" : "read")
        }
        // A file without lists has the default, [].
        XCTAssertEqual(accessWord(.lists, ScopeFile(calendars: nil, folders: nil)), "none")
        for lists in [nil, named] as [[String]?] {
            for reminderWrites in [false, true] {
                let file = ScopeFile(calendars: [], folders: [], lists: lists, reminderWrites: reminderWrites)
                XCTAssertEqual(accessWord(.lists, file), reminderWrites ? "read and write" : "read")
                XCTAssertEqual(accessWord(.calendars, file), "none")
            }
        }
        // Reminder writes do not reach calendars.
        XCTAssertEqual(accessWord(.calendars, ScopeFile(calendars: named, folders: [], lists: named, reminderWrites: true)), "read")
    }

    func testSummary() {
        XCTAssertEqual(remoteSummary(usable: true, listeners: []), "No listener is running.")
        XCTAssertEqual(remoteSummary(usable: true, listeners: [(8788, .current)]),
                       "A listener is running on port 8788 and is using this scope file as it stands.")
        XCTAssertEqual(remoteSummary(usable: true, listeners: [(8788, .changed)]),
                       "A listener is running on port 8788, but the scope file was changed after it started: restart it for the change to take effect.")
        XCTAssertEqual(remoteSummary(usable: true, listeners: [(8788, .otherFile)]),
                       "A listener is running on port 8788 with another scope file.")
        XCTAssertEqual(remoteSummary(usable: false, listeners: []),
                       "The scope file has a problem: a listener started with it now would stop (see scopeFile.problem). No listener is running.")
        XCTAssertTrue(remoteSummary(usable: nil, listeners: []).hasPrefix("Whether the scope file would work could not be checked"))
        XCTAssertEqual(remoteSummary(usable: true, listeners: [(8765, .current), (8766, .current)]),
                       "2 listeners are running, on ports 8765 and 8766. All are using this scope file as it stands.")
        XCTAssertEqual(remoteSummary(usable: true, listeners: [(8765, .changed), (8766, .changed), (8767, .current)]),
                       "3 listeners are running, on ports 8765, 8766 and 8767. The scope file was changed after the ones on ports "
                       + "8765 and 8766 started: restart them for the change to take effect. The one on port 8767 is using this scope file as it stands.")
        XCTAssertEqual(remoteSummary(usable: true, listeners: [(8765, .current), (8788, .otherFile)]),
                       "2 listeners are running, on ports 8765 and 8788. The one on port 8765 is using this scope file as it stands. "
                       + "The one on port 8788 uses another scope file.")
    }

    func testListenerOptions() {
        let defaultScope = (defaultScopeFile as NSString).expandingTildeInPath
        let binary = "/Applications/Iris.app/Contents/MacOS/iris"
        func options(_ arguments: [String], executable: String = binary) -> [String]? {
            listenerOptions(executable: executable, ["iris"] + arguments).map { [String($0.port), $0.scopeFile] }
        }
        XCTAssertEqual(options(["mcp", "--http"]), ["8765", defaultScope])
        XCTAssertEqual(options(["mcp", "--http", "--port", "8770"]), ["8770", defaultScope])
        XCTAssertEqual(options(["mcp", "--port=8770", "--http"]), ["8770", defaultScope])
        XCTAssertEqual(options(["mcp", "--http", "--scope-file", "/tmp/a b/scope file.json", "--token-file", "/t"]),
                       ["8765", "/tmp/a b/scope file.json"])
        XCTAssertEqual(options(["mcp", "--http", "--scope-file=/tmp/a b/c"]), ["8765", "/tmp/a b/c"])
        XCTAssertEqual(options(["mcp", "--http", "--scope-file", "~/s"]), ["8765", ("~/s" as NSString).expandingTildeInPath])
        XCTAssertNil(options(["mcp"]))
        XCTAssertNil(options(["calendar", "events"]))
        XCTAssertNil(options(["remote", "status"]))
        XCTAssertNil(options(["mcp", "--http", "--port", "0"]))
        XCTAssertNil(options(["mcp", "--http"], executable: "/bin/sh"))
    }

    func testProcessArguments() {
        func bytes(_ text: String) -> [UInt8] { Array(text.utf8) + [0] }
        var buffer = withUnsafeBytes(of: Int32(4)) { Array($0) }
        buffer += bytes("/Apps/My Iris.app/Contents/MacOS/iris") + [0, 0, 0]
        buffer += bytes("iris") + bytes("mcp") + bytes("--scope-file") + bytes("/a b/scope file.json")
        buffer += bytes("HOME=/Users/someone")
        let parsed = parseProcessArguments(buffer)
        XCTAssertEqual(parsed?.0, "/Apps/My Iris.app/Contents/MacOS/iris")
        XCTAssertEqual(parsed?.1, ["iris", "mcp", "--scope-file", "/a b/scope file.json"])
        XCTAssertNil(parseProcessArguments([1, 0]))
        // An argument count past the end is not read as arguments.
        XCTAssertNil(parseProcessArguments(withUnsafeBytes(of: Int32(3)) { Array($0) } + bytes("/x/iris") + bytes("iris")))
    }

    // The status names what is in scope: no assistant may reach it, over stdio or HTTP.
    func testRemoteIsNoTool() throws {
        XCTAssertFalse(tools.contains { $0.command.first == "remote" })
        let everything = HTTPScope(calendars: nil, folders: nil, lists: nil, writes: true, sharedEvents: true, reminderWrites: true)
        XCTAssertFalse(try httpOffering(everything).contains { $0.command.first == "remote" })
    }
}
