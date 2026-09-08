#!/usr/bin/env python3
"""Configure GitHub Linux release signing, retaining the private key on this machine."""
import argparse
import base64
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def gh(*args, **kwargs):
    return subprocess.run(["gh", *args], check=True, capture_output=True, text=True, **kwargs).stdout.strip()


def setup(repository, key):
    info = json.loads(gh("repo", "view", repository, "--json", "visibility,nameWithOwner"))
    if info["visibility"] != "PUBLIC":
        raise ValueError("Make the release repository public before configuring unauthenticated downloads.")
    repository = info["nameWithOwner"]
    variables = json.loads(gh("variable", "list", "--repo", repository, "--json", "name,value"))
    existing = next((item["value"] for item in variables if item["name"] == "LINUX_PUBLIC_ED_KEY"), None)
    key = key.expanduser().absolute()
    if key.resolve().is_relative_to(ROOT):
        raise ValueError("Store the private signing key outside the repository.")
    if key.is_symlink():
        raise ValueError("The signing-key path must be a regular file, not a symlink.")
    if not key.exists():
        secrets = json.loads(gh("secret", "list", "--repo", repository, "--json", "name"))
        if existing or any(item["name"] == "LINUX_PRIVATE_ED_KEY" for item in secrets):
            raise ValueError("GitHub already has a Linux signing key. Restore its original private key and pass --key; generating a replacement would break updates.")
        key.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        subprocess.run(["python3", str(ROOT / "Scripts/generate-linux-update-key.py"), str(key)], check=True, capture_output=True)
    if key.stat().st_mode & 0o077 or key.stat().st_uid != os.getuid():
        raise ValueError("The private key must be owned by you with mode 600 (chmod 600 KEY_FILE).")
    encoded = key.read_text().strip()
    seed = base64.b64decode(encoded, validate=True)
    if len(seed) != 32:
        raise ValueError("The Linux private key must contain a base64-encoded 32-byte Ed25519 seed.")
    with tempfile.TemporaryDirectory(prefix="freemind-signing-") as temporary:
        der = Path(temporary) / "private.der"
        der.write_bytes(bytes.fromhex("302e020100300506032b657004220420") + seed)
        der.chmod(0o600)
        public = subprocess.run(["openssl", "pkey", "-inform", "DER", "-in", str(der), "-pubout", "-outform", "DER"], capture_output=True, check=True).stdout[-32:]
    public = base64.b64encode(public).decode()
    if existing and existing != public:
        raise ValueError("GitHub uses a different public key. Restore the original private key instead of replacing it.")
    gh("secret", "set", "LINUX_PRIVATE_ED_KEY", "--repo", repository, input=encoded)
    gh("variable", "set", "LINUX_PUBLIC_ED_KEY", "--repo", repository, "--body", public)
    print(f"Linux signing configured for {repository}. Keep a secure backup of {key}.")
    print("Push the source changes and a new vMAJOR.MINOR.PATCH tag to build and publish install.sh and both Linux architectures.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("repository", help="GitHub owner/repository")
    parser.add_argument("--key", type=Path, default=Path.home() / ".local/share/freemind-release/linux-ed25519.key")
    args = parser.parse_args()
    try:
        setup(args.repository, args.key)
    except subprocess.CalledProcessError as error:
        parser.exit(1, "GitHub/signing command failed: " + (error.stderr.decode() if isinstance(error.stderr, bytes) else error.stderr or str(error)) + "\n")
    except (ValueError, OSError) as error:
        parser.exit(1, str(error) + "\n")
