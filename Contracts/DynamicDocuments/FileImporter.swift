import DynamicFiles
import DynamicRuntime
#if canImport(DynamicSwiftUI)
import DynamicSwiftUI
#else
import SwiftUI
#endif

/// `UTType`'s name, so a SwiftUI call compiles as written.
public typealias UTType = ContentType

/// Whether a view's picker is showing, kept across updates.
final class PickerPresentation {

    private var isShowing = false

    /// Shows the picker when `isPresented` turns true, once. `show` is
    /// handed what to call when the picker has gone.
    ///
    /// The view is being evaluated when this is called, so the picker is
    /// asked for once that's done: a host that answers at once then
    /// changes the app's state between updates, and not during one.
    func update(_ isPresented: Bool, show: @escaping (@escaping () -> Void) -> Void) {
        guard isPresented, !isShowing else { return }
        isShowing = true
        GuestExecutor.whenIdle {
            show { self.isShowing = false }
        }
    }
}

/// A view that shows the platform's picker for opening files while
/// `isPresented` is true. The picker is the host's own, over the app's
/// window: nothing goes into the render IR.
public struct _FileImporterView<Content: View>: View {

    let content: Content

    let isPresented: Binding<Bool>

    let types: [ContentType]

    let allowsMultiple: Bool

    let access: DocumentAccess

    let onCompletion: (Result<[Document], DocumentError>) -> Void

    @State private var presentation = PickerPresentation()

    init(
        content: Content,
        isPresented: Binding<Bool>,
        types: [ContentType],
        allowsMultiple: Bool,
        access: DocumentAccess,
        onCompletion: @escaping (Result<[Document], DocumentError>) -> Void
    ) {
        self.content = content
        self.isPresented = isPresented
        self.types = types
        self.allowsMultiple = allowsMultiple
        self.access = access
        self.onCompletion = onCompletion
    }

    public var body: some View {
        let isPresented = self.isPresented
        let onCompletion = self.onCompletion
        presentation.update(isPresented.wrappedValue) { finished in
            DocumentPicker().open(types, allowsMultiple: allowsMultiple, access: access) { result in
                finished()
                isPresented.wrappedValue = false
                if case .success(let documents) = result, documents.isEmpty {
                    // Cancelled: nothing to report, as in SwiftUI.
                    return
                }
                onCompletion(result)
            }
        }
        return content
    }
}

/// A view that shows the platform's picker for saving a file while
/// `isPresented` is true.
public struct _FileExporterView<Content: View>: View {

    let content: Content

    let isPresented: Binding<Bool>

    let file: FilePath?

    let defaultFilename: String?

    let onCompletion: (Result<Document?, DocumentError>) -> Void

    @State private var presentation = PickerPresentation()

    init(
        content: Content,
        isPresented: Binding<Bool>,
        file: FilePath?,
        defaultFilename: String?,
        onCompletion: @escaping (Result<Document?, DocumentError>) -> Void
    ) {
        self.content = content
        self.isPresented = isPresented
        self.file = file
        self.defaultFilename = defaultFilename
        self.onCompletion = onCompletion
    }

    public var body: some View {
        let isPresented = self.isPresented
        let onCompletion = self.onCompletion
        if let file {
            presentation.update(isPresented.wrappedValue) { finished in
                DocumentPicker().export(file, suggestedName: defaultFilename) { result in
                    finished()
                    isPresented.wrappedValue = false
                    switch result {
                    case .success(.cancelled):
                        // Nothing to report, as in SwiftUI.
                        break
                    case .success(let export):
                        onCompletion(.success(export.document))
                    case .failure(let error):
                        onCompletion(.failure(error))
                    }
                }
            }
        }
        return content
    }
}

extension View {

    /// Shows the platform's picker for opening files while `isPresented`
    /// is true, and sets it back to false when the picker goes.
    ///
    /// ```swift
    /// .fileImporter(isPresented: $importing, allowedContentTypes: [.image]) { result in
    ///     if case .success(let documents) = result { show(documents) }
    /// }
    /// ```
    ///
    /// As SwiftUI's, with a `Document` where SwiftUI gives a `URL`, and
    /// `access` for a file the app means to change. Cancelling calls
    /// nothing.
    public func fileImporter(
        isPresented: Binding<Bool>,
        allowedContentTypes: [ContentType],
        allowsMultipleSelection: Bool = false,
        access: DocumentAccess = .read,
        onCompletion: @escaping (Result<[Document], DocumentError>) -> Void
    ) -> _FileImporterView<Self> {
        _FileImporterView(content: self, isPresented: isPresented, types: allowedContentTypes,
                          allowsMultiple: allowsMultipleSelection, access: access, onCompletion: onCompletion)
    }

    /// Shows the platform's picker for saving `file` while `isPresented`
    /// is true: a file the app already wrote, in one of its own
    /// directories or in another document. With no file, nothing shows.
    ///
    /// ```swift
    /// .fileExporter(isPresented: $exporting, file: draft, defaultFilename: "Notes.txt") { result in
    ///     if case .success(let saved?) = result { document = saved }
    /// }
    /// ```
    ///
    /// The result is the saved document, or `nil` where the host saved a
    /// copy it can't reach again. Cancelling calls nothing.
    public func fileExporter(
        isPresented: Binding<Bool>,
        file: FilePath?,
        defaultFilename: String? = nil,
        onCompletion: @escaping (Result<Document?, DocumentError>) -> Void
    ) -> _FileExporterView<Self> {
        _FileExporterView(content: self, isPresented: isPresented, file: file,
                          defaultFilename: defaultFilename, onCompletion: onCompletion)
    }
}
