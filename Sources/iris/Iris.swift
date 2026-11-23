import ArgumentParser
import EventKit

@main
struct Entry {
    static func main() async {
        if launchedAsApp() { runMenuBar() }
        becomeResponsible()
        await Iris.main()
    }
}

struct Iris: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "iris",
        abstract: "Apple Calendar and Notes for the agents you run. JSON on stdout, errors on stderr.",
        discussion: "Opened as an app without arguments (Finder, open -a Iris, login), Iris shows a menu bar icon with the Calendar and Notes permission state instead.",
        subcommands: [Status.self, Doctor.self, CalendarCommand.self, NotesCommand.self, MCP.self]
    )
}

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show the Calendar and Notes permission state. Never prompts.")

    func run() throws {
        try emit(StatusInfo(responsible: responsibleDescription(),
                            calendars: describe(EKEventStore.authorizationStatus(for: .event)),
                            notes: notesPermission()))
    }
}

struct StatusInfo: Encodable {
    let responsible: String
    let calendars: String
    let notes: String
}

func describe(_ status: EKAuthorizationStatus) -> String {
    switch status {
    case .notDetermined: return "not determined"
    case .restricted: return "restricted"
    case .denied: return "denied"
    case .fullAccess: return "full access"
    case .writeOnly: return "write only"
    @unknown default: return "unknown (\(status.rawValue))"
    }
}
