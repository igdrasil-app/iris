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
        abstract: "Apple Calendar, Notes and Reminders for the agents you run. JSON on stdout, errors on stderr.",
        discussion: "Opened as an app without arguments (Finder, open -a Iris, login), Iris shows a menu bar icon instead, with whether iris mcp --http is running, what it allows in Calendar, Reminders and Notes, and any permission Iris lacks. Its Remote access switch runs iris mcp --http itself, with the default files, on port 8765 or the one set with defaults write app.igdrasil.iris remoteAccessPort -int <port>, logging to ~/Library/Logs/iris-http.log; turned on with no token file or no scope file, it creates them, the scope sharing nothing. It starts none while another iris mcp --http runs.",
        subcommands: [Status.self, Doctor.self, CalendarCommand.self, NotesCommand.self, RemindersCommand.self, MCP.self, RemoteCommand.self]
    )
}

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show the Calendar, Notes and Reminders permission state. Never prompts.")

    func run() throws {
        try emit(StatusInfo(responsible: responsibleDescription(),
                            calendars: describe(EKEventStore.authorizationStatus(for: .event)),
                            notes: notesPermission(),
                            reminders: describe(EKEventStore.authorizationStatus(for: .reminder))))
    }
}

struct StatusInfo: Encodable {
    let responsible: String
    let calendars: String
    let notes: String
    let reminders: String
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
