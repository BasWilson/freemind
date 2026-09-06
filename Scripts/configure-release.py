#!/usr/bin/env python3
"""Validate release inputs and stamp a built app without editing source metadata."""

import argparse
import base64
import binascii
import os
from pathlib import Path
import platform
import plistlib
import re


def configure(info, environment, architecture):
    info = dict(info)
    version = environment.get("FREEMIND_RELEASE_VERSION", "")
    repository = environment.get("FREEMIND_UPDATE_REPOSITORY", "")
    public_key = environment.get("SPARKLE_PUBLIC_ED_KEY", "")
    if version:
        if not re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", version):
            raise ValueError("FREEMIND_RELEASE_VERSION must be a stable version such as 0.1.0")
        # Sparkle compares CFBundleVersion, so use the tag's version on every
        # runner instead of the local build counter or a workflow run number.
        info["CFBundleShortVersionString"] = version
        info["CFBundleVersion"] = version
    info.pop("SUFeedURL", None)
    info.pop("SUPublicEDKey", None)
    if repository or public_key:
        if not version or not repository or not public_key:
            raise ValueError("Updates require FREEMIND_RELEASE_VERSION, FREEMIND_UPDATE_REPOSITORY and SPARKLE_PUBLIC_ED_KEY together")
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9_.-]+", repository) or repository.split("/")[1] in (".", ".."):
            raise ValueError("FREEMIND_UPDATE_REPOSITORY must be a GitHub owner/repo")
        try:
            decoded_key = base64.b64decode(public_key, validate=True)
        except (ValueError, binascii.Error) as error:
            raise ValueError("SPARKLE_PUBLIC_ED_KEY must be a base64 Ed25519 public key") from error
        if len(decoded_key) != 32:
            raise ValueError("SPARKLE_PUBLIC_ED_KEY must decode to 32 bytes")
        if architecture not in ("arm64", "x86_64"):
            raise ValueError(f"Unsupported release architecture: {architecture}")
        info["SUFeedURL"] = f"https://github.com/{repository}/releases/latest/download/appcast-{architecture}.xml"
        info["SUPublicEDKey"] = public_key
    return info


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("plist", type=Path, nargs="?", default=Path("Resources/Info.plist"))
    parser.add_argument("--check", action="store_true", help="Validate without writing")
    args = parser.parse_args()
    try:
        info = configure(plistlib.loads(args.plist.read_bytes()), os.environ, platform.machine())
    except ValueError as error:
        parser.error(str(error))
    if not args.check:
        args.plist.write_bytes(plistlib.dumps(info, sort_keys=False))


if __name__ == "__main__":
    main()
