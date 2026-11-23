import DynamicFiles
import DynamicRuntime
#if canImport(DynamicSwiftUI)
import DynamicSwiftUI
#else
import SwiftUI
#endif

/// A download a page started and `WebPage.downloadDecider` accepted.
///
/// It's observable: a view that reads `bytesReceived` updates as it goes.
/// When it's done, `file` is where it is, in the app's caches under
/// `Downloads/`. The file is the app's: give the user a copy with
/// `DocumentPicker`'s `export`, or move it with `Files`.
public final class WebDownload: Observable {

    /// What the page asked to download.
    public let request: WebDownloadRequest

    public var bytesReceived: Int64 {
        registrar.access(self, propertyIndex: 0)
        return values.bytesReceived
    }

    /// `nil` while the server hasn't said.
    public var expectedLength: Int64? {
        registrar.access(self, propertyIndex: 1)
        return values.expectedLength
    }

    /// Where the file is, once it's done.
    public var file: FilePath? {
        registrar.access(self, propertyIndex: 2)
        return values.file
    }

    /// Why it stopped: `.cancelled` after `cancel()`.
    public var error: WebError? {
        registrar.access(self, propertyIndex: 3)
        return values.error
    }

    /// Done, or stopped.
    public var isFinished: Bool {
        file != nil || error != nil
    }

    /// Stops it, if it isn't done.
    public func cancel() {
        guard let content else { return }
        if WebContentProxy.Methods.cancelDownload.isAvailable {
            content.cancelDownload(identifier)
        }
        failed(WebError(.cancelled))
    }

    init(_ identifier: Int32, _ request: WebDownloadRequest, content: any WebContent) {
        self.identifier = identifier
        self.request = request
        self.content = content
        values.expectedLength = request.expectedLength
    }

    private struct Values {
        var bytesReceived: Int64 = 0
        var expectedLength: Int64?
        var file: FilePath?
        var error: WebError?
    }

    private let identifier: Int32

    private let registrar = ObservationRegistrar()

    private var values = Values()

    /// The host's page, while the download goes on.
    private var content: (any WebContent)?

    private func mutate(_ index: Int, _ change: () -> Void) {
        registrar.withMutation(of: self, propertyIndex: index, change)
    }

    func progressed(received: Int64, expected: Int64) {
        guard content != nil else { return }
        if received != values.bytesReceived {
            mutate(0) { values.bytesReceived = received }
        }
        let expectedLength = expected < 0 ? nil : expected
        if expectedLength != values.expectedLength {
            mutate(1) { values.expectedLength = expectedLength }
        }
    }

    func finished(_ file: FilePath) {
        guard content != nil else { return }
        content = nil
        mutate(2) { values.file = file }
    }

    func failed(_ error: WebError) {
        guard content != nil else { return }
        content = nil
        mutate(3) { values.error = error }
    }
}

/// A site's request for the camera, the microphone or location, for
/// `WebPage.onPermissionRequest`. The first answer counts; one let go
/// unanswered is denied.
///
/// The platform asks the user for the app as it does for any of the app's
/// own uses, the first time. The engine doesn't remember a site's answer:
/// an app that offers "always allow" keeps it itself, by `origin`.
public final class WebPermissionRequest {

    /// The site asking, such as `https://meet.example.com`.
    public let origin: String

    public let kinds: WebPermissionKinds

    public func grant() {
        answer(true)
    }

    public func deny() {
        answer(false)
    }

    public func answer(_ granted: Bool) {
        guard let content else { return }
        self.content = nil
        if WebContentProxy.Methods.answerPermission.isAvailable {
            content.answerPermission(identifier, granted: granted)
        }
    }

    init(_ identifier: Int32, origin: String, kinds: WebPermissionKinds, content: any WebContent) {
        self.identifier = identifier
        self.origin = origin
        self.kinds = kinds
        self.content = content
    }

    deinit {
        answer(false)
    }

    private let identifier: Int32

    private var content: (any WebContent)?
}
