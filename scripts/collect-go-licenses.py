#!/usr/bin/env python3
"""Collect license files for the Go modules used by the macOS command."""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path


DEFAULT_PACKAGE = "./cmd/dj4ghub-macos"
LICENSE_NAME_RE = re.compile(
    r"^(license|licence|copying|notice|copyright)"
    r"(?:$|[-_][A-Za-z0-9._+-]+$|\.(?:txt|md|markdown|rst|html)$)",
    re.IGNORECASE,
)
SKIP_DIR_NAMES = {
    ".git",
    ".hg",
    ".svn",
    ".idea",
    ".vscode",
    "__pycache__",
    "node_modules",
    "vendor",
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Copy LICENSE/NOTICE/COPYING/COPYRIGHT files for the actual Go "
            "module dependencies of ./cmd/dj4ghub-macos."
        )
    )
    parser.add_argument("output_dir", help="directory to receive collected license files")
    parser.add_argument(
        "--package",
        default=DEFAULT_PACKAGE,
        help=f"Go package to inspect with go list -deps (default: {DEFAULT_PACKAGE})",
    )
    parser.add_argument(
        "--manifest",
        default="GO-LICENSES.txt",
        help="manifest filename written inside output_dir (default: GO-LICENSES.txt)",
    )
    return parser.parse_args()


def run_go_list(package: str) -> list[dict[str, object]]:
    fmt = (
        "{{if .Module}}"
        "{{.Module.Path}}\t{{.Module.Version}}\t{{.Module.Dir}}\t{{.Module.Main}}"
        "\t{{with .Module.Replace}}{{.Path}}\t{{.Version}}\t{{.Dir}}{{end}}"
        "{{end}}"
    )
    proc = subprocess.run(
        ["go", "list", "-deps", "-f", fmt, package],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    modules: list[dict[str, object]] = []
    seen_paths: set[str] = set()
    for line in proc.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        parts = line.split("\t")
        parts.extend([""] * (7 - len(parts)))
        path, version, directory, main, replace_path, replace_version, replace_dir = parts[:7]
        if not path or not directory or main == "true":
            continue
        if path in seen_paths:
            continue
        seen_paths.add(path)
        replacement = None
        if replace_path:
            replacement = {
                "Path": replace_path,
                "Version": replace_version,
                "Dir": replace_dir,
            }
        module = {
            "Path": path,
            "Version": version,
            "Dir": directory,
            "Replace": replacement,
        }
        modules.append(module)
    modules.sort(key=lambda item: str(item["Path"]))
    return modules


def safe_component_name(module_path: str) -> str:
    safe = module_path.replace("/", "__")
    return re.sub(r"[^A-Za-z0-9._+-]+", "_", safe)


def is_license_file(path: Path) -> bool:
    return path.is_file() and LICENSE_NAME_RE.match(path.name) is not None


def find_license_files(module_dir: Path) -> list[Path]:
    license_files: list[Path] = []
    for root, dirs, files in os.walk(module_dir):
        dirs[:] = sorted(
            name
            for name in dirs
            if name not in SKIP_DIR_NAMES and not name.startswith(".")
        )
        root_path = Path(root)
        for filename in sorted(files):
            candidate = root_path / filename
            if is_license_file(candidate):
                license_files.append(candidate)
    return license_files


def copy_license_files(output_dir: Path, modules: list[dict[str, object]]) -> list[dict[str, object]]:
    manifest: list[dict[str, object]] = []
    for module in modules:
        module_path = str(module["Path"])
        module_dir = Path(str(module["Dir"]))
        license_files = find_license_files(module_dir)
        copied_files: list[str] = []
        component_dir = output_dir / safe_component_name(module_path)
        for source in license_files:
            relative = source.relative_to(module_dir)
            destination = component_dir / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, destination)
            copied_files.append(relative.as_posix())
        manifest.append(
            {
                "module": module_path,
                "version": str(module.get("Version") or ""),
                "replace": module.get("Replace"),
                "license_files": copied_files,
            }
        )
    return manifest


def format_source(module: dict[str, object]) -> str:
    replacement = module.get("replace")
    if isinstance(replacement, dict):
        path = replacement.get("Path")
        version = replacement.get("Version")
        if path and version:
            return f"replace {path} {version}"
        if path:
            return f"replace {path}"
    version = str(module.get("version") or "")
    return version or "(local replace)"


def write_manifest(
    output_dir: Path, manifest_name: str, package: str, entries: list[dict[str, object]]
) -> None:
    manifest_path = output_dir / manifest_name
    lines = [
        "Go dependency license files",
        "",
        f"Package: {package}",
        "",
    ]
    modules_with_license = 0
    license_count = 0
    for entry in entries:
        files = list(entry["license_files"])
        if files:
            modules_with_license += 1
            license_count += len(files)
        lines.append(str(entry["module"]))
        lines.append(f"  Source: {format_source(entry)}")
        if files:
            lines.append("  License files:")
            component = safe_component_name(str(entry["module"]))
            for filename in files:
                lines.append(f"    - {component}/{filename}")
        else:
            lines.append("  License files: none found")
        lines.append("")
    lines.append(f"Modules inspected: {len(entries)}")
    lines.append(f"Modules with license files: {modules_with_license}")
    lines.append(f"License files copied: {license_count}")
    manifest_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> int:
    args = parse_args()
    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    modules = run_go_list(args.package)
    manifest = copy_license_files(output_dir, modules)
    write_manifest(output_dir, args.manifest, args.package, manifest)
    copied = sum(len(entry["license_files"]) for entry in manifest)
    with_license = sum(1 for entry in manifest if entry["license_files"])
    print(
        f"Collected {copied} license files for {with_license}/{len(manifest)} "
        f"Go modules into {output_dir}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
