"""Implementation embedded in the single-file, release-specific Linux installer."""
import argparse
import ctypes
import ctypes.util
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tempfile
import urllib.error

import freemind_update as update
import freemind_integrate as integrate


def missing_dependencies():
    missing = [name for name in ("tmux", "git", "openssl") if not shutil.which(name)]
    for library, label in (("gtk-4", "GTK4"), ("vte-2.91-gtk4", "VTE for GTK4"), ("gtksourceview-5", "GtkSourceView 5")):
        if not ctypes.util.find_library(library):
            missing.append(label)
    return missing


def dependencies(no_deps):
    missing = missing_dependencies()
    if missing:
        print("Missing dependencies: " + ", ".join(missing), flush=True)
        if no_deps:
            raise ValueError("Install the missing packages and run the installer again.")
        if shutil.which("pacman"):
            commands = [["sudo", "pacman", "-S", "--needed", "gtk4", "vte4", "gtksourceview5", "tmux", "git", "python", "openssl", "ca-certificates"]]
        elif shutil.which("apt-get"):
            commands = [["sudo", "apt-get", "update"], ["sudo", "apt-get", "install", "libgtk-4-1", "libvte-2.91-gtk4-0", "libgtksourceview-5-0", "tmux", "git", "python3", "openssl", "ca-certificates"]]
        else:
            raise ValueError("Install GTK4 4.14+, VTE GTK4, GtkSourceView 5, tmux, Git and OpenSSL 3 using your package manager, then rerun.")
        print("Your package manager will request permission to install these dependencies. Freemind itself installs without sudo.", flush=True)
        try:
            terminal = open("/dev/tty", "r+")
        except OSError as error:
            raise ValueError("Dependency installation needs a terminal. Install the packages first, then rerun with --no-deps.") from error
        with terminal:
            for command in commands:
                subprocess.run(command, stdin=terminal, check=True)
        missing = missing_dependencies()
        if missing:
            raise ValueError("Dependencies are still missing: " + ", ".join(missing))
    gtk = ctypes.CDLL(ctypes.util.find_library("gtk-4"))
    if (gtk.gtk_get_major_version(), gtk.gtk_get_minor_version()) < (4, 14):
        raise ValueError("This release needs GTK4 4.14 or newer (Ubuntu 24.04+ or current Arch/Omarchy).")
    openssl = subprocess.run(["openssl", "version"], capture_output=True, text=True, check=True).stdout
    if not openssl.startswith("OpenSSL 3."):
        raise ValueError("This release needs OpenSSL 3 for signature verification.")


def release(config):
    base = f"https://github.com/{config['repository']}/releases/download/v{config['version']}/linux-{config['architecture']}.json"
    with tempfile.TemporaryDirectory(prefix="freemind-install-feed-") as temporary:
        folder = Path(temporary)
        update.fetch(base, folder / "manifest", 65536)
        update.fetch(base + ".sig", folder / "signature", 64)
        payload = (folder / "manifest").read_bytes()
        signature = (folder / "signature").read_bytes()
    data = update.manifest(payload, signature, config)
    if data["version"] != config["version"]:
        raise ValueError("The manifest does not match this installer's release version.")
    return data, payload, signature


def install(config, root):
    root = root.expanduser().absolute()
    if any(ord(character) < 32 for character in str(root)):
        raise ValueError("The installation path cannot contain control characters.")
    current = root / "current"
    if current.exists() or current.is_symlink():
        installed = update.configuration(current)
        if any(installed[key] != config[key] for key in ("publicKey", "repository", "architecture")):
            raise ValueError("This folder contains an installation with a different signing identity. Choose another --prefix.")
        update.install_root(current, installed)
        with update.locked(root):
            installed = update.configuration(current)
            if update.version(installed["version"]) >= update.version(config["version"]):
                print(f"Freemind {installed['version']} is already installed; keeping this version.")
            else:
                update.stage(root, installed, release(config))
                update.install_pending(root, installed)
    else:
        if root.exists() and any(root.iterdir()):
            raise ValueError("Choose an empty installation folder with --prefix.")
        data, _, _ = release(config)
        with tempfile.TemporaryDirectory(prefix="freemind-install-") as temporary:
            folder = Path(temporary)
            archive = folder / "archive.tar.gz"
            url = f"https://github.com/{config['repository']}/releases/download/v{data['version']}/{data['archive']}"
            print(f"Downloading Freemind {data['version']} for {config['architecture']}…", flush=True)
            update.fetch(url, archive, data["size"])
            update.verify_archive(archive, data)
            app = folder / "app"
            app.mkdir()
            update.extract(archive, app)
            embedded = update.configuration(app)
            if any(embedded[key] != config[key] for key in ("publicKey", "repository", "architecture", "version")):
                raise ValueError("The downloaded release identity does not match this installer.")
            # Validate the downloaded executable's runtime before creating an installation.
            result = subprocess.run([str(app / "launch"), "--help"], capture_output=True, text=True, timeout=30)
            if result.returncode:
                raise ValueError("This build cannot run on this system:\n" + result.stderr[-4000:])
            update.install_local(app, root)
    integrate.register(root)


def main(config):
    parser = argparse.ArgumentParser(description="Install a signed Freemind release from GitHub, or upgrade an existing per-user installation.")
    parser.add_argument("--prefix", type=Path, default=Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local/share")) / "freemind")
    parser.add_argument("--no-deps", action="store_true", help="Check dependencies without invoking sudo or a package manager")
    args = parser.parse_args()
    try:
        if os.geteuid() == 0:
            raise ValueError("Run this installer as your desktop user, without sudo.")
        if platform.system() != "Linux" or update.architecture() == "unsupported":
            raise ValueError("Freemind Linux releases support x86_64 and aarch64 Linux.")
        libc, number = platform.libc_ver()
        if libc != "glibc" or tuple(map(int, number.split(".")[:2])) < (2, 39):
            raise ValueError("This build needs glibc 2.39+ (Ubuntu 24.04+ or current Arch/Omarchy).")
        config = dict(config, architecture=update.architecture())
        dependencies(args.no_deps)
        install(config, args.prefix)
    except urllib.error.HTTPError as error:
        print(f"Installation failed: GitHub returned HTTP {error.code}. Check that this Linux release is published and public.", file=sys.stderr)
        return 1
    except (ValueError, OSError, KeyError, TypeError, update.tarfile.TarError, subprocess.SubprocessError) as error:
        print(f"Installation failed: {error}", file=sys.stderr)
        return 1
    return 0
