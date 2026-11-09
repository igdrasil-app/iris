import AppKit
import ArgumentParser
import Foundation

// IGD-84 throwaway: times Apple Events to Notes from inside the signed app. Not shipped.
struct NotesSpike: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "notes-spike", shouldDisplay: false)

    @Option var folder = "Notes"

    func run() throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        let running = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Notes").isEmpty
        print("Notes running before first event: \(running)")
        let f = "folder \"\(folder)\""

        time("count of all notes", "count of notes")
        time("folders: name of every folder", "name of every folder")
        time("folders again (warm)", "name of every folder")
        time("count in \(f)", "count of notes of \(f)")
        time("batched: name+id+mod date of every note of \(f)",
             "{name, id, modification date} of every note of \(f)")
        time("looped: name of each note of \(f)", """
            set out to {}
            repeat with n in notes of \(f)
                set end of out to name of n
            end repeat
            out
            """)
        time("batched: name of every note, all accounts", "name of every note")
        let firstID = time("id of note 1 of \(f)", "id of note 1 of \(f)")
        if let id = firstID?.stringValue {
            time("body of one note by id", "body of note id \"\(id)\"")
            time("plaintext of one note by id", "plaintext of note id \"\(id)\"")
        }
        time("batched: plaintext of every note of \(f)", "plaintext of every note of \(f)")
        time("batched: plaintext of every note, all accounts", "plaintext of every note")
        time("search: name of notes whose plaintext contains \"the\"",
             "name of every note whose plaintext contains \"the\"")
    }

    @discardableResult
    func time(_ label: String, _ body: String) -> NSAppleEventDescriptor? {
        let source = "tell application \"Notes\"\n\(body)\nend tell"
        guard let script = NSAppleScript(source: source) else { print("\(label): compile failed"); return nil }
        var error: NSDictionary?
        let start = Date()
        // NSAppleScript is main-thread only; off it the reply never arrives.
        let result = DispatchQueue.main.sync { script.executeAndReturnError(&error) }
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        if let error {
            print("\(label): \(ms) ms ERROR \(error[NSAppleScript.errorNumber] ?? "") \(error[NSAppleScript.errorMessage] ?? "")")
            return nil
        }
        let size = result.numberOfItems > 0 ? "\(result.numberOfItems) items" : String((result.stringValue ?? "").prefix(60))
        print("\(label): \(ms) ms -> \(size)")
        return result
    }
}
