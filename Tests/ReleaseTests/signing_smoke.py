#!/usr/bin/env python3
"""Exercise the real Sparkle signing tools with disposable keys and a built app."""

import json
import os
from pathlib import Path
import platform
import subprocess
import tempfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]


def run(arguments, **options):
    return subprocess.run(arguments, cwd=ROOT, check=True, **options)


def main():
    # Keys exist only in this process and its children's stdin/environment;
    # nothing is written to the login Keychain or the repository.
    generated = run([
        "swift", "-module-cache-path", str(ROOT / ".build/module-cache"), "-e",
        '''import CryptoKit
import Foundation
let key = Curve25519.Signing.PrivateKey()
let wrongKey = Curve25519.Signing.PrivateKey()
let data = try JSONSerialization.data(withJSONObject: [
    "private": key.rawRepresentation.base64EncodedString(),
    "public": key.publicKey.rawRepresentation.base64EncodedString(),
    "wrong": wrongKey.rawRepresentation.base64EncodedString()])
print(String(decoding: data, as: UTF8.self))''',
    ], capture_output=True, text=True)
    keys = json.loads(generated.stdout)
    environment = {**os.environ, "FREEMIND_RELEASE_VERSION": "0.0.0",
                   "FREEMIND_UPDATE_REPOSITORY": "example/FreemindSigningTest",
                   "SPARKLE_PUBLIC_ED_KEY": keys["public"], "SPARKLE_PRIVATE_ED_KEY": keys["private"]}
    architecture = platform.machine()
    signing_tool = str(ROOT / ".build/artifacts/sparkle/Sparkle/bin/sign_update")

    with tempfile.TemporaryDirectory(prefix="freemind-signing-test-") as temporary:
        directory = Path(temporary)
        app = directory / "Freemind.app"
        run(["ditto", str(ROOT / "dist/Freemind.app"), str(app)])
        run(["python3", "Scripts/configure-release.py", str(app / "Contents/Info.plist")], env=environment)
        run(["codesign", "--force", "--sign", "-", str(app)], capture_output=True)
        run(["codesign", "--verify", "--deep", "--strict", str(app)])
        archive = directory / f"Freemind-0.0.0-macOS-{architecture}-update.zip"
        run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(app), str(archive)])
        run(["bash", "Scripts/generate-appcast.sh", str(directory)], env=environment)
        feed = directory / f"appcast-{architecture}.xml"
        enclosure = ET.parse(feed).find("./channel/item/enclosure")
        signature = enclosure.get("{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature")
        run([signing_tool, "--ed-key-file", "-", "--verify", str(archive), signature],
            input=keys["private"], text=True, capture_output=True)

        tampered = directory / "tampered.zip"
        tampered.write_bytes(archive.read_bytes() + b"tampered")
        result = subprocess.run([signing_tool, "--ed-key-file", "-", "--verify", str(tampered), signature],
                                input=keys["private"], text=True, capture_output=True)
        if result.returncode == 0:
            raise RuntimeError("Sparkle accepted a tampered archive")
        tampered.unlink()

        feed.write_bytes(feed.read_bytes().replace(b"<title>", b"<title>Tampered ", 1))
        result = subprocess.run([signing_tool, "--ed-key-file", "-", "--verify", str(feed)],
                                input=keys["private"], text=True, capture_output=True)
        if result.returncode == 0:
            raise RuntimeError("Sparkle accepted a tampered feed")

        result = subprocess.run(["bash", "Scripts/generate-appcast.sh", str(directory)], cwd=ROOT,
                                env={**environment, "SPARKLE_PRIVATE_ED_KEY": keys["wrong"]}, capture_output=True, text=True)
        if result.returncode == 0:
            raise RuntimeError("The release pipeline accepted a mismatched signing key")
        print("Signing smoke test passed: signed feed/archive verified; tampering and mismatched keys rejected.")


if __name__ == "__main__":
    main()
