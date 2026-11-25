"""Collect the licenses of the modules linked into Gridnote's desktop account client."""
import shutil
import subprocess
import sys
from pathlib import Path


def collect(folder):
    module = Path(__file__).resolve().parents[1] / "Desktop"
    folder.mkdir(parents=True, exist_ok=True)
    goroot = subprocess.check_output(["go", "env", "GOROOT"], text=True).strip()
    shutil.copyfile(Path(goroot) / "LICENSE", folder / "Go-LICENSE")
    linked = subprocess.check_output(
        ["go", "list", "-deps", "-f", "{{with .Module}}{{if not .Main}}{{.Path}} {{.Dir}}{{end}}{{end}}", "./chatgpt"],
        cwd=module, text=True,
    )
    for entry in sorted(set(linked.splitlines()) - {""}):
        name, path = entry.split(" ", 1)
        license_file = next(p for p in Path(path).glob("LICENSE*") if p.is_file())
        shutil.copyfile(license_file, folder / (name.replace("/", "-") + "-LICENSE"))
        for notice in Path(path).glob("NOTICE*"):
            if notice.is_file():
                shutil.copyfile(notice, folder / (name.replace("/", "-") + "-" + notice.name))


if __name__ == "__main__":
    collect(Path(sys.argv[1]))
