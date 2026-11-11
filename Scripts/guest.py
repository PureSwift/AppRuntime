#!/usr/bin/env python3
"""
Builds guest code: compiles a Swift package's guest library product for each
target, seals the native slices, links App.wasm, and assembles the universal
bundle that is handed to a host (Documentation/DynamicRuntime.md §5.1, §7.5).

No host code is built. The host picks a slice, links or loads it, and checks
SDK compatibility.

    guest.py targets
    guest.py slice  --product ExampleApp --target linux-arm64 [--package PATH]
    guest.py bundle --product ExampleApp --id org.example.app --name Example
                    --version 1.0 --build 1 [--target ID ...] [--capability bluetooth ...]
                    [--resources DIR] [--icon FILE] [--output DIR]

Slices are written to <package>/.build/guest/<product>/<target>/ and bundles
to <package>/.build/guest/<product>/<id>.app unless --output is given.

Requirements: the Swift toolchain selected for the package (.swift-version),
the matching Embedded wasm Swift SDK for wasm32, and Xcode command line tools
for the Apple targets.

Limitations: target settings from Package.swift (defines, unsafe flags,
platform-conditional dependencies) are not read, apart from dependencies
gated on a trait that isn't enabled by default, which are left out; every
target is compiled as an
Embedded Swift library with the settings below.
"""

import argparse
import hashlib
import json
import os
import plistlib
import re
import shutil
import struct
import subprocess
import sys
from pathlib import Path

ABI_VERSION = 1

# Symbols a sealed native slice may leave undefined (§7.5).
ALLOWED_UNDEFINED = re.compile(
    r"^(rt_[a-z0-9_]+|gl[A-Z][A-Za-z0-9]*|malloc|free|posix_memalign|memcpy|memmove|memset|memcmp"
    r"|abort|write|clock_gettime|arc4random_buf|getentropy|putchar)$"
)
# ARM EABI spellings of memcpy/memset; glibc, musl and bionic export them.
ALLOWED_ARM_EABI = re.compile(r"^__aeabi_mem(cpy|move|set|clr)[48]?$")
# Apple targets link against libSystem, which also provides bzero and libm,
# and re-exports compiler-rt (soft-float and 64-bit integer helpers that the
# soft-float armv7-apple-none-macho target calls, as Swift-iOS6 does).
ALLOWED_APPLE = re.compile(
    r"^(bzero|__bzero|ceil|floor|trunc|round|roundf|sqrt|fmod"
    r"|__(ashl|ashr|lshr|mul|div|udiv|mod|umod|neg|add|sub|eq|ne|lt|le|gt|ge|unord|cmp|ucmp"
    r"|fix|fixuns|float|floatun|extend|trunc|pow)[a-z]*[0-9]?)$"
)
GUEST_EXPORTS = ("rt_main", "rt_dispatch", "rt_finalize")
SUPPORT = Path(__file__).resolve().parent / "support"
GLIBC_ONLY = re.compile(r"(_chk$|^__errno_location$|^__errno$|^__tls_get_addr$|@)")

# ---------------------------------------------------------------------------
# Targets
# ---------------------------------------------------------------------------

ARMV7_HARD = ["-mfloat-abi=hard", "-mfpu=vfpv3-d16"]      # Linux armhf: AAPCS-VFP
ARMV7_SOFTFP = ["-mfloat-abi=softfp", "-mfpu=vfpv3-d16"]  # Android armeabi-v7a

# kind: wasm | elf | macho. A target with several "slices" is a fat archive.
#
# Apple: the toolchain's Embedded stdlib for OS triples requires iOS 18 /
# macOS 14, and there is none for tvOS, watchOS or visionOS. Embedded code
# makes no OS calls, so arm64 slices are compiled for arm64-apple-none-macho
# (the same Darwin calling convention) and stamped with the platform and
# minimum OS when sealed. x86_64 has no none-macho stdlib; it is compiled for
# macOS 26, which folds away #available checks (their runtime helper isn't in
# the allowed symbols), and stamped 10.15. arm64_32 (watchOS 6 hardware) has no Embedded
# stdlib at all, so those watches use App.wasm.
APPLE_ARM64 = "arm64-apple-none-macho"

# Native slices are built without concurrency until the guest executor (§5.4)
# exists. The prebuilt runtime needs executor hooks and more libc than §7.5
# allows, and aarch64-none-none-elf has no _Concurrency module at all.
# canImport(_Concurrency) can't detect that, so packages check this define.
# wasm32 links the runtime, and its linker strips what's unused.
NO_CONCURRENCY = ["EMBEDDED_NO_CONCURRENCY"]
TARGETS = {
    "wasm32": dict(kind="wasm", triple="wasm32-unknown-wasip1",
                   about="WASI reactor module, every host"),
    # Swift-iOS6 (https://github.com/colemancda/Swift-iOS6): ARM, not Thumb,
    # because dyld enters a Thumb entry point in ARM state; r9 reserved,
    # because the bare-metal target keeps values in it across calls into
    # libSystem. The host still realigns the stack on calls into the slice
    # (iOS keeps it 4-byte aligned, AAPCS expects 8) and fixes Thumb bits
    # in the prebuilt concurrency runtime after its final link.
    "ios-armv7": dict(kind="macho", about="iOS 6, Embedded Swift armv7 (Swift-iOS6 setup)", slices=[
        dict(triple="armv7-apple-none-macho", arch="armv7", platform="ios", minimum="6.0",
             cflags=["-marm", "-ffixed-r9"], support=["ios6-compat.c"])]),
    "ios-arm64": dict(kind="macho", about="iOS 13", slices=[
        dict(triple=APPLE_ARM64, arch="arm64", platform="ios", minimum="13.0")]),
    "macos": dict(kind="macho", about="macOS 10.15, arm64 + x86_64 in one archive", slices=[
        dict(triple=APPLE_ARM64, arch="arm64", platform="macos", minimum="11.0"),
        dict(triple="x86_64-apple-macos26", arch="x86_64", platform="macos", minimum="10.15")]),
    "tvos-arm64": dict(kind="macho", about="tvOS 13", slices=[
        dict(triple=APPLE_ARM64, arch="arm64", platform="tvos", minimum="13.0")]),
    "watchos-arm64": dict(kind="macho", about="watchOS 6 on arm64 hardware (arm64_32 watches use App.wasm)", slices=[
        dict(triple=APPLE_ARM64, arch="arm64", platform="watchos", minimum="6.0")]),
    "visionos-arm64": dict(kind="macho", about="visionOS 1", slices=[
        dict(triple=APPLE_ARM64, arch="arm64", platform="xros", minimum="1.0")]),
    "linux-arm64": dict(kind="elf", triple="aarch64-none-none-elf", about="Linux arm64, libc-agnostic"),
    "linux-armv7": dict(kind="elf", triple="armv7-none-none-eabi", cflags=ARMV7_HARD,
                        support=["armv7-eabi.c"], about="Linux armv7 hard-float, libc-agnostic"),
    "linux-x86_64": dict(kind="elf", triple="x86_64-unknown-none-elf", cpu="nehalem", support=["x86_64-half.c"],
                         about="Linux x86_64 (x86-64-v2: SSE4.2, POPCNT), libc-agnostic"),
    "android-arm64-v8a": dict(kind="elf", triple="aarch64-none-none-elf", about="Android arm64-v8a"),
    "android-armeabi-v7a": dict(kind="elf", triple="armv7-none-none-eabi", cflags=ARMV7_SOFTFP,
                                support=["armv7-eabi.c"], about="Android armeabi-v7a (softfp)"),
    "android-x86_64": dict(kind="elf", triple="x86_64-unknown-none-elf", cpu="nehalem", support=["x86_64-half.c"],
                           about="Android x86_64 (SSE4.2 and POPCNT, as the ABI requires)"),
}

PLATFORM_GROUPS = {
    "wasm": ["wasm32"],
    "ios": ["ios-armv7", "ios-arm64"],
    "macos": ["macos"],
    "tvos": ["tvos-arm64"],
    "watchos": ["watchos-arm64"],
    "visionos": ["visionos-arm64"],
    "linux": ["linux-arm64", "linux-armv7", "linux-x86_64"],
    "android": ["android-arm64-v8a", "android-armeabi-v7a", "android-x86_64"],
}


class BuildError(Exception):
    pass


def run(arguments, cwd=None, quiet=False, filter_warnings=()):
    """Runs a command; raises BuildError with its output on failure."""
    result = subprocess.run([str(a) for a in arguments], cwd=cwd, capture_output=True, text=True)
    output = (result.stdout + result.stderr).strip()
    if result.returncode != 0:
        raise BuildError(f"{' '.join(str(a) for a in arguments[:3])} … failed:\n{output}")
    if output and not quiet:
        lines = [line for line in output.splitlines() if not any(w in line for w in filter_warnings)]
        if lines:
            print("\n".join(lines))
    return result.stdout


# ---------------------------------------------------------------------------
# Toolchain
# ---------------------------------------------------------------------------

class Toolchain:

    def __init__(self, package):
        info = json.loads(run(["swift", "-print-target-info"], cwd=package, quiet=True))
        resources = Path(info["paths"]["runtimeResourcePath"])
        self.usr = resources.parent.parent
        self.bin = self.usr / "bin"
        version = run(["swift", "--version"], cwd=package, quiet=True)
        match = re.search(r"Swift version (\d+\.\d+(?:\.\d+)?)", version)
        self.version = match.group(1) if match else ""

    def tool(self, name):
        path = self.bin / name
        if not path.exists():
            raise BuildError(f"{name} not found in {self.bin}")
        return path

    def embedded_library(self, triple, name):
        """A prebuilt Embedded runtime library for a triple, if the toolchain has one."""
        directory = self.usr / "lib" / "swift" / "embedded" / normalize_embedded(triple)
        path = directory / f"lib{name}.a"
        return path if path.exists() else None

    def wasm_sdk(self):
        """The wasm32-unknown-wasip1 directory of the matching Swift SDK."""
        if "RT_WASM_SDK" in os.environ:
            return Path(os.environ["RT_WASM_SDK"])
        roots = [Path.home() / "Library/org.swift.swiftpm/swift-sdks", Path.home() / ".swiftpm/swift-sdks"]
        for root in roots:
            for bundle in sorted(root.glob(f"swift-{self.version}-RELEASE_wasm.artifactbundle")):
                for candidate in bundle.glob("*/wasm32-unknown-wasip1"):
                    if (candidate / "embedded-swift-sdk.json").exists():
                        return candidate
        raise BuildError(
            f"no Embedded wasm Swift SDK for Swift {self.version}; install it with "
            "`swift sdk install <swift.org wasm SDK URL> --checksum <checksum>` or set RT_WASM_SDK")


def normalize_embedded(triple):
    """Embedded stdlib directory names drop the OS version."""
    return re.sub(r"(ios|macos|tvos|watchos|xros)\d+(\.\d+)*$", r"\1", triple)


# ---------------------------------------------------------------------------
# Package graph
# ---------------------------------------------------------------------------

class Target:

    def __init__(self, package_path, description):
        self.name = description["name"]
        self.c99name = description.get("c99name", self.name)
        self.type = description["type"]
        self.is_swift = description["module_type"] == "SwiftTarget"
        self.path = Path(package_path) / description["path"]
        self.sources = [self.path / source for source in description.get("sources", [])]
        self.target_dependencies = description.get("target_dependencies", [])
        self.product_dependencies = description.get("product_dependencies", [])
        self.package_path = Path(package_path)


def disabled_trait_dependencies(manifest):
    """Dependencies gated on traits the package doesn't enable by default.

    `swift package describe` lists them unconditionally, but a trait that's
    off means the dependency isn't part of the build.
    """
    enabled = set()
    for trait in manifest.get("traits", []):
        if trait.get("name") == "default":
            enabled.update(trait.get("enabledTraits", []))
    disabled = {}
    for target in manifest.get("targets", []):
        for dependency in target.get("dependencies", []):
            for details in dependency.values():
                condition = next((d for d in details if isinstance(d, dict)), None) if details else None
                traits = (condition or {}).get("traits") or []
                if traits and not enabled.intersection(traits):
                    disabled.setdefault(target["name"], set()).add(details[0])
    return disabled


class PackageGraph:

    def __init__(self, root):
        self.root = Path(root).resolve()
        self.targets = {}    # (package path, name) -> Target
        self.products = {}   # product name -> (package path, [target names])
        self.uses_build_plugins = False
        self.load(self.root)
        dependencies = json.loads(run(["swift", "package", "show-dependencies", "--format", "json"], cwd=self.root, quiet=True))
        pending = list(dependencies.get("dependencies", []))
        while pending:
            dependency = pending.pop()
            self.load(Path(dependency["path"]))
            pending.extend(dependency.get("dependencies", []))

    def load(self, path):
        if any(key[0] == path for key in self.targets):
            return
        description = json.loads(run(["swift", "package", "describe", "--type", "json"], cwd=path, quiet=True))
        manifest = json.loads(run(["swift", "package", "dump-package"], cwd=path, quiet=True))
        disabled = disabled_trait_dependencies(manifest)
        for target in description["targets"]:
            model = Target(path, target)
            excluded = disabled.get(model.name, set())
            model.target_dependencies = [d for d in model.target_dependencies if d not in excluded]
            model.product_dependencies = [d for d in model.product_dependencies if d not in excluded]
            self.targets[(path, target["name"])] = model
        for product in description["products"]:
            self.products.setdefault(product["name"], (path, product["targets"]))

    def generated_sources(self, target):
        """Swift sources a build-tool plugin generated for `target` during the host build."""
        outputs = self.root / ".build/plugins/outputs" / target.package_path.name.lower() / target.name / "destination"
        return sorted(outputs.glob("*/*.swift"))

    def closure(self, product):
        """Targets of a product in dependency order, plus the macro targets they use."""
        if product not in self.products:
            raise BuildError(f"no product named {product}")
        package, names = self.products[product]
        ordered, macros, visiting = [], [], set()

        def visit(target):
            key = (target.package_path, target.name)
            if key in visiting:
                return
            visiting.add(key)
            if target.type == "macro":
                macros.append(target)
                return
            if target.type == "plugin":
                self.uses_build_plugins = True
            if target.type in ("plugin", "executable", "test"):
                return  # build tools, not guest code
            for name in target.target_dependencies:
                visit(self.targets[(target.package_path, name)])
            for name in target.product_dependencies:
                dependency_package, dependency_targets = self.products[name]
                for dependency in dependency_targets:
                    visit(self.targets[(dependency_package, dependency)])
            ordered.append(target)

        for name in names:
            visit(self.targets[(package, name)])
        return ordered, macros


# ---------------------------------------------------------------------------
# Compilation
# ---------------------------------------------------------------------------

class Compiler:
    """Compiles every target of a closure for one triple into objects."""

    def __init__(self, toolchain, graph, product, triple, output, cflags=(), features=(), wasm_sdk=None, cpu=None, defines=()):
        self.cpu = cpu
        self.defines = list(defines)
        self.toolchain = toolchain
        self.graph = graph
        self.product = product
        self.triple = triple
        self.output = Path(output)
        self.cflags = list(cflags)
        self.features = list(features)
        self.wasm_sdk = wasm_sdk

    def common_c_flags(self):
        flags = ["-target", self.triple, "-Os", "-fPIC", "-fno-stack-protector", "-D__EMBEDDED_SWIFT__"] + self.cflags
        if self.cpu:
            flags.append(f"-march={self.cpu}")
        if self.wasm_sdk:
            flags += ["--sysroot", self.wasm_sdk / "WASI.sdk"]
        else:
            flags.append("-ffreestanding")
        for feature in self.features:
            flags += ["-Xclang", "-target-feature", "-Xclang", feature]
        return flags

    def swift_flags(self):
        flags = [
            "-target", self.triple,
            "-enable-experimental-feature", "Embedded",
            "-wmo", "-parse-as-library", "-Osize", "-swift-version", "6",
            "-Xfrontend", "-disable-stack-protector",
            "-D", "SWIFT_PACKAGE",
            "-I", self.output,
        ]
        if self.cpu:
            flags += ["-target-cpu", self.cpu]
        for define in self.defines:
            flags += ["-D", define]
        if self.wasm_sdk:
            flags += ["-sdk", self.wasm_sdk / "WASI.sdk",
                      "-resource-dir", self.wasm_sdk / "swift.xctoolchain/usr/lib/swift"]
        for flag in self.common_c_flags():
            if not str(flag).startswith("-march="):
                flags += ["-Xcc", flag]
        return flags

    def compile_support(self, names):
        """Runtime support objects sealed into the slice (Scripts/support)."""
        objects = []
        for name in names:
            obj = self.output / f"support-{Path(name).stem}.o"
            run([self.toolchain.tool("clang"), *self.common_c_flags(), "-c", SUPPORT / name, "-o", obj])
            objects.append(obj)
        return objects

    def compile(self, targets, plugins):
        self.output.mkdir(parents=True, exist_ok=True)
        objects, module_maps = [], []
        for target in targets:
            if target.is_swift:
                objects.append(self.compile_swift(target, plugins, module_maps))
            else:
                objects += self.compile_c(target, module_maps)
        return objects

    def compile_c(self, target, module_maps):
        include = target.path / "include"
        module_map = include / "module.modulemap"
        if not module_map.exists():
            module_map = self.output / f"{target.c99name}.modulemap"
            module_map.write_text(f'module {target.c99name} {{\n    umbrella "{include}"\n    export *\n}}\n')
        module_maps.append((include, module_map))
        objects = []
        for source in target.sources:
            if source.suffix not in (".c", ".s", ".S"):
                continue
            obj = self.output / f"{target.c99name}-{source.stem}.o"
            run([self.toolchain.tool("clang"), *self.common_c_flags(), "-I", include, "-I", target.path,
                 "-c", source, "-o", obj])
            objects.append(obj)
        return objects

    def compile_swift(self, target, plugins, module_maps):
        sources = [s for s in target.sources if s.suffix == ".swift"]
        sources += self.graph.generated_sources(target)
        obj = self.output / f"{target.c99name}.o"
        flags = self.swift_flags()
        flags += ["-package-name", target.package_path.name.lower()]
        for include, module_map in module_maps:
            flags += ["-Xcc", f"-I{include}", "-Xcc", f"-fmodule-map-file={module_map}"]
        for plugin, module in plugins:
            flags += ["-load-plugin-executable", f"{plugin}#{module}"]
        run([self.toolchain.tool("swiftc"), *flags, "-module-name", target.c99name, *sources,
             "-emit-module", "-emit-module-path", self.output / f"{target.c99name}.swiftmodule",
             "-c", "-o", obj], filter_warnings=("remark:",))
        return obj


def build_plugins(graph, product, macros):
    """Builds the product's macro plugins for the build machine."""
    if not macros and not graph.uses_build_plugins:
        return []
    run(["swift", "build", "--product", product], cwd=graph.root, quiet=True)
    plugins = []
    for macro in macros:
        candidates = [p for p in (graph.root / ".build").rglob(macro.name) if p.is_file() and os.access(p, os.X_OK)]
        candidates += [p for p in (graph.root / ".build").rglob(f"{macro.name}-tool") if p.is_file() and os.access(p, os.X_OK)]
        if not candidates:
            raise BuildError(f"macro plugin {macro.name} was not built")
        plugins.append((max(candidates, key=lambda p: p.stat().st_mtime), macro.c99name))
    return plugins


# ---------------------------------------------------------------------------
# Sealing and checks (§7.5)
# ---------------------------------------------------------------------------

def runtime_libraries(toolchain, triple, concurrency):
    names = ["swiftUnicodeDataTables"]
    if concurrency:
        names.append("swift_Concurrency")
    return [lib for lib in (toolchain.embedded_library(triple, name) for name in names) if lib]


def seal_elf(toolchain, objects, libraries, output):
    sealed = output / "app.o"
    run([toolchain.tool("ld.lld"), "-r", "-o", sealed, *objects, *libraries])
    run([toolchain.tool("llvm-objcopy"), *[f"--keep-global-symbol={s}" for s in GUEST_EXPORTS], sealed])
    return sealed


def seal_macho(toolchain, objects, libraries, output, slice_config):
    sealed = output / f"app-{slice_config['arch']}.o"
    exports = output / "exports.txt"
    exports.write_text("".join(f"_{s}\n" for s in GUEST_EXPORTS))
    minimum = slice_config["minimum"]
    run(["xcrun", "ld", "-r", "-arch", slice_config["arch"],
         "-platform_version", slice_config["platform"], minimum, minimum,
         "-exported_symbols_list", exports, *objects, *libraries, "-o", sealed],
        filter_warnings=("no platform load command", "was built for newer"))
    return sealed


def symbols(toolchain, obj, undefined):
    flags = ["--undefined-only"] if undefined else ["--defined-only", "--extern-only"]
    names = run([toolchain.tool("llvm-nm"), *flags, "--format=just-symbols", obj], quiet=True).split()
    return sorted(set(names))


def check_sealed(toolchain, obj, macho):
    """Returns a list of problems with a sealed object."""
    problems = []
    strip = (lambda s: s[1:] if s.startswith("_") else s) if macho else (lambda s: s)
    for symbol in map(strip, symbols(toolchain, obj, undefined=True)):
        if symbol in GUEST_EXPORTS:
            problems.append(f"guest export {symbol} is undefined")
        elif GLIBC_ONLY.search(symbol):
            problems.append(f"glibc-only reference {symbol}")
        elif not (ALLOWED_UNDEFINED.match(symbol)
                  or (macho and ALLOWED_APPLE.match(symbol))
                  or (not macho and ALLOWED_ARM_EABI.match(symbol))):
            problems.append(f"undefined symbol outside the allowed set: {symbol}")
    exported = [strip(s) for s in symbols(toolchain, obj, undefined=False)]
    if sorted(exported) != sorted(GUEST_EXPORTS):
        problems.append(f"exported symbols are {exported}, expected {list(GUEST_EXPORTS)}")
    headers = run([toolchain.tool("llvm-objdump"), "-h", obj], quiet=True)
    abi_section = "__rt_abi" if macho else ".rt_abi"
    if abi_section not in headers:
        problems.append(f"missing {abi_section} section")
    return problems


def archive(toolchain, obj, path):
    path.unlink(missing_ok=True)
    run([toolchain.tool("llvm-ar"), "rcs", path, obj])
    return path


# ---------------------------------------------------------------------------
# Metadata (§10)
# ---------------------------------------------------------------------------

def dump_section(toolchain, obj, section):
    out = obj.parent / (section.strip(".").replace(",", "_") + ".bin")
    out.unlink(missing_ok=True)
    try:
        run([toolchain.tool("llvm-objcopy"), f"--dump-section={section}={out}", obj, obj.parent / "dump.tmp"], quiet=True)
    except BuildError:
        return b""
    finally:
        (obj.parent / "dump.tmp").unlink(missing_ok=True)
    return out.read_bytes() if out.exists() else b""


def decode_contracts(data):
    """Decodes rt.contracts records (RuntimeABI.ContractMetadata)."""
    contracts, offset = [], 0

    def take(count):
        nonlocal offset
        if offset + count > len(data):
            raise BuildError("malformed rt.contracts section")
        value = data[offset:offset + count]
        offset += count
        return value

    def string():
        (length,) = struct.unpack("<H", take(2))
        return take(length).decode("utf-8")

    while offset < len(data):
        if data[offset] == 0:
            offset += 1
            continue
        if take(3) != b"RTC" or take(1)[0] != 1:
            raise BuildError("malformed rt.contracts section")
        kind = take(1)[0]
        (version,) = struct.unpack("<I", take(4))
        name, capability = string(), string()
        (count,) = struct.unpack("<H", take(2))
        methods = []
        for _ in range(count):
            method_kind = take(1)[0]
            methods.append(dict(key=string(), signature=string(), kind=method_kind))
        contracts.append(dict(name=name, kind="contract" if kind == 1 else "callback",
                              version=version, capability=capability or None, methods=methods))
    return contracts


# ---------------------------------------------------------------------------
# wasm32
# ---------------------------------------------------------------------------

def wasm_sections(data):
    """Imports, exports and custom section names of a wasm module."""
    def leb(i):
        result = shift = 0
        while True:
            byte = data[i]
            i += 1
            result |= (byte & 0x7F) << shift
            shift += 7
            if byte < 0x80:
                return result, i

    def name(i):
        length, i = leb(i)
        return data[i:i + length].decode(), i + length

    imports, exports, custom = [], [], []
    i = 8
    while i < len(data):
        section, i = data[i], i + 1
        size, i = leb(i)
        end = i + size
        if section == 0:
            custom.append(name(i)[0])
        elif section == 2:
            count, j = leb(i)
            for _ in range(count):
                module, j = name(j)
                field, j = name(j)
                kind, j = data[j], j + 1
                if kind == 0:
                    _, j = leb(j)
                elif kind in (1, 2):
                    if kind == 1:
                        j += 1
                    flags, j = leb(j)
                    _, j = leb(j)
                    if flags & 1:
                        _, j = leb(j)
                elif kind == 3:
                    j += 2
                imports.append(f"{module}.{field}")
        elif section == 7:
            count, j = leb(i)
            for _ in range(count):
                field, j = name(j)
                j += 1
                _, j = leb(j)
                exports.append(field)
        i = end
    return imports, exports, custom


def build_wasm(toolchain, graph, product, targets, plugins, output, contracts_section):
    sdk = toolchain.wasm_sdk()
    compiler = Compiler(toolchain, graph, product, TARGETS["wasm32"]["triple"], output, wasm_sdk=sdk)
    objects = compiler.compile(targets, plugins)
    linked = output / "App.linked.wasm"
    resources = sdk / "swift.xctoolchain/usr/lib/swift"
    run([toolchain.tool("swiftc"), "-target", "wasm32-unknown-wasip1", "-emit-executable",
         "-sdk", sdk / "WASI.sdk", "-sysroot", sdk / "WASI.sdk",
         "-resource-dir", resources, "-Xclang-linker", "-resource-dir", "-Xclang-linker", resources / "clang",
         "-static-stdlib", "-enable-experimental-feature", "Embedded",
         "-Xclang-linker", "-mexec-model=reactor",
         "-Xlinker", "--gc-sections",
         "-Xlinker", "-lswiftUnicodeDataTables", "-Xlinker", "-lswift_Concurrency",
         *objects, "-o", linked])
    wasm = output / "App.wasm"
    arguments = [toolchain.tool("llvm-objcopy"), "--strip-debug"]
    if contracts_section:
        section_file = output / "rt.contracts.bin"
        section_file.write_bytes(contracts_section)
        arguments += ["--add-section", f"rt.contracts={section_file}"]
    run([*arguments, linked, wasm])
    linked.unlink()

    imports, exports, custom = wasm_sections(wasm.read_bytes())
    problems = []
    for name in imports:
        if not (name.startswith("rt.") or name.startswith("wasi_snapshot_preview1.")):
            problems.append(f"import outside rt and WASI preview 1: {name}")
    for name in ("_initialize", "rt_main", "rt_dispatch", "rt_finalize", "rt_alloc", "rt_free", "memory"):
        if name not in exports:
            problems.append(f"missing export {name}")
    if "_start" in exports:
        problems.append("module is a command (_start), not a reactor")
    if "rt.abi" not in custom:
        problems.append("missing rt.abi section")
    if problems:
        raise BuildError("App.wasm:\n  " + "\n  ".join(problems))
    return wasm


# ---------------------------------------------------------------------------
# Slices
# ---------------------------------------------------------------------------

class Builder:

    def __init__(self, package, product):
        self.package = Path(package).resolve()
        self.product = product
        self.toolchain = Toolchain(self.package)
        self.graph = PackageGraph(self.package)
        self.targets, macros = self.graph.closure(product)
        self.plugins = build_plugins(self.graph, product, macros)
        self.root = self.package / ".build" / "guest" / product
        self._contracts = None

    def slice(self, target_id, output=None):
        """Builds one slice; returns the path of libapp.a or App.wasm."""
        config = TARGETS[target_id]
        output = Path(output) if output else self.root / target_id
        if output.exists():
            shutil.rmtree(output)
        output.mkdir(parents=True)
        print(f"==> {target_id}: {config['about']}")
        if config["kind"] == "wasm":
            return build_wasm(self.toolchain, self.graph, self.product, self.targets, self.plugins,
                              output, self.contracts_section())
        if config["kind"] == "elf":
            return self.elf_slice(config, output)
        return self.macho_slice(config, output)

    def elf_slice(self, config, output):
        triple = config["triple"]
        compiler = Compiler(self.toolchain, self.graph, self.product, triple, output / "objects",
                            cflags=config.get("cflags", ()), cpu=config.get("cpu"), defines=NO_CONCURRENCY)
        objects = compiler.compile(self.targets, self.plugins)
        objects += compiler.compile_support(config.get("support", []))
        sealed = seal_elf(self.toolchain, objects, runtime_libraries(self.toolchain, triple, concurrency=True), output)
        problems = check_sealed(self.toolchain, sealed, macho=False)
        if problems:
            raise BuildError(f"{output.name}:\n  " + "\n  ".join(problems))
        return archive(self.toolchain, sealed, output / "libapp.a")

    def macho_slice(self, config, output):
        archives = []
        for slice_config in config["slices"]:
            directory = output / slice_config["arch"]
            compiler = Compiler(self.toolchain, self.graph, self.product, slice_config["triple"], directory / "objects",
                                cflags=slice_config.get("cflags", ()), features=slice_config.get("features", ()),
                                defines=NO_CONCURRENCY)
            objects = compiler.compile(self.targets, self.plugins)
            objects += compiler.compile_support(slice_config.get("support", []))
            libraries = runtime_libraries(self.toolchain, slice_config["triple"], concurrency=True)
            sealed = seal_macho(self.toolchain, objects, libraries, directory, slice_config)
            problems = check_sealed(self.toolchain, sealed, macho=True)
            if problems:
                raise BuildError(f"{output.name} ({slice_config['arch']}):\n  " + "\n  ".join(problems))
            archives.append(archive(self.toolchain, sealed, directory / "libapp.a"))
        result = output / "libapp.a"
        if len(archives) == 1:
            shutil.copy(archives[0], result)
        else:
            run(["xcrun", "lipo", "-create", *archives, "-output", result])
        return result

    def contracts_section(self):
        """The rt.contracts records, read from a native ELF build of the product."""
        if self._contracts is None:
            directory = self.root / ".metadata"
            if directory.exists():
                shutil.rmtree(directory)
            # Any ELF triple works; this one ships the Embedded concurrency
            # module, which aarch64-none-none-elf doesn't.
            compiler = Compiler(self.toolchain, self.graph, self.product, "x86_64-unknown-none-elf", directory)
            objects = compiler.compile(self.targets, self.plugins)
            sealed = seal_elf(self.toolchain, objects, [], directory)
            self._contracts = dump_section(self.toolchain, sealed, ".rt_contracts")
        return self._contracts


# ---------------------------------------------------------------------------
# Bundle (§7.5)
# ---------------------------------------------------------------------------

SAFE_COMPONENT = re.compile(r"^[^/\x00]+$")


def safe_component(value, what):
    if not value or value in (".", "..") or not SAFE_COMPONENT.match(value):
        raise BuildError(f"{what} must be a single path component: {value!r}")
    return value


def code_resources(bundle):
    """Per-file SHA-256 hashes. Signing them is the packager's job."""
    files = {}
    for path in sorted(bundle.rglob("*")):
        relative = path.relative_to(bundle).as_posix()
        if path.is_file() and not relative.startswith("_CodeSignature/"):
            files[relative] = hashlib.sha256(path.read_bytes()).digest()
    return {"files": files}


def build_bundle(arguments):
    builder = Builder(arguments.package, arguments.product)
    identifier = safe_component(arguments.id, "bundle identifier")
    executable = safe_component(arguments.executable or arguments.product, "executable name")
    targets = expand_targets(arguments.target or ["all"])
    if "wasm32" not in targets:
        targets.insert(0, "wasm32")  # every bundle carries App.wasm

    contracts = decode_contracts(builder.contracts_section())
    capabilities = sorted(set(arguments.capability or []))
    required = sorted({c["capability"] for c in contracts if c["capability"]})
    missing = [c for c in required if c not in capabilities]
    if missing:
        raise BuildError(f"contracts require undeclared capabilities: {', '.join(missing)}")
    for unused in sorted(set(capabilities) - set(required)):
        print(f"warning: capability '{unused}' is declared but no contract uses it")

    output = Path(arguments.output) if arguments.output else builder.root
    bundle = output / f"{identifier}.app"
    if bundle.exists():
        shutil.rmtree(bundle)
    bundle.mkdir(parents=True)

    for target_id in targets:
        built = builder.slice(target_id)
        destination = bundle / ("wasm32/App.wasm" if target_id == "wasm32" else f"lib/{target_id}/libapp.a")
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy(built, destination)

    if arguments.resources:
        shutil.copytree(arguments.resources, bundle / "resources")
    if arguments.icon:
        shutil.copy(arguments.icon, bundle / "icon.png")

    info = {
        "CFBundleIdentifier": identifier,
        "CFBundleName": arguments.name,
        "CFBundleDisplayName": arguments.name,
        "CFBundleExecutable": executable,
        "CFBundleShortVersionString": arguments.version,
        "CFBundleVersion": str(arguments.build),
        "RTABIVersion": ABI_VERSION,
        "RTTargets": targets,
        "RTCapabilities": capabilities,
        "RTContracts": [{"Name": c["name"], "Version": c["version"], "Kind": c["kind"]} for c in contracts],
    }
    if arguments.languages:
        info["CFBundleLocalizations"] = arguments.languages
    with open(bundle / "Info.plist", "wb") as file:
        plistlib.dump(info, file)

    signature = bundle / "_CodeSignature"
    signature.mkdir()
    with open(signature / "CodeResources", "wb") as file:
        plistlib.dump(code_resources(bundle), file)
    print(f"ok: {bundle}")
    return bundle


def expand_targets(names):
    targets = []
    for name in names:
        if name == "all":
            expanded = list(TARGETS)
        elif name in PLATFORM_GROUPS:
            expanded = PLATFORM_GROUPS[name]
        elif name in TARGETS:
            expanded = [name]
        else:
            raise BuildError(f"unknown target {name}; see `guest.py targets`")
        targets += [t for t in expanded if t not in targets]
    return targets


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    commands = parser.add_subparsers(dest="command", required=True)

    commands.add_parser("targets", help="list target IDs and platform groups")

    slice_parser = commands.add_parser("slice", help="build slices for targets or platform groups")
    slice_parser.add_argument("--package", default=".")
    slice_parser.add_argument("--product", required=True, help="guest library product")
    slice_parser.add_argument("--target", action="append", required=True, help="target ID or group (repeatable)")

    bundle_parser = commands.add_parser("bundle", help="build slices and assemble the universal bundle")
    bundle_parser.add_argument("--package", default=".")
    bundle_parser.add_argument("--product", required=True, help="guest library product")
    bundle_parser.add_argument("--id", required=True, help="bundle identifier")
    bundle_parser.add_argument("--name", required=True)
    bundle_parser.add_argument("--version", required=True)
    bundle_parser.add_argument("--build", type=int, required=True, help="integer build number")
    bundle_parser.add_argument("--executable", help="CFBundleExecutable; defaults to the product")
    bundle_parser.add_argument("--target", action="append", help="target ID or group; default all")
    bundle_parser.add_argument("--capability", action="append", help="declared capability (repeatable)")
    bundle_parser.add_argument("--language", dest="languages", action="append")
    bundle_parser.add_argument("--resources", help="directory copied to resources/")
    bundle_parser.add_argument("--icon", help="PNG copied to icon.png")
    bundle_parser.add_argument("--output", help="directory for <id>.app")

    arguments = parser.parse_args()
    try:
        if arguments.command == "targets":
            for name, config in TARGETS.items():
                print(f"{name:22} {config['about']}")
            print()
            for group, names in PLATFORM_GROUPS.items():
                print(f"{group:22} {' '.join(names)}")
        elif arguments.command == "slice":
            builder = Builder(arguments.package, arguments.product)
            for target_id in expand_targets(arguments.target):
                print(f"ok: {builder.slice(target_id)}")
        else:
            build_bundle(arguments)
    except BuildError as error:
        print(f"error: {error}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
