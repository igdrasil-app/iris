import ArgumentParser
import Foundation

struct NotesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "notes",
        abstract: "Read Apple Notes.",
        subcommands: [NoteFolders.self]
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

    // Folders join their account by id: names repeat across accounts and parents.
    var accountOf: [String: String] = [:]
    for (account, folders) in zip(accounts, accountFolders) {
        for id in strings(folders) { accountOf[id] = account }
    }

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

/// NSAppleScript must run on the main thread: off it the reply never arrives and the call hangs with no timeout.
/// The source is always a fixed string; nothing a caller supplies is pasted into it.
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
