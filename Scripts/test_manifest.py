"""Tests for manifest.py. Run with: python3 -m unittest discover -s Scripts -p 'test_*.py'"""

import platform
import shutil
import tempfile
import unittest
from pathlib import Path

import guest
import manifest

ROOT = Path(__file__).resolve().parent.parent
EXAMPLE = ROOT / "examples" / "ExampleAppManifest"


def sample(**changes):
    value = {
        "format": 1,
        "id": "org.example.App",
        "name": {"key": "app.name"},
        "version": "1.2.3",
        "build": 7,
        "languages": ["en", "es"],
        "capabilities": [{"name": "bluetooth", "options": {}, "usage": {"key": "perm.bluetooth"}}],
        "platforms": [{"name": "ios", "minimum": "15.0"}, {"name": "macos", "minimum": "12.0"},
                      {"name": "android", "minSDK": 26, "targetSDK": 35}, {"name": "linux"}],
    }
    value.update(changes)
    return value


BEACON = [{"name": "org.example.Beacon", "capability": "bluetooth", "version": 1, "kind": "contract"}]


class StringsTests(unittest.TestCase):

    def setUp(self):
        self.directory = Path(tempfile.mkdtemp())

    def tearDown(self):
        shutil.rmtree(self.directory)

    def strings(self, data):
        path = self.directory / "Manifest.strings"
        path.write_bytes(data)
        return manifest.read_strings(path)

    def test_text_format(self):
        self.assertEqual(self.strings(
            b'/* comment */\n"a" = "x \\"y\\"\\n";\n// line\nunquoted.key = "\\U00e9";\n"b"="";'
        ), {"a": 'x "y"\n', "unquoted.key": "\u00e9", "b": ""})

    def test_utf16_and_plists(self):
        self.assertEqual(self.strings(b"\xff\xfe" + '"k" = "\u00f1";'.encode("utf-16-le")), {"k": "\u00f1"})
        import plistlib
        self.assertEqual(self.strings(plistlib.dumps({"k": "v"})), {"k": "v"})

    def test_errors_name_the_line(self):
        with self.assertRaisesRegex(manifest.ManifestError, r":2: expected ';'"):
            self.strings(b'"a" = "x";\n"b" = "y"\n')

    def test_round_trip(self):
        path = self.directory / "out.strings"
        values = {"a": 'quote " and \\ and\nnewline', "b": "plain"}
        manifest.write_strings(path, values)
        self.assertEqual(manifest.read_strings(path), values)


class CheckTests(unittest.TestCase):

    def check(self, value, targets=("wasm32", "ios-arm64", "macos"), contracts=BEACON, icon=None):
        return manifest.check(value, icon, EXAMPLE / "resources", contracts, list(targets), guest.TARGETS)

    def test_example_passes(self):
        errors, warnings = self.check(sample(id="org.pureswift.example"))
        self.assertEqual(errors, [])
        self.assertEqual(warnings, ["no icon"])

    def test_identity(self):
        errors, _ = self.check(sample(id="app", version="1.2.3.4", build=0))
        self.assertEqual(len(errors), 3, errors)

    def test_missing_strings(self):
        errors, _ = self.check(sample(languages=["en", "es", "fr"],
                                      capabilities=[{"name": "bluetooth", "options": {},
                                                     "usage": {"key": "perm.missing"}}]))
        self.assertIn("no fr.lproj/Manifest.strings in the resources, for name", errors)
        self.assertIn("en.lproj/Manifest.strings has no 'perm.missing' (bluetooth usage)", errors)
        self.assertIn("es.lproj/Manifest.strings has no 'perm.missing' (bluetooth usage)", errors)

    def test_capabilities(self):
        errors, warnings = self.check(sample(capabilities=[{"name": "camera", "options": {}, "usage": {"value": "x"}},
                                                           {"name": "teleport", "options": {}}]))
        self.assertIn("capability 'bluetooth' isn't declared, but org.example.Beacon requires it", errors)
        self.assertIn("capability 'camera' is declared but no contract requires it", warnings)
        self.assertIn("capability 'teleport' isn't one hosts know", warnings)
        _, warnings = self.check(sample(capabilities=[{"name": name, "options": {}, "usage": {"value": "x"}}
                                                      for name in ("motion", "nfc", "localNetwork")]))
        self.assertFalse([w for w in warnings if "isn't one hosts know" in w], warnings)

    def test_document_types(self):
        files = {"name": "userFiles", "options": {}}
        types = [{"name": {"key": "app.name"}, "types": ["image/*", "image/png", "*/*"], "role": "viewer"},
                 {"name": {"value": "Text"}, "types": ["text/plain", ".md"], "role": "editor"}]
        documents = [dict(name="org.pureswift.documents.Documents", kind="contract", version=1,
                          capability="userFiles", methods=[])]
        errors, warnings = self.check(sample(capabilities=[files], documentTypes=types), contracts=documents)
        self.assertFalse(errors, errors)
        self.assertFalse([w for w in warnings if "document" in w or "userFiles" in w], warnings)

        errors, _ = self.check(sample(capabilities=[], documentTypes=types), contracts=[])
        self.assertIn("documentTypes needs the 'userFiles' capability: the files arrive through the documents "
                      "contract", errors)
        errors, warnings = self.check(sample(capabilities=[files], documentTypes=[
            {"name": {"key": "type.missing"}, "types": ["image", "png", "Image/PNG", ".gpx"], "role": "owner"},
            {"name": {"value": "None"}, "types": [], "role": "viewer"},
            {"name": {"value": "Tracks"}, "types": [".gpx"], "role": "viewer"},
        ]), contracts=documents)
        self.assertIn("document type 1: 'image' isn't a MIME type (image/png, image/*) or an extension (.gpx)", errors)
        self.assertIn("document type 1: 'png' isn't a MIME type (image/png, image/*) or an extension (.gpx)", errors)
        self.assertIn("document type 1: 'Image/PNG' isn't a MIME type (image/png, image/*) or an extension (.gpx)",
                      errors)
        self.assertIn("document type 1: unknown role 'owner'", errors)
        self.assertIn("document type 2 names no types", errors)
        self.assertIn("en.lproj/Manifest.strings has no 'type.missing' (document type 1's name)", errors)
        self.assertEqual([w for w in warnings if "MIME" in w],
                         ["document type 3 has no MIME type: Android matches files by MIME type only"])

    def test_push(self):
        push = [dict(name="org.pureswift.notifications.Notifications", kind="contract", version=1,
                     capability="notifications", methods=[]),
                dict(name="org.pureswift.notifications.Push", kind="contract", version=1,
                     capability="notifications", methods=[])]
        local = push[:1]
        plain = {"name": "notifications", "options": {}}
        remote = {"name": "notifications", "options": {"remote": "true", "exactTiming": "true"}}
        android = {"googleServices": "google-services.json"}

        errors, warnings = self.check(sample(capabilities=[remote], android=android), contracts=push)
        self.assertFalse(errors, errors)
        self.assertFalse([w for w in warnings if "push" in w or "remote" in w], warnings)

        # An app that registers for pushes has to say so.
        errors, _ = self.check(sample(capabilities=[plain]), contracts=push)
        self.assertIn("org.pureswift.notifications.Push registers for pushes, so the manifest must declare them: "
                      ".notifications(remote: true)", errors)
        errors, _ = self.check(sample(capabilities=[]), contracts=push)
        self.assertEqual(len([e for e in errors if "notifications" in e]), 1, "undeclared is said once")
        errors, warnings = self.check(sample(capabilities=[plain]), contracts=local)
        self.assertFalse(errors, errors)
        _, warnings = self.check(sample(capabilities=[remote], android=android), contracts=local)
        self.assertIn("notifications declares remote, but the app doesn't register for pushes", warnings)

        # Android's push needs the app's Firebase configuration.
        _, warnings = self.check(sample(capabilities=[remote]), contracts=push)
        self.assertIn("push on Android needs the app's Firebase configuration: android googleServices", warnings)
        linux = [{"name": "linux"}]
        _, warnings = self.check(sample(capabilities=[remote], platforms=linux), contracts=push, targets=())
        self.assertFalse([w for w in warnings if "Firebase" in w], warnings)
        for bad in ("../google-services.json", "/etc/google-services.json", "google-services.txt"):
            errors, _ = self.check(sample(capabilities=[remote], android={"googleServices": bad}), contracts=push)
            self.assertIn(f"android googleServices {bad!r} isn't a .json file beside the manifest", errors)

        info = manifest.info_plist(sample(capabilities=[remote], android=android), EXAMPLE / "resources", None)
        self.assertEqual(info["RTCapabilityOptions"], {"notifications": {"remote": "true", "exactTiming": "true"}})
        self.assertEqual(info["RTPlatformExtras"], {"android": android})

    def test_background_tasks(self):
        tasks = [dict(name="org.pureswift.background.Tasks", kind="contract", version=1,
                      capability="backgroundTasks", methods=[])]
        background = {"name": "backgroundTasks", "options": {}}
        declared = [{"identifier": "org.example.App.sync", "kind": "refresh"},
                    {"identifier": "org.example.App.index", "kind": "processing"}]
        errors, warnings = self.check(sample(capabilities=[background], backgroundTasks=declared), contracts=tasks)
        self.assertFalse(errors, errors)
        self.assertFalse([w for w in warnings if "background" in w or "refresh" in w], warnings)

        errors, _ = self.check(sample(capabilities=[], backgroundTasks=declared), contracts=[])
        self.assertIn("backgroundTasks needs the 'backgroundTasks' capability", errors)
        errors, warnings = self.check(sample(capabilities=[background], backgroundTasks=[
            {"identifier": "sync", "kind": "refresh"}, {"identifier": "sync", "kind": "refresh"},
            {"identifier": "has space", "kind": "refresh"}, {"identifier": "", "kind": "processing"},
            {"identifier": "odd", "kind": "forever"},
        ]), contracts=tasks)
        self.assertIn("background task 'sync' is named twice", errors)
        self.assertIn("background task 'has space' isn't an identifier, such as org.example.App.refresh", errors)
        self.assertIn("background task '' isn't an identifier, such as org.example.App.refresh", errors)
        self.assertIn("background task 'odd': unknown kind 'forever'", errors)
        self.assertIn("more than one refresh task: iOS keeps one refresh request pending at a time", warnings)

        info = manifest.info_plist(sample(capabilities=[background], backgroundTasks=declared), EXAMPLE / "resources", None)
        self.assertEqual(info["RTBackgroundTasks"], [{"Identifier": "org.example.App.sync", "Kind": "refresh"},
                                                     {"Identifier": "org.example.App.index", "Kind": "processing"}])
        self.assertNotIn("RTBackgroundTasks", manifest.info_plist(sample(), EXAMPLE / "resources", None))

        # Only a push wakes the app.
        wakes = {"name": "notifications", "options": {"wakesApp": "true"}}
        errors, _ = self.check(sample(capabilities=[wakes]), contracts=[])
        self.assertIn("notifications declares wakesApp without remote: only a push wakes the app", errors)

    def test_optional_capabilities(self):
        # A web view works without network, so it never requires it; with a
        # web view in the app, declaring network isn't unused.
        web = [dict(name="org.pureswift.web.WebContent", kind="contract", version=1, capability=None, methods=[])]
        network = sample(capabilities=[{"name": "network", "options": {}}])
        errors, warnings = self.check(network, contracts=web)
        self.assertFalse([e for e in errors if "capability" in e], errors)
        self.assertFalse([w for w in warnings if "network" in w], warnings)
        errors, _ = self.check(sample(capabilities=[]), contracts=web)
        self.assertFalse([e for e in errors if "capability" in e], errors)
        _, warnings = self.check(network, contracts=[])
        self.assertIn("capability 'network' is declared but no contract requires it", warnings)

    def test_platforms(self):
        errors, _ = self.check(sample(platforms=[
            {"name": "ios", "minimum": "12.0"}, {"name": "macos", "minimum": "10.14"},
            {"name": "android", "minSDK": 30, "targetSDK": 29}, {"name": "linux"}, {"name": "linux"},
            {"name": "beos"},
        ]))
        self.assertIn("ios minimum 12.0 is below the ios-arm64 slice's 13.0", errors)
        self.assertIn("macos minimum 10.14 is below the macos slice's 10.15", errors)
        self.assertIn("Android's targetSDK is below its minSDK", errors)
        self.assertIn("platform 'linux' is listed twice", errors)
        self.assertIn("unknown platform 'beos'", errors)

    def test_icon(self):
        errors, warnings = self.check(sample(), icon=EXAMPLE / "missing.png")
        self.assertIn(f"icon {EXAMPLE / 'missing.png'} not found", errors)
        self.assertNotIn("no icon", warnings)

    def test_default_targets(self):
        targets = manifest.default_targets(sample(), guest.TARGETS, guest.PLATFORM_GROUPS)
        self.assertEqual(targets[0], "wasm32")
        self.assertIn("ios-arm64", targets)
        self.assertNotIn("ios-armv7", targets, "iOS 15 doesn't run on armv7")
        self.assertIn("android-x86_64", targets)
        self.assertNotIn("tvos-arm64", targets)
        old = sample(platforms=[{"name": "ios", "minimum": "9.0"}])
        self.assertIn("ios-armv7", manifest.default_targets(old, guest.TARGETS, guest.PLATFORM_GROUPS))


class OutputTests(unittest.TestCase):

    def test_info_plist(self):
        value = sample(
            capabilities=[{"name": "bluetooth", "options": {}, "usage": {"key": "perm.bluetooth"}},
                          {"name": "location", "options": {"access": "always"}, "usage": {"value": "Maps"}},
                          {"name": "network", "options": {}}],
            apple={"category": "public.app-category.utilities", "extraInfoPlist": {}},
        )
        info = manifest.info_plist(value, EXAMPLE / "resources", "icon.png")
        self.assertEqual(info["CFBundleDisplayName"], "Example", "the development language's")
        self.assertEqual(info["RTDisplayNameKey"], "app.name")
        self.assertEqual(info["RTCapabilityUsage"], {"bluetooth": "perm.bluetooth",
                                                     "location": "RTCapabilityUsage.location"})
        self.assertEqual(info["RTCapabilityOptions"], {"location": {"access": "always"}})
        self.assertEqual(info["RTPlatforms"]["android"], {"MinSDK": 26, "TargetSDK": 35})
        self.assertEqual(info["RTPlatforms"]["linux"], {})
        self.assertEqual(info["RTIcon"], "icon.png")
        self.assertEqual(info["RTPlatformExtras"], {"apple": value["apple"]})
        self.assertNotIn("RTDocumentTypes", info)

        value["documentTypes"] = [{"name": {"key": "app.name"}, "types": ["image/*"], "role": "viewer"},
                                  {"name": {"value": "Text"}, "types": ["text/plain", ".md"], "role": "editor"}]
        info = manifest.info_plist(value, EXAMPLE / "resources", None)
        self.assertEqual(info["RTDocumentTypes"], [
            {"Name": "Example", "NameKey": "app.name", "Types": ["image/*"], "Role": "viewer"},
            {"Name": "Text", "Types": ["text/plain", ".md"], "Role": "editor"},
        ])

        with tempfile.TemporaryDirectory() as bundle:
            manifest.write_strings_files(value, EXAMPLE / "resources", bundle)
            spanish = manifest.read_strings(Path(bundle) / "es.lproj" / "Manifest.strings")
            self.assertEqual(spanish["RTCapabilityUsage.location"], "Maps")
            self.assertEqual(spanish["app.name"], "Ejemplo", "the app's own strings are kept")

    def test_encoding_is_canonical(self):
        self.assertEqual(manifest.encode({"b": 1, "a": "\u00f1"}), '{"a":"\u00f1","b":1}'.encode())


class EvaluateTests(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        cls.swiftc = guest.Toolchain(ROOT).tool("swiftc")

    def test_example(self):
        value = manifest.evaluate(EXAMPLE / "App.swift", self.swiftc)
        self.assertEqual(value["id"], "org.pureswift.example")
        self.assertEqual(value["product"], "ExampleApp")
        self.assertEqual(value["capabilities"][0]["usage"], {"key": "perm.bluetooth"})

    def test_errors_point_into_the_manifest(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "App.swift"
            path.write_text("import AppManifest\nlet app = App(id: 1)\n")
            with self.assertRaisesRegex(manifest.ManifestError, r"App.swift|main.swift:2"):
                manifest.evaluate(path, self.swiftc)

    @unittest.skipUnless(platform.system() == "Darwin", "the write sandbox is macOS only")
    def test_sandbox_blocks_writes(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory).resolve() / "escaped.txt"
            path = Path(directory) / "App.swift"
            path.write_text(
                "import AppManifest\nimport Foundation\n"
                f'let written = FileManager.default.createFile(atPath: "{target}", contents: Data())\n'
                'let app = App(id: "org.example.App", name: written ? "written" : "blocked", '
                'version: "1", build: 1, platforms: [.linux])\n')
            value = manifest.evaluate(path, self.swiftc)
            self.assertEqual(value["name"], {"value": "blocked"})
            self.assertFalse(target.exists())


if __name__ == "__main__":
    unittest.main()
