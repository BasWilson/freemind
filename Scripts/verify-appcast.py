#!/usr/bin/env python3
"""Check that a release feed describes the exact app archive being uploaded."""

import base64
import os
from pathlib import Path
import platform
import plistlib
import sys
import xml.etree.ElementTree as ET
import zipfile


def verify(feed, archive, version, repository, public_key, architecture):
    sparkle = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
    items = ET.parse(feed).findall("./channel/item")
    if len(items) != 1:
        raise ValueError("Expected exactly one release in the generated feed")
    item = items[0]
    enclosure = item.find("enclosure")
    expected_url = f"https://github.com/{repository}/releases/download/v{version}/{archive.name}"
    if enclosure is None or enclosure.get("url") != expected_url:
        raise ValueError("Feed download URL does not match this release archive")
    if int(enclosure.get("length", "0")) != archive.stat().st_size:
        raise ValueError("Feed download length does not match the archive")
    if len(base64.b64decode(enclosure.get(sparkle + "edSignature", ""), validate=True)) != 64:
        raise ValueError("Feed has no valid Ed25519 archive signature")
    if item.findtext(sparkle + "version") != version:
        raise ValueError("Feed version does not match the release tag")
    with zipfile.ZipFile(archive) as zipped:
        info = plistlib.loads(zipped.read("Freemind.app/Contents/Info.plist"))
    expected = {
        "CFBundleVersion": version,
        "CFBundleShortVersionString": version,
        "SUFeedURL": f"https://github.com/{repository}/releases/latest/download/appcast-{architecture}.xml",
        "SUPublicEDKey": public_key,
        "SUVerifyUpdateBeforeExtraction": True,
        "SURequireSignedFeed": True,
    }
    if any(info.get(key) != value for key, value in expected.items()):
        raise ValueError("Archive update configuration does not match this release")
    if item.findtext(sparkle + "minimumSystemVersion") != info["LSMinimumSystemVersion"]:
        raise ValueError("Feed minimum macOS version does not match the app")


if __name__ == "__main__":
    verify(Path(sys.argv[1]), Path(sys.argv[2]), os.environ["FREEMIND_RELEASE_VERSION"],
           os.environ["FREEMIND_UPDATE_REPOSITORY"], os.environ["SPARKLE_PUBLIC_ED_KEY"], platform.machine())
