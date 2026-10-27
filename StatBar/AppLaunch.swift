import Foundation

enum AppLaunchMode: Equatable {
    case normal
    case report(seconds: Double)
    case snapshot(path: String, light: Bool)
    case measureIdle

    init(arguments: [String]) throws {
        let modes = ["--report", "--snapshot", "--measure-idle"].filter { arguments.contains($0) }
        guard modes.count <= 1 else {
            throw LaunchError("Use only one of --report, --snapshot, or --measure-idle.")
        }
        if let index = arguments.firstIndex(of: "--snapshot") {
            guard arguments.indices.contains(index + 1), !arguments[index + 1].hasPrefix("-") else {
                throw LaunchError("--snapshot requires an output PNG path.")
            }
            self = .snapshot(path: arguments[index + 1], light: arguments.contains("--snapshot-light"))
        } else if let index = arguments.firstIndex(of: "--report") {
            var seconds = 4.5
            if arguments.indices.contains(index + 1) {
                let value = arguments[index + 1]
                // Defaults flags may follow --report without an explicit duration.
                if !value.hasPrefix("-") || Double(value) != nil {
                    guard let duration = Double(value), duration.isFinite, duration > 0, duration <= 86_400 else {
                        throw LaunchError("--report duration must be greater than zero and at most 86400 seconds.")
                    }
                    seconds = duration
                }
            }
            self = .report(seconds: seconds)
        } else if arguments.contains("--measure-idle") {
            self = .measureIdle
        } else {
            self = .normal
        }
    }

    var isDiagnostic: Bool { self != .normal }

    var isHeadless: Bool {
        switch self {
        case .report, .snapshot: true
        case .normal, .measureIdle: false
        }
    }

    struct LaunchError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}

/// Every concurrently launching copy elects the same oldest process. A copy must
/// never defer to a younger process, or both copies can decide to quit.
struct AppInstance: Equatable {
    let processIdentifier: Int32
    let launchDate: Date?

    func precedes(_ other: AppInstance) -> Bool {
        let date = launchDate ?? .distantPast
        let otherDate = other.launchDate ?? .distantPast
        return date == otherDate ? processIdentifier < other.processIdentifier : date < otherDate
    }
}
