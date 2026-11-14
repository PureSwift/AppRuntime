import Foundation
import RuntimeABI
import RuntimeHost
import Testing

/// Reading the app's keys, from a dictionary and from property list bytes.
@Suite struct AppInfoTests {

    static let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleIdentifier</key>
            <string>org.example.Weather</string>
            <key>CFBundleShortVersionString</key>
            <string>1.2</string>
            <key>CFBundleVersion</key>
            <string>7</string>
            <key>RTABIVersion</key>
            <integer>1</integer>
            <key>RTCapabilities</key>
            <array>
                <string>location</string>
            </array>
            <key>RTCapabilityUsage</key>
            <dict>
                <key>location</key>
                <string>LocationUsage</string>
            </dict>
            <key>RTContracts</key>
            <array>
                <dict>
                    <key>Kind</key>
                    <string>contract</string>
                    <key>Name</key>
                    <string>org.pureswift.ui.Renderer</string>
                    <key>Version</key>
                    <integer>1</integer>
                </dict>
                <dict>
                    <key>Kind</key>
                    <string>callback</string>
                    <key>Name</key>
                    <string>org.pureswift.ui.RendererDelegate</string>
                    <key>Version</key>
                    <integer>1</integer>
                </dict>
            </array>
            <key>RTTargets</key>
            <array>
                <string>android-arm64-v8a</string>
            </array>
        </dict>
        </plist>
        """

    @Test func readsPropertyListBytes() throws {
        let info = try AppInfo(propertyList: Data(Self.xml.utf8))
        #expect(info.identifier == "org.example.Weather")
        #expect(info.name == "Weather")
        #expect(info.version == "1.2")
        #expect(info.build == "7")
        #expect(info.abiVersion == 1)
        #expect(info.capabilities == [.location])
        #expect(info.capabilityUsage == ["location": "LocationUsage"])
        #expect(info.targets == ["android-arm64-v8a"])
        #expect(info.contracts == [
            AppInfo.Contract(name: "org.pureswift.ui.Renderer", version: 1, kind: .contract),
            AppInfo.Contract(name: "org.pureswift.ui.RendererDelegate", version: 1, kind: .callback),
        ])
        #expect(info.contractNames == ["org.pureswift.ui.Renderer", "org.pureswift.ui.RendererDelegate"])
    }

    @Test func readsADictionaryTheSameWay() throws {
        let data = Data(Self.xml.utf8)
        let dictionary = try #require(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        #expect(try AppInfo(infoDictionary: dictionary) == AppInfo(propertyList: data))
    }

    @Test func readsBinaryPropertyLists() throws {
        let data = Data(Self.xml.utf8)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        let binary = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        #expect(try AppInfo(propertyList: binary) == AppInfo(propertyList: data))
    }

    @Test func requiresTheABIVersion() {
        #expect(throws: AppInfoError.missing("RTABIVersion")) {
            try AppInfo(infoDictionary: ["CFBundleIdentifier": "org.example.App"])
        }
        let plist = """
            <plist version="1.0"><dict><key>CFBundleIdentifier</key><string>org.example.App</string></dict></plist>
            """
        #expect(throws: AppInfoError.missing("RTABIVersion")) {
            try AppInfo(propertyList: Data(plist.utf8))
        }
    }

    @Test func rejectsUnknownContractKinds() {
        let entry: [String: Any] = ["Name": "org.example.Thing", "Version": 1, "Kind": "service"]
        #expect(throws: AppInfoError.malformed("RTContracts")) {
            try AppInfo(infoDictionary: ["RTABIVersion": 1, "RTContracts": [entry]])
        }
        let plist = Self.xml.replacingOccurrences(of: "<string>callback</string>", with: "<string>service</string>")
        #expect(throws: AppInfoError.malformed("RTContracts")) {
            try AppInfo(propertyList: Data(plist.utf8))
        }
    }

    @Test func namesTheMalformedKey() {
        let plist = Self.xml.replacingOccurrences(
            of: "<key>RTABIVersion</key>\n    <integer>1</integer>",
            with: "<key>RTABIVersion</key>\n    <string>one</string>"
        )
        #expect(throws: AppInfoError.malformed("RTABIVersion")) {
            try AppInfo(propertyList: Data(plist.utf8))
        }
    }

    @Test func reportsAMissingFile() {
        #expect(throws: AppInfoError.missing("/nonexistent/Info.plist")) {
            try AppInfo(contentsOf: "/nonexistent/Info.plist")
        }
    }

    @Test func defaultsTheNameToTheIdentifiersLastPart() {
        #expect(AppInfo(identifier: "org.example.Weather", abiVersion: 1).name == "Weather")
        #expect(AppInfo(identifier: "Weather", abiVersion: 1).name == "Weather")
        #expect(AppInfo(identifier: "org.example.Weather", name: "Forecast", abiVersion: 1).name == "Forecast")
    }
}
