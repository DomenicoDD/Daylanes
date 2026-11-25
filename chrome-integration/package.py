"""Zip the extension for the Chrome Web Store.

The store assigns its own ID and refuses a manifest "key", so the zip leaves it out.
"""

import json
import sys
import zipfile
from pathlib import Path

SOURCE = Path(__file__).resolve().parent / "extension"


def package(target):
    manifest = json.loads((SOURCE / "manifest.json").read_text())
    manifest.pop("key", None)
    with zipfile.ZipFile(target, "w", zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("manifest.json", json.dumps(manifest, indent=2) + "\n")
        for path in sorted(SOURCE.iterdir()):
            if path.is_file() and path.name != "manifest.json" and not path.name.startswith("."):
                archive.write(path, path.name)
    return target


if __name__ == "__main__":
    version = json.loads((SOURCE / "manifest.json").read_text())["version"]
    default = Path.cwd() / f"daylanes-extension-{version}.zip"
    print(package(Path(sys.argv[1]) if len(sys.argv) > 1 else default))
