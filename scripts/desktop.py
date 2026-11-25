#!/usr/bin/env python3
"""Build a self-contained desktop launcher from the prepared standalone site."""
import argparse
import os
import platform
from pathlib import Path
import shutil
import subprocess
import tempfile
import zipfile

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("site", type=Path)
parser.add_argument("destination", type=Path)
parser.add_argument("--os", choices=["windows", "linux", "darwin"], required=True)
parser.add_argument("--arch", choices=["amd64", "arm64","host"], required=True)
args = parser.parse_args()
if args.arch=="host":
    args.arch="arm64" if platform.machine().lower() in ("arm64","aarch64") else "amd64"
if not (args.site / "sw.js").is_file():
    parser.error("Build the offline site first.")
args.destination.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory() as tmp:
    project = Path(tmp)
    shutil.copytree(args.site, project / "site")
    shutil.copy(root / "Desktop" / "main.go", project)
    name = "Gridnote" + (".exe" if args.os == "windows" else "")
    env = dict(os.environ, GOOS=args.os, GOARCH=args.arch, CGO_ENABLED="0")
    subprocess.run(["go", "build", "-trimpath", "-ldflags=-s -w", "-o", name, "main.go"],
                   cwd=project, env=env, check=True)
    target = args.destination / f"Gridnote-{args.os}-{args.arch}.zip"
    with zipfile.ZipFile(target, "w", zipfile.ZIP_DEFLATED) as archive:
        archive.write(project / name, name)
        archive.write(root / "LICENSE", "LICENSE")
        toolchain = Path(subprocess.check_output(["go", "env", "GOROOT"], text=True).strip())
        archive.write(toolchain / "LICENSE", "licenses/Go-LICENSE")
        for notice in sorted((args.site / "vendor").rglob("*")):
            if notice.is_file() and ("LICENSE" in notice.name.upper() or "NOTICE" in notice.name.upper()):
                archive.write(notice, "licenses/" + notice.relative_to(args.site / "vendor").as_posix())
    print(target)
