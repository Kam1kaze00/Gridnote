#!/usr/bin/env python3
"""Package a committed revision of Gridnote on macOS with Go and Command Line Tools."""
import argparse
import hashlib
import os
import platform
import shutil
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path


def package(ref, destination):
    root = Path(__file__).resolve().parents[1]
    commit = subprocess.check_output(
        ["git", "rev-parse", "--verify", "--end-of-options", ref + "^{commit}"],
        cwd=root, text=True,
    ).strip()
    if platform.system() != "Darwin" or not shutil.which("go"):
        raise SystemExit("Packaging requires macOS, Go and the Command Line Tools.")
    destination.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=destination) as temporary:
        scratch = Path(temporary)
        archives = scratch / "archives"
        archives.mkdir()
        source = archives / "Gridnote-source.zip"
        subprocess.run(
            ["git", "archive", "--format=zip", "--prefix=Gridnote/", "-o", str(source), commit],
            check=True, cwd=root,
        )
        with zipfile.ZipFile(source) as archive:
            archive.extractall(scratch)
        checkout = scratch / "Gridnote"
        site = scratch / "site"
        subprocess.run([sys.executable, "scripts/prepare_web.py", str(site)], cwd=checkout, check=True)
        for arch in ("arm64", "x86_64"):
            folder = scratch / arch
            app = folder / "Gridnote.app"
            subprocess.run(["zsh", "build.sh", str(folder)], cwd=checkout, check=True,
                           env=dict(os.environ, GRIDNOTE_ARCH=arch))
            subprocess.run(["codesign", "--verify", "--strict", str(app)], check=True)
            subprocess.run(["lipo", "-verify_arch", arch, str(app / "Contents/MacOS/Gridnote")], check=True)
            shutil.copyfile(checkout / "docs/Open Gridnote on Mac.txt", folder / "Open Gridnote on Mac.txt")
            subprocess.run(["ditto", "-c", "-k", str(folder),
                            str(archives / f"Gridnote-macOS-{arch}.zip")], check=True)
        for system in ("windows", "linux"):
            for arch in ("amd64", "arm64"):
                subprocess.run([sys.executable, "scripts/desktop.py", str(site), str(archives),
                                "--os", system, "--arch", arch], cwd=checkout, check=True)
        with zipfile.ZipFile(archives / "Gridnote-standalone.zip", "w", zipfile.ZIP_DEFLATED) as portable:
            for file in sorted(site.rglob("*")):
                if file.is_file():
                    portable.write(file, "Gridnote/site/" + file.relative_to(site).as_posix())
            portable.write(checkout / "study_server.py", "Gridnote/study_server.py")
            portable.writestr("Gridnote/README.txt",
                              "Gridnote offline notebook\n\nIn this folder run python3 study_server.py --site site\n"
                              "Open http://127.0.0.1:8765 in your browser. On Windows you can use py instead of python3.\n"
                              "For HTTPS hosting, serve the contents of the site folder.\n")
        checksums = []
        for archive in sorted(archives.glob("*.zip")):
            with zipfile.ZipFile(archive) as bundle:
                if bundle.testzip():
                    raise ValueError(f"Damaged archive: {archive.name}")
            digest = hashlib.sha256(archive.read_bytes()).hexdigest()
            checksums.append(f"{digest}  {archive.name}\n")
        (archives / "SHA256SUMS.txt").write_bytes("".join(checksums).encode("ascii"))
        for file in archives.iterdir():
            file.replace(destination / file.name)
    print(f"Packaged {commit} in {destination}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("destination", type=Path)
    parser.add_argument("--ref", default="HEAD")
    args = parser.parse_args()
    package(args.ref, args.destination.resolve())
