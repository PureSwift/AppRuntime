// The example app's manifest (§7.1). Build its bundle with:
//
//     Scripts/guest.py bundle --manifest examples/ExampleAppManifest/App.swift
import AppManifest

let app = App(
    id: "org.pureswift.example",
    name: .localized("app.name"),
    version: "1.0", build: 1,
    languages: ["en", "es"],
    product: "ExampleApp",
    capabilities: [
        // The Beacon contract requires it.
        .bluetooth(usage: .localized("perm.bluetooth")),
    ],
    platforms: [.iOS("15.0"), .macOS("12.0"), .android(minSDK: 26, targetSDK: 35), .linux],
    apple: .init(category: .developerTools)
)
