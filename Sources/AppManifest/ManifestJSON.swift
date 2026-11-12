/// The manifest as JSON, the form `guest.py` reads and every slice embeds in
/// its `rt.manifest` section (§10).
///
/// Keys are sorted and there's no whitespace, so the same manifest always
/// gives the same bytes. Written by hand: no Foundation, so the runner
/// builds anywhere `swiftc` does.
public extension App {

    /// Version of the JSON layout.
    static let manifestFormatVersion = 1

    func manifestJSON() -> String {
        var object: [String: JSONValue] = [
            "format": .integer(Self.manifestFormatVersion),
            "id": .string(id),
            "name": name.json,
            "version": .string(version),
            "build": .integer(build),
            "languages": .array(languages.map(JSONValue.string)),
            "capabilities": .array(capabilities.map(\.json)),
            "platforms": .array(platforms.map(\.json)),
        ]
        object["product"] = product.map(JSONValue.string)
        object["icon"] = icon.map(JSONValue.string)
        object["apple"] = apple.map(\.json)
        object["android"] = android.map(\.json)
        var output = ""
        JSONValue.object(object).write(to: &output)
        return output
    }
}

extension ManifestText {

    var json: JSONValue {
        switch self {
        case .verbatim(let value): .object(["value": .string(value)])
        case .localized(let key): .object(["key": .string(key)])
        }
    }
}

extension Capability {

    var json: JSONValue {
        var object: [String: JSONValue] = [
            "name": .string(name),
            "options": .object(options.mapValues(JSONValue.string)),
        ]
        object["usage"] = usage?.json
        return .object(object)
    }
}

extension Platform {

    var json: JSONValue {
        var object: [String: JSONValue] = ["name": .string(name)]
        object["minimum"] = minimum.map(JSONValue.string)
        object["minSDK"] = minSDK.map(JSONValue.integer)
        object["targetSDK"] = targetSDK.map(JSONValue.integer)
        return .object(object)
    }
}

extension AppleSettings {

    var json: JSONValue {
        var object: [String: JSONValue] = ["extraInfoPlist": .object(extraInfoPlist.mapValues(\.json))]
        object["category"] = category.map { .string($0.rawValue) }
        if !privacy.isEmpty {
            object["privacy"] = .object(privacy.mapValues(\.json))
        }
        return .object(object)
    }
}

extension AndroidSettings {

    var json: JSONValue {
        var object: [String: JSONValue] = [:]
        object["extraManifest"] = extraManifest.map(JSONValue.string)
        return .object(object)
    }
}

extension PropertyListValue {

    var json: JSONValue {
        switch self {
        case .string(let value): .string(value)
        case .integer(let value): .integer(value)
        case .real(let value): .real(value)
        case .boolean(let value): .boolean(value)
        case .array(let values): .array(values.map(\.json))
        case .dictionary(let values): .object(values.mapValues(\.json))
        }
    }
}

indirect enum JSONValue {

    case string(String)
    case integer(Int)
    case real(Double)
    case boolean(Bool)
    case array([JSONValue])
    case object([String: JSONValue])

    func write(to output: inout String) {
        switch self {
        case .string(let value):
            Self.write(string: value, to: &output)
        case .integer(let value):
            output += String(value)
        case .real(let value):
            // Always with a fraction or exponent, so it reads back as a real.
            var text = value.isFinite ? String(value) : "0.0"
            if !text.contains(".") && !text.contains("e") {
                text += ".0"
            }
            output += text
        case .boolean(let value):
            output += value ? "true" : "false"
        case .array(let values):
            output += "["
            for (index, value) in values.enumerated() {
                if index > 0 { output += "," }
                value.write(to: &output)
            }
            output += "]"
        case .object(let values):
            output += "{"
            for (index, key) in values.keys.sorted().enumerated() {
                if index > 0 { output += "," }
                Self.write(string: key, to: &output)
                output += ":"
                values[key]!.write(to: &output)
            }
            output += "}"
        }
    }

    private static func write(string: String, to output: inout String) {
        output += "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            case _ where scalar.value < 0x20:
                let hex = String(scalar.value, radix: 16)
                output += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
            default:
                output.unicodeScalars.append(scalar)
            }
        }
        output += "\""
    }
}
