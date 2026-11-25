"""Register the built Tracker Chrome helper for the current macOS user.

Tracker.app does this on launch. Use this script only to register a helper by hand.
"""

import argparse
import json
import os
import re
import sys
import tempfile
from pathlib import Path

HOST_NAME = "com.domenicodidonna.tracker.chrome"
# Fixed by the "key" in extension/manifest.json.
EXTENSION_ID = "lkckmlojgpfflmkhkaapcijpjehdmobo"


# Keep in step with TrackerChromeWire.browsers.
BROWSER_FOLDERS = ["Google/Chrome", "Google/Chrome Beta", "Google/Chrome Dev", "Google/Chrome Canary",
                   "Microsoft Edge", "Microsoft Edge Beta", "BraveSoftware/Brave-Browser",
                   "BraveSoftware/Brave-Browser-Beta", "Arc/User Data", "Vivaldi", "Chromium"]


def manifest_path(home, folder="Google/Chrome"):
    return home / "Library/Application Support" / folder / "NativeMessagingHosts" / f"{HOST_NAME}.json"


def installed_browsers(home):
    return [folder for folder in BROWSER_FOLDERS if (home / "Library/Application Support" / folder).is_dir()]


def registration(extension_id, executable):
    if not re.fullmatch(r"[a-p]{32}", extension_id):
        raise ValueError("Copy the exact 32-character extension ID from chrome://extensions.")
    executable = executable.expanduser().resolve(strict=True)
    if executable.name != "TrackerChromeHost" or not executable.is_file() or not os.access(executable, os.X_OK):
        raise ValueError("Choose the built TrackerChromeHost executable from Tracker.app/Contents/MacOS.")
    return {
        "name": HOST_NAME,
        "description": "Tracker local Chrome tab bridge",
        "path": str(executable),
        "type": "stdio",
        "allowed_origins": [f"chrome-extension://{extension_id}/"],
    }


def install(home, extension_id, executable, folder="Google/Chrome"):
    manifest = registration(extension_id, executable)
    target = manifest_path(home, folder)
    target.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode="w", dir=target.parent, encoding="utf-8", delete=False) as contents:
        temporary = Path(contents.name)
        try:
            json.dump(manifest, contents, indent=2)
            contents.write("\n")
            contents.close()
            temporary.replace(target)
        finally:
            temporary.unlink(missing_ok=True)
    return target


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="action", required=True)
    add = commands.add_parser("install")
    add.add_argument("executable", type=Path)
    add.add_argument("--extension-id", default=EXTENSION_ID,
                     help="Only for a copy of the extension without the manifest key.")
    commands.add_parser("remove")
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("This build supports Chromium browsers on macOS.")
    try:
        folders = installed_browsers(Path.home())
        if not folders:
            parser.error("No supported Chromium browser is installed for this user.")
        for folder in folders:
            if args.action == "install":
                print(install(Path.home(), args.extension_id, args.executable, folder))
            else:
                target = manifest_path(Path.home(), folder)
                target.unlink(missing_ok=True)
                print(f"Removed {target}")
    except (OSError, ValueError) as error:
        parser.error(str(error))


if __name__ == "__main__":
    main()
