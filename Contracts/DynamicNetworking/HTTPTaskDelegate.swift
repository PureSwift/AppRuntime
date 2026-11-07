import DynamicRuntime

/// Receives an `HTTPTask`'s events on the main thread, in order: one
/// response, any number of data chunks, then completion.
@DynamicCallback("org.pureswift.network.HTTPTaskDelegate")
public protocol HTTPTaskDelegate: AnyObject {

    func didReceiveResponse(_ task: HTTPTask, response: HTTPResponse)

    func didReceiveData(_ task: HTTPTask, data: [UInt8])

    /// `error` is a `NetworkError` raw value, `0` on success; `message` is
    /// the host's description of the failure.
    func didComplete(_ task: HTTPTask, error: Int32, message: String?)
}
