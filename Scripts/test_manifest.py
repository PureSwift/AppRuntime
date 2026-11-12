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
