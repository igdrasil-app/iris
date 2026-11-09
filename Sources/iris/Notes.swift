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
        abstract: "List Notes folders: id, name, account, noteCount.",
        discussion: """
            Every folder of every account, subfolders and Recently Deleted included. Names can repeat; \
            the id tells folders apart. noteCount is what the folder shows: a note shown in several \
            folders, as a smart folder does, counts in each. The first run asks to let Iris control Notes; \
            a denial is changed under System Settings › Privacy & Security › Automation.
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
    let noteCount: Int
}

// One Apple Event per property, each covering every folder: one event per folder costs ~46 ms.
// The order of `every folder` is the same in each, so the lists line up by index.
private let foldersScript = """
    tell application "Notes"
        {id of every folder, name of every folder, id of every note of every folder, ¬
            name of every account, id of every folder of every account}
    end tell
    """

@MainActor
private func readFolders() throws -> [FolderInfo] {
    let parts = items(try runNotesScript(foldersScript))
    guard parts.count == 5 else { throw IrisError("Notes returned \(parts.count) lists for folders, expected 5") }
    let ids = strings(parts[0])
    let names = strings(parts[1])
    let noteLists = items(parts[2])
    let accounts = strings(parts[3])
    let accountFolders = items(parts[4])
    guard names.count == ids.count, noteLists.count == ids.count, accountFolders.count == accounts.count else {
        throw IrisError("Notes changed while folders were read; run again")
    }

    // Folders join their account by id: names repeat across accounts and parents.
    var accountOf: [String: String] = [:]
    for (account, folders) in zip(accounts, accountFolders) {
        for id in strings(folders) { accountOf[id] = account }
    }

    var folders: [FolderInfo] = []
    for index in ids.indices {
        guard let account = accountOf[ids[index]] else { throw IrisError("Notes changed while folders were read; run again") }
        folders.append(FolderInfo(id: ids[index], name: names[index], account: account,
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
