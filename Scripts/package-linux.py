#!/usr/bin/env python3
"""Package native Linux binaries and Swift runtime; sign a bounded update manifest.

System dependencies remain GTK4 >= 4.14, VTE GTK4, GtkSourceView 5, tmux,
Git, Python >= 3.11 and OpenSSL >= 3. Build in the documented Ubuntu 24.04
container to keep the glibc baseline stable.
"""
import base64
import hashlib
import gzip
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("linux_update", ROOT / "Linux/Support/update.py")
update = importlib.util.module_from_spec(spec); spec.loader.exec_module(update)


def package(binary_folder, output, environment):
    number = environment["FREEMIND_RELEASE_VERSION"]; update.version(number)
    public = environment["LINUX_PUBLIC_ED_KEY"]
    seed = base64.b64decode(environment["LINUX_PRIVATE_ED_KEY"], validate=True)
    if len(seed) != 32 or len(base64.b64decode(public, validate=True)) != 32:
        raise ValueError("Linux Ed25519 keys must be base64-encoded 32-byte keys.")
    config = {"schemaVersion": 1, "version": number, "architecture": update.architecture(), "repository": environment["FREEMIND_UPDATE_REPOSITORY"], "publicKey": public}
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="freemind-package-") as temporary:
        folder = Path(temporary); app = folder / "app"; app.mkdir()
        (app / "release.json").write_text(json.dumps(config, indent=2) + "\n")
        update.configuration(app)
        for name in ("freemind-linux", "freemind-helper"):
            shutil.copy2(binary_folder / name, app / name)
        shutil.copy2(ROOT / "Linux/Support/update.py", app / "update.py")
        shutil.copy2(ROOT / "Linux/Support/integrate.py", app / "integrate.py")
        shutil.copy2(ROOT / "Linux/Support/launch", app / "launch"); (app / "launch").chmod(0o755)
        shutil.copy2(ROOT / "Scripts/install-linux.sh", app / "install.sh")
        shutil.copy2(ROOT / "Linux/Support/dev.freemind.Linux.svg", app / "dev.freemind.Linux.svg")
        shutil.copytree(ROOT / "Resources/licenses", app / "licenses")
        (app / "lib").mkdir()
        libraries = set()
        for binary in (app / "freemind-linux", app / "freemind-helper"):
            listing = subprocess.run(["ldd", str(binary)], capture_output=True, text=True, check=True).stdout
            if "not found" in listing: raise ValueError("Missing runtime library: " + listing)
            for name, path in re.findall(r"\s*(\S+) => (/\S+)", listing):
                if name.startswith(("libswift", "libFoundation", "lib_Foundation", "libicu")) or "/swift/" in path or "/swiftly/" in path:
                    libraries.add((name, path))
        for name, path in libraries: shutil.copy2(path, app / "lib" / name)
        archive_name = f"Freemind-{number}-Linux-{config['architecture']}.tar.gz"
        archive = output / archive_name
        epoch = int(environment.get("SOURCE_DATE_EPOCH", "0"))
        def normalized(info):
            info.uid = info.gid = 0; info.uname = info.gname = ""; info.mtime = epoch
            return info
        # All archive entries are regular files or directories; dereference libs.
        with archive.open("wb") as stream, gzip.GzipFile(filename="", mode="wb", fileobj=stream, mtime=epoch) as compressed, tarfile.open(fileobj=compressed, mode="w", dereference=True) as tar:
            for item in sorted(app.iterdir()): tar.add(item, arcname=item.name, filter=normalized)
        data = {"schemaVersion": 1, "version": number, "architecture": config["architecture"], "archive": archive_name, "size": archive.stat().st_size, "sha256": hashlib.file_digest(archive.open("rb"), "sha256").hexdigest()}
        payload = (json.dumps(data, sort_keys=True, separators=(",", ":")) + "\n").encode()
        feed = output / f"linux-{config['architecture']}.json"; feed.write_bytes(payload)
        key = folder / "private.der"; key.write_bytes(bytes.fromhex("302e020100300506032b657004220420") + seed); key.chmod(0o600)
        signature = feed.with_suffix(".json.sig")
        subprocess.run(["openssl", "pkeyutl", "-sign", "-rawin", "-keyform", "DER", "-inkey", str(key), "-in", str(feed), "-out", str(signature)], check=True, capture_output=True)
        update.manifest(payload, signature.read_bytes(), config)
        (output / (archive_name + ".sha256")).write_text(f"{data['sha256']}  {archive_name}\n")
        return archive


if __name__ == "__main__":
    if len(sys.argv) != 2: raise SystemExit("Usage: python3 Scripts/package-linux.py BINARY_FOLDER")
    print(package(Path(sys.argv[1]), ROOT / "dist", os.environ))
