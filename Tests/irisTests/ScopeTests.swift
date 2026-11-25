import XCTest
@testable import iris

final class ScopeTests: XCTestCase {
    private func parse(_ text: String) throws -> ScopeFile {
        try parseScopeFile(Data(text.utf8))
    }

    func testScopeFile() throws {
        XCTAssertEqual(try parse(#"{"calendars": ["Work", "id-1"], "folders": ["Folder A"]}"#),
                       ScopeFile(calendars: ["Work", "id-1"], folders: ["Folder A"]))
        XCTAssertEqual(try parse(#"{"calendars": "all", "folders": "all"}"#), ScopeFile(calendars: nil, folders: nil))
        XCTAssertEqual(try parse(#"{"calendars": [], "folders": "all"}"#), ScopeFile(calendars: [], folders: nil))

        // Writes are off unless the file says true.
        XCTAssertFalse(try parse(#"{"calendars": [], "folders": []}"#).writes)
        XCTAssertTrue(try parse(#"{"calendars": [], "folders": [], "writes": true}"#).writes)
        XCTAssertFalse(try parse(#"{"calendars": [], "folders": [], "writes": false}"#).writes)

        // Shared events are refused unless the file says true, which needs writes.
        XCTAssertFalse(try parse(#"{"calendars": [], "folders": [], "writes": true}"#).sharedEvents)
        XCTAssertFalse(try parse(#"{"calendars": [], "folders": [], "writes": true, "sharedEvents": false}"#).sharedEvents)
        XCTAssertFalse(try parse(#"{"calendars": [], "folders": [], "sharedEvents": false}"#).sharedEvents)
        XCTAssertEqual(try parse(#"{"calendars": [], "folders": [], "writes": true, "sharedEvents": true}"#),
                       ScopeFile(calendars: [], folders: [], writes: true, sharedEvents: true))

        // Each is refused: nothing is assumed, least of all "all", writes or shared events.
        let refused = [
            "sharedEvents without writes": #"{"calendars": [], "folders": [], "sharedEvents": true}"#,
            "sharedEvents with writes false": #"{"calendars": [], "folders": [], "writes": false, "sharedEvents": true}"#,
            "sharedEvents 1": #"{"calendars": [], "folders": [], "writes": true, "sharedEvents": 1}"#,
            "sharedEvents a string": #"{"calendars": [], "folders": [], "writes": true, "sharedEvents": "true"}"#,
            "sharedEvents null": #"{"calendars": [], "folders": [], "writes": true, "sharedEvents": null}"#,
            "sharedEvents a list": #"{"calendars": [], "folders": [], "writes": true, "sharedEvents": [true]}"#,
            "SharedEvents": #"{"calendars": [], "folders": [], "writes": true, "SharedEvents": true}"#,
            "writes 1": #"{"calendars": [], "folders": [], "writes": 1}"#,
            "writes 0": #"{"calendars": [], "folders": [], "writes": 0}"#,
            "writes a string": #"{"calendars": [], "folders": [], "writes": "true"}"#,
            "writes null": #"{"calendars": [], "folders": [], "writes": null}"#,
            "writes a list": #"{"calendars": [], "folders": [], "writes": [true]}"#,
            "Writes": #"{"calendars": [], "folders": [], "Writes": true}"#,
            "missing key": #"{"calendars": "all"}"#,
            "no keys": "{}",
            "unknown key": #"{"calendars": [], "folders": [], "calender": []}"#,
            "null": #"{"calendars": null, "folders": []}"#,
            "a bare string": #"{"calendars": "Work", "folders": []}"#,
            "ALL": #"{"calendars": "ALL", "folders": []}"#,
            "true": #"{"calendars": true, "folders": []}"#,
            "a number in the list": #"{"calendars": ["Work", 1], "folders": []}"#,
            "a nested list": #"{"calendars": [["Work"]], "folders": []}"#,
            "a list at the top": #"[{"calendars": [], "folders": []}]"#,
            "not JSON": "calendars: Work",
            "empty": "",
        ]
        for (name, text) in refused { XCTAssertThrowsError(try parse(text), name) }
    }

    private let folders = [
        ShownFolder(id: "f1", name: "Work", noteIds: ["n1", "n2"]),
        ShownFolder(id: "f2", name: "Home", noteIds: ["n3"]),
        ShownFolder(id: "f3", name: "Work", noteIds: ["n4"]),          // the same name in another account
        ShownFolder(id: "smart", name: "Starred", noteIds: ["n1", "n3"]),  // shows notes kept elsewhere
    ]

    private func notes(_ tokens: [String], allowed: Set<String>?) throws -> Set<String>? {
        try resolveFolders(tokens, in: folders, allowed: allowed)
    }

    func testSelectionWithoutScope() throws {
        XCTAssertNil(try notes([], allowed: nil), "every note")
        XCTAssertEqual(try notes(["Work"], allowed: nil), ["n1", "n2", "n4"])
        XCTAssertThrowsError(try notes(["Nope"], allowed: nil))
    }

    func testSelectionWithinScope() throws {
        // No selection: what the allowed folders show, a smart folder's notes included.
        XCTAssertEqual(try notes([], allowed: ["f2", "smart"]), ["n1", "n3"])
        // A subset of the allowed folders.
        XCTAssertEqual(try notes(["Home"], allowed: ["f2", "smart"]), ["n3"])
        // A shared name takes only the allowed folder that has it.
        XCTAssertEqual(try notes(["Work"], allowed: ["f1"]), ["n1", "n2"])
        XCTAssertEqual(try notes(["f1"], allowed: ["f1"]), ["n1", "n2"])
    }

    func testOutOfScopeIsMissing() {
        // Disjoint, by name and by id, answered exactly as a folder that does not exist.
        for token in ["Home", "f2", "Nope"] {
            XCTAssertThrowsError(try notes([token], allowed: ["f1"])) { error in
                XCTAssertEqual("\(error)", "no folder named \(token); see `iris notes folders`")
            }
        }
        // One allowed and one not: an error, never the allowed half alone.
        XCTAssertThrowsError(try notes(["f1", "f2"], allowed: ["f1"]))
        // An allowed id that no longer exists matches nothing, and no name brings back a folder.
        XCTAssertEqual(try notes([], allowed: ["gone"]), [])
    }

    func testEmptyScope() throws {
        XCTAssertEqual(try notes([], allowed: []), [])
        XCTAssertThrowsError(try notes(["Work"], allowed: []))
    }

    func testPickKeepsOrderAndShares() {
        let items = [Named(id: "c1", name: "Work"), Named(id: "c2", name: "Work"), Named(id: "c3", name: "Home")]
        let picked = pick(["Home", "Work"], from: items, allowed: ["c2", "c3"], id: \.id, name: \.name)
        XCTAssertEqual(picked.found?.map(\.id), ["c3", "c2"])
        XCTAssertEqual(picked.missing, [])
        XCTAssertNil(pick([], from: items, allowed: nil, id: \.id, name: \.name).found)
    }

    func testAllowedIds() throws {
        XCTAssertNil(try allowedIds(nil, "--allowed-folders"))
        XCTAssertEqual(try allowedIds("[]", "--allowed-folders"), [])
        XCTAssertEqual(try allowedIds(#"["a,b", "c"]"#, "--allowed-folders"), ["a,b", "c"])
        for value in ["", "a", #""a""#, "[1]", "{}", "null"] {
            XCTAssertThrowsError(try allowedIds(value, "--allowed-folders"), value)
        }
    }

    func testLimitedTool() throws {
        let scope = HTTPScope(calendars: ["c2", "c1"], folders: nil)
        let events = try XCTUnwrap(tools.first { $0.name == "events" })
        XCTAssertEqual(try events.limited(to: scope).command, ["calendar", "events", "--allowed-calendars", #"["c1","c2"]"#])
        XCTAssertEqual(try events.limited(to: HTTPScope(calendars: [], folders: nil)).command,
                       ["calendar", "events", "--allowed-calendars", "[]"])
        let notes = try XCTUnwrap(tools.first { $0.name == "notes" })
        XCTAssertEqual(try notes.limited(to: scope).command, ["notes", "list"], "folders: all")
        // A tool whose command takes no scope option is refused, even when the scope says all.
        let unscoped = Tool(name: "unscoped", description: "", command: ["calendar", "add"], scope: nil, parameters: [])
        XCTAssertThrowsError(try unscoped.limited(to: HTTPScope(calendars: nil, folders: nil)))
        // Every tool offered over HTTP can be limited.
        for name in httpToolNames + httpWriteToolNames {
            let tool = try XCTUnwrap(tools.first { $0.name == name })
            XCTAssertNoThrow(try tool.limited(to: scope), name)
        }
    }

    func testShiftedBatchIsCaught() {
        XCTAssertTrue(unshifted(["n1", "n2", "n3"], ["n1", "n2", "n3"]))
        XCTAssertTrue(unshifted([], []))
        // n2 removed and n4 added between the first and the last request: the count is the same.
        XCTAssertFalse(unshifted(["n1", "n2", "n3"], ["n1", "n3", "n4"]))
        // The same notes in another order would join one note's text to another's id.
        XCTAssertFalse(unshifted(["n1", "n2"], ["n2", "n1"]))
        XCTAssertFalse(unshifted(["n1", "n2"], ["n1"]))
    }

    // A caller's value that spells the scope option stays a value: the command still gets the pinned ids.
    private let smuggled = #"--allowed-folders=["outside"]"#

    func testFolderScopeSurvivesCallerArguments() throws {
        let notes = try XCTUnwrap(tools.first { $0.name == "notes" })
        let search = try XCTUnwrap(tools.first { $0.name == "search_notes" })
        for ids: Set<String> in [[], ["f1"], ["f1", "f2"]] {
            let scope = HTTPScope(calendars: nil, folders: ids)
            let listing = try notes.limited(to: scope).argv(["folders": [smuggled], "title": smuggled])
            XCTAssertEqual(listing.filter { $0.hasPrefix("--allowed-folders") }.count, 1)
            let list = try NoteList.parse(Array(listing.dropFirst(2)))
            XCTAssertEqual(try allowedIds(list.allowedFolders, "--allowed-folders"), ids)
            XCTAssertEqual(list.folders, [smuggled])
            XCTAssertEqual(list.title, smuggled)

            let searching = try search.limited(to: scope).argv(["text": smuggled, "folders": [smuggled]])
            let found = try NoteSearch.parse(Array(searching.dropFirst(2)))
            XCTAssertEqual(try allowedIds(found.allowedFolders, "--allowed-folders"), ids)
            XCTAssertEqual(found.text, smuggled)
            XCTAssertEqual(found.folders, [smuggled])
        }
    }

    func testCalendarScopeSurvivesCallerArguments() throws {
        let smuggled = #"--allowed-calendars=["outside"]"#
        let events = try XCTUnwrap(tools.first { $0.name == "events" })
        for ids: Set<String> in [[], ["c1"], ["c1", "c2"]] {
            let argv = try events.limited(to: HTTPScope(calendars: ids, folders: nil))
                .argv(["calendars": [smuggled], "title": smuggled])
            XCTAssertEqual(argv.filter { $0.hasPrefix("--allowed-calendars") }.count, 1)
            let parsed = try Events.parse(Array(argv.dropFirst(2)))
            XCTAssertEqual(try allowedIds(parsed.allowedCalendars, "--allowed-calendars"), ids)
            XCTAssertEqual(parsed.calendars, [smuggled])
            XCTAssertEqual(parsed.title, smuggled)
        }
    }

    func testWriteScopeSurvivesCallerArguments() throws {
        let smuggled = #"--allowed-calendars=["outside"]"#
        func limited(_ name: String, _ ids: Set<String>, _ arguments: [String: Any]) throws -> [String] {
            let argv = try XCTUnwrap(tools.first { $0.name == name })
                .limited(to: HTTPScope(calendars: ids, folders: nil)).argv(arguments)
            // After "--" every word is a value, so only the words before it can be the option.
            XCTAssertEqual(argv.prefix { $0 != "--" }.filter { $0.hasPrefix("--allowed-calendars") }.count, 1, name)
            return Array(argv.dropFirst(2))
        }
        for ids: Set<String> in [[], ["c1"], ["c1", "c2"]] {
            let add = try AddEvent.parse(try limited("add_event", ids, [
                "calendar": smuggled, "title": smuggled, "start": "2026-10-13", "location": smuggled]))
            XCTAssertEqual(try allowedIds(add.allowedCalendars, "--allowed-calendars"), ids)
            XCTAssertEqual(add.calendar, smuggled)
            XCTAssertEqual(add.title, smuggled)

            let update = try UpdateEvent.parse(try limited("update_event", ids, [
                "id": smuggled, "calendar": smuggled, "title": smuggled, "notes": smuggled]))
            XCTAssertEqual(try allowedIds(update.allowedCalendars, "--allowed-calendars"), ids)
            XCTAssertEqual(update.id, smuggled)
            XCTAssertEqual(update.calendar, smuggled)

            let delete = try DeleteEvent.parse(try limited("delete_event", ids, ["id": smuggled, "occurrence": smuggled]))
            XCTAssertEqual(try allowedIds(delete.allowedCalendars, "--allowed-calendars"), ids)
            XCTAssertEqual(delete.id, smuggled)
            XCTAssertEqual(delete.span, "this")
        }
    }

    func testOnlyMineSurvivesCallerArguments() throws {
        let negations = ["--no-only-mine", "--only-mine=false", "--only-mine", "--no-only-mine=true", "--disable-only-mine"]
        for calendars: Set<String>? in [nil, [], ["c1"]] {
            let scope = HTTPScope(calendars: calendars, folders: nil, writes: true)
            for name in ["update_event", "delete_event"] {
                let tool = try XCTUnwrap(tools.first { $0.name == name }).limited(to: scope)
                // Pinned in the command and not offered to the caller, so asking for it is an unknown parameter.
                XCTAssertEqual(tool.command.last, "--only-mine", name)
                XCTAssertNil((tool.definition["inputSchema"] as? [String: Any])
                    .flatMap { $0["properties"] as? [String: Any] }?["onlyMine"], name)
                for value in [true, false] {
                    XCTAssertThrowsError(try tool.argv(["id": "e1", "onlyMine": value]), name)
                }
                for word in negations {
                    // update checks occurrence as a date before it runs, delete does not.
                    var arguments: [String: Any] = ["id": word]
                    if name == "delete_event" { arguments["occurrence"] = word }
                    if name == "update_event" {
                        arguments.merge(["title": word, "notes": word, "calendar": word, "location": word]) { $1 }
                    }
                    let argv = try tool.argv(arguments)
                    // After "--" every word is a value, so only the words before it can be the flag.
                    XCTAssertEqual(argv.prefix { $0 != "--" }.filter { $0 == "--only-mine" }.count, 1, "\(name) \(word)")
                    let words = Array(argv.dropFirst(2))
                    if name == "update_event" {
                        let update = try UpdateEvent.parse(words)
                        XCTAssertTrue(update.onlyMine, word)
                        XCTAssertEqual(update.id, word)
                        XCTAssertEqual(update.title, word)
                        XCTAssertEqual(try allowedIds(update.allowedCalendars, "--allowed-calendars"), calendars)
                    } else {
                        let delete = try DeleteEvent.parse(words)
                        XCTAssertTrue(delete.onlyMine, word)
                        XCTAssertEqual(delete.id, word)
                        XCTAssertEqual(try allowedIds(delete.allowedCalendars, "--allowed-calendars"), calendars)
                    }
                }
            }
            // add_event and the reads have no onlyMine and are left as they were.
            for name in ["add_event", "events"] {
                XCTAssertFalse(try XCTUnwrap(tools.first { $0.name == name }).limited(to: scope).command.contains("--only-mine"))
            }
        }
    }

    func testOnlyMineIsTheCallersWithSharedEvents() throws {
        let scope = HTTPScope(calendars: ["c1"], folders: nil, writes: true, sharedEvents: true)
        let update = try XCTUnwrap(tools.first { $0.name == "update_event" }).limited(to: scope)
        let delete = try XCTUnwrap(tools.first { $0.name == "delete_event" }).limited(to: scope)
        for tool in [update, delete] {
            XCTAssertFalse(tool.command.contains("--only-mine"), tool.name)
            XCTAssertNotNil((tool.definition["inputSchema"] as? [String: Any])
                .flatMap { $0["properties"] as? [String: Any] }?["onlyMine"], tool.name)
        }
        XCTAssertFalse(try UpdateEvent.parse(Array(try update.argv(["id": "e1", "title": "--only-mine"]).dropFirst(2))).onlyMine)
        XCTAssertFalse(try UpdateEvent.parse(Array(try update.argv(["id": "e1", "onlyMine": false]).dropFirst(2))).onlyMine)
        XCTAssertTrue(try UpdateEvent.parse(Array(try update.argv(["id": "e1", "onlyMine": true]).dropFirst(2))).onlyMine)
        XCTAssertFalse(try DeleteEvent.parse(Array(try delete.argv(["id": "--only-mine"]).dropFirst(2))).onlyMine)
        XCTAssertTrue(try DeleteEvent.parse(Array(try delete.argv(["id": "e1", "onlyMine": true]).dropFirst(2))).onlyMine)
        XCTAssertThrowsError(try delete.argv(["id": "e1", "onlyMine": "false"]), "a string is not a boolean")
    }
}
