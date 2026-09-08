#!/usr/bin/env python3
"""Signed, per-user Linux releases. No root access or in-place binary replacement.

The signed manifest binds version, architecture, archive name, length and SHA-256.
Installation re-verifies the cached archive and extracts only regular files and
folders into a new version directory before atomically replacing `current`.
Older versions remain available for hooks in surviving tmux sessions.
"""
import argparse
import base64
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import platform
import re
import shutil
import stat
import subprocess
import tarfile
import tempfile
import urllib.request

MAX_ARCHIVE = 512 * 1024 * 1024
MAX_EXPANDED = 2 * 1024 * 1024 * 1024
VERSION = r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"


def version(value):
    if not isinstance(value, str) or not re.fullmatch(VERSION, value):
        raise ValueError("Expected a stable release version, for example 0.2.0.")
    return tuple(map(int, value.split(".")))


def architecture():
    return {"arm64": "aarch64", "aarch64": "aarch64", "x86_64": "x86_64"}.get(platform.machine(), "unsupported")


def configuration(directory):
    data = json.loads((directory / "release.json").read_text())
    version(data["version"])
    if data.get("schemaVersion") != 1 or data["architecture"] != architecture():
        raise ValueError("This release does not support this machine’s architecture.")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9_.-]+", data["repository"]) or data["repository"].split("/")[1] in (".", ".."):
        raise ValueError("Invalid release repository.")
    if len(base64.b64decode(data["publicKey"], validate=True)) != 32:
        raise ValueError("Invalid release signing key.")
    return data


def verify_signature(payload, signature, public_key):
    raw = base64.b64decode(public_key, validate=True)
    if len(raw) != 32 or len(signature) != 64:
        raise ValueError("Invalid update signature.")
    # RFC 8410 SubjectPublicKeyInfo for an Ed25519 raw public key.
    with tempfile.TemporaryDirectory(prefix="freemind-signature-") as temporary:
        folder = Path(temporary)
        (folder / "key.der").write_bytes(bytes.fromhex("302a300506032b6570032100") + raw)
        (folder / "data").write_bytes(payload)
        (folder / "signature").write_bytes(signature)
        result = subprocess.run(["openssl", "pkeyutl", "-verify", "-pubin", "-keyform", "DER", "-inkey", str(folder / "key.der"), "-rawin", "-in", str(folder / "data"), "-sigfile", str(folder / "signature")], capture_output=True, timeout=15)
        if result.returncode:
            raise ValueError("Update signature verification failed. Your installed version has not changed.")


def manifest(payload, signature, config):
    verify_signature(payload, signature, config["publicKey"])
    data = json.loads(payload)
    version(data["version"])
    expected = f"Freemind-{data['version']}-Linux-{config['architecture']}.tar.gz"
    if data.get("schemaVersion") != 1 or data.get("architecture") != config["architecture"] or data.get("archive") != expected:
        raise ValueError("Update manifest targets a different platform or archive.")
    if not isinstance(data.get("size"), int) or not 0 < data["size"] <= MAX_ARCHIVE or not re.fullmatch(r"[0-9a-f]{64}", data.get("sha256", "")):
        raise ValueError("Invalid update archive size or checksum.")
    return data


class HTTPSOnly(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, msg, headers, newurl):
        if not newurl.startswith("https://"):
            raise ValueError("Refusing an insecure update redirect.")
        return super().redirect_request(request, fp, code, msg, headers, newurl)


def fetch(url, destination, limit):
    if not url.startswith("https://"):
        raise ValueError("Updates require HTTPS.")
    request = urllib.request.Request(url, headers={"User-Agent": "Freemind-Linux-Updater", "Accept": "application/octet-stream"})
    with urllib.request.build_opener(HTTPSOnly()).open(request, timeout=30) as response, destination.open("wb") as output:
        total = 0
        while chunk := response.read(1024 * 1024):
            total += len(chunk)
            if total > limit:
                raise ValueError("Update download exceeds the expected size.")
            output.write(chunk)
        output.flush(); os.fsync(output.fileno())


def check(config):
    base = f"https://github.com/{config['repository']}/releases/latest/download/linux-{config['architecture']}.json"
    with tempfile.TemporaryDirectory(prefix="freemind-feed-") as temporary:
        folder = Path(temporary)
        fetch(base, folder / "manifest", 65536)
        fetch(base + ".sig", folder / "signature", 64)
        payload = (folder / "manifest").read_bytes(); signature = (folder / "signature").read_bytes()
    data = manifest(payload, signature, config)
    return data, payload, signature


def install_root(directory, config):
    directory = directory.resolve()
    if directory.parent.name != "versions":
        raise ValueError("Updates are installed by your package manager for this build.")
    root = directory.parent.parent
    for path in (root, root / "versions", directory):
        info = path.lstat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o022:
            raise ValueError("Update directories must be owned by you and not writable by other users.")
    marker = json.loads((root / "install.json").read_text())
    if any(marker.get(key) != config[key] for key in ("repository", "publicKey")):
        raise ValueError("Installation identity does not match this release.")
    current = (root / "current").resolve(strict=True)
    if current.parent != root / "versions":
        raise ValueError("Invalid current-version link.")
    return root


@contextlib.contextmanager
def locked(root):
    descriptor = os.open(root / ".update.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield


def atomic_write(path, data):
    descriptor, name = tempfile.mkstemp(dir=path.parent, prefix=".write-")
    try:
        with os.fdopen(descriptor, "wb") as output:
            output.write(data); output.flush(); os.fsync(output.fileno())
        os.replace(name, path)
    finally:
        Path(name).unlink(missing_ok=True)


def verify_archive(archive, data):
    if archive.stat().st_size != data["size"]:
        raise ValueError("Update archive length does not match the signed manifest.")
    with archive.open("rb") as stream:
        checksum = hashlib.file_digest(stream, "sha256").hexdigest()
    if checksum != data["sha256"]:
        raise ValueError("Update checksum verification failed. Your installed version has not changed.")


def stage(root, config, checked_release=None):
    data, payload, signature = checked_release if checked_release is not None else check(config)
    if version(data["version"]) <= version(config["version"]):
        return {"available": False, "version": config["version"], "pending": False}
    updates = root / ".updates"
    updates.mkdir(mode=0o700, exist_ok=True)
    if updates.is_symlink():
        raise ValueError("Update cache must not be a symlink.")
    with tempfile.TemporaryDirectory(dir=updates, prefix="download-") as temporary:
        archive = Path(temporary) / "archive.tar.gz"
        url = f"https://github.com/{config['repository']}/releases/download/v{data['version']}/{data['archive']}"
        fetch(url, archive, data["size"])
        verify_archive(archive, data)
        # One version directory commits the archive and its signature together.
        (Path(temporary) / "manifest.json").write_bytes(payload)
        (Path(temporary) / "manifest.sig").write_bytes(signature)
        target = updates / data["version"]
        if target.exists(): shutil.rmtree(target)
        os.rename(temporary, target)
        atomic_write(updates / "pending", data["version"].encode())
    return {"available": True, "version": data["version"], "pending": True}


def extract(archive, destination):
    with tarfile.open(archive, "r:gz") as tar:
        total = 0; names = set()
        for entry in tar:
            path = PurePosixPath(entry.name)
            if path.is_absolute() or ".." in path.parts or not path.parts or "\\" in entry.name or any(ord(c) < 32 for c in entry.name):
                raise ValueError("Unsafe path in update archive.")
            if not (entry.isdir() or entry.isreg()) or path in names or len(names) > 20000:
                raise ValueError("Unsupported or duplicate entry in update archive.")
            names.add(path); total += entry.size
            if total > MAX_EXPANDED:
                raise ValueError("Expanded update is too large.")
            target = destination.joinpath(*path.parts)
            if entry.isdir(): target.mkdir(parents=True, exist_ok=True)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                with tar.extractfile(entry) as source, target.open("xb") as output:
                    shutil.copyfileobj(source, output)
                target.chmod(0o755 if entry.mode & 0o111 else 0o644)
    for name in ("freemind-linux", "freemind-helper", "launch", "update.py", "release.json"):
        if not (destination / name).is_file(): raise ValueError(f"Update is missing {name}.")


def install_pending(root, config):
    updates = root / ".updates"
    pointer = updates / "pending"
    if not pointer.exists(): return {"installed": False}
    number = pointer.read_text(); version(number)
    candidate = updates / number
    payload = (candidate / "manifest.json").read_bytes(); signature = (candidate / "manifest.sig").read_bytes()
    data = manifest(payload, signature, config)
    if data["version"] != number: raise ValueError("Pending update version mismatch.")
    current = configuration((root / "current").resolve())
    if version(number) <= version(current["version"]):
        pointer.unlink(); return {"installed": False}
    archive = candidate / "archive.tar.gz"
    verify_archive(archive, data)
    versions = root / "versions"
    with tempfile.TemporaryDirectory(dir=versions, prefix=".install-") as temporary:
        target = Path(temporary)
        extract(archive, target)
        release = configuration(target)
        if any(release[key] != config[key] for key in ("publicKey", "repository", "architecture")) or release["version"] != number:
            raise ValueError("Downloaded release identity does not match the signed update.")
        destination = versions / number
        if destination.exists():
            # Never overwrite a version that another running app might use.
            raise ValueError("This version directory already exists. The current installation has not changed.")
        os.rename(target, destination)
    link = root / ".current-next"
    link.unlink(missing_ok=True)
    link.symlink_to(Path("versions") / number)
    os.replace(link, root / "current")
    descriptor = os.open(root, os.O_RDONLY | os.O_DIRECTORY)
    try: os.fsync(descriptor)
    finally: os.close(descriptor)
    pointer.unlink()
    return {"installed": True, "version": number}


def install_local(directory, root):
    config = configuration(directory)
    root = root.expanduser().absolute()
    if root.exists() and any(root.iterdir()):
        raise ValueError("Choose an empty installation folder. Use the app to update an existing installation.")
    root.mkdir(mode=0o755, parents=True, exist_ok=True)
    versions = root / "versions"; versions.mkdir()
    target = versions / config["version"]
    shutil.copytree(directory, target, symlinks=False)
    atomic_write(root / "install.json", json.dumps({key: config[key] for key in ("repository", "publicKey")}).encode())
    (root / "current").symlink_to(Path("versions") / config["version"])
    return {"installed": True, "launcher": str(root / "current/launch")}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("check", "download", "install", "install-local"))
    parser.add_argument("--directory", type=Path, default=Path(__file__).resolve().parent)
    parser.add_argument("--prefix", type=Path, default=Path.home() / ".local/share/freemind")
    args = parser.parse_args()
    try:
        directory = args.directory.resolve(); config = configuration(directory)
        if args.action == "install-local": result = install_local(directory, args.prefix)
        else:
            root = install_root(directory, config)
            with locked(root):
                if args.action == "install": result = install_pending(root, config)
                elif args.action == "download": result = stage(root, config)
                else:
                    data, _, _ = check(config)
                    result = {"available": version(data["version"]) > version(config["version"]), "version": data["version"], "pending": (root / ".updates/pending").exists()}
        print(json.dumps(result))
    except (ValueError, OSError, KeyError, TypeError, tarfile.TarError, subprocess.SubprocessError) as error:
        print(json.dumps({"error": str(error)})); return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
