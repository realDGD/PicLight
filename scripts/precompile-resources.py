#!/usr/bin/env python3
"""Validate checked-in resources without Xcode; explicitly update them when needed."""

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile


ARTIFACTS = {"icon": "Assets.car", "metal": "default.metallib"}


class ResourceError(Exception):
    pass


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def inputs(root, name):
    if name == "icon":
        directory = root / "Resources/AppIcon/PicLight.icon"
        required = [directory / "icon.json", root / "Resources/AppIcon/PicLight.icns"]
    else:
        directory = root / "PicViewMac/Shaders"
        required = [directory / "ImageShaders.metal"]
    for path in required:
        if not path.is_file():
            raise ResourceError(f"missing source: {path.relative_to(root)}")
    paths = set(required)
    paths.update(p for p in directory.rglob("*") if p.is_file()
                 and p.name != ".DS_Store" and not p.name.startswith("._"))
    return {p.relative_to(root).as_posix(): digest(p) for p in sorted(paths)}


def configurations(minimum):
    # Bump the appropriate recipe when changing its compiler arguments below.
    return {
        "icon": {"recipe": 1, "platform": "macosx", "target_device": "mac",
                 "minimum_system_version": minimum, "app_icon": "PicLight"},
        "metal": {"recipe": 1, "platform": "macosx", "target": f"air64-apple-macos{minimum}"},
    }


def load_manifest(cache):
    path = cache / "manifest.json"
    if not path.exists():
        return {"schema": 1, "resources": {}}
    try:
        manifest = json.loads(path.read_text(encoding="utf-8"))
        if (not isinstance(manifest, dict) or manifest.get("schema") != 1
                or not isinstance(manifest.get("resources"), dict)):
            raise ValueError("unsupported schema")
        return manifest
    except (ValueError, OSError) as error:
        raise ResourceError(f"invalid {path.name}: {error}") from error


def stale_reason(cache, entry, name, source_inputs, configuration):
    if not isinstance(entry, dict):
        return "missing manifest entry"
    if entry.get("configuration") != configuration:
        return "compiler target or recipe changed"
    if entry.get("inputs") != source_inputs:
        return "source files changed"
    artifact = entry.get("artifact")
    if not isinstance(artifact, dict) or artifact.get("path") != ARTIFACTS[name]:
        return "invalid artifact entry"
    path = cache / ARTIFACTS[name]
    if not path.is_file() or path.stat().st_size == 0:
        return "missing or empty artifact"
    if digest(path) != artifact.get("sha256"):
        return "artifact SHA-256 mismatch"
    return None


def run(command):
    try:
        result = subprocess.run([str(p) for p in command], capture_output=True, text=True)
    except OSError as error:
        raise ResourceError(f"cannot run {command[0]}: {error}") from error
    if result.returncode:
        raise ResourceError(f"{Path(command[0]).name} failed ({result.returncode}):\n"
                            + result.stdout + result.stderr)
    return result.stdout.strip()


def compile_resource(root, name, configuration, work, xcrun, sdk):
    output = work / ARTIFACTS[name]
    if name == "icon":
        tool = run([xcrun, "--find", "actool"])
        catalog = work / "catalog"
        catalog.mkdir()
        run([tool, "--output-format", "human-readable-text", "--notices", "--warnings", "--errors",
             "--platform", configuration["platform"], "--target-device", configuration["target_device"],
             "--minimum-deployment-target", configuration["minimum_system_version"],
             "--app-icon", configuration["app_icon"],
             "--output-partial-info-plist", work / "partial.plist",
             "--compile", catalog, root / "Resources/AppIcon/PicLight.icon"])
        shutil.move(catalog / "Assets.car", output)
        tools = {"actool": run([tool, "--version"])}
    else:
        # SDK-specific lookup can select Xcode's placeholder instead of an
        # installed Metal toolchain. Resolve tools first, pass SDK explicitly.
        tool = run([xcrun, "--find", "metal"])
        linker = run([xcrun, "--find", "metallib"])
        air = work / "ImageShaders.air"
        run([tool, "-target", configuration["target"], "-isysroot", sdk,
             "-c", root / "PicViewMac/Shaders/ImageShaders.metal", "-o", air])
        run([linker, air, "-o", output])
        tools = {"metal": run([tool, "--version"]).split("\nInstalledDir:", 1)[0],
                 "metallib": run([linker, "--version"])}
    if not output.is_file() or output.stat().st_size == 0:
        raise ResourceError(f"compiler produced no {output.name}")
    return output, tools


def update(root, cache, manifest, source_inputs, configs, stale):
    xcrun = shutil.which("xcrun")
    if not xcrun:
        raise ResourceError("xcrun unavailable; resource refresh needs actool / metal / metallib")
    sdk = run([xcrun, "--sdk", "macosx", "--show-sdk-path"])
    sdk_version = run([xcrun, "--sdk", "macosx", "--show-sdk-version"])
    cache.parent.mkdir(parents=True, exist_ok=True)
    # Compile everything needed before replacing anything. A failed compiler
    # leaves the previous cache intact; manifest and artifacts move together.
    with tempfile.TemporaryDirectory(prefix=".precompiled-", dir=cache.parent) as temporary:
        work = Path(temporary)
        ready = work / "ready"
        if cache.exists():
            shutil.copytree(cache, ready)
        else:
            ready.mkdir()
        for name in stale:
            output, tools = compile_resource(root, name, configs[name], work, xcrun, sdk)
            shutil.copy2(output, ready / ARTIFACTS[name])
            manifest["resources"][name] = {
                "configuration": configs[name], "inputs": source_inputs[name],
                "artifact": {"path": ARTIFACTS[name], "sha256": digest(output)},
                "compiler": {"sdk_version": sdk_version, "tools": tools},
                "generated_at_utc": datetime.now(timezone.utc).isoformat(),
            }
        for name in ARTIFACTS:
            if inputs(root, name) != source_inputs[name]:
                raise ResourceError(f"{name}: sources changed during compilation; retry")
        (ready / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n",
                                             encoding="utf-8")
        previous = work / "previous"
        if cache.exists():
            cache.rename(previous)
        try:
            ready.rename(cache)
        except OSError:
            if previous.exists():
                previous.rename(cache)
            raise
    print("Updated precompiled resources: " + ", ".join(stale))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("check", "update"))
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--minimum-system-version", default=os.environ.get("MINIMUM_SYSTEM_VERSION", "14.0"))
    parser.add_argument("--force", action="store_true", help="update both resources even if unchanged")
    arguments = parser.parse_args()
    if not re.fullmatch(r"\d+\.\d+(?:\.\d+)?", arguments.minimum_system_version):
        parser.error("minimum system version must be numeric, e.g. 14.0")
    root = arguments.root.resolve()
    cache = root / "Resources/Precompiled"
    configs = configurations(arguments.minimum_system_version)
    try:
        try:
            manifest = load_manifest(cache)
        except ResourceError:
            if arguments.command != "update":
                raise
            manifest = {"schema": 1, "resources": {}}
        source_inputs = {name: inputs(root, name) for name in ARTIFACTS}
        stale = {name: reason for name in ARTIFACTS
                 if (reason := stale_reason(cache, manifest["resources"].get(name), name,
                                            source_inputs[name], configs[name]))}
        if arguments.command == "check":
            if stale:
                raise ResourceError("; ".join(f"{name}: {reason}" for name, reason in stale.items()))
            print("Precompiled resources match sources, target and SHA-256.")
        elif stale or arguments.force:
            update(root, cache, manifest, source_inputs, configs,
                   list(ARTIFACTS) if arguments.force else list(stale))
        else:
            print("Precompiled resources unchanged; no compiler needed.")
        return 0
    except (ResourceError, OSError) as error:
        print(f"error: {error}\n"
              "Refresh with an installed resource toolchain (does not install tools or switch xcode-select):\n"
              "  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer python3 scripts/precompile-resources.py "
              f"update --minimum-system-version {arguments.minimum_system_version}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
