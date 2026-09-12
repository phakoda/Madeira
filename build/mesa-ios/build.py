#!/usr/bin/env python3
"""Pinned, CI-only Apple ARM64 softpipe/OSMesa build and static packaging."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tarfile
import urllib.request
import venv

ROOT = Path(__file__).resolve().parent
MANIFEST = json.loads((ROOT / "source.json").read_text())
USER_AGENT = "OpenAI File Downloader, XaiImageApiFetch/1.0"


def run(args, *, cwd=None):
    print("+ " + shlex.join(map(str, args)), flush=True)
    subprocess.run(list(map(str, args)), cwd=cwd, check=True)


def capture(args, *, cwd=None):
    return subprocess.check_output(list(map(str, args)), cwd=cwd, text=True).strip()


def fetch(url):
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=180) as response:
        return response.read()


def download(url, path, digest):
    if path.exists() and hashlib.sha256(path.read_bytes()).hexdigest() == digest:
        return
    data = fetch(url)
    if hashlib.sha256(data).hexdigest() != digest:
        raise RuntimeError(f"SHA256 mismatch: {path.name}")
    partial = path.with_suffix(path.suffix + ".partial")
    partial.write_bytes(data)
    partial.replace(path)


def bootstrap(work):
    """Wheel-only install, with our User-Agent on every remote request."""
    envdir = work / "python"
    if not envdir.exists():
        venv.EnvBuilder(with_pip=True).create(envdir)
    python = envdir / "bin/python"
    # pip's vendored packaging avoids a bootstrap network install of packaging.
    tags = json.loads(capture([python, "-c", "import json; from pip._vendor.packaging.tags import sys_tags; print(json.dumps([str(t) for t in sys_tags()]))"]))
    ranking = {tag: index for index, tag in enumerate(tags)}
    wheels = work / "wheels"
    wheels.mkdir(exist_ok=True)
    selected = []
    provenance = []
    for package, version in MANIFEST["python_packages"].items():
        candidates = []
        for entry in MANIFEST["python_wheels"]:
            if entry["package"] != package:
                continue
            name = entry["filename"]
            if not name.endswith(".whl"):
                continue
            py, abi, platform = name[:-4].rsplit("-", 3)[1:]
            compatible = [ranking[f"{p}-{a}-{s}"] for p in py.split(".")
                          for a in abi.split(".") for s in platform.split(".")
                          if f"{p}-{a}-{s}" in ranking]
            if compatible:
                candidates.append((min(compatible), name, entry))
        if not candidates:
            raise RuntimeError(f"No binary wheel for {package}=={version}; use Python 3.12 on macOS")
        _, filename, entry = min(candidates, key=lambda item: item[:2])
        digest = entry["sha256"]
        wheel = wheels / filename
        download(entry["url"], wheel, digest)
        selected.append(wheel)
        provenance.append({"file": filename, "sha256": digest, "url": entry["url"]})
    run([python, "-m", "pip", "install", "--no-index", "--no-deps", "--disable-pip-version-check", *selected])
    os.environ["PATH"] = str(envdir / "bin") + os.pathsep + os.environ["PATH"]
    return provenance


def source(work):
    archive = work / (MANIFEST["directory"] + ".tar.xz")
    download(MANIFEST["url"], archive, MANIFEST["sha256"])
    directory = work / MANIFEST["directory"]
    if not directory.exists():
        with tarfile.open(archive) as bundle:
            # Python 3.12's data filter rejects paths/links escaping destination.
            bundle.extractall(work, filter="data")
    return directory


def expand_responses(tokens, cwd, depth=0):
    if depth > 8:
        raise RuntimeError("Recursive linker response file")
    expanded = []
    for token in tokens:
        if token.startswith("@") and not token.startswith(("@rpath/", "@loader_path/", "@executable_path/")):
            response = Path(token[1:])
            if not response.is_absolute():
                response = cwd / response
            expanded.extend(expand_responses(shlex.split(response.read_text()), cwd, depth + 1))
        else:
            expanded.append(token)
    return expanded


def archive_inputs(command, cwd):
    """Read the actual validated OSMesa link, including Darwin force_load/rsp."""
    tokens = expand_responses(shlex.split(command), cwd)
    flattened = []
    for token in tokens:
        if token.startswith("-Wl,"):
            flattened.extend(expand_responses(token[4:].split(","), cwd))
        else:
            flattened.append(token)
    files = []
    for index, token in enumerate(flattened):
        if token in ("-filelist",):
            listing = Path(flattened[index + 1])
            if not listing.is_absolute():
                listing = cwd / listing
            for line in listing.read_text().splitlines():
                files.append(Path(line))
        if token.endswith((".a", ".o")):
            files.append(Path(token))
        if token.endswith(".dylib") and (index == 0 or flattened[index - 1] not in ("-o", "-install_name")):
            # OSMesa's output is the only dylib permitted; internal shared
            # dependencies would make the archive incomplete.
            raise RuntimeError(f"Unexpected dynamic dependency: {token}")
    resolved = list(dict.fromkeys((f if f.is_absolute() else cwd / f).resolve() for f in files))
    if not any(f.suffix == ".o" for f in resolved) or not any(f.suffix == ".a" for f in resolved):
        raise RuntimeError("OSMesa link did not expose both target objects and static dependencies")
    for path in resolved:
        if not path.is_file() or not path.is_relative_to(cwd.resolve()):
            raise RuntimeError(f"Non-build or missing archive input: {path}")
    return resolved


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--sdk", required=True, choices=("iphoneos", "iphonesimulator"))
    parser.add_argument("--deployment-target", default="16.0")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if os.environ.get("CI") != "true" or os.environ.get("GITHUB_ACTIONS") != "true" or sys.platform != "darwin":
        parser.error("Cross-compilation is restricted to macOS GitHub Actions")
    if not re.fullmatch(r"\d+\.\d+(?:\.\d+)?", args.deployment_target):
        parser.error("Invalid deployment target")
    work = ROOT / ".work" / args.sdk
    work.mkdir(parents=True, exist_ok=True)
    provenance = bootstrap(work)
    src = source(work)
    sdk = capture(["xcrun", "--sdk", args.sdk, "--show-sdk-path"])
    tools = {name: capture(["xcrun", "--sdk", args.sdk, "--find", executable])
             for name, executable in {"c": "clang", "cpp": "clang++", "objc": "clang", "ar": "ar", "strip": "strip"}.items()}
    triple = f"arm64-apple-ios{args.deployment_target}" + ("-simulator" if args.sdk == "iphonesimulator" else "")
    flags = ["-target", triple, "-isysroot", sdk]
    # No cross pkg-config search of the build Mac's Homebrew libraries.
    false_pkg = work / "no-target-pkg-config"
    false_pkg.write_text("#!/bin/sh\nexit 1\n")
    false_pkg.chmod(0o755)
    cross = work / "cross.ini"
    cross.write_text("[binaries]\n" + "\n".join(f"{key} = {value!r}" for key, value in tools.items())
                     + f"\npkg-config = {str(false_pkg)!r}\n[host_machine]\nsystem = 'darwin'\ncpu_family = 'aarch64'\ncpu = 'arm64'\nendian = 'little'\n"
                     + "[properties]\nneeds_exe_wrapper = true\n[built-in options]\n"
                     + "\n".join(f"{language}_{kind} = {flags!r}" for language in ("c", "cpp", "objc") for kind in ("args", "link_args")) + "\n")
    build = work / "build"
    out = (args.output or ROOT / "out" / args.sdk).resolve()
    out.mkdir(parents=True, exist_ok=True)
    options = ["-Ddefault_library=static", "-Db_lto=false", "-Dbuildtype=release",
               "-Dplatforms=[]", "-Dgallium-drivers=softpipe", "-Dvulkan-drivers=[]",
               "-Dosmesa=true", "-Dllvm=disabled", "-Ddraw-use-llvm=false",
               "-Dshared-glapi=disabled", "-Dgles1=disabled", "-Dgles2=disabled",
               "-Dglx=disabled", "-Degl=disabled", "-Dgbm=disabled", "-Dglvnd=disabled",
               "-Dgallium-vdpau=disabled", "-Dgallium-va=disabled", "-Dgallium-xa=disabled",
               "-Dgallium-nine=false", "-Dgallium-opencl=disabled", "-Dgallium-rusticl=false",
               "-Dvalgrind=disabled", "-Dlibunwind=disabled", "-Dlmsensors=disabled",
               "-Dxmlconfig=disabled", "-Dexpat=disabled", "-Dzlib=disabled", "-Dzstd=disabled",
               "-Dshader-cache=disabled", "-Dbuild-tests=false", "-Dtools=[]"]
    # Reconfigure explicitly, so a resumed job cannot use stale cross arguments.
    run(["meson", "setup", *( ["--wipe"] if (build / "meson-private/coredata.dat").exists() else [] ),
         build, src, "--cross-file", cross, "--wrap-mode=nodownload", *options])
    targets = json.loads(capture(["meson", "introspect", "--targets", build]))
    osmesa = [target for target in targets if target["name"] == "OSMesa" and target["type"] == "shared library"]
    if len(osmesa) != 1 or len(osmesa[0]["filename"]) != 1:
        raise RuntimeError("Unexpected pinned OSMesa build target")
    target = Path(osmesa[0]["filename"][0]).relative_to(build).as_posix()
    # Keep response files so packaging can expand exactly what the linker read.
    run(["ninja", "-C", build, "-d", "keeprsp", target])
    commands = capture(["ninja", "-C", build, "-t", "commands", target]).splitlines()
    (work / "link-commands.txt").write_text("\n".join(commands) + "\n")
    # Meson's Darwin linker uses -shared, which clang translates to a dylib.
    # Select the actual output target instead of relying on a driver spelling.
    link_commands = []
    for line in commands:
        tokens = expand_responses(shlex.split(line), build)
        for index, token in enumerate(tokens[:-1]):
            if token == '-o' and Path(tokens[index + 1]).as_posix() == target:
                link_commands.append(line)
                break
    if len(link_commands) != 1:
        raise RuntimeError("Expected one OSMesa dynamic link after static dependency builds")
    inputs = archive_inputs(link_commands[0], build)
    filelist = work / "archive-inputs.txt"
    filelist.write_text("\n".join(map(str, inputs)) + "\n")
    library = out / "libOSMesa.a"
    libtool = capture(["xcrun", "--sdk", args.sdk, "--find", "libtool"])
    run([libtool, "-static", "-o", library, "-filelist", filelist])
    arch = capture(["xcrun", "lipo", "-archs", library])
    if arch != "arm64":
        raise RuntimeError(f"Incorrect final archive architecture: {arch}")
    symbols = capture(["xcrun", "nm", "-gjU", library]).splitlines()
    for symbol in ("_OSMesaCreateContextExt", "_OSMesaMakeCurrent", "_OSMesaDestroyContext", "_glClear", "_glFinish"):
        if symbol not in symbols:
            raise RuntimeError(f"Final archive lacks {symbol}")
    if any(symbol.startswith(("_LLVM", "_lp_build_")) for symbol in symbols):
        raise RuntimeError("Unexpected LLVM/JIT symbol in softpipe archive")
    shutil.copy2(src / "docs/license.rst", out / "MESA-LICENSE.rst")
    headers = out / "include/GL"
    headers.mkdir(parents=True, exist_ok=True)
    for name in ("osmesa.h", "gl.h", "glext.h", "glcorearb.h"):
        shutil.copy2(src / "include/GL" / name, headers / name)
    khr = out / "include/KHR"
    khr.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src / "include/KHR/khrplatform.h", khr / "khrplatform.h")
    # Link an actual OSMesa renderer against ONLY the final archive and Apple
    # system libraries. This catches lost transitive archive members/symbols.
    smoke = out / "osmesa-link-smoke"
    run([tools["c"], *flags, "-I", out / "include", "-c", ROOT / "link-smoke.c", "-o", work / "link-smoke.o"])
    run([tools["cpp"], *flags, work / "link-smoke.o", library, "-o", smoke])
    metadata = capture(["xcrun", "vtool", "-show-build", smoke])
    expected = "IOSSIMULATOR" if args.sdk == "iphonesimulator" else "IOS"
    if not re.search(r"platform\s+" + expected + r"\b", metadata):
        raise RuntimeError(f"Incorrect linked Mach-O platform; expected {expected}: {metadata}")
    (out / "build.json").write_text(json.dumps({"source": MANIFEST, "sdk": args.sdk,
        "sdk_version": capture(["xcrun", "--sdk", args.sdk, "--show-sdk-version"]),
        "target": triple, "xcode": capture(["xcodebuild", "-version"]), "python_wheels": provenance,
        "archive_sha256": hashlib.sha256(library.read_bytes()).hexdigest(), "options": options,
        "inputs": [str(path.relative_to(build)) for path in inputs],
        "validation": "ARM64 archive, required symbols, and SDK-specific executable link; execution not performed"}, indent=2) + "\n")
    print(f"Static softpipe OSMesa ready: {library}")


if __name__ == "__main__":
    main()
