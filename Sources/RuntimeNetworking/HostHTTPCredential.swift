import DynamicNetworking
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// `HTTPCredential` over a `URLCredential`. The password stays inside it.
public final class HostHTTPCredential: HTTPCredential {

    let credential: URLCredential

    private let persistenceValue: Int32

    init(user: String, password: String, persistence: Int32) {
        let persistenceValue = HTTPCredentialPersistence(rawValue: persistence) ?? .none
        let mapped: URLCredential.Persistence = switch persistenceValue {
        case .none: .none
        case .forSession: .forSession
        case .permanent: .permanent
        }
        self.credential = URLCredential(user: user, password: password, persistence: mapped)
        self.persistenceValue = persistenceValue.rawValue
    }

    public static func make(user: String, password: String, persistence: Int32) -> HostHTTPCredential {
        HostHTTPCredential(user: user, password: password, persistence: persistence)
    }

    public func user() -> String {
        credential.user ?? ""
    }

    public func persistence() -> Int32 {
        persistenceValue
    }
}
