"""Exercise the packaged desktop launcher on the CI runner's own OS and architecture."""
from pathlib import Path
import os
import platform
import subprocess
import tempfile
import time
from urllib.request import urlopen
from zipfile import ZipFile

root = Path(__file__).resolve().parents[1]
target = {"Darwin": "darwin", "Windows": "windows", "Linux": "linux"}[platform.system()]
arch = "arm64" if platform.machine().lower() in ("aarch64", "arm64") else "amd64"
archive = root / "build" / "releases" / f"Gridnote-{target}-{arch}.zip"
address = "http://127.0.0.1:48765/"
with tempfile.TemporaryDirectory() as scratch:
    with ZipFile(archive) as bundle:
        name = "Gridnote.exe" if target == "windows" else "Gridnote"
        binary = Path(bundle.extract(name, scratch))
        binary.chmod(0o755)
    with subprocess.Popen([str(binary), "--no-open"]) as app:
        try:
            for attempt in range(60):
                if app.poll() is not None:
                    raise RuntimeError("The isolated test launcher exited before its notebook opened")
                try:
                    with urlopen(address + "_gridnote", timeout=1) as response:
                        if response.read() == b"Gridnote standalone v1":
                            break
                except OSError:
                    time.sleep(0.1)
            else:
                raise RuntimeError("The packaged notebook did not respond")
            env = dict(os.environ, GRIDNOTE_URL=address)
            tests = ["browser.cjs", "major-tools.cjs", "themes.cjs"]
            if env.get("ENGINE") == "webkit":
                tests.extend(["ipad.cjs", "organizer.cjs"])
            elif env.get("ENGINE", "chromium") == "chromium":
                tests.append("mobile.cjs")
            for test in tests:
                print(f"Testing {test}", flush=True)
                subprocess.run(["node", str(root / "Tests" / test)], cwd=root, env=env,
                               check=True, timeout=240)
        finally:
            app.terminate()
