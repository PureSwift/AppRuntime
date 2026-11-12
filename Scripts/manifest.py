"""
App.swift manifests (DynamicRuntime.md §7.1–7.3, DarwinAppRuntime's
ManifestPackager.md §1), for guest.py.

`evaluate` compiles App.swift with the AppManifest library into a throwaway
executable for the build machine and runs it sandboxed, the way SwiftPM
reads Package.swift; it prints the manifest as JSON. `check` runs the
packaging checks, and `info_plist` gives the bundle's portable Info.plist
keys.
"""

import json
import platform
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LIBRARY = ROOT / "Sources" / "AppManifest"
FORMAT_VERSION = 1

# Manifest platform -> guest.py platform group.
PLATFORM_GROUPS = {
    "ios": "ios", "macos": "macos", "tvos": "tvos", "watchos": "watchos",
    "visionos": "visionos", "android": "android", "linux": "linux",
}
# Slice platform (ld's -platform_version) -> manifest platform.
SLICE_PLATFORMS = {"ios": "ios", "ios-simulator": "ios", "macos": "macos", "tvos": "tvos",
                   "watchos": "watchos", "xros": "visionos"}
KNOWN_CAPABILITIES = {"bluetooth", "camera", "location", "notifications", "network", "graphics",
                      "motion", "nfc", "localNetwork"}

IDENTIFIER = re.compile(r"^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$")
VERSION = re.compile(r"^\d+(\.\d+){0,2}$")
LANGUAGE = re.compile(r"^[A-Za-z]{2,3}([-_][A-Za-z0-9]+)*$")

STRINGS_FILE = "Manifest.strings"
RUN_TIMEOUT = 60


class ManifestError(Exception):
    pass


# ---------------------------------------------------------------------------
# Evaluation
# ---------------------------------------------------------------------------

def evaluate(path, swiftc):
    """Compiles and runs App.swift; returns the manifest as a dict."""
    path = Path(path).resolve()
    if not path.is_file():
        raise ManifestError(f"no manifest at {path}")
    with tempfile.TemporaryDirectory(prefix="app-manifest-") as work:
        work = Path(work).resolve()
        sources = sorted(LIBRARY.glob("*.swift"))
        swiftc = [swiftc, *_sdk()]
        _run([*swiftc, "-parse-as-library", "-wmo", "-module-name", "AppManifest",
              "-emit-module", "-emit-module-path", work / "AppManifest.swiftmodule",
              "-c", *sources, "-o", work / "AppManifest.o"], "AppManifest")
        # Top-level code is only allowed in main.swift. Appending keeps the
        # manifest's own line numbers in diagnostics.
        main = work / "main.swift"
        main.write_text(path.read_text() + "\n\nprint(app.manifestJSON())\n")
        runner = work / "manifest"
        _run([*swiftc, "-I", work, main, work / "AppManifest.o", "-o", runner], path.name)
        try:
            result = subprocess.run(sandboxed([str(runner)], work), capture_output=True,
                                    text=True, timeout=RUN_TIMEOUT, cwd=work)
        except subprocess.TimeoutExpired:
            raise ManifestError(f"{path.name} didn't finish in {RUN_TIMEOUT} s")
        if result.returncode != 0:
            raise ManifestError(f"{path.name} failed:\n{result.stderr.strip()}")
    try:
        manifest = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise ManifestError(f"{path.name} printed something other than its manifest: {error}")
    if manifest.get("format") != FORMAT_VERSION:
        raise ManifestError(f"manifest format {manifest.get('format')}, expected {FORMAT_VERSION}")
    return manifest


def _sdk():
    """On macOS, the SDK a swift.org toolchain needs to link."""
    if platform.system() != "Darwin":
        return []
    path = subprocess.run(["xcrun", "--sdk", "macosx", "--show-sdk-path"],
                          capture_output=True, text=True).stdout.strip()
    return ["-sdk", path] if path else []


def sandboxed(command, work):
    """`command` with no network and, on macOS, no writes outside `work`."""
    if platform.system() == "Darwin" and shutil.which("sandbox-exec"):
        profile = "\n".join([
            "(version 1)",
            "(allow default)",
            "(deny network*)",
            "(deny file-write*)",
            f'(allow file-write* (subpath "{work}") (literal "/dev/null") (literal "/dev/dtracehelper"))',
        ])
        return ["sandbox-exec", "-p", profile, *command]
    if shutil.which("unshare") and subprocess.run(["unshare", "--user", "--net", "true"],
                                                  capture_output=True).returncode == 0:
        return ["unshare", "--user", "--net", "--", *command]
    print("warning: no sandbox available; running the manifest unsandboxed")
    return command


def _run(arguments, what):
    result = subprocess.run([str(a) for a in arguments], capture_output=True, text=True)
    if result.returncode != 0:
        raise ManifestError(f"compiling {what} failed:\n{(result.stderr or result.stdout).strip()}")


def encode(manifest):
    """The canonical JSON every slice embeds as rt.manifest."""
    return json.dumps(manifest, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()


# ---------------------------------------------------------------------------
# .strings files
# ---------------------------------------------------------------------------

def read_strings(path):
    """Reads a .strings file: the text format, or an XML or binary plist."""
    data = Path(path).read_bytes()
    if data.startswith(b"bplist") or data.lstrip().startswith(b"<?xml"):
        import plistlib
        return {str(k): str(v) for k, v in plistlib.loads(data).items()}
    for bom, encoding in ((b"\xef\xbb\xbf", "utf-8"), (b"\xff\xfe", "utf-16-le"), (b"\xfe\xff", "utf-16-be")):
        if data.startswith(bom):
            text = data[len(bom):].decode(encoding)
            break
    else:
        text = data.decode("utf-8")
    return _StringsParser(text, path).parse()


def write_strings(path, strings):
    def quote(value):
        escaped = value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\t", "\\t")
        return f'"{escaped}"'
    lines = [f"{quote(key)} = {quote(strings[key])};" for key in sorted(strings)]
    Path(path).write_text("\n".join(lines) + "\n", encoding="utf-8")


class _StringsParser:

    UNQUOTED = re.compile(r"[A-Za-z0-9_.$:/\-]+")
    ESCAPES = {"n": "\n", "t": "\t", "r": "\r", '"': '"', "\\": "\\", "'": "'", "0": "\0"}

    def __init__(self, text, path):
        self.text, self.path, self.i = text, path, 0

    def fail(self, message):
        line = self.text.count("\n", 0, self.i) + 1
        raise ManifestError(f"{self.path}:{line}: {message}")

    def skip(self):
        while self.i < len(self.text):
            if self.text[self.i].isspace():
                self.i += 1
            elif self.text.startswith("/*", self.i):
                end = self.text.find("*/", self.i + 2)
                if end < 0:
                    self.fail("unterminated comment")
                self.i = end + 2
            elif self.text.startswith("//", self.i):
                end = self.text.find("\n", self.i)
                self.i = len(self.text) if end < 0 else end + 1
            else:
                return

    def string(self):
        self.skip()
        if self.i < len(self.text) and self.text[self.i] == '"':
            self.i += 1
            value = []
            while self.i < len(self.text):
                c = self.text[self.i]
                self.i += 1
                if c == '"':
                    return "".join(value)
                if c == "\\":
                    e = self.text[self.i:self.i + 1]
                    self.i += 1
                    if e in ("U", "u"):
                        value.append(chr(int(self.text[self.i:self.i + 4], 16)))
                        self.i += 4
                    elif e in self.ESCAPES:
                        value.append(self.ESCAPES[e])
                    else:
                        value.append(e)
                else:
                    value.append(c)
            self.fail("unterminated string")
        match = self.UNQUOTED.match(self.text, self.i)
        if not match:
            self.fail("expected a string")
        self.i = match.end()
        return match.group()

    def expect(self, character):
        before = self.i
        self.skip()
        if not self.text.startswith(character, self.i):
            self.i = before  # report the line where it's missing
            self.fail(f"expected '{character}'")
        self.i += 1

    def parse(self):
        strings = {}
        self.skip()
        while self.i < len(self.text):
            key = self.string()
            self.expect("=")
            strings[key] = self.string()
            self.expect(";")
            self.skip()
        return strings


# ---------------------------------------------------------------------------
# Targets and checks
# ---------------------------------------------------------------------------

def version_tuple(version):
    return tuple(int(part) for part in str(version).split("."))


def platforms(manifest):
    return {p["name"]: p for p in manifest.get("platforms", [])}


def default_targets(manifest, targets, groups):
    """The targets for the manifest's platforms, plus wasm32.

    Leaves out targets whose `maximum` OS is below the platform's minimum,
    such as iOS 6 armv7 for an iOS 15 app.
    """
    selected = ["wasm32"]
    declared = platforms(manifest)
    for name, entry in declared.items():
        group = PLATFORM_GROUPS.get(name)
        for target_id in groups.get(group, []):
            maximum = targets[target_id].get("maximum")
            if maximum and entry.get("minimum") and version_tuple(entry["minimum"]) > version_tuple(maximum):
                continue
            if target_id not in selected:
                selected.append(target_id)
    return selected


def localized_keys(manifest):
    """Every `.localized` key the manifest uses, with where it's used."""
    keys = []
    if "key" in manifest["name"]:
        keys.append((manifest["name"]["key"], "name"))
    for capability in manifest.get("capabilities", []):
        usage = capability.get("usage") or {}
        if "key" in usage:
            keys.append((usage["key"], f"{capability['name']} usage"))
    return keys


def strings_for(resources, language):
    path = Path(resources) / f"{language}.lproj" / STRINGS_FILE if resources else None
    return read_strings(path) if path and path.is_file() else None


def check(manifest, icon, resources, contracts, targets, target_configs):
    """The packaging checks (§7.3, ManifestPackager.md §1.2): (errors, warnings)."""
    errors, warnings = [], []
    if not IDENTIFIER.match(manifest["id"]):
        errors.append(f"id {manifest['id']!r} isn't a reverse-DNS identifier, such as org.example.App")
    if not VERSION.match(manifest["version"]):
        errors.append(f"version {manifest['version']!r} isn't 1 to 3 dot-separated integers")
    if manifest["build"] < 1:
        errors.append("build must be a positive integer (Android's versionCode)")

    languages = manifest.get("languages", [])
    if not languages:
        errors.append("languages is empty")
    for language in languages:
        if not LANGUAGE.match(language):
            errors.append(f"language {language!r} isn't a BCP 47 tag")
    keys = localized_keys(manifest)
    for language in languages if keys else []:
        strings = strings_for(resources, language)
        if strings is None:
            errors.append(f"no {language}.lproj/{STRINGS_FILE} in the resources, for {keys[0][1]}")
            continue
        for key, use in keys:
            if key not in strings:
                errors.append(f"{language}.lproj/{STRINGS_FILE} has no {key!r} ({use})")

    declared = [c["name"] for c in manifest.get("capabilities", [])]
    for name in sorted({n for n in declared if declared.count(n) > 1}):
        errors.append(f"capability {name!r} is declared twice")
    required = sorted({c["capability"] for c in contracts if c["capability"]})
    for name in required:
        if name not in declared:
            users = ", ".join(c["name"] for c in contracts if c["capability"] == name)
            errors.append(f"capability {name!r} isn't declared, but {users} requires it")
    for name in sorted(set(declared) - set(required)):
        warnings.append(f"capability {name!r} is declared but no contract requires it")
    for name in sorted(set(declared) - KNOWN_CAPABILITIES):
        warnings.append(f"capability {name!r} isn't one hosts know")

    names = [p["name"] for p in manifest.get("platforms", [])]
    if not names:
        errors.append("platforms is empty")
    for name in sorted({n for n in names if names.count(n) > 1}):
        errors.append(f"platform {name!r} is listed twice")
    for name in sorted(set(names) - set(PLATFORM_GROUPS)):
        errors.append(f"unknown platform {name!r}")
    declared_platforms = platforms(manifest)
    android = declared_platforms.get("android")
    if android and android.get("targetSDK", 0) < android.get("minSDK", 0):
        errors.append("Android's targetSDK is below its minSDK")
    for target_id in targets:
        config = target_configs[target_id]
        for slice_config in config.get("slices", []):
            name = SLICE_PLATFORMS.get(slice_config["platform"])
            entry = declared_platforms.get(name)
            if not entry or not entry.get("minimum"):
                continue
            if version_tuple(entry["minimum"]) < version_tuple(slice_config["minimum"]):
                errors.append(f"{name} minimum {entry['minimum']} is below the {target_id} slice's "
                              f"{slice_config['minimum']}")

    if not icon:
        warnings.append("no icon")
    elif not Path(icon).is_file():
        errors.append(f"icon {icon} not found")
    return errors, warnings


# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------

def usage_key(capability):
    """The Manifest.strings key of a capability's usage text."""
    usage = capability.get("usage") or {}
    return usage.get("key") or f"RTCapabilityUsage.{capability['name']}"


def resolve(text, strings):
    """A manifest text's value in one language; the key if it's missing."""
    if "value" in text:
        return text["value"]
    return (strings or {}).get(text["key"], text["key"])


def write_strings_files(manifest, resources, bundle_resources):
    """Adds the manifest's written-out usage texts to each language's
    Manifest.strings in the bundle, so hosts find every usage by key."""
    verbatim = {usage_key(c): c["usage"]["value"] for c in manifest.get("capabilities", [])
                if "value" in (c.get("usage") or {})}
    if not verbatim:
        return
    for language in manifest["languages"]:
        strings = strings_for(resources, language) or {}
        strings.update(verbatim)
        directory = Path(bundle_resources) / f"{language}.lproj"
        directory.mkdir(parents=True, exist_ok=True)
        write_strings(directory / STRINGS_FILE, strings)


def info_plist(manifest, resources, icon_name):
    """The bundle's portable Info.plist keys from the manifest."""
    development = strings_for(resources, manifest["languages"][0])
    name = resolve(manifest["name"], development)
    info = {
        "CFBundleIdentifier": manifest["id"],
        "CFBundleName": name,
        "CFBundleDisplayName": name,
        "CFBundleShortVersionString": manifest["version"],
        "CFBundleVersion": str(manifest["build"]),
        "CFBundleLocalizations": manifest["languages"],
        "CFBundleDevelopmentRegion": manifest["languages"][0],
        "RTCapabilities": sorted(c["name"] for c in manifest.get("capabilities", [])),
        "RTPlatforms": {},
    }
    if "key" in manifest["name"]:
        info["RTDisplayNameKey"] = manifest["name"]["key"]
    for entry in manifest.get("platforms", []):
        values = {}
        if entry.get("minimum"):
            values["Minimum"] = entry["minimum"]
        if entry.get("minSDK") is not None:
            values["MinSDK"] = entry["minSDK"]
        if entry.get("targetSDK") is not None:
            values["TargetSDK"] = entry["targetSDK"]
        info["RTPlatforms"][entry["name"]] = values
    usage = {c["name"]: usage_key(c) for c in manifest.get("capabilities", []) if c.get("usage")}
    if usage:
        info["RTCapabilityUsage"] = usage
    options = {c["name"]: c["options"] for c in manifest.get("capabilities", []) if c.get("options")}
    if options:
        info["RTCapabilityOptions"] = options
    if icon_name:
        info["RTIcon"] = icon_name
    extras = {key: manifest[key] for key in ("apple", "android") if manifest.get(key)}
    if extras:
        info["RTPlatformExtras"] = extras
    return info
