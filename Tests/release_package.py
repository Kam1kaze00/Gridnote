"""Start the release ZIP for this runner's OS and CPU architecture."""
from pathlib import Path
from tempfile import TemporaryDirectory
from urllib.request import urlopen
from zipfile import ZipFile
import platform
import subprocess
import sys
import time


def check_mac(packages, folder, machine):
    arch = "arm64" if machine == "arm64" else "x86_64"
    subprocess.run(["ditto", "-x", "-k", packages / f"Gridnote-macOS-{arch}.zip", folder], check=True)
    app = folder / "Gridnote.app"
    assert (folder / "Open Gridnote on Mac.txt").is_file()
    subprocess.run(["codesign", "--verify", "--strict", app], check=True)
    binary = app / "Contents/MacOS/Gridnote"
    subprocess.run(["lipo", binary, "-verify_arch", arch], check=True)
    with subprocess.Popen([binary]) as started:
        try:
            # Inspect the window geometry without opening or writing a notebook.
            source = """
import CoreGraphics
import Foundation
let pid = Int(CommandLine.arguments[1])!
for _ in 0..<80 {
  let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
  if rows.contains(where: { row in
    guard row[kCGWindowOwnerPID as String] as? Int == pid, row[kCGWindowLayer as String] as? Int == 0,
      let bounds = row[kCGWindowBounds as String] as? [String: Double] else { return false }
    return bounds["Width"] == 640 && (bounds["Height"] ?? 0) >= 540
  }) { exit(0) }
  Thread.sleep(forTimeInterval: 0.15)
}
exit(1)
"""
            probe = folder / "window.swift"
            probe.write_text(source)
            subprocess.run(["swift", probe, str(started.pid)], check=True, timeout=90)
        finally:
            started.terminate()


def check_desktop(packages, folder, system, machine):
    arch = "arm64" if machine in ("arm64", "aarch64") else "amd64"
    filename = "Gridnote.exe" if system == "windows" else "Gridnote"
    with ZipFile(packages / f"Gridnote-{system}-{arch}.zip") as archive:
        app = Path(archive.extract(filename, folder))
    app.chmod(0o755)
    with subprocess.Popen([app, "--no-open"]) as started:
        try:
            origin = "http://127.0.0.1:48765/"
            for _ in range(80):
                if started.poll() is not None:
                    raise RuntimeError("Desktop launcher exited during startup")
                try:
                    with urlopen(origin + "_gridnote", timeout=1) as page:
                        assert page.read() == b"Gridnote standalone v1"
                    break
                except OSError:
                    time.sleep(0.15)
            else:
                raise RuntimeError("Desktop launcher did not start")
            for path, marker in [("", b'id="welcome"'), ("launcher.js", b"Continue notebook"),
                                 ("majors.js", b"Binary search"), ("assets/default-cover.svg", b"Gridnote"),
                                 ("assets/pixel-tools.svg", b"symbol"), ("assets/pixelifysans.ttf", b"\x00\x01\x00\x00")]:
                with urlopen(origin + path, timeout=5) as response:
                    assert marker in response.read(), path
        finally:
            started.terminate()


if __name__ == "__main__":
    packages = Path(sys.argv[1]).resolve()
    system, machine = platform.system().lower(), platform.machine().lower()
    with TemporaryDirectory() as directory:
        if system == "darwin":
            check_mac(packages, Path(directory), machine)
        else:
            check_desktop(packages, Path(directory), system, machine)
    print(f"Opened the public download candidate on {system} {machine}")
