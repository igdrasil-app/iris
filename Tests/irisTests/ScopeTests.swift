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

    func testTicks() throws {
        let none = ScopeFile(calendars: [], folders: [])
        func tick(_ tick: ScopeTick, _ file: ScopeFile) -> ScopeFile {
            applying(tick, to: file, items: tick.kind == .lists ? lists : named).file
        }
        // All is "all".
        XCTAssertEqual(tick(.all(.calendars), ScopeFile(calendars: ["c1"], folders: [])), ScopeFile(calendars: nil, folders: []))
        XCTAssertEqual(tick(.all(.lists), ScopeFile(calendars: [], folders: [], lists: ["l1"])), ScopeFile(calendars: [], folders: [], lists: nil))
        // From "all", unticking one leaves every other one shared, by id.
        XCTAssertEqual(tick(.item(.calendars, "c2", false), ScopeFile(calendars: nil, folders: [], writes: true)),
                       ScopeFile(calendars: ["c1", "c3"], folders: [], writes: true))
        // From a list, one is added at the end or taken out; ticking every one never makes "all".
        XCTAssertEqual(tick(.item(.calendars, "c3", true), ScopeFile(calendars: ["c1"], folders: [])),
                       ScopeFile(calendars: ["c1", "c3"], folders: []))
        XCTAssertEqual(tick(.item(.calendars, "c2", true), ScopeFile(calendars: ["c1", "c3"], folders: [])),
                       ScopeFile(calendars: ["c1", "c3", "c2"], folders: []))
        XCTAssertEqual(tick(.item(.calendars, "c1", false), ScopeFile(calendars: ["c1", "c3"], folders: [])),
                       ScopeFile(calendars: ["c3"], folders: []))
        // Names become ids, in their place; a name two calendars share names both, and the other stays.
        let twins = named + [Named(id: "c4", name: "Work")]
        XCTAssertEqual(applying(.item(.calendars, "c2", true), to: ScopeFile(calendars: ["Work"], folders: []), items: twins).file,
                       ScopeFile(calendars: ["c1", "c4", "c2"], folders: []))
        XCTAssertEqual(applying(.item(.calendars, "c4", false), to: ScopeFile(calendars: ["Work"], folders: []), items: twins).file,
                       ScopeFile(calendars: ["c1"], folders: []))
        // The last one: Off, and with it no changes and no events with other people.
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
        XCTAssertEqual(try checkedApplying(.item(.calendars, "c4", true), to: ScopeFile(calendars: ["c1"], folders: []), items: confusing).file,
                       ScopeFile(calendars: ["c1", "c4"], folders: []))
        // Stuck: each shared id is another item's name, so every item tick is refused; Off gets out in one click,
        // never through "all", and then an item can be ticked.
        let stuck = [Named(id: "a", name: "Work"), Named(id: "b", name: "Home"), Named(id: "c", name: "a"), Named(id: "d", name: "b")]
        let both = ScopeFile(calendars: ["a", "b"], folders: [], writes: true)
        for tick in [ScopeTick.item(.calendars, "a", false), .item(.calendars, "b", false), .item(.calendars, "c", true),
                     .item(.calendars, "d", true)] {
            XCTAssertThrowsError(try checkedApplying(tick, to: both, items: stuck), "\(tick)")
        }
        let cleared = try checkedApplying(.access(.calendars, .off), to: both, items: stuck)
        XCTAssertEqual(cleared.file, ScopeFile(calendars: [], folders: []))
        XCTAssertEqual(cleared.remembered, [.calendars: ["a", "b"]])
        let withC = try checkedApplying(.item(.calendars, "c", true), to: cleared.file, items: stuck)
        XCTAssertEqual(withC.file, ScopeFile(calendars: ["c"], folders: []))
        // An id another item is named after can be shared only beside that other item.
        XCTAssertThrowsError(try checkedApplying(.item(.calendars, "a", true), to: cleared.file, items: stuck))
        XCTAssertEqual(try checkedApplying(.item(.calendars, "a", true), to: withC.file, items: stuck).file,
                       ScopeFile(calendars: ["c", "a"], folders: []))
        // Turned on again, the stuck selection is not restored as it was, which would be refused: what would be
        // refused is dropped, and with nothing left, everything is shared.
        XCTAssertEqual(try checkedApplying(.access(.calendars, .readOnly), to: cleared.file, items: stuck, remembered: cleared.remembered).file,
                       ScopeFile(calendars: nil, folders: []))
        // An entry that was there already and names nothing does not stop another change.
        XCTAssertEqual(try checkedApplying(.item(.calendars, "c2", true), to: ScopeFile(calendars: ["Old"], folders: []), items: named).file,
                       ScopeFile(calendars: ["Old", "c2"], folders: []))
        // Events with other people need changes.
        let one = ScopeFile(calendars: ["c1"], folders: [], writes: true)
        XCTAssertEqual(tick(.sharedEvents(true), one), ScopeFile(calendars: ["c1"], folders: [], writes: true, sharedEvents: true))
        XCTAssertEqual(tick(.sharedEvents(false), ScopeFile(calendars: ["c1"], folders: [], writes: true, sharedEvents: true)), one)
        XCTAssertEqual(tick(.sharedEvents(true), ScopeFile(calendars: ["c1"], folders: [])), ScopeFile(calendars: ["c1"], folders: []))
        XCTAssertEqual(tick(.sharedEvents(true), none), none)
        // A tick of one app leaves the others as written, also writes on with no calendars, which the file allows.
        let mixed = ScopeFile(calendars: ["Work"], folders: nil, lists: ["Errands"], writes: true, reminderWrites: true)
        XCTAssertEqual(applying(.item(.folders, "f1", false), to: mixed, items: [Named(id: "f1", name: "Recipes")]).file,
                       ScopeFile(calendars: ["Work"], folders: [], lists: ["Errands"], writes: true, reminderWrites: true))
        let writesAlone = ScopeFile(calendars: [], folders: [], writes: true, sharedEvents: true)
        XCTAssertEqual(applying(.access(.folders, .readOnly), to: writesAlone, items: []).file,
                       ScopeFile(calendars: [], folders: nil, writes: true, sharedEvents: true))
        XCTAssertEqual(tick(.item(.lists, "l1", true), writesAlone),
                       ScopeFile(calendars: [], folders: [], lists: ["l1"], writes: true, sharedEvents: true))
        XCTAssertEqual(tick(.access(.lists, .readWrite), mixed),
                       ScopeFile(calendars: ["Work"], folders: nil, lists: ["Errands"], writes: true, reminderWrites: true))
    }

    /// Off, Read Only and Read & Write for each app, from every kind of file, to every level: what each shares and
    /// whether it allows changes, by the rules; and the file always one a server reads.
    func testAccessLevels() throws {
        let folders = [Named(id: "f1", name: "Recipes"), Named(id: "f2", name: "Travel")]
        func items(_ kind: ScopeKind) -> [Named] { kind == .calendars ? named : kind == .lists ? lists : folders }
        func writes(_ file: ScopeFile, _ kind: ScopeKind) -> Bool {
            kind == .calendars ? file.writes : kind == .lists ? file.reminderWrites : false
        }
        let starts = [ScopeFile(calendars: [], folders: []),                                       // nothing; no lists key
                      ScopeFile(calendars: nil, folders: nil, lists: nil),                         // "all"
                      ScopeFile(calendars: nil, folders: nil, lists: nil, writes: true, sharedEvents: true, reminderWrites: true),
                      ScopeFile(calendars: ["c1", "c3"], folders: ["f2"], lists: ["l2"]),          // ids
                      ScopeFile(calendars: ["Work"], folders: ["Travel"], lists: ["Errands"], writes: true, reminderWrites: true),  // names
                      ScopeFile(calendars: ["Old"], folders: ["Old"], lists: ["Old"], writes: true, sharedEvents: true, reminderWrites: true),  // a missing entry
                      ScopeFile(calendars: [], folders: [], writes: true)]                         // writes with no calendars
        for start in starts {
            for kind in [ScopeKind.calendars, .lists, .folders] {
                for level in [ShareLevel.off, .readOnly, .readWrite] {
                    let after = applying(.access(kind, level), to: start, items: items(kind)).file
                    let label = "\(start) \(kind) \(level)"
                    XCTAssertEqual(try parseScopeFile(encodeScopeFile(after)), after, label)
                    switch level {
                    case .off:
                        XCTAssertEqual(after[kind], [], label)
                        XCTAssertFalse(writes(after, kind), label)
                    case .readOnly, .readWrite:
                        // What it shared stays as written; from none, with nothing remembered, everything.
                        XCTAssertEqual(after[kind], start[kind] == [] ? nil : start[kind], label)
                        XCTAssertEqual(writes(after, kind), level == .readWrite && kind != .folders, label)
                    }
                    if kind == .calendars && !after.writes { XCTAssertFalse(after.sharedEvents, label) }
                    // The other apps' keys are as written.
                    for other in [ScopeKind.calendars, .lists, .folders] where other != kind {
                        XCTAssertEqual(after[other], start[other], label)
                        XCTAssertEqual(writes(after, other), writes(start, other), label)
                    }
                    if kind != .calendars { XCTAssertEqual(after.sharedEvents, start.sharedEvents, label) }
                }
            }
        }
        // Read Only and Read & Write keep events with other people only with changes on.
        let shared = ScopeFile(calendars: ["c1"], folders: [], writes: true, sharedEvents: true)
        XCTAssertEqual(applying(.access(.calendars, .readWrite), to: shared, items: named).file, shared)
        XCTAssertEqual(applying(.access(.calendars, .readOnly), to: shared, items: named).file, ScopeFile(calendars: ["c1"], folders: []))
    }

    /// Off remembers what an app shared, and turning it on shares that again: "all", ids, names as they read now,
    /// without what was deleted since; nothing remembered, or nothing left, is everything.
    func testOffAndOnAgain() throws {
        func turn(_ level: ShareLevel, _ file: ScopeFile, _ remembered: SharedBefore = [:], items: [Named]? = nil) -> (file: ScopeFile, remembered: SharedBefore) {
            applying(.access(.calendars, level), to: file, items: items ?? named, remembered: remembered)
        }
        let all = ScopeFile(calendars: nil, folders: [], writes: true)
        let offFromAll = turn(.off, all)
        XCTAssertEqual(offFromAll.file, ScopeFile(calendars: [], folders: []))
        XCTAssertEqual(offFromAll.remembered, [:])
        XCTAssertEqual(turn(.readOnly, offFromAll.file, offFromAll.remembered).file, ScopeFile(calendars: nil, folders: []))

        let some = ScopeFile(calendars: ["c1", "c3"], folders: [])
        let offFromSome = turn(.off, some, [.lists: ["l1"]])
        XCTAssertEqual(offFromSome.remembered, [.calendars: ["c1", "c3"], .lists: ["l1"]])
        let onAgain = turn(.readWrite, offFromSome.file, offFromSome.remembered)
        XCTAssertEqual(onAgain.file, ScopeFile(calendars: ["c1", "c3"], folders: [], writes: true))
        // Turned on, it forgets; the other apps' are kept.
        XCTAssertEqual(onAgain.remembered, [.lists: ["l1"]])
        // One deleted since: the rest. All deleted: everything.
        let withoutC3 = Array(named.prefix(2))
        XCTAssertEqual(turn(.readOnly, offFromSome.file, offFromSome.remembered, items: withoutC3).file, ScopeFile(calendars: ["c1"], folders: []))
        XCTAssertEqual(turn(.readOnly, offFromSome.file, offFromSome.remembered, items: [Named(id: "c9", name: "New")]).file,
                       ScopeFile(calendars: nil, folders: []))
        // A file that named calendars by name: restored by what the names name now, by id, never everything.
        let byName = turn(.off, ScopeFile(calendars: ["Work", "Old"], folders: []))
        XCTAssertEqual(byName.remembered, [.calendars: ["Work", "Old"]])
        XCTAssertEqual(turn(.readOnly, byName.file, byName.remembered, items: named + [Named(id: "c4", name: "Work")]).file,
                       ScopeFile(calendars: ["c1", "c4"], folders: []))
        // A file that says [] by hand, nothing remembered: everything.
        XCTAssertEqual(turn(.readOnly, ScopeFile(calendars: [], folders: [])).file, ScopeFile(calendars: nil, folders: []))
        // The last item unticked remembers that item, as Off does; Off when already off remembers nothing new.
        let last = applying(.item(.calendars, "c2", false), to: ScopeFile(calendars: ["c2"], folders: [], writes: true), items: named)
        XCTAssertEqual(last.file, ScopeFile(calendars: [], folders: []))
        XCTAssertEqual(last.remembered, [.calendars: ["c2"]])
        XCTAssertEqual(turn(.off, last.file, last.remembered).remembered, [.calendars: ["c2"]])
        XCTAssertEqual(turn(.readOnly, last.file, last.remembered).file, ScopeFile(calendars: ["c2"], folders: []))
        // Read Only to Read & Write and back changes only writes, and remembers nothing.
        XCTAssertEqual(turn(.readWrite, some, [.calendars: ["c2"]]).file, ScopeFile(calendars: ["c1", "c3"], folders: [], writes: true))
        XCTAssertEqual(turn(.readWrite, some, [.calendars: ["c2"]]).remembered, [.calendars: ["c2"]])
        // Only an app turned on with something remembered needs its items listed first.
        XCTAssertTrue(ScopeTick.access(.calendars, .readOnly).needsListing([.calendars: ["c1"]]))
        XCTAssertFalse(ScopeTick.access(.calendars, .readOnly).needsListing([.lists: ["l1"]]))
        XCTAssertFalse(ScopeTick.access(.calendars, .off).needsListing([.calendars: ["c1"]]))
        XCTAssertFalse(ScopeTick.all(.calendars).needsListing([:]))
        XCTAssertTrue(ScopeTick.item(.calendars, "c1", true).needsListing([:]))
    }

    /// What is remembered is kept in the defaults given, by changes to the file on disk, and only there.
    func testRememberedOnDisk() throws {
        let folder = NSTemporaryDirectory() + "iris-remembered-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: folder + "/defaults"))
        defer { defaults.removePersistentDomain(forName: folder + "/defaults") }
        let path = folder + "/http-scope"
        try writeScopeFile(ScopeFile(calendars: ["c1"], folders: nil, lists: ["l2"]), to: path)
        _ = try changeScopeFile(path, .access(.calendars, .off), items: [], remembering: defaults)
        _ = try changeScopeFile(path, .access(.folders, .off), items: [], remembering: defaults)
        XCTAssertEqual(sharedBefore(defaults), [.calendars: ["c1"]])
        XCTAssertEqual(defaults.stringArray(forKey: "sharedBeforeOff.calendars"), ["c1"])
        XCTAssertEqual(try changeScopeFile(path, .access(.calendars, .readOnly), items: named, remembering: defaults).file,
                       ScopeFile(calendars: ["c1"], folders: [], lists: ["l2"]))
        XCTAssertEqual(sharedBefore(defaults), [:])
        XCTAssertEqual(try changeScopeFile(path, .access(.folders, .readOnly), items: [], remembering: defaults).file,
                       ScopeFile(calendars: ["c1"], folders: nil, lists: ["l2"]))
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
            var remembered: SharedBefore = [:]
            for _ in 0..<200 {
                let kind = [ScopeKind.calendars, .lists, .folders][Int(random.next() % 3)]
                let items = kind == .calendars ? listings["calendar"]! : kind == .lists ? listings["reminders"]! : listings["notes"]!
                let on = random.next() % 2 == 0
                let tick: ScopeTick = switch random.next() % 5 {
                case 0: .all(kind)
                case 1, 2: .item(kind, items[Int(random.next() % UInt64(items.count))].id, on)
                case 3: .access(kind, [ShareLevel.off, .readOnly, .readWrite][Int(random.next() % 3)])
                default: .sharedEvents(on)
                }
                (file, remembered) = applying(tick, to: file, items: items, remembered: remembered)
                XCTAssertEqual(try parseScopeFile(encodeScopeFile(file)), file, "\(tick)")
                XCTAssertNoThrow(try pinScope(file, "/x/scope", listing: listing), "\(tick)")
                // Something is remembered only for an app that shares none.
                for kind in remembered.keys { XCTAssertEqual(file[kind], [], "\(tick)") }
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
        XCTAssertThrowsError(try changeScopeFile(path, .all(.calendars), items: []))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), broken)
        let copy = try resetScopeFile(path, now: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(copy.hasPrefix(path + ".broken-19"))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: copy)), broken)
        XCTAssertEqual(loadScopeFile(path), .file(ScopeFile(calendars: [], folders: [])))
        XCTAssertEqual(mode(path), 0o600)
        // A file the server would refuse for its mode is no scope file to write over either: a tick leaves it as it
        // is, mode and all, rather than fix it quietly.
        chmod(path, 0o644)
        guard case .broken = loadScopeFile(path) else { return XCTFail("a file others can read reads as broken") }
        let loose = try Data(contentsOf: URL(fileURLWithPath: path))
        XCTAssertThrowsError(try changeScopeFile(path, .all(.calendars), items: []))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), loose)
        XCTAssertEqual(mode(path), 0o644)

        // Through a link: the file it leads to is replaced, the link stays, and its folder is the one checked.
        chmod(path, 0o600)
        try FileManager.default.createDirectory(atPath: folder + "/links", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: folder + "/links/http-scope", withDestinationPath: path)
        _ = try changeScopeFile(folder + "/links/http-scope", .all(.folders), items: [])
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: folder + "/links/http-scope"), path)
        XCTAssertEqual(loadScopeFile(path), .file(ScopeFile(calendars: [], folders: nil)))
        // The lock is a file of its own beside the target, owner-only and empty; nothing beside the link.
        XCTAssertEqual(mode(path + ".lock"), 0o600)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path + ".lock")), Data())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder + "/links"), ["http-scope"])
    }

    /// A server with writes on holds its state folder locked for its whole life, and by default that folder holds the
    /// scope file: a tick goes through all the same, at once.
    func testTickWhileTheFolderIsLocked() throws {
        let folder = NSTemporaryDirectory() + "iris-held-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: folder) }
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // As WriteGuard takes it.
        let state = open(folder, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        defer { close(state) }
        XCTAssertEqual(flock(state, LOCK_EX | LOCK_NB), 0)
        let begun = Date()
        let changed = try changeScopeFile(folder + "/http-scope", .sharedEvents(true), items: []).file
        XCTAssertEqual(changed, ScopeFile(calendars: [], folders: []))
        XCTAssertEqual(try changeScopeFile(folder + "/http-scope", .all(.calendars), items: []).file,
                       ScopeFile(calendars: nil, folders: []))
        XCTAssertEqual(try changeScopeFile(folder + "/http-scope", .access(.calendars, .readWrite), items: []).file,
                       ScopeFile(calendars: nil, folders: [], writes: true))
        XCTAssertLessThan(Date().timeIntervalSince(begun), 0.5)
        // And the server's own lock is still its own.
        let other = open(folder, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        defer { close(other) }
        XCTAssertNotEqual(flock(other, LOCK_EX | LOCK_NB), 0)
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
    /// server would start with still is; and nothing is shared that was not before the tick, ticked by it, or, for an
    /// app turned on again, named by what it shared before it was turned off (everything when none of that is left).
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
        /// What remembered entries share again now, as `restored` works it out, independently.
        func restoring(_ entries: [String]) -> Set<String> {
            var shared = Set(entries.flatMap { pick([$0], from: items, allowed: nil, id: \.id, name: \.name).found ?? [] }.map(\.id))
            while let confusing = shared.first(where: { id in items.contains { $0.name == id && !shared.contains($0.id) } }) {
                shared.remove(confusing)
            }
            return shared
        }
        var refused = 0
        var accepted = 0
        var restores = 0
        for start in [ScopeFile(calendars: [], folders: []), ScopeFile(calendars: nil, folders: []),
                      ScopeFile(calendars: ["Work", "c2"], folders: [], writes: true)] {
            var file = start
            var remembered: SharedBefore = [:]
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
                let level = [ShareLevel.off, .readOnly, .readWrite][Int(random.next() % 3)]
                let tick: ScopeTick = switch random.next() % 7 {
                case 0: .all(.calendars)
                case 1: missing.map { .remove(.calendars, $0) } ?? .access(.calendars, level)
                case 2, 3: .access(.calendars, level)
                default: .item(.calendars, id, on)
                }
                let before = pinned(file)
                let after: (file: ScopeFile, remembered: SharedBefore)
                do {
                    after = try checkedApplying(tick, to: file, items: items, remembered: remembered)
                } catch {
                    refused += 1
                    continue
                }
                XCTAssertEqual(try parseScopeFile(encodeScopeFile(after.file)), after.file, "\(tick)")
                if let shared = before {
                    let now = try XCTUnwrap(pinned(after.file), "a file a server took is refused after \(tick)")
                    accepted += 1
                    if case .all = tick {
                    } else if case .access(_, let level) = tick, level != .off, file.calendars == [] {
                        restores += 1
                        let again = remembered[.calendars].map(restoring)
                        if let now {
                            XCTAssertTrue(now.isSubset(of: again ?? []), "\(tick) shared more than it shared before")
                        } else {
                            XCTAssertTrue(again?.isEmpty ?? true, "\(tick) turned what it shared before into all")
                        }
                    } else if let now, let shared {
                        let ticked: Set<String> = if case .item(_, let id, true) = tick { [id] } else { [] }
                        XCTAssertTrue(now.isSubset(of: shared.union(ticked)), "\(tick) shared more than it was given")
                    } else if now == nil {
                        XCTAssertNil(shared, "\(tick) turned a list into all")
                    }
                }
                file = after.file
                remembered = after.remembered
            }
        }
        // Each happens often enough to mean something.
        XCTAssertGreaterThan(refused, 20)
        XCTAssertGreaterThan(accepted, 300)
        XCTAssertGreaterThan(restores, 20)
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
