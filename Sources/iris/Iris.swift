import ArgumentParser
import EventKit

@main
struct Entry {
    static func main() async {
        becomeResponsible()
        await Iris.main()
    }
}

struct Iris: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "iris",
        abstract: "Apple Calendar for the agents you run. JSON on stdout, errors on stderr.",
        subcommands: [Status.self, CalendarCommand.self]
    )
}

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show the calendar permission state. Never prompts.")

    func run() throws {
        try emit(StatusInfo(responsible: responsibleDescription(),
                            calendars: describe(EKEventStore.authorizationStatus(for: .event))))
    }
}

struct StatusInfo: Encodable {
    let responsible: String
    let calendars: String
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
