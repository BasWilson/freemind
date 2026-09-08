#!/usr/bin/env python3
"""Write installation instructions for the GitHub release page."""
import argparse
from pathlib import Path
import re


def notes(repository, version, linux):
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9_.-]+", repository) or repository.split("/")[1] in (".", ".."):
        raise ValueError("Expected a GitHub owner/repository.")
    if not re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", version):
        raise ValueError("Expected a stable MAJOR.MINOR.PATCH version.")
    base = f"https://github.com/{repository}/releases/download/v{version}"
    text = "## Install Freemind\n\n"
    if linux:
        text += f"""### Linux / Omarchy

Run as your normal desktop user:

```sh
curl -fsSL {base}/install.sh | bash
```

The installer detects x86_64 or ARM64, installs missing runtime dependencies on
Arch/Omarchy or Ubuntu 24.04+, verifies the signed download and adds Freemind to
your app launcher. No Swift toolchain or source checkout is needed. Python 3.11+
and curl must already be available. Only dependency installation requests sudo.

Open **Freemind** from your app launcher or run `freemind /path/to/workspace`.
Future signed updates are available in **Settings → General**.

Manual downloads: [Intel/AMD]({base}/Freemind-{version}-Linux-x86_64.tar.gz) ·
[ARM64]({base}/Freemind-{version}-Linux-aarch64.tar.gz).
Extract the archive and run `bash install.sh` inside it.

"""
    text += f"""### macOS

Download [Apple Silicon]({base}/Freemind-{version}-macOS-arm64.zip) or
[Intel]({base}/Freemind-{version}-macOS-x86_64.zip), unzip and move Freemind into
Applications. Requires macOS 14+. These builds are locally signed, without Apple
notarization; first launch may require **System Settings → Privacy & Security →
Open Anyway**. The `-update.zip` files are for the automatic updater.

Install and sign in to Codex CLI separately on either platform.
See the [README](https://github.com/{repository}/blob/v{version}/README.md) for usage.
"""
    return text


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--linux", action="store_true")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.write_text(notes(args.repository, args.version, args.linux))
