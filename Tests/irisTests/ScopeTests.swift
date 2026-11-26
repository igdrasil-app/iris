import EventKit
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

    func testScopeFileLists() throws {
        // No lists key is no lists, as a file written before reminders came to HTTP meant.
        XCTAssertEqual(try parse(#"{"calendars": "all", "folders": "all"}"#).lists, [])
        XCTAssertEqual(try parse(#"{"calendars": "all", "folders": "all", "lists": []}"#).lists, [])
        XCTAssertNil(try parse(#"{"calendars": [], "folders": [], "lists": "all"}"#).lists)
        XCTAssertEqual(try parse(#"{"calendars": [], "folders": [], "lists": ["Errands", "id-1"], "writes": true}"#),
                       ScopeFile(calendars: [], folders: [], lists: ["Errands", "id-1"], writes: true))
        let refused = [
            "null": #"{"calendars": [], "folders": [], "lists": null}"#,
            "a bare string": #"{"calendars": [], "folders": [], "lists": "Errands"}"#,
            "ALL": #"{"calendars": [], "folders": [], "lists": "ALL"}"#,
            "a number in the list": #"{"calendars": [], "folders": [], "lists": ["Errands", 1]}"#,
            "an object": #"{"calendars": [], "folders": [], "lists": {}}"#,
            "Lists": #"{"calendars": [], "folders": [], "Lists": []}"#,
            "lists alone": #"{"lists": "all"}"#,
        ]
        for (name, text) in refused { XCTAssertThrowsError(try parse(text), name) }
    }

    func testScopeFileReminderWrites() throws {
        // Off unless the file says true; "writes" does not turn them on.
        XCTAssertFalse(try parse(#"{"calendars": [], "folders": [], "lists": ["Errands"]}"#).reminderWrites)
        XCTAssertFalse(try parse(#"{"calendars": [], "folders": [], "lists": ["Errands"], "writes": true}"#).reminderWrites)
        XCTAssertFalse(try parse(#"{"calendars": [], "folders": [], "reminderWrites": false}"#).reminderWrites)
        XCTAssertEqual(try parse(#"{"calendars": [], "folders": [], "lists": ["Errands"], "reminderWrites": true}"#),
                       ScopeFile(calendars: [], folders: [], lists: ["Errands"], reminderWrites: true))
        XCTAssertEqual(try parse(#"{"calendars": [], "folders": [], "lists": "all", "reminderWrites": true}"#),
                       ScopeFile(calendars: [], folders: [], lists: nil, reminderWrites: true))
        let refused = [
            "without lists": #"{"calendars": [], "folders": [], "reminderWrites": true}"#,
            "with lists []": #"{"calendars": [], "folders": [], "lists": [], "reminderWrites": true}"#,
            "without lists, writes on": #"{"calendars": [], "folders": [], "writes": true, "reminderWrites": true}"#,
            "1": #"{"calendars": [], "folders": [], "lists": ["Errands"], "reminderWrites": 1}"#,
            "a string": #"{"calendars": [], "folders": [], "lists": ["Errands"], "reminderWrites": "true"}"#,
            "null": #"{"calendars": [], "folders": [], "lists": ["Errands"], "reminderWrites": null}"#,
            "ReminderWrites": #"{"calendars": [], "folders": [], "lists": ["Errands"], "ReminderWrites": true}"#,
        ]
        for (name, text) in refused { XCTAssertThrowsError(try parse(text), name) }
    }

    func testHTTPOffering() throws {
        let reads = ["calendars", "events", "note_folders", "notes", "search_notes", "show_note"]
        for lists: Set<String>? in [nil, [], ["l1"]] {
            for writes in [false, true] {
                for reminderWrites in [false, true] {
                    let scope = HTTPScope(calendars: nil, folders: nil, lists: lists, writes: writes, reminderWrites: reminderWrites)
                    let names = try httpOffering(scope).map(\.name)
                    // Calendar writes only with writes, reminder writes only with reminderWrites, and no reminder
                    // tool without lists: no lists offers what a server offered before reminders came to HTTP.
                    let hasLists = lists != []
                    let expected = reads + (writes ? httpWriteToolNames : []) + (hasLists ? ["reminder_lists", "reminders"] : [])
                        + (hasLists && reminderWrites ? httpReminderWriteToolNames : [])
                    XCTAssertEqual(Set(names), Set(expected), "\(String(describing: lists)) \(writes) \(reminderWrites)")
                    XCTAssertEqual(names.count, expected.count)
                }
            }
        }
    }

    func testEveryOfferedToolIsAReadOrGuarded() throws {
        XCTAssertTrue(isHTTPWrite("future_write"), "a name that is not a read is guarded")
        let reminderWrites = ["add_reminder", "update_reminder", "complete_reminder", "delete_reminder"]
        XCTAssertEqual(httpReminderWriteToolNames, reminderWrites)
        for name in httpWriteToolNames + reminderWrites {
            XCTAssertTrue(isHTTPWrite(name), name)
        }
        // Every tool iris has is a read named in httpToolNames or guarded as a write: nothing is neither.
        for tool in tools {
            XCTAssertNotEqual(httpToolNames.contains(tool.name), isHTTPWrite(tool.name), tool.name)
        }
    }

    func testNotRepeatingIsPinnedOverHTTP() throws {
        let negations = ["--no-not-repeating", "--not-repeating=false", "--not-repeating", "--disable-not-repeating"]
        let delete = try XCTUnwrap(tools.first { $0.name == "delete_reminder" })
        // Over stdio it is the caller's.
        XCTAssertFalse(try DeleteReminder.parse(Array(try delete.argv(["id": "r1"]).dropFirst(2))).notRepeating)
        XCTAssertTrue(try DeleteReminder.parse(Array(try delete.argv(["id": "r1", "notRepeating": true]).dropFirst(2))).notRepeating)
        for lists: Set<String>? in [nil, ["l1"]] {
            for sharedEvents in [false, true] {
                let scope = HTTPScope(calendars: nil, folders: nil, lists: lists, writes: sharedEvents,
                                      sharedEvents: sharedEvents, reminderWrites: true)
                let tool = try delete.limited(to: scope)
                // Pinned in the command, whatever the scope, and not offered to the caller.
                XCTAssertEqual(tool.command.last, "--not-repeating")
                XCTAssertNil((tool.definition["inputSchema"] as? [String: Any])
                    .flatMap { $0["properties"] as? [String: Any] }?["notRepeating"])
                for value in [true, false] {
                    XCTAssertThrowsError(try tool.argv(["id": "r1", "notRepeating": value]))
                }
                for word in negations {
                    let argv = try tool.argv(["id": word])
                    XCTAssertEqual(argv.prefix { $0 != "--" }.filter { $0 == "--not-repeating" }.count, 1, word)
                    let parsed = try DeleteReminder.parse(Array(argv.dropFirst(2)))
                    XCTAssertTrue(parsed.notRepeating, word)
                    XCTAssertEqual(parsed.id, word)
                    XCTAssertEqual(try allowedIds(parsed.allowedLists, "--allowed-lists"), lists)
                }
            }
        }
        // No other tool gets it.
        for tool in tools where tool.name != "delete_reminder" {
            XCTAssertFalse(try tool.limited(to: HTTPScope(calendars: nil, folders: nil, lists: nil)).command.contains("--not-repeating"),
                           tool.name)
        }
    }

    func testReminderWriteScopeSurvivesCallerArguments() throws {
        let smuggled = #"--allowed-lists=["outside"]"#
        func limited(_ name: String, _ ids: Set<String>, _ arguments: [String: Any]) throws -> [String] {
            let argv = try XCTUnwrap(tools.first { $0.name == name })
                .limited(to: HTTPScope(calendars: nil, folders: nil, lists: ids, reminderWrites: true)).argv(arguments)
            XCTAssertEqual(argv.prefix { $0 != "--" }.filter { $0.hasPrefix("--allowed-lists") }.count, 1, name)
            return Array(argv.dropFirst(2))
        }
        for ids: Set<String> in [[], ["l1"], ["l1", "l2"]] {
            let add = try AddReminder.parse(try limited("add_reminder", ids, ["list": smuggled, "title": smuggled]))
            XCTAssertEqual(try allowedIds(add.allowedLists, "--allowed-lists"), ids)
            XCTAssertEqual(add.list, smuggled)
            let update = try UpdateReminder.parse(try limited("update_reminder", ids, ["id": smuggled, "list": smuggled]))
            XCTAssertEqual(try allowedIds(update.allowedLists, "--allowed-lists"), ids)
            XCTAssertEqual(update.id, smuggled)
            XCTAssertEqual(update.list, smuggled)
            let complete = try CompleteReminder.parse(try limited("complete_reminder", ids, ["id": smuggled]))
            XCTAssertEqual(try allowedIds(complete.allowedLists, "--allowed-lists"), ids)
            XCTAssertEqual(complete.id, smuggled)
            let delete = try DeleteReminder.parse(try limited("delete_reminder", ids, ["id": smuggled]))
            XCTAssertEqual(try allowedIds(delete.allowedLists, "--allowed-lists"), ids)
            XCTAssertEqual(delete.id, smuggled)
        }
    }

    func testEmptyListScopeIsNone() async throws {
        let lists = [Named(id: "l1", name: "Errands"), Named(id: "l2", name: "Home")]
        // No list named: every allowed list, which is none, never nil (every list).
        for allowed: Set<String> in [[], ["gone"]] {
            XCTAssertEqual(pick([], from: lists, allowed: allowed, id: \.id, name: \.name).found?.count, 0)
        }
        XCTAssertEqual(try resolveLists([], among: [], allowed: [])?.count, 0)
        XCTAssertThrowsError(try resolveLists(["Errands"], among: [], allowed: [])) { error in
            XCTAssertEqual("\(error)", "no reminder list named Errands; see `iris reminders lists`")
        }
        // An empty list of lists never reaches EventKit, which would read it as every list.
        let none = try await fetchReminders(in: EKEventStore(), lists: [], status: .all)
        XCTAssertTrue(none.isEmpty)
        // The scope reaches the command as [], whatever the caller sends.
        let smuggled = #"--allowed-lists=["outside"]"#
        let reminders = try XCTUnwrap(tools.first { $0.name == "reminders" })
        for ids: Set<String> in [[], ["l1"]] {
            let argv = try reminders.limited(to: HTTPScope(calendars: nil, folders: nil, lists: ids))
                .argv(["lists": [smuggled], "dueFrom": "2026-10-13"])
            XCTAssertEqual(argv.filter { $0.hasPrefix("--allowed-lists") }.count, 1)
            let parsed = try ReminderList.parse(Array(argv.dropFirst(2)))
            XCTAssertEqual(try allowedIds(parsed.allowedLists, "--allowed-lists"), ids)
            XCTAssertEqual(parsed.lists, [smuggled])
        }
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

    func testPickTakesAnIdBeforeAName() {
        let items = [Named(id: "c1", name: "Work"), Named(id: "c2", name: "c1")]
        XCTAssertEqual(pick(["c1"], from: items, allowed: nil, id: \.id, name: \.name).found?.map(\.id), ["c1"])
        // The name still reaches the other when the id is out of scope.
        XCTAssertEqual(pick(["c1"], from: items, allowed: ["c2"], id: \.id, name: \.name).found?.map(\.id), ["c2"])
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
        for name in httpToolNames + httpWriteToolNames + httpReminderWriteToolNames {
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

    // The menu bar's ticks, with invented calendars; the same rules hold for lists and folders.
    private let named = [Named(id: "c1", name: "Work"), Named(id: "c2", name: "Family"), Named(id: "c3", name: "Birthdays")]
    private let lists = [Named(id: "l1", name: "Errands"), Named(id: "l2", name: "Groceries")]

    func testTicks() {
        let none = ScopeFile(calendars: [], folders: [])
        func tick(_ tick: ScopeTick, _ file: ScopeFile) -> ScopeFile {
            applying(tick, to: file, items: tick.kind == .lists ? lists : named)
        }
        // All on is "all"; off shares none.
        XCTAssertEqual(tick(.all(.calendars, true), none), ScopeFile(calendars: nil, folders: []))
        XCTAssertEqual(tick(.all(.calendars, false), ScopeFile(calendars: nil, folders: [], writes: true, sharedEvents: true)), none)
        XCTAssertEqual(tick(.all(.lists, true), none), ScopeFile(calendars: [], folders: [], lists: nil))
        XCTAssertEqual(tick(.all(.lists, false), ScopeFile(calendars: [], folders: [], lists: nil, reminderWrites: true)), none)
        // From "all", unticking one leaves every other one shared, by id.
        XCTAssertEqual(tick(.item(.calendars, "c2", false), ScopeFile(calendars: nil, folders: [], writes: true)),
                       ScopeFile(calendars: ["c1", "c3"], folders: [], writes: true))
        // From a list, one is added at the end or taken out.
        XCTAssertEqual(tick(.item(.calendars, "c3", true), ScopeFile(calendars: ["c1"], folders: [])),
                       ScopeFile(calendars: ["c1", "c3"], folders: []))
        XCTAssertEqual(tick(.item(.calendars, "c1", false), ScopeFile(calendars: ["c1", "c3"], folders: [])),
                       ScopeFile(calendars: ["c3"], folders: []))
        // Names become ids, in their place; a name two calendars share names both, and the other stays.
        let twins = named + [Named(id: "c4", name: "Work")]
        XCTAssertEqual(applying(.item(.calendars, "c2", true), to: ScopeFile(calendars: ["Work"], folders: []), items: twins),
                       ScopeFile(calendars: ["c1", "c4", "c2"], folders: []))
        XCTAssertEqual(applying(.item(.calendars, "c4", false), to: ScopeFile(calendars: ["Work"], folders: []), items: twins),
                       ScopeFile(calendars: ["c1"], folders: []))
        // The last one: nothing shared, and with it no changes and no events with other people.
        XCTAssertEqual(tick(.item(.calendars, "c1", false), ScopeFile(calendars: ["c1"], folders: [], writes: true, sharedEvents: true)), none)
        XCTAssertEqual(tick(.item(.lists, "l1", false), ScopeFile(calendars: [], folders: [], lists: ["l1"], reminderWrites: true)), none)
        // An entry that names nothing stays as written until it is removed itself; an id is never doubled.
        XCTAssertEqual(tick(.item(.calendars, "c2", true), ScopeFile(calendars: ["Old", "c1", "Work"], folders: [])),
                       ScopeFile(calendars: ["Old", "c1", "c2"], folders: []))
        XCTAssertEqual(tick(.remove(.calendars, "Old"), ScopeFile(calendars: ["Old", "c1"], folders: [])),
                       ScopeFile(calendars: ["c1"], folders: []))
        XCTAssertEqual(tick(.remove(.calendars, "Old"), ScopeFile(calendars: ["Old"], folders: [], writes: true)), none)
        // Removing one turns the rest of the key into ids, as every change to a key does.
        XCTAssertEqual(tick(.remove(.calendars, "Gone"), ScopeFile(calendars: ["Work", "Gone"], folders: [])),
                       ScopeFile(calendars: ["c1"], folders: []))
        // Against the items listed just now: an id that is gone is refused, and so is an entry that is one item's id
        // and another's name while that other is not shared.
        XCTAssertThrowsError(try checkedApplying(.item(.calendars, "c9", true), to: ScopeFile(calendars: [], folders: []), items: named)) {
            XCTAssertEqual("\($0)", "That calendar no longer exists, so nothing was changed.")
        }
        let confusing = named + [Named(id: "c4", name: "c1")]
        XCTAssertThrowsError(try checkedApplying(.item(.calendars, "c1", true), to: ScopeFile(calendars: [], folders: []), items: confusing))
        XCTAssertEqual(try checkedApplying(.item(.calendars, "c4", true), to: ScopeFile(calendars: ["c1"], folders: []), items: confusing),
                       ScopeFile(calendars: ["c1", "c4"], folders: []))
        // An entry that was there already and names nothing does not stop another change.
        XCTAssertEqual(try checkedApplying(.item(.calendars, "c2", true), to: ScopeFile(calendars: ["Old"], folders: []), items: named),
                       ScopeFile(calendars: ["Old", "c2"], folders: []))
        // Changes, and events with other people, which need changes.
        let one = ScopeFile(calendars: ["c1"], folders: [])
        XCTAssertEqual(tick(.writes(true), one), ScopeFile(calendars: ["c1"], folders: [], writes: true))
        XCTAssertEqual(tick(.sharedEvents(true), ScopeFile(calendars: ["c1"], folders: [], writes: true)),
                       ScopeFile(calendars: ["c1"], folders: [], writes: true, sharedEvents: true))
        XCTAssertEqual(tick(.writes(false), ScopeFile(calendars: ["c1"], folders: [], writes: true, sharedEvents: true)), one)
        XCTAssertEqual(tick(.sharedEvents(false), ScopeFile(calendars: ["c1"], folders: [], writes: true, sharedEvents: true)),
                       ScopeFile(calendars: ["c1"], folders: [], writes: true))
        let someLists = ScopeFile(calendars: [], folders: [], lists: ["l2"])
        XCTAssertEqual(tick(.reminderWrites(true), someLists), ScopeFile(calendars: [], folders: [], lists: ["l2"], reminderWrites: true))
        XCTAssertEqual(tick(.reminderWrites(false), ScopeFile(calendars: [], folders: [], lists: ["l2"], reminderWrites: true)), someLists)
        // What the rules do not allow changes nothing.
        XCTAssertEqual(tick(.writes(true), none), none)
        XCTAssertEqual(tick(.sharedEvents(true), one), one)
        XCTAssertEqual(tick(.reminderWrites(true), none), none)
        // A tick of one app leaves the others as written, also writes on with no calendars, which the file allows.
        let mixed = ScopeFile(calendars: ["Work"], folders: nil, lists: ["Errands"], writes: true, reminderWrites: true)
        XCTAssertEqual(applying(.item(.folders, "f1", false), to: mixed, items: [Named(id: "f1", name: "Recipes")]),
                       ScopeFile(calendars: ["Work"], folders: [], lists: ["Errands"], writes: true, reminderWrites: true))
        let writesAlone = ScopeFile(calendars: [], folders: [], writes: true, sharedEvents: true)
        XCTAssertEqual(applying(.all(.folders, true), to: writesAlone, items: []),
                       ScopeFile(calendars: [], folders: nil, writes: true, sharedEvents: true))
        XCTAssertEqual(tick(.item(.lists, "l1", true), writesAlone),
                       ScopeFile(calendars: [], folders: [], lists: ["l1"], writes: true, sharedEvents: true))
    }

    func testEncodedFileReadsBack() throws {
        let files = [ScopeFile(calendars: [], folders: []), ScopeFile(calendars: nil, folders: nil, lists: nil),
                     ScopeFile(calendars: ["c1", "x/y \"quoted\""], folders: ["f/1"], lists: ["l1"], writes: true,
                               sharedEvents: true, reminderWrites: true)]
        for file in files { XCTAssertEqual(try parseScopeFile(encodeScopeFile(file)), file) }
        XCTAssertEqual(String(decoding: encodeScopeFile(ScopeFile(calendars: ["c1"], folders: nil, writes: true)), as: UTF8.self), """
            {
              "calendars" : [
                "c1"
              ],
              "folders" : "all",
              "lists" : [

              ],
              "writes" : true
            }

            """)
    }

    /// From several files, 200 random ticks each: every file in between reads back as itself, keeps the rules, and is
    /// one a server would start with, as no tick ever names what does not exist.
    func testTicksKeepTheRules() throws {
        var random = SplitMix(seed: 161)
        let listings: [String: [Named]] = ["calendar": named, "reminders": lists,
                                           "notes": [Named(id: "f1", name: "Recipes"), Named(id: "f2", name: "Travel")]]
        func listing(_ arguments: [String]) throws -> Data {
            let nameKey = arguments[0] == "notes" ? "name" : "title"
            return try JSONSerialization.data(withJSONObject: listings[arguments[0]]!.map { ["id": $0.id, nameKey: $0.name] })
        }
        let starts = [ScopeFile(calendars: [], folders: []), ScopeFile(calendars: nil, folders: nil, lists: nil),
                      ScopeFile(calendars: ["Work", "c3"], folders: ["Recipes"], lists: ["Errands"], writes: true, reminderWrites: true),
                      ScopeFile(calendars: nil, folders: [], lists: nil, writes: true, sharedEvents: true, reminderWrites: true)]
        for start in starts {
            var file = start
            for _ in 0..<200 {
                let kind = [ScopeKind.calendars, .lists, .folders][Int(random.next() % 3)]
                let items = kind == .calendars ? listings["calendar"]! : kind == .lists ? listings["reminders"]! : listings["notes"]!
                let on = random.next() % 2 == 0
                let tick: ScopeTick = switch random.next() % 5 {
                case 0: .all(kind, on)
                case 1, 2: .item(kind, items[Int(random.next() % UInt64(items.count))].id, on)
                case 3: [.writes(on), .sharedEvents(on)][Int(random.next() % 2)]
                default: .reminderWrites(on)
                }
                file = applying(tick, to: file, items: items)
                XCTAssertEqual(try parseScopeFile(encodeScopeFile(file)), file, "\(tick)")
                XCTAssertNoThrow(try pinScope(file, "/x/scope", listing: listing), "\(tick)")
            }
        }
    }

    @MainActor
    func testScopeFileOnDisk() throws {
        let folder = NSTemporaryDirectory() + "iris-scope-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let path = folder + "/Iris/http-scope"
        func inode() -> UInt64? { (try? FileManager.default.attributesOfItem(atPath: path)[.systemFileNumber] as? UInt64) ?? nil }
        func mode(_ path: String) -> Int? { try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int }

        // None yet: the first write makes the folder, owner-only, and the file.
        XCTAssertEqual(loadScopeFile(path), .missing)
        try writeScopeFile(ScopeFile(calendars: ["c1"], folders: []), to: path)
        XCTAssertEqual(mode(folder + "/Iris"), 0o700)
        XCTAssertEqual(mode(path), 0o600)
        XCTAssertEqual(loadScopeFile(path), .file(ScopeFile(calendars: ["c1"], folders: [])))
        // Each write is a new file renamed into place, nothing left beside it; a reader sees a whole file every time.
        let first = inode()
        let reader = ReaderState()
        let reads = DispatchGroup()
        DispatchQueue.global().async(group: reads) {
            while !reader.isStopped {
                guard case .file = loadScopeFile(path) else { return reader.fail() }
            }
        }
        for index in 0..<200 {
            try writeScopeFile(ScopeFile(calendars: (0...index % 7).map { "c\($0)" }, folders: nil, lists: nil), to: path)
        }
        reader.stop()
        reads.wait()
        XCTAssertEqual(reader.failures, 0)
        XCTAssertNotEqual(inode(), first)
        XCTAssertEqual(mode(path), 0o600)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder + "/Iris"), ["http-scope"])
        // A folder others can write in gets nothing.
        try FileManager.default.createDirectory(atPath: folder + "/open", withIntermediateDirectories: true)
        chmod(folder + "/open", 0o777)
        XCTAssertThrowsError(try writeScopeFile(ScopeFile(calendars: [], folders: []), to: folder + "/open/http-scope"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder + "/open"), [])

        // A file that is not a scope file is never written over by a tick; reset keeps it beside the new one.
        let broken = Data("{\"calendars\": [\"c1\"".utf8)
        try broken.write(to: URL(fileURLWithPath: path))
        guard case .broken = loadScopeFile(path) else { return XCTFail("a broken file reads as broken") }
        let changes = ScopeChanges(path: path, listing: { _ in [] }) {}
        XCTAssertThrowsError(try changes.apply(.all(.calendars, true), items: []))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), broken)
        let copy = try resetScopeFile(path, now: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(copy.hasPrefix(path + ".broken-19"))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: copy)), broken)
        XCTAssertEqual(loadScopeFile(path), .file(ScopeFile(calendars: [], folders: [])))
        XCTAssertEqual(mode(path), 0o600)
        // Reset does nothing to a file that reads well, as one fixed by hand while its alert was open.
        XCTAssertNil(try changes.reset())
        // A file the server would refuse for its mode is no scope file to write over either: a tick leaves it as it
        // is, mode and all, rather than fix it quietly.
        chmod(path, 0o644)
        guard case .broken = loadScopeFile(path) else { return XCTFail("a file others can read reads as broken") }
        let loose = try Data(contentsOf: URL(fileURLWithPath: path))
        XCTAssertThrowsError(try changes.apply(.all(.calendars, true), items: []))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), loose)
        XCTAssertEqual(mode(path), 0o644)

        // Through a link: the file it leads to is replaced, the link stays, and its folder is the one checked.
        chmod(path, 0o600)
        try FileManager.default.createDirectory(atPath: folder + "/links", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: folder + "/links/http-scope", withDestinationPath: path)
        _ = try ScopeChanges(path: folder + "/links/http-scope", listing: { _ in [] }) {}.apply(.all(.folders, true), items: [])
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: folder + "/links/http-scope"), path)
        XCTAssertEqual(loadScopeFile(path), .file(ScopeFile(calendars: [], folders: nil)))
    }

    /// The lock is held for the whole change: a change while another holds it waits, and gives up when it is not let go.
    func testScopeLock() throws {
        let folder = NSTemporaryDirectory() + "iris-lock-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let path = folder + "/http-scope"
        let held = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            try? withScopeLock(path) {
                held.signal()
                release.wait()
            }
        }
        held.wait()
        let begun = Date()
        XCTAssertThrowsError(try withScopeLock(path, wait: 0.3) {}) { error in
            XCTAssertEqual("\(error)", "Another copy of Iris is changing what is shared; try again.")
        }
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(begun), 0.3)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { release.signal() }
        XCTAssertNoThrow(try withScopeLock(path, wait: 2) {})
    }

    /// Ticks against listings that change between them: items deleted, renamed, named like another's id, added, and a
    /// menu that still shows a deleted one. After each tick that is not refused, the file reads back as itself; a file a
    /// server would start with still is; and nothing is shared that was not before the tick or ticked by it.
    func testTicksAgainstChangingListings() throws {
        var random = SplitMix(seed: 126)
        var items = named
        var added = 10
        var deleted: [String] = []
        func pinned(_ file: ScopeFile) -> Set<String>?? {
            let listing = { (_: [String]) throws -> Data in
                try JSONSerialization.data(withJSONObject: items.map { ["id": $0.id, "title": $0.name] })
            }
            guard let scope = try? pinScope(file, "/x/scope", listing: listing) else { return nil }
            return .some(scope.calendars.map { Set($0.map(\.id)) })
        }
        var refused = 0
        var accepted = 0
        for start in [ScopeFile(calendars: [], folders: []), ScopeFile(calendars: nil, folders: []),
                      ScopeFile(calendars: ["Work", "c2"], folders: [], writes: true)] {
            var file = start
            for _ in 0..<300 {
                let index = Int(random.next() % UInt64(items.count))
                switch random.next() % 8 {
                case 0 where items.count > 1:
                    deleted.append(items.remove(at: index).id)
                case 1:
                    items[index] = Named(id: items[index].id, name: items[Int(random.next() % UInt64(items.count))].id)
                case 2:
                    items[index] = Named(id: items[index].id, name: items[Int(random.next() % UInt64(items.count))].name)
                case 3:
                    added += 1
                    items.append(Named(id: "c\(added)", name: ["Work", "Family", "Trips", "c1"][Int(random.next() % 4)]))
                default:
                    break
                }
                let stale = deleted.isEmpty ? nil : deleted[Int(random.next() % UInt64(deleted.count))]
                let current = items[Int(random.next() % UInt64(items.count))].id
                let id = random.next() % 6 == 0 ? stale ?? current : current
                let missing = (file.calendars ?? []).first { entry in !items.contains { $0.id == entry || $0.name == entry } }
                let on = random.next() % 2 == 0
                let tick: ScopeTick = switch random.next() % 6 {
                case 0: .all(.calendars, on)
                case 1: missing.map { .remove(.calendars, $0) } ?? .writes(on)
                case 2: .writes(on)
                default: .item(.calendars, id, on)
                }
                let before = pinned(file)
                let after: ScopeFile
                do {
                    after = try checkedApplying(tick, to: file, items: items)
                } catch {
                    refused += 1
                    continue
                }
                XCTAssertEqual(try parseScopeFile(encodeScopeFile(after)), after, "\(tick)")
                if let shared = before {
                    let now = try XCTUnwrap(pinned(after), "a file a server took is refused after \(tick)")
                    accepted += 1
                    if case .all(_, true) = tick { } else if let now, let shared {
                        let ticked: Set<String> = if case .item(_, let id, true) = tick { [id] } else { [] }
                        XCTAssertTrue(now.isSubset(of: shared.union(ticked)), "\(tick) shared more than it was given")
                    } else if now == nil {
                        XCTAssertNil(shared, "\(tick) turned a list into all")
                    }
                }
                file = after
            }
        }
        // Both happen often enough to mean something.
        XCTAssertGreaterThan(refused, 20)
        XCTAssertGreaterThan(accepted, 300)
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

/// A seeded generator, so a failing sequence of ticks can be run again.
struct SplitMix: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// A stop flag and a count shared with a reading thread.
final class ReaderState: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private var count = 0

    var isStopped: Bool { lock.withLock { stopped } }
    var failures: Int { lock.withLock { count } }
    func stop() { lock.withLock { stopped = true } }
    func fail() { lock.withLock { count += 1 } }
}
