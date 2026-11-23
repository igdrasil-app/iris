import ArgumentParser
import Foundation

struct NotesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "notes",
        abstract: "Read Apple Notes.",
        subcommands: [NoteFolders.self, NoteList.self, NoteShow.self]
    )
}

struct NoteFolders: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "folders",
        abstract: "List Notes folders: id, name, account, parent, noteCount.",
        discussion: """
            Every folder of every account, subfolders and Recently Deleted included. Names can repeat; \
            the id tells folders apart. parent is the id of the folder it sits in, or null at the top of \
            its account. noteCount is what the folder shows: a note shown in several folders, as a smart \
            folder does, counts in each. The first run asks to let Iris control Notes; a denial is changed \
            under System Settings › Privacy & Security › Automation. Notes gets 30 seconds to answer each request.
            """
    )

    func run() async throws {
        let folders = try await MainActor.run { try readFolders() }
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

@MainActor
private func readFolders() throws -> [FolderInfo] {
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
        folders.append(FolderInfo(id: ids[index], name: names[index], account: account,
                                  parent: folderIds.contains(container) ? container : nil,
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

    func validate() throws {
        _ = try since.map(parseDate)
        if title == "" { throw ValidationError("--title must not be empty") }
        if limit < 1 { throw ValidationError("--limit must be at least 1") }
    }

    func run() async throws {
        let (notes, shown) = try await MainActor.run { try readNotes() }
        let scope = try resolveFolders(folders, in: shown)
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
private let notesScript = """
    tell application "Notes"
        with timeout of 30 seconds
            {id of every note, name of every note, creation date of every note, ¬
                modification date of every note, password protected of every note, shared of every note, ¬
                container of every note, ¬
                id of every folder, name of every folder, id of every note of every folder, ¬
                name of every account, id of every folder of every account}
        end timeout
    end tell
    """

@MainActor
private func readNotes() throws -> ([NoteInfo], [ShownFolder]) {
    let parts = items(try runNotesScript(notesScript))
    guard parts.count == 12 else { throw IrisError("Notes returned \(parts.count) lists for notes, expected 12") }
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
    guard [names.count, created.count, modified.count, locked.count, shared.count, containers.count]
            .allSatisfy({ $0 == ids.count }),
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
        let folderId = home.flatMap { folderName[$0] == nil ? nil : $0 }
        notes.append(NoteInfo(id: ids[index], title: names[index],
                              folder: folderId.flatMap { folderName[$0] }, folderId: folderId,
                              account: folderId.flatMap { accountOf[$0] },
                              modifiedDate: modifiedDate, created: iso(createdDate),
                              locked: locked[index].booleanValue, shared: shared[index].booleanValue))
    }
    return (notes, folders)
}

/// The ids of the notes the named folders show; nil for every note. Match by id or name: a name in several
/// accounts takes each folder, and a name that matches nothing is an error, never every folder.
private func resolveFolders(_ tokens: [String], in folders: [ShownFolder]) throws -> Set<String>? {
    if tokens.isEmpty { return nil }
    var shown: Set<String> = []
    var missing: [String] = []
    for token in tokens {
        let hits = folders.filter { $0.id == token || $0.name == token }
        if hits.isEmpty { missing.append(token) } else { hits.forEach { shown.formUnion($0.noteIds) } }
    }
    guard missing.isEmpty else {
        throw IrisError("no folder named \(missing.joined(separator: ", ")); see `iris notes folders`")
    }
    return shown
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

    func validate() throws {
        guard isNoteId(id) else { throw ValidationError("not a note id; note ids come from `iris notes list`") }
    }

    func run() async throws {
        let note = try await MainActor.run { try readNote(id, html: html) }
        try emit(note)
    }
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
// answers missing value; any other error still fails. The folder lists join the note's container to a
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
            {name of theNote, creation date of theNote, modification date of theNote, ¬
                password protected of theNote, shared of theNote, container of theNote, ¬
                plaintext of theNote, \(html ? "body of theNote" : "missing value"), ¬
                name of every attachment of theNote, ¬
                id of every folder, name of every folder, name of every account, id of every folder of every account}
        end timeout
    end tell
    """
}

@MainActor
private func readNote(_ id: String, html: Bool) throws -> NoteDetail {
    let result = try runNotesScript(noteScript(id, html: html))
    guard result.descriptorType == typeAEList else { throw IrisError("no note with id \(id); see `iris notes list`") }
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
    let folderId = home.flatMap { folderName[$0] == nil ? nil : $0 }
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

private func notesError(_ error: NSDictionary) -> IrisError {
    let number = (error[NSAppleScript.errorNumber] as? NSNumber)?.intValue
    let message = error[NSAppleScript.errorMessage] as? String ?? ""
    switch number {
    case -1743:
        return IrisError("Iris may not control Notes; turn on Notes under Iris in System Settings › Privacy & Security › Automation")
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
