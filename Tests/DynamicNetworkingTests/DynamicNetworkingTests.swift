import Testing
import DynamicNetworking
import DynamicRuntime

/// Pins the HTTP client contracts.
@Suite struct DynamicNetworkingTests {

    func method(_ descriptor: ContractDescriptor, _ key: String) -> MethodDescriptor? {
        descriptor.methods.first { $0.key == key }
    }

    static let descriptors = [
        HTTPSessionConfigurationProxy.descriptor, HTTPSessionProxy.descriptor, HTTPRequestProxy.descriptor,
        HTTPResponseProxy.descriptor, HTTPTaskProxy.descriptor, HTTPTaskDelegateProxy.descriptor,
        HTTPCredentialProxy.descriptor, ParsedURLProxy.descriptor,
    ]

    @Test func session() {
        let session = HTTPSessionProxy.descriptor
        #expect(session.capability == .network)
        #expect(method(session, "shared") == MethodDescriptor("shared", "()O", .constructor))
        #expect(method(session, "make:")?.kind == .constructor)
        #expect(method(session, "dataTask:delegate:")?.signature == Signature("(OO)O"))
        #expect(method(session, "uploadTask:body:delegate:")?.signature == Signature("(OOO)O"))
        #expect(method(HTTPSessionConfigurationProxy.descriptor, "makeEphemeral")?.kind == .constructor)
        #expect(method(HTTPSessionConfigurationProxy.descriptor, "setAllowsConstrainedNetworkAccess:")?.signature == Signature("(Z)V"))
    }

    @Test func tasksStartSuspended() {
        let task = HTTPTaskProxy.descriptor
        #expect(method(task, "resume") != nil)
        #expect(method(task, "suspend") == nil, "suspending isn't portable")
        #expect(method(task, "countOfBytesExpectedToReceive")?.signature == Signature("()J"))
        #expect(method(HTTPRequestProxy.descriptor, "make:")?.signature == Signature("(O)O"), "failable constructor")
    }

    @Test func synchronousDecisions() {
        let delegate = HTTPTaskDelegateProxy.descriptor
        #expect(method(delegate, "willPerformRedirect:response:newRequest:")?.signature == Signature("(OOO)Z"))
        #expect(method(delegate, "didReceiveResponse:response:")?.signature == Signature("(OO)Z"))
        #expect(method(delegate, "didReceiveChallenge:method:host:realm:previousFailureCount:")?.signature == Signature("(OIOOI)O"))
        #expect(method(delegate, "didSendBodyData:bytesSent:totalBytesSent:totalBytesExpectedToSend:")?.signature == Signature("(OJJJ)V"))
        #expect(method(HTTPCredentialProxy.descriptor, "make:password:persistence:")?.signature == Signature("(OOI)O"))
        #expect(method(HTTPCredentialProxy.descriptor, "password") == nil, "the password is write-only")
    }

    @Test func recordsRoundTrip() {
        #expect(Set(Self.descriptors.map(\.name)).count == Self.descriptors.count)
        #expect(ContractMetadata.decode(Self.descriptors.flatMap(ContractMetadata.encode)) == Self.descriptors)
    }

    @Test func codes() {
        #expect(NetworkError(rawValue: 12) == .insecureConnectionNotAllowed)
        #expect(HTTPTaskState(rawValue: 1) == .suspended)
    }
}
