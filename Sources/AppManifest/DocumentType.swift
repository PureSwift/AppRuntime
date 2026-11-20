/// A kind of file the app opens, so the system offers the app for it: in
/// the file manager's "open with", and from other apps.
///
/// ```swift
/// documentTypes: [
///     .init(name: .localized("type.image"), types: ["image/*"], role: .viewer),
///     .init(name: "Text", types: ["text/plain", ".md"], role: .editor),
/// ]
/// ```
///
/// The files arrive through `DocumentPicker.opened`, so an app with
/// document types declares `.userFiles`.
public struct DocumentType: Sendable, Equatable {

    /// What people call this kind of file.
    public var name: ManifestText

    /// MIME types (`image/png`), MIME groups (`image/*`) and extensions
    /// (`.gpx`), as a picker takes them. Android matches by MIME type only.
    public var types: [String]

    public var role: DocumentRole

    public init(name: ManifestText, types: [String], role: DocumentRole = .viewer) {
        self.name = name
        self.types = types
        self.role = role
    }
}

/// What an app does with a kind of file.
public enum DocumentRole: String, Sendable {

    /// Shows it.
    case viewer

    /// Changes it, and saves it back.
    case editor
}
