import ArgumentParser
import EventKit
import Foundation

struct Doctor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show the installed version and path, the permission state, and whether a newer release exists. Never prompts.",
        discussion: """
            version and bundle come from Iris.app, so a bare build prints null for both. \
            latest is the newest release on the Homebrew tap, null when GitHub does not answer \
            within a few seconds; that is never an error. update holds the upgrade command and \
            is present only when latest is newer than version.
            """
    )

    func run() async throws {
        let executable = executablePath().map { URL(fileURLWithPath: $0).resolvingSymlinksInPath() }
        let app = executable.flatMap(installedApp)
        let version = app?.infoDictionary?["CFBundleShortVersionString"] as? String
        let latest = await latestRelease()
        var update: String?
        if let version, let latest, isNewer(latest, than: version) {
            update = "brew upgrade --cask igdrasil-app/tap/iris"
        }
        try emit(DoctorInfo(version: version,
                            path: executable?.path,
                            bundle: app?.bundleIdentifier,
                            calendars: describe(EKEventStore.authorizationStatus(for: .event)),
                            responsible: responsibleDescription(),
                            latest: latest,
                            update: update))
    }
}

/// The app around the binary, three directories up from Contents/MacOS/iris. Bundle.main
/// does not look through Homebrew's symlink, and a bare build is in no app at all.
func installedApp(around executable: URL) -> Bundle? {
    let app = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    guard app.pathExtension == "app" else { return nil }
    return Bundle(url: app)
}

struct DoctorInfo: Encodable {
    let version: String?
    let path: String?
    let bundle: String?
    let calendars: String
    let responsible: String
    let latest: String?
    let update: String?

    enum CodingKeys: CodingKey { case version, path, bundle, calendars, responsible, latest, update }

    // An unknown fact prints as null so the reader sees the check ran; update is only there when there is one.
    func encode(to encoder: Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(version, forKey: .version)
        try fields.encode(path, forKey: .path)
        try fields.encode(bundle, forKey: .bundle)
        try fields.encode(calendars, forKey: .calendars)
        try fields.encode(responsible, forKey: .responsible)
        try fields.encode(latest, forKey: .latest)
        try fields.encodeIfPresent(update, forKey: .update)
    }
}

/// The newest release on the tap without its v, or nil when GitHub does not answer within the timeout.
func latestRelease() async -> String? {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 3
    configuration.timeoutIntervalForResource = 3
    var request = URLRequest(url: URL(string: "https://api.github.com/repos/igdrasil-app/homebrew-tap/releases/latest")!)
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    request.setValue("iris", forHTTPHeaderField: "User-Agent")
    guard let (data, response) = try? await URLSession(configuration: configuration).data(for: request),
          (response as? HTTPURLResponse)?.statusCode == 200,
          let release = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let tag = release["tag_name"] as? String else { return nil }
    return tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
}

/// Compares numbers, not text: 0.1.10 is newer than 0.1.9.
func isNewer(_ candidate: String, than current: String) -> Bool {
    func numbers(_ version: String) -> [Int] { version.split(separator: ".").map { Int($0) ?? 0 } }
    return numbers(current).lexicographicallyPrecedes(numbers(candidate))
}
