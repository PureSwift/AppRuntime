/// A task the system may start the app to run in the background. iOS runs
/// only the tasks an app's `Info.plist` names, so they're declared, on
/// every platform.
///
/// ```swift
/// backgroundTasks: [
///     .refresh("org.example.mail.sync"),
///     .processing("org.example.mail.index"),
/// ]
/// ```
///
/// An app with tasks declares `.backgroundTasks`.
public struct BackgroundTaskDeclaration: Sendable, Equatable {

    /// What `BackgroundTaskRequest` names: usually the app's identifier
    /// and what the task does.
    public var identifier: String

    public var kind: Kind

    public enum Kind: String, Sendable {

        /// Short and frequent: fetching what's new.
        case refresh

        /// Long and rare, when the device is idle.
        case processing
    }

    public init(identifier: String, kind: Kind) {
        self.identifier = identifier
        self.kind = kind
    }

    public static func refresh(_ identifier: String) -> BackgroundTaskDeclaration {
        BackgroundTaskDeclaration(identifier: identifier, kind: .refresh)
    }

    public static func processing(_ identifier: String) -> BackgroundTaskDeclaration {
        BackgroundTaskDeclaration(identifier: identifier, kind: .processing)
    }
}
