import DynamicNetworking
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Network)
import Network
#endif

extension NetworkError {

    /// The contract's code for a URLSession failure (`HTTPClient.md`).
    /// Failures with no matching code are `unknown`; `report(_:)` logs them.
    ///
    /// Codes are matched as `URLError.Code`s, which have Apple's values on
    /// every platform. swift-corelibs-foundation's `NSURLError…` constants
    /// for TLS and certificate failures are one less than those (its
    /// `NSURLErrorSecureConnectionFailed` is Apple's
    /// `NSURLErrorServerCertificateHasBadDate`), and its URLSession reports
    /// those failures as `NSURLErrorUnknown` anyway.
    init(urlSessionError error: Error) {
        let error = error as NSError
        guard error.domain == NSURLErrorDomain else {
            self = .unknown
            return
        }
        switch URLError.Code(rawValue: error.code) {
        case .cancelled:
            self = .cancelled
        case .badURL, .unsupportedURL:
            self = .invalidURL
        case .timedOut:
            self = .timedOut
        case .cannotFindHost, .dnsLookupFailed:
            self = .cannotFindHost
        case .cannotConnectToHost:
            self = .cannotConnectToHost
        case .networkConnectionLost:
            self = .connectionLost
        case .notConnectedToInternet:
            self = Self.unavailableNetwork(error)
        case .internationalRoamingOff, .dataNotAllowed:
            self = .networkAccessNotAllowed
        case .callIsActive:
            self = .notConnectedToInternet
        case .secureConnectionFailed, .clientCertificateRejected, .clientCertificateRequired:
            self = .secureConnectionFailed
        case .serverCertificateUntrusted, .serverCertificateHasBadDate,
            .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
            self = .serverCertificateUntrusted
        case .appTransportSecurityRequiresSecureConnection:
            self = .insecureConnectionNotAllowed
        case .httpTooManyRedirects:
            self = .tooManyRedirects
        case .badServerResponse, .redirectToNonExistentLocation, .zeroByteResource,
            .cannotDecodeRawData, .cannotDecodeContentData, .cannotParseResponse:
            self = .badServerResponse
        case .userAuthenticationRequired, .userCancelledAuthentication:
            self = .userAuthenticationRequired
        // A cache-only load with nothing cached.
        case .resourceUnavailable, .cannotLoadFromNetwork:
            self = .resourceUnavailable
        default:
            self = .unknown
        }
    }

    /// `NSURLErrorNotConnectedToInternet` covers a network that's there but
    /// that the configuration or the user disallowed. Only Apple platforms
    /// say which; elsewhere it's always `notConnectedToInternet`.
    private static func unavailableNetwork(_ error: NSError) -> NetworkError {
        #if canImport(Network)
        if let reason = (error as Error as? URLError)?.networkUnavailableReason {
            switch reason {
            case .cellular, .expensive, .constrained:
                return .networkAccessNotAllowed
            default:
                break
            }
        }
        // The path URLSession gave up on says if local network access was
        // denied (iOS 14+). The key isn't public API, so its absence is
        // normal.
        if let path = error.userInfo["_NSURLErrorNWPathKey"] as? nw_path_t,
           nw_path_get_unsatisfied_reason(path) == nw_path_unsatisfied_reason_local_network_denied {
            return .localNetworkDenied
        }
        #endif
        return .notConnectedToInternet
    }

    /// Logs a failure the contract has no code for, so it isn't lost
    /// (`HostNetworkingModule.log`). Call on the main thread.
    static func report(_ error: Error, code: NetworkError) {
        guard code == .unknown, let log = HostNetworkingModule.log else { return }
        let error = error as NSError
        log("HTTP task failed with an error the contract has no code for: \(error.domain) \(error.code): \(error.localizedDescription)")
    }
}
