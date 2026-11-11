import Testing
import AppManifest

@Suite struct AppManifestTests {

    @Test func designExampleEncodes() {
        let app = App(
            id: "org.pureswift.blescanner",
            name: .localized("app.name"),
            version: "1.4.0", build: 42,
            languages: ["en", "es"],
            product: "BLEScanner",
            capabilities: [
                .bluetooth(usage: .localized("perm.bluetooth")),
                .location(.whenInUse, usage: .localized("perm.location")),
            ],
            platforms: [.iOS("15.0"), .macOS("12.0"), .android(minSDK: 26, targetSDK: 35), .linux],
            icon: "AppIcon.png",
            apple: .init(category: .utilities, extraInfoPlist: ["UIRequiresFullScreen": true])
        )
        #expect(app.manifestJSON() == #"""
            {"apple":{"category":"public.app-category.utilities","extraInfoPlist":{"UIRequiresFullScreen":true}},\#
            "build":42,\#
            "capabilities":[{"name":"bluetooth","options":{},"usage":{"key":"perm.bluetooth"}},\#
            {"name":"location","options":{"access":"whenInUse"},"usage":{"key":"perm.location"}}],\#
            "format":1,"icon":"AppIcon.png","id":"org.pureswift.blescanner","languages":["en","es"],\#
            "name":{"key":"app.name"},\#
            "platforms":[{"minimum":"15.0","name":"ios"},{"minimum":"12.0","name":"macos"},\#
            {"minSDK":26,"name":"android","targetSDK":35},{"name":"linux"}],\#
            "product":"BLEScanner","version":"1.4.0"}
            """#)
    }

    @Test func optionalFieldsAreLeftOut() {
        let app = App(id: "org.example.Minimal", name: "Minimal", version: "1", build: 1, platforms: [.linux])
        #expect(app.manifestJSON() == #"{"build":1,"capabilities":[],"format":1,"id":"org.example.Minimal","languages":["en"],"name":{"value":"Minimal"},"platforms":[{"name":"linux"}],"version":"1"}"#)
    }

    @Test func stringsAndValuesAreEscaped() {
        let app = App(
            id: "org.example.Escapes",
            name: "Say \"hi\"\n\\ \u{1}",
            version: "1.0",
            build: 1,
            capabilities: [.notifications, .network, .graphics()],
            platforms: [.tvOS("13.0"), .watchOS("6.0"), .visionOS("1.0")],
            apple: .init(extraInfoPlist: [
                "Real": 2.0,
                "Ratio": 0.5,
                "List": ["a", 1],
                "Nested": ["Key": false],
            ]),
            android: .init(extraManifest: "<uses-feature android:name=\"x\"/>")
        )
        let json = app.manifestJSON()
        #expect(json.contains(#""name":{"value":"Say \"hi\"\n\\ \u0001"}"#))
        #expect(json.contains(#"{"List":["a",1],"Nested":{"Key":false},"Ratio":0.5,"Real":2.0}"#))
        #expect(json.contains(#""android":{"extraManifest":"<uses-feature android:name=\"x\"/>"}"#))
        #expect(json.contains(#"{"name":"graphics","options":{"api":"gles2"}}"#))
        #expect(json.contains(#"[{"minimum":"13.0","name":"tvos"},{"minimum":"6.0","name":"watchos"},{"minimum":"1.0","name":"visionos"}]"#))
    }
}
