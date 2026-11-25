import json
import os
from pathlib import Path
import select
import socket
import struct
import subprocess
import tempfile
import time
import unittest
from uuid import UUID, uuid4
import sys

INTEGRATION = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(INTEGRATION))
import register


def read_frame(stream):
    if not select.select([stream], [], [], 5)[0]:
        raise TimeoutError("No native message")
    prefix = stream.read(4)
    return json.loads(stream.read(struct.unpack("=I", prefix)[0]))


def write_frame(stream, message):
    encoded = json.dumps(message).encode()
    stream.write(struct.pack("=I", len(encoded)) + encoded)
    stream.flush()


@unittest.skipUnless(sys.platform == "darwin", "Native bridge supports macOS")
class BridgeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.scratch = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.scratch.cleanup)
        cls.harness = str(Path(cls.scratch.name) / "bridge")
        subprocess.run(
            ["xcrun", "swiftc", "-parse-as-library", "TrackerChromeWire.swift", "TrackerChromeHost.swift",
             "TrackerChromeClient.swift", "tests/bridge_harness.swift", "-o", cls.harness],
            cwd=INTEGRATION, check=True, capture_output=True,
        )

    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix="tr.")
        self.addCleanup(directory.cleanup)
        self.directory = Path(directory.name)

    def host(self, allow="allow"):
        proc = subprocess.Popen(
            [self.harness, "host", str(self.directory), allow],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        )
        self.addCleanup(proc.__exit__, None, None, None)
        self.addCleanup(lambda: proc.stdin.close())
        self.addCleanup(lambda: proc.kill() if proc.poll() is None else None)
        until = time.monotonic() + 3
        while not any(self.directory.iterdir()) and proc.poll() is None and time.monotonic() < until:
            time.sleep(.01)
        self.assertEqual(len(list(self.directory.iterdir())), 1, "Native host did not create its socket")
        return proc

    def sample(self):
        return subprocess.Popen([self.harness, "sample", str(self.directory)], stdout=subprocess.PIPE)

    def test_registration_uses_one_exact_origin_and_correct_executable(self):
        extension = "abcdefghijklmnop" * 2
        executable = self.directory / "path with spaces" / "TrackerChromeHost"
        executable.parent.mkdir()
        executable.touch(mode=0o700)
        manifest = register.install(self.directory, extension, executable)
        values = json.loads(manifest.read_text())
        self.assertEqual(values["path"], str(executable.resolve()))
        self.assertEqual(values["allowed_origins"], [f"chrome-extension://{extension}/"])
        self.assertEqual(manifest.stat().st_mode & 0o777, 0o600)
        for origin, allowed in [
            (f"chrome-extension://{extension}", True),
            (f"chrome-extension://{extension}/", True),
            (f"chrome-extension://{extension}/bad", False),
            ("chrome-extension://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/", False),
        ]:
            with self.subTest(origin=origin):
                result = subprocess.run([self.harness, "allows", str(manifest), origin])
                self.assertEqual(result.returncode, 0 if allowed else 1)

    def test_native_host_relays_only_requested_validated_tab(self):
        host = self.host()
        self.assertFalse(select.select([host.stdout], [], [], .05)[0])
        with self.sample() as client:
            request = read_frame(host.stdout)
            self.assertEqual(request["type"], "snapshot")
            UUID(request["id"])
            reply = {"version": 1, "id": request["id"], "status": "tab",
                     "url": "https://example.org/client", "profile": "Work"}
            write_frame(host.stdin, {**reply, "id": str(uuid4())})
            write_frame(host.stdin, {**reply, "url": reply["url"] + "?token=private"})
            write_frame(host.stdin, {**reply, "url": reply["url"] + "/someone%40example.org"})
            write_frame(host.stdin, {**reply, "profile": "Work\n"})
            time.sleep(0.35)
            write_frame(host.stdin, reply)
            result, _ = client.communicate(timeout=3)
            self.assertEqual(json.loads(result), reply)

    def test_expired_snapshot_cannot_be_reused(self):
        host = self.host()
        with self.sample() as first:
            expired = read_frame(host.stdout)
            self.assertEqual(first.communicate(timeout=3)[0], b"")
        write_frame(host.stdin, {"version": 1, "id": expired["id"], "status": "tab",
                                 "url": "https://example.org/previous-page"})
        with self.sample() as second:
            request = read_frame(host.stdout)
            self.assertNotEqual(request["id"], expired["id"])
            write_frame(host.stdin, {"version": 1, "id": request["id"], "status": "tab",
                                     "url": "https://example.org/current-page"})
            self.assertEqual(json.loads(second.communicate(timeout=3)[0])["url"], "https://example.org/current-page")

    def test_removed_registration_cannot_request_from_chrome(self):
        host = self.host(allow="revoked")
        with self.sample() as client:
            self.assertEqual(client.communicate(timeout=3)[0], b"")
        self.assertEqual(host.wait(timeout=3), 0)
        self.assertEqual(host.stdout.read(), b"")


class ExtensionIdentityTests(unittest.TestCase):
    def test_manifest_key_gives_the_registered_extension_id(self):
        import base64
        import hashlib
        manifest = json.loads((INTEGRATION / "extension/manifest.json").read_text())
        digest = hashlib.sha256(base64.b64decode(manifest["key"])).hexdigest()[:32]
        derived = "".join(chr(ord("a") + int(c, 16)) for c in digest)
        self.assertEqual(derived, register.EXTENSION_ID)
        wire = (INTEGRATION / "TrackerChromeWire.swift").read_text()
        self.assertIn(f'static let extensionID = "{derived}"', wire)
        for folder in register.BROWSER_FOLDERS:
            self.assertIn(f'folder: "{folder}"', wire)
