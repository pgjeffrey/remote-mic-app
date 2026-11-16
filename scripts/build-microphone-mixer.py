#!/usr/bin/env python3
"""Build and embed the pinned public microphone-mixing engine in a SayAll App.

This permanent packaging step owns native OBS compilation, the dependency
closure, resources and nested signatures. SwiftPM owns the Swift host.
"""
import argparse
from collections import deque
import hashlib
import re
import os
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OBS_COMMIT = "65c320b46e1af5c7a555161aea6182cdf7a8c524"


def run(*args):
    subprocess.run([str(arg) for arg in args], check=True)


def output(*args):
    return subprocess.check_output([str(arg) for arg in args], text=True).strip()


def dependencies(binary, architecture=None):
    selection = ("-arch", architecture) if architecture else ()
    lines = output("otool", *selection, "-L", binary).splitlines()
    # Universal binaries can contain several unindented architecture headers.
    return [line.strip().split(" (compatibility", 1)[0] for line in lines
            if line.strip() and line[:1].isspace()]


def rpaths(binary, architecture=None):
    selection = ("-arch", architecture) if architecture else ()
    return re.findall(r"cmd LC_RPATH\s+cmdsize \d+\s+path (.+?) \(offset", output("otool", *selection, "-l", binary))


def system_library(value):
    return value.startswith(("/usr/lib/", "/System/Library/"))


def bundle(app, roots, search_roots, architecture=None):
    app = Path(app).resolve()
    frameworks = app / "Contents/Frameworks"
    frameworks.mkdir(parents=True, exist_ok=True)
    searches = [frameworks, *[Path(root).resolve() for root in search_roots]]
    queue = deque()
    completed = set()
    origins = {}
    fingerprints = {}

    def fingerprint(path):
        if path not in fingerprints:
            fingerprints[path] = hashlib.sha256(path.read_bytes()).digest()
        return fingerprints[path]

    def schedule(original, target):
        original, target = Path(original).resolve(), Path(target).resolve()
        if not target.is_relative_to(app):
            raise RuntimeError(f"Refusing to rewrite a binary outside the application: {target}")
        if target in origins:
            # A reference can resolve to a binary that was already copied and
            # rewritten. Its on-disk bytes have changed, but its identity has not.
            if original != target and origins[target] != fingerprint(original):
                raise RuntimeError(f"Different libraries would occupy the same bundled path: {target}")
            return
        signature = fingerprint(original)
        if target.exists() and original != target and fingerprint(target) != signature:
            raise RuntimeError(f"Existing bundled library has different contents: {target}")
        origins[target] = signature
        queue.append((original, target))

    for original, target in roots:
        schedule(original, target)

    def locate(value, original):
        candidates = []
        if value.startswith("@loader_path/"):
            candidates.append(original.parent / value.removeprefix("@loader_path/"))
        elif value.startswith("@executable_path/"):
            candidates.append(app / "Contents/MacOS" / value.removeprefix("@executable_path/"))
        elif value.startswith("@rpath/"):
            suffix = value.removeprefix("@rpath/")
            for path in rpaths(original, architecture):
                path = path.replace("@loader_path", str(original.parent)).replace("@executable_path", str(app / "Contents/MacOS"))
                candidates.append(Path(path) / suffix)
            candidates.extend(root / suffix for root in searches)
        else:
            candidates.append(Path(value))
        for candidate in candidates:
            if candidate.is_file():
                return candidate.resolve()
        # Dependencies in a relocatable obs-deps archive may retain their build
        # prefix. Search by exact filename and reject ambiguous alternatives.
        matches = {path.resolve() for root in searches for path in root.rglob(Path(value).name) if path.is_file()}
        if len(matches) == 1:
            return matches.pop()
        raise RuntimeError(f"Cannot resolve {value} required by {original}; candidates={sorted(map(str, matches))}")

    def destination(source):
        try:
            source.relative_to(frameworks)
            return source
        except ValueError:
            pass
        for parent in source.parents:
            if parent.suffix == ".framework":
                target = frameworks / parent.name
                if not target.exists():
                    shutil.copytree(parent, target, symlinks=True)
                return target / source.relative_to(parent)
        return frameworks / source.name

    while queue:
        original, target = queue.popleft()
        if target in completed:
            continue
        completed.add(target)
        if not target.exists():
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(original, target)
        target.chmod(target.stat().st_mode | 0o200)
        for dependency in dependencies(original, architecture):
            if system_library(dependency):
                continue
            source = locate(dependency, original)
            if source == original:
                continue  # LC_ID_DYLIB is listed by otool as well.
            copied = destination(source).resolve()
            schedule(source, copied)
            relative = copied.relative_to(frameworks)
            new = "@rpath/" + str(relative)
            if dependency != new:
                output("install_name_tool", "-change", dependency, new, target)
        if target.suffix == ".dylib" or ".framework/" in str(target):
            output("install_name_tool", "-id", "@rpath/" + str(target.relative_to(frameworks)), target)
        existing = rpaths(target, architecture)
        for path in existing:
            if path.startswith("/") and not system_library(path):
                output("install_name_tool", "-delete_rpath", path, target)
        runtime_path = "@executable_path/../Frameworks"
        if runtime_path not in existing:
            output("install_name_tool", "-add_rpath", runtime_path, target)

    for binary in completed:
        for dependency in dependencies(binary, architecture):
            if dependency.startswith("/") and not system_library(dependency):
                raise RuntimeError(f"Build-machine dependency remains in {binary}: {dependency}")
            if dependency.startswith("@rpath/") and not (frameworks / dependency.removeprefix("@rpath/")).exists():
                raise RuntimeError(f"Missing bundled dependency in {binary}: {dependency}")
    return completed

def copy_tree(source, destination):
    shutil.copytree(source, destination, symlinks=True, dirs_exist_ok=True)


def prepare_obs(arch, minimum):
    cache = Path(os.environ.get("SAYALL_MIXER_CACHE_PATH",
                               "/private/tmp/sayall-microphone-mixer"))
    source = Path(os.environ.get("SAYALL_MIXER_OBS_SOURCE_PATH", cache / "obs-studio"))
    build = Path(os.environ.get("SAYALL_MIXER_OBS_BUILD_PATH", cache / arch / "obs"))
    if not (source / ".git").exists():
        source.parent.mkdir(parents=True, exist_ok=True)
        run("git", "clone", "--depth", "1", "--branch", "33.0.1",
            "https://github.com/obsproject/obs-studio.git", source)
    if output("git", "-C", source, "rev-parse", "HEAD") != OBS_COMMIT:
        raise RuntimeError("OBS checkout does not match the pinned commit")
    if output("git", "-C", source, "status", "--porcelain", "--untracked-files=no"):
        raise RuntimeError("OBS checkout contains tracked source changes")
    framework = build / "libobs/Release/libobs.framework"
    metal = build / "libobs-metal/Release/libobs-metal.dylib"
    if not (framework / "libobs").is_file() or not metal.is_file():
        run("cmake", "--preset", "macos", "-S", source, "-B", build,
            f"-DCMAKE_OSX_ARCHITECTURES={arch}", f"-DCMAKE_OSX_DEPLOYMENT_TARGET={minimum}",
            "-DOBS_VERSION_OVERRIDE=33.0.1", "-DOBS_BUILD_NUMBER=1",
            "-DENABLE_FRONTEND=OFF", "-DENABLE_CORE_MODULES=OFF",
            "-DENABLE_SCRIPTING=OFF", "-DENABLE_BROWSER=OFF", "-DENABLE_TEST_INPUT=OFF",
            "-DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO")
        run("cmake", "--build", build, "--config", "Release", "--target",
            "libobs", "libobs-metal", "--parallel")
    for binary in (framework / "libobs", metal):
        if arch not in output("lipo", "-archs", binary).split():
            raise RuntimeError("OBS cache is missing the selected architecture")
    return source, build, framework, metal


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--arch", required=True, choices=["arm64", "x86_64"])
    parser.add_argument("--minimum", required=True)
    args = parser.parse_args()
    source, build, framework, metal = prepare_obs(args.arch, args.minimum)
    deps = source / ".deps/obs-deps-2026-10-23-universal"
    native = ROOT / "Sources/MicrophoneMixerNative"
    work = ROOT / ".build/microphone-mixer" / args.arch
    work.mkdir(parents=True, exist_ok=True)
    pipe_test = work / "AudioPipeTests"
    run("xcrun", "clang++", "-std=c++17", ROOT / "Tests/MicrophoneMixerNativeTests/AudioPipeTests.cpp",
        "-o", pipe_test)
    run(pipe_test)
    sdk = output("xcrun", "--sdk", "macosx", "--show-sdk-path")
    common = ["-O2", "-arch", args.arch, "-isysroot", sdk,
              f"-mmacosx-version-min={args.minimum}", "-fPIC", "-DNDEBUG",
              f"-I{source / 'libobs'}", f"-I{build / 'config'}", f"-I{deps / 'include'}",
              f"-I{source / 'plugins/mac-capture'}", f"-ffile-prefix-map={ROOT}=/build/sayall",
              f"-ffile-prefix-map={source}=/build/obs"]
    objects = []
    for filename in ["MixerBridge.mm", "Devices.mm", "HALOutput.cpp", "InputModule.c"]:
        target = work / (filename + ".o")
        flags = ["-std=c17"] if filename.endswith(".c") else ["-std=c++17"]
        if filename.endswith(".mm"):
            flags += ["-fobjc-arc"]
        run("xcrun", "clang++" if not filename.endswith(".c") else "clang",
            *common, *flags, "-c", native / filename, "-o", target)
        objects.append(target)
    enumeration = work / "audio-device-enum.o"
    run("xcrun", "clang", *common, "-std=c17", "-c",
        source / "plugins/mac-capture/audio-device-enum.c", "-o", enumeration)
    frameworks = args.app / "Contents/Frameworks"
    resources = args.app / "Contents/Resources/MicrophoneMixer"
    frameworks.mkdir(parents=True, exist_ok=True)
    resources.mkdir(parents=True, exist_ok=True)
    shared = ["-arch", args.arch, "-isysroot", sdk, f"-mmacosx-version-min={args.minimum}",
              "-F", framework.parent, "-framework", "libobs", "-framework", "Foundation",
              "-framework", "CoreAudio", "-framework", "AudioUnit", "-framework", "CoreFoundation",
              "-Wl,-rpath,@executable_path/../Frameworks"]
    bridge = frameworks / "libSayAllMicrophoneMixer.dylib"
    plugin = frameworks / "MixerMacInput.so"
    run("xcrun", "clang++", "-dynamiclib", *objects[:3], *shared,
        "-Wl,-install_name,@rpath/libSayAllMicrophoneMixer.dylib", "-o", bridge)
    run("xcrun", "clang", "-bundle", objects[3], enumeration, *shared, "-o", plugin)
    bundled_framework = frameworks / "libobs.framework"
    copy_tree(framework, bundled_framework)
    bundled_metal = frameworks / "libobs-metal.dylib"
    shutil.copy2(metal, bundled_metal)
    copy_tree(source / "plugins/mac-capture/data", resources / "mac-input")
    shutil.copy2(source / "COPYING", resources / "OBS-COPYING.txt")
    if (deps / "share/licenses").exists():
        copy_tree(deps / "share/licenses", resources / "Licenses")
    compiler = Path(output("xcrun", "--find", "swiftc"))
    runtime = compiler.parent.parent / "lib/swift/macosx"
    run("xcrun", "swift-stdlib-tool", "--copy", "--platform", "macosx",
        "--scan-executable", bundled_metal, "--destination", frameworks)
    roots = [(bridge, bridge), (plugin, plugin), (framework / "libobs", bundled_framework / "libobs"),
             (metal, bundled_metal)]
    roots += [(path, path) for path in frameworks.glob("libswift*.dylib")]
    binaries = bundle(args.app, roots,
                      [framework.parent, metal.parent, deps / "lib", deps / "Frameworks", runtime],
                      architecture=args.arch)
    # Host path sanitization runs before all nested signatures below are applied.
    run("python3", ROOT / "scripts/sanitize-release-paths.py", args.app)
    identity = os.environ.get("CODE_SIGN_IDENTITY", "-")
    signing = ["--timestamp=none"] if identity == "-" else ["--options", "runtime", "--timestamp"]
    for binary in sorted(binaries, key=lambda path: len(path.parts), reverse=True):
        if ".framework/" not in str(binary):
            run("codesign", "--force", "--sign", identity, *signing, binary)
    for path in sorted(frameworks.glob("*.framework")):
        if path.name != "Sparkle.framework":
            run("codesign", "--force", "--sign", identity, *signing, path)
    print("MICROPHONE MIXER BUILD result=passed version=33.0.1")


if __name__ == "__main__":
    main()
