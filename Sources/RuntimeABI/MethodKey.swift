/// Derives portable method keys from Swift declarations (§4.3).
///
/// The key is the base name, then `:` for the first parameter, then
/// `label:` for every later parameter. An unlabeled later parameter
/// contributes a bare `:`.
///
/// | Swift | Key |
/// |---|---|
/// | `stopScan()` | `stopScan` |
/// | `connect(_ p: Peripheral)` | `connect:` |
/// | `connect(_ p: Peripheral, timeout: Int32)` | `connect:timeout:` |
/// | `scan(services: [String], allowDuplicates: Bool)` | `scan:allowDuplicates:` |
/// | `replaceSubtree(_ id: [UInt8], _ tree: [UInt8])` | `replaceSubtree::` |
///
/// Contracts forbid overloads, so base name plus arity is unique and every
/// backend can map the key to its own convention (Java name + arity, ObjC
/// selector).
public enum MethodKey {

    /// Builds a key from a base name and argument labels (`nil` = unlabeled).
    public static func make(baseName: String, labels: [String?]) -> String {
        var key = baseName
        for (index, label) in labels.enumerated() {
            if index > 0, let label {
                key += label
            }
            key += ":"
        }
        return key
    }

    /// Number of arguments a key describes.
    public static func arity(of key: String) -> Int {
        key.utf8.reduce(0) { $0 + ($1 == 0x3A ? 1 : 0) }
    }

    /// The base name of a key.
    public static func baseName(of key: String) -> Substring {
        key.prefix { $0 != ":" }
    }
}
