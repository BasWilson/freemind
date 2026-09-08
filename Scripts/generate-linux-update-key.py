#!/usr/bin/env python3
"""Generate a Linux update-signing key without printing the private key."""
import argparse
import base64
import os
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("private_file", type=Path, help="New private-key file; keep outside your repository")
args = parser.parse_args()
with tempfile.TemporaryDirectory(prefix="freemind-key-") as temporary:
    pem = Path(temporary) / "key.pem"
    subprocess.run(["openssl", "genpkey", "-algorithm", "ED25519", "-out", str(pem)], check=True, capture_output=True)
    private = subprocess.run(["openssl", "pkey", "-in", str(pem), "-outform", "DER"], check=True, capture_output=True).stdout[-32:]
    public = subprocess.run(["openssl", "pkey", "-in", str(pem), "-pubout", "-outform", "DER"], check=True, capture_output=True).stdout[-32:]
    descriptor = os.open(args.private_file, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "wb") as output: output.write(base64.b64encode(private) + b"\n")
    print("LINUX_PUBLIC_ED_KEY=" + base64.b64encode(public).decode())
    print(f"Private key saved to {args.private_file}. Add its contents as the LINUX_PRIVATE_ED_KEY repository secret.")
