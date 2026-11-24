import ArgumentParser
import Foundation

struct NotesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "notes",
        abstract: "Read Apple Notes.",
        subcommands: [NoteFolders.self, NoteList.self, NoteSearch.self, NoteShow.self]
    )
}

struct NoteFolders: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "folders",
        abstract: "List Notes folders: id, name, account, parent, noteCount.",
        discussion: """
            Every folder of every account, subfolders included. Names can repeat; \
            the id tells folders apart. parent is the id of the folder it sits in, or null at the top of \
            its account. noteCount is what the folder shows: a note shown in several folders, as a smart \
            folder does, counts in each. The first run asks to let Iris control Notes; a denial is changed \
            under System Settings › Privacy & Security › Automation. Notes gets 30 seconds to answer each request.
            """
    )

    @Option(help: allowedHelp(.folders))
    var allowedFolders: String?

    func validate() throws {
        _ = try allowedIds(allowedFolders, "--allowed-folders")
    }

    func run() async throws {
        let allowed = try allowedIds(allowedFolders, "--allowed-folders")
        let folders = try await MainActor.run { try readFolders(allowed: allowed) }
        try emit(folders)
    }
}

struct FolderInfo: Encodable {
    let id: String
    let name: String
    let account: String
    let parent: String?
    let noteCount: Int

    enum CodingKeys: CodingKey { case id, name, account, parent, noteCount }

    // Written out so a top-level folder carries "parent": null instead of dropping the key.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(account, forKey: .account)
        try container.encode(parent, forKey: .parent)
        try container.encode(noteCount, forKey: .noteCount)
    }
}

// One Apple Event per property, each covering every folder: one event per folder costs ~46 ms.
// The order of `every folder` is the same in each, so the lists line up by index.
// Without the timeout a stalled Notes holds the call for the default 120 seconds. The timeout is per
// event, so a stalled Notes fails on the first one at 30 s.
private let foldersScript = """
    tell application "Notes"
        with timeout of 30 seconds
            {id of every folder, name of every folder, id of every note of every folder, ¬
                id of container of every folder, ¬
                name of every account, id of every account, id of every folder of every account}
        end timeout
    end tell
    """

/// Every folder, or only the allowed ones; a folder whose parent is not allowed then shows parent null.
@MainActor
private func readFolders(allowed: Set<String>?) throws -> [FolderInfo] {
    let parts = items(try runNotesScript(foldersScript))
    guard parts.count == 7 else { throw IrisError("Notes returned \(parts.count) lists for folders, expected 7") }
    let ids = strings(parts[0])
    let names = strings(parts[1])
    let noteLists = items(parts[2])
    let containers = strings(parts[3])
    let accounts = strings(parts[4])
    let accountIds = Set(strings(parts[5]))
    let accountFolders = items(parts[6])
    guard names.count == ids.count, noteLists.count == ids.count, containers.count == ids.count,
          accountIds.count == accounts.count, accountFolders.count == accounts.count else {
        throw IrisError("Notes changed while folders were read; run again")
    }
    let folderIds = Set(ids)
    let accountOf = accountByFolder(accounts, accountFolders)

    var folders: [FolderInfo] = []
    for index in ids.indices {
        // A folder sits in another folder or, at the top, in its account.
        let container = containers[index]
        guard let account = accountOf[ids[index]],
              folderIds.contains(container) || accountIds.contains(container) else {
            throw IrisError("Notes changed while folders were read; run again")
        }
        guard allowed?.contains(ids[index]) ?? true else { continue }
        folders.append(FolderInfo(id: ids[index], name: names[index], account: account,
                                  parent: folderIds.contains(container) && (allowed?.contains(container) ?? true) ? container : nil,
                                  noteCount: noteLists[index].numberOfItems))
    }
    return folders
}

/// Folders join their account by id: names repeat across accounts and parents.
private func accountByFolder(_ accounts: [String], _ accountFolders: [NSAppleEventDescriptor]) -> [String: String] {
    var accountOf: [String: String] = [:]
    for (account, folders) in zip(accounts, accountFolders) {
        for id in strings(folders) { accountOf[id] = account }
    }
    return accountOf
}

struct NoteList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List notes, newest first: id, title, folder, folderId, account, created, modified, locked, shared.",
        discussion: """
            Filters apply first, then notes are sorted by modified, newest first (equal dates by id), then \
            --limit keeps the first ones (default 50). A note shown in several folders is listed once. folder is \
            the folder the note is kept in; --folder lists the notes a folder shows, so a folder that only shows \
            notes kept elsewhere, as a smart folder does, lists them with their own folder. folder, folderId and \
            account are null when Notes names no listed folder for the note. locked: the note is password protected; its title still shows. No note text \
            is listed. The first run asks to let Iris control Notes; a denial is changed under System Settings › \
            Privacy & Security › Automation. Notes gets 30 seconds to answer each request.
            """
    )

    @Option(name: .customLong("folder"), help: "Folder id or name, from `iris notes folders`; repeat for several. A name in several accounts includes each; one that matches nothing is an error. Default: every folder.")
    var folders: [String] = []

    @Option(help: "Only notes modified at or after this time: 2026-10-13 (local midnight), 2026-10-13T09:00 (local time), or ISO 8601 with an offset or Z. Default: any time.")
    var since: String?

    @Option(help: "Only notes whose title contains this text, ignoring case. Default: every note.")
    var title: String?

    @Option(help: "At most this many notes.")
    var limit = 50

    @Option(help: allowedHelp(.folders))
    var allowedFolders: String?

    func validate() throws {
        _ = try since.map(parseDate)
        if title == "" { throw ValidationError("--title must not be empty") }
        if limit < 1 { throw ValidationError("--limit must be at least 1") }
        _ = try allowedIds(allowedFolders, "--allowed-folders")
    }

    func run() async throws {
        let allowed = try allowedIds(allowedFolders, "--allowed-folders")
        let (notes, shown) = try await MainActor.run { try readNotes(withText: false, allowed: allowed) }
        let scope = try resolveFolders(folders, in: shown, allowed: allowed)
        let start = try since.map(parseDate)
        let listed = notes
            .filter { note in
                (scope?.contains(note.id) ?? true)
                    && (start.map { note.modifiedDate >= $0 } ?? true)
                    && (title.map { note.title.range(of: $0, options: .caseInsensitive) != nil } ?? true)
            }
            // Equal dates fall back to the id, so --limit keeps the same notes run to run.
            .sorted { ($0.modifiedDate, $0.id) > ($1.modifiedDate, $1.id) }
            .prefix(limit)
        try emit(Array(listed))
    }
}

struct NoteInfo: Encodable {
    let id: String
    let title: String
    let folder: String?
    let folderId: String?
    let account: String?
    let modifiedDate: Date
    let created: String
    let locked: Bool
    let shared: Bool
    /// The plain text, read only for search and never for a locked note; not part of the output.
    var text: String? = nil

    enum CodingKeys: CodingKey { case id, title, folder, folderId, account, created, modified, locked, shared }

    // Written out so a note no folder shows carries "folder": null instead of dropping the key.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(folder, forKey: .folder)
        try container.encode(folderId, forKey: .folderId)
        try container.encode(account, forKey: .account)
        try container.encode(created, forKey: .created)
        try container.encode(iso(modifiedDate), forKey: .modified)
        try container.encode(locked, forKey: .locked)
        try container.encode(shared, forKey: .shared)
    }
}

/// A folder and the ids of the notes it shows, smart folders included.
struct ShownFolder {
    let id: String
    let name: String
    let noteIds: [String]
}

// The note properties come from app-level `every note`, whose lists line up by index; a note shown in
// several folders appears there once per folder. `id of container` answers missing value, but `container`
// is a reference whose key is the id of the folder the note is kept in. The nested `every note of every
// folder` order differs from the app-level order, so it is only used for membership, never by index.
// The text of every note is the costly list, so only search asks for it; list gets missing value there.
private func notesScript(withText: Bool) -> String {
    """
    tell application "Notes"
        with timeout of 30 seconds
            {id of every note, name of every note, creation date of every note, ¬
                modification date of every note, password protected of every note, shared of every note, ¬
                container of every note, ¬
                id of every folder, name of every folder, id of every note of every folder, ¬
                name of every account, id of every folder of every account, ¬
                \(withText ? "plaintext of every note" : "missing value")}
        end timeout
    end tell
    """
}

/// Every note, with the folder it is kept in only when that folder is allowed.
@MainActor
private func readNotes(withText: Bool, allowed: Set<String>?) throws -> ([NoteInfo], [ShownFolder]) {
    let parts = items(try runNotesScript(notesScript(withText: withText)))
    guard parts.count == 13 else { throw IrisError("Notes returned \(parts.count) lists for notes, expected 13") }
    let ids = strings(parts[0])
    let names = strings(parts[1])
    let created = items(parts[2])
    let modified = items(parts[3])
    let locked = items(parts[4])
    let shared = items(parts[5])
    let containers = items(parts[6])
    let folderIds = strings(parts[7])
    let folderNames = strings(parts[8])
    let noteLists = items(parts[9])
    let accounts = strings(parts[10])
    let accountFolders = items(parts[11])
    let texts = withText ? items(parts[12]) : []
    guard [names.count, created.count, modified.count, locked.count, shared.count, containers.count]
            .allSatisfy({ $0 == ids.count }),
          !withText || texts.count == ids.count,
          folderNames.count == folderIds.count, noteLists.count == folderIds.count,
          accountFolders.count == accounts.count else {
        throw IrisError("Notes changed while notes were read; run again")
    }

    let folders = folderIds.indices.map {
        ShownFolder(id: folderIds[$0], name: folderNames[$0], noteIds: strings(noteLists[$0]))
    }
    let folderName = Dictionary(folders.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    let accountOf = accountByFolder(accounts, accountFolders)

    var notes: [NoteInfo] = []
    var seen: Set<String> = []
    for index in ids.indices where seen.insert(ids[index]).inserted {
        guard let createdDate = created[index].dateValue, let modifiedDate = modified[index].dateValue else {
            throw IrisError("Notes returned a note without a date; run again")
        }
        // The folder the note is kept in, or nil when Notes names no listed folder. Any folder showing the
        // note would be a guess, and possibly a smart one.
        let home = containers[index].forKeyword(AEKeyword(keyAEKeyData))?.stringValue
        let folderId = homeFolder(home, among: folderName, allowed: allowed)
        let isLocked = locked[index].booleanValue
        notes.append(NoteInfo(id: ids[index], title: names[index],
                              folder: folderId.flatMap { folderName[$0] }, folderId: folderId,
                              account: folderId.flatMap { accountOf[$0] },
                              modifiedDate: modifiedDate, created: iso(createdDate),
                              locked: isLocked, shared: shared[index].booleanValue,
                              // Decided here, not by what Notes returns, as in `notes show`.
                              text: withText && !isLocked ? texts[index].stringValue : nil))
    }
    return (notes, folders)
}

/// The ids of the notes the named folders show; nil for every note. Match by id or name: a name in several
/// accounts takes each folder, and a name that matches nothing is an error, never every folder.
/// Under a scope only allowed folders can be named, and no names means every allowed folder: so with no
/// names this is the one rule for which notes are in scope, for list, search and show alike.
func resolveFolders(_ tokens: [String], in folders: [ShownFolder], allowed: Set<String>?) throws -> Set<String>? {
    let (found, missing) = pick(tokens, from: folders, allowed: allowed, id: \.id, name: \.name)
    guard missing.isEmpty else {
        throw IrisError("no folder named \(missing.joined(separator: ", ")); see `iris notes folders`")
    }
    return found.map { Set($0.flatMap(\.noteIds)) }
}

/// The id of the folder a note is kept in, or nil when Notes names no listed folder or it is not allowed.
private func homeFolder(_ home: String?, among folderName: [String: String], allowed: Set<String>?) -> String? {
    home.flatMap { folderName[$0] == nil || !(allowed?.contains($0) ?? true) ? nil : $0 }
}

struct NoteSearch: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search",
        abstract: "Find notes whose title or text contains every given word: id, title, folder, folderId, modified, snippet.",
        discussion: """
            The text is split on whitespace into words; a note matches when every word occurs in its title or \
            its text, anywhere and in any order, as part of a longer word too. Case and diacritics are ignored: \
            cafe finds café and café finds cafe. There is no ranking: matches are sorted by modified, newest \
            first (equal dates by id), then --limit keeps the first ones (default 20). A note shown in several \
            folders is listed once; folder, folderId and --folder mean what they mean in `iris notes list`. \
            snippet is the note's text with every run of whitespace, newlines included, turned into one space: \
            160 characters starting 60 before the first occurrence of the first word, in the order given, that \
            occurs in the text, fewer at the start or end of the text, with no space at either end. snippet is \
            null when the words occur only in the title. A locked note (password protected) is matched on its \
            title only and its snippet is null. Each run reads the text of every note, so it takes longer than \
            `iris notes list`. Text starting with - goes after --: iris notes search -- -word. The first run \
            asks to let Iris control Notes; a denial is changed under System Settings › Privacy & Security › \
            Automation. Notes gets 30 seconds to answer each request.
            """
    )

    @Argument(help: "The words to find, in one argument: quote several words.")
    var text: String

    @Option(name: .customLong("folder"), help: "Folder id or name, from `iris notes folders`; repeat for several. A name in several accounts includes each; one that matches nothing is an error. Default: every folder.")
    var folders: [String] = []

    @Option(help: "At most this many notes.")
    var limit = 20

    @Option(help: allowedHelp(.folders))
    var allowedFolders: String?

    func validate() throws {
        // No words would match every note.
        if words.isEmpty { throw ValidationError("the search text must contain a word") }
        if limit < 1 { throw ValidationError("--limit must be at least 1") }
        _ = try allowedIds(allowedFolders, "--allowed-folders")
    }

    private var words: [String] { text.split(whereSeparator: \.isWhitespace).map(String.init) }

    func run() async throws {
        let allowed = try allowedIds(allowedFolders, "--allowed-folders")
        let (notes, shown) = try await MainActor.run { try readNotes(withText: true, allowed: allowed) }
        let scope = try resolveFolders(folders, in: shown, allowed: allowed)
        let found = notes
            .filter { note in
                (scope?.contains(note.id) ?? true)
                    && words.allSatisfy { word in
                        note.title.range(of: word, options: searchOptions) != nil
                            || note.text?.range(of: word, options: searchOptions) != nil
                    }
            }
            .sorted { ($0.modifiedDate, $0.id) > ($1.modifiedDate, $1.id) }
            .prefix(limit)
        try emit(found.map { NoteMatch(note: $0, snippet: snippet(of: $0.text, around: words)) })
    }
}

private let searchOptions: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

/// The text with whitespace runs collapsed, cut to 160 characters starting 60 before the first word, in query
/// order, that occurs in it, then trimmed. A word holds no whitespace, so collapsing moves none of its occurrences.
private func snippet(of text: String?, around words: [String]) -> String? {
    guard let text else { return nil }
    let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    guard let hit = words.lazy.compactMap({ flat.range(of: $0, options: searchOptions) }).first else { return nil }
    let start = flat.index(hit.lowerBound, offsetBy: -60, limitedBy: flat.startIndex) ?? flat.startIndex
    let end = flat.index(start, offsetBy: 160, limitedBy: flat.endIndex) ?? flat.endIndex
    // Only the spaces the collapse put in: `.whitespaces` would also strip a zero-width space a word may hold.
    return flat[start..<end].trimmingCharacters(in: CharacterSet(charactersIn: " "))
}

struct NoteMatch: Encodable {
    let note: NoteInfo
    let snippet: String?

    enum CodingKeys: CodingKey { case id, title, folder, folderId, modified, snippet }

    // Written out so null fields keep their keys.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(note.id, forKey: .id)
        try container.encode(note.title, forKey: .title)
        try container.encode(note.folder, forKey: .folder)
        try container.encode(note.folderId, forKey: .folderId)
        try container.encode(iso(note.modifiedDate), forKey: .modified)
        try container.encode(snippet, forKey: .snippet)
    }
}

struct NoteShow: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Show one note: id, title, folder, folderId, account, created, modified, locked, shared, body, attachments.",
        discussion: """
            The id comes from `iris notes list`. body is the note's plain text. attachments are the names of \
            its attachments, null for one Notes gives no name. folder, folderId and account are null when \
            Notes names no listed folder for the note. A locked note (password protected) prints locked: true \
            and null for body, html and attachments, even when it is unlocked in Notes. --html adds html, the \
            note's HTML body, which can be large. An id that is not a note id is a usage error; a note id \
            that matches no note is an error. The first run asks to let Iris control Notes; a denial is \
            changed under System Settings › Privacy & Security › Automation. Notes gets 30 seconds to answer \
            each request.
            """
    )

    @Argument(help: "Note id, from `iris notes list`.")
    var id: String

    @Flag(help: "Add html, the note's HTML body.")
    var html = false

    @Option(help: allowedHelp(.folders))
    var allowedFolders: String?

    func validate() throws {
        guard isNoteId(id) else { throw ValidationError("not a note id; note ids come from `iris notes list`") }
        _ = try allowedIds(allowedFolders, "--allowed-folders")
    }

    func run() async throws {
        let allowed = try allowedIds(allowedFolders, "--allowed-folders")
        let note = try await MainActor.run { () throws -> NoteDetail in
            // A note no allowed folder shows is not looked at: it fails as a note that does not exist.
            if let allowed {
                let inScope = try resolveFolders([], in: readShownFolders(), allowed: allowed) ?? []
                if !inScope.contains(id) { throw noSuchNote(id) }
            }
            return try readNote(id, html: html, allowed: allowed)
        }
        try emit(note)
    }
}

private func noSuchNote(_ id: String) -> IrisError {
    IrisError("no note with id \(id); see `iris notes list`")
}

// Which notes each folder shows, for a limited `notes show`. A fixed script: no caller text goes in.
private let shownFoldersScript = """
    tell application "Notes"
        with timeout of 30 seconds
            {id of every folder, name of every folder, id of every note of every folder}
        end timeout
    end tell
    """

@MainActor
private func readShownFolders() throws -> [ShownFolder] {
    let parts = items(try runNotesScript(shownFoldersScript))
    guard parts.count == 3 else { throw IrisError("Notes returned \(parts.count) lists for folders, expected 3") }
    let ids = strings(parts[0])
    let names = strings(parts[1])
    let noteLists = items(parts[2])
    guard names.count == ids.count, noteLists.count == ids.count else {
        throw IrisError("Notes changed while folders were read; run again")
    }
    return ids.indices.map { ShownFolder(id: ids[$0], name: names[$0], noteIds: strings(noteLists[$0])) }
}

/// The id is pasted into the script, so it must be exactly the form Notes prints, nothing more.
private func isNoteId(_ id: String) -> Bool {
    id.wholeMatch(of: #/x-coredata://[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}/ICNote/p[0-9]+/#) != nil
}

struct NoteDetail: Encodable {
    let id: String
    let title: String
    let folder: String?
    let folderId: String?
    let account: String?
    let created: String
    let modified: String
    let locked: Bool
    let shared: Bool
    let body: String?
    let showsHtml: Bool
    let html: String?
    let attachments: [String?]?

    enum CodingKeys: CodingKey { case id, title, folder, folderId, account, created, modified, locked, shared, body, html, attachments }

    // Written out so empty fields carry null instead of dropping the key; html is left out unless asked for.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(folder, forKey: .folder)
        try container.encode(folderId, forKey: .folderId)
        try container.encode(account, forKey: .account)
        try container.encode(created, forKey: .created)
        try container.encode(modified, forKey: .modified)
        try container.encode(locked, forKey: .locked)
        try container.encode(shared, forKey: .shared)
        try container.encode(body, forKey: .body)
        if showsHtml { try container.encode(html, forKey: .html) }
        try container.encode(attachments, forKey: .attachments)
    }
}

// `note id` is resolved once; each property after it is one Apple Event. Only a lookup that finds no note
// answers missing value; any other error still fails. A locked note is never asked for its text or
// attachments. The folder lists join the note's container to a
// folder name and account, as `notes list` does.
private func noteScript(_ id: String, html: Bool) -> String {
    """
    tell application "Notes"
        with timeout of 30 seconds
            try
                set theNote to note id "\(id)"
            on error number -1728
                return missing value
            end try
            set isLocked to password protected of theNote
            set {theText, theHtml, theNames} to {missing value, missing value, missing value}
            if not isLocked then
                set {theText, theHtml, theNames} to {plaintext of theNote, ¬
                    \(html ? "body of theNote" : "missing value"), name of every attachment of theNote}
            end if
            {name of theNote, creation date of theNote, modification date of theNote, ¬
                isLocked, shared of theNote, container of theNote, theText, theHtml, theNames, ¬
                id of every folder, name of every folder, name of every account, id of every folder of every account}
        end timeout
    end tell
    """
}

@MainActor
private func readNote(_ id: String, html: Bool, allowed: Set<String>?) throws -> NoteDetail {
    let result = try runNotesScript(noteScript(id, html: html))
    guard result.descriptorType == typeAEList else { throw noSuchNote(id) }
    let parts = items(result)
    guard parts.count == 13 else { throw IrisError("Notes returned \(parts.count) items for a note, expected 13") }
    let folderIds = strings(parts[9])
    let folderNames = strings(parts[10])
    let accounts = strings(parts[11])
    let accountFolders = items(parts[12])
    guard let created = parts[1].dateValue, let modified = parts[2].dateValue,
          folderNames.count == folderIds.count, accountFolders.count == accounts.count else {
        throw IrisError("Notes changed while the note was read; run again")
    }
    let folderName = Dictionary(zip(folderIds, folderNames), uniquingKeysWith: { first, _ in first })
    let home = parts[5].forKeyword(AEKeyword(keyAEKeyData))?.stringValue
    let folderId = homeFolder(home, among: folderName, allowed: allowed)
    // Decided here, not by what Notes returns: once the note is unlocked in Notes, Notes hands out its text.
    let locked = parts[3].booleanValue
    return NoteDetail(id: id, title: parts[0].stringValue ?? "",
                      folder: folderId.flatMap { folderName[$0] }, folderId: folderId,
                      account: folderId.flatMap { accountByFolder(accounts, accountFolders)[$0] },
                      created: iso(created), modified: iso(modified),
                      locked: locked, shared: parts[4].booleanValue,
                      body: locked ? nil : parts[6].stringValue,
                      showsHtml: html, html: locked ? nil : parts[7].stringValue,
                      attachments: locked ? nil : items(parts[8]).map(\.stringValue))
}

/// NSAppleScript must run on the main thread: off it the reply never arrives and the call hangs with no timeout.
/// The source is a fixed string; the only caller text ever put in is a note id that passed `isNoteId`.
@MainActor
func runNotesScript(_ source: String) throws -> NSAppleEventDescriptor {
    guard let script = NSAppleScript(source: source) else { throw IrisError("the Notes script does not compile") }
    var error: NSDictionary?
    let result = script.executeAndReturnError(&error)
    if let error { throw notesError(error) }
    return result
}

let notesAutomationFix = "turn on Notes under Iris in System Settings › Privacy & Security › Automation"

/// Whether Iris may control Notes. Without ask it never prompts and never launches Notes;
/// with ask it shows the dialog when there is none yet and blocks until the person answers.
func notesPermission(ask: Bool = false) -> String {
    let notes = NSAppleEventDescriptor(bundleIdentifier: "com.apple.Notes")
    let code = withExtendedLifetime(notes) {
        AEDeterminePermissionToAutomateTarget(notes.aeDesc, typeWildCard, typeWildCard, ask)
    }
    switch Int(code) {
    case Int(noErr): return "granted"
    case errAEEventNotPermitted: return "denied"
    case errAEEventWouldRequireUserConsent: return "not determined"
    case procNotFound: return "unknown (Notes not running)"
    default: return "unknown (\(code))"
    }
}

private func notesError(_ error: NSDictionary) -> IrisError {
    let number = (error[NSAppleScript.errorNumber] as? NSNumber)?.intValue
    let message = error[NSAppleScript.errorMessage] as? String ?? ""
    switch number {
    case -1743:
        return IrisError("Iris may not control Notes; \(notesAutomationFix)")
    case -1712:
        return IrisError("Notes did not answer in time; if a permission dialog was open, answer it and run this again")
    default:
        let code = number.map(String.init) ?? "unknown"
        return IrisError("Notes error \(code): \(message.isEmpty ? "no message" : message)")
    }
}

/// The items of an Apple Event list, which counts from 1.
private func items(_ list: NSAppleEventDescriptor) -> [NSAppleEventDescriptor] {
    (0..<list.numberOfItems).compactMap { list.atIndex($0 + 1) }
}

private func strings(_ list: NSAppleEventDescriptor) -> [String] {
    items(list).map { $0.stringValue ?? "" }
}
