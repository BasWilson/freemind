"""Build a real local release archive with an ephemeral key and validate its install.

Run after the Linux frontend build, with Scripts/linux-env.sh sourced. This never
contacts or publishes a release and never writes outside a temporary directory.
"""
import base64
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("packager", ROOT / "Scripts/package-linux.py")
packager = importlib.util.module_from_spec(spec); spec.loader.exec_module(packager)
update = packager.update

with tempfile.TemporaryDirectory(prefix="freemind-package-test-") as temporary:
    root = Path(temporary); key = root / "key.pem"
    subprocess.run(["openssl", "genpkey", "-algorithm", "ED25519", "-out", str(key)], capture_output=True, check=True)
    private = subprocess.run(["openssl", "pkey", "-in", str(key), "-outform", "DER"], capture_output=True, check=True).stdout[-32:]
    public = subprocess.run(["openssl", "pkey", "-in", str(key), "-pubout", "-outform", "DER"], capture_output=True, check=True).stdout[-32:]
    env = dict(os.environ, FREEMIND_RELEASE_VERSION="0.0.1", FREEMIND_UPDATE_REPOSITORY="example/freemind", LINUX_PUBLIC_ED_KEY=base64.b64encode(public).decode(), LINUX_PRIVATE_ED_KEY=base64.b64encode(private).decode())
    archive = packager.package(ROOT / ".build/linux" / os.environ.get("FREEMIND_CONFIGURATION", "debug"), root / "dist", env)
    extracted = root / "extracted"; extracted.mkdir()
    update.extract(archive, extracted)
    config = update.configuration(extracted)
    feed = root / "dist" / f"linux-{config['architecture']}.json"
    metadata = update.manifest(feed.read_bytes(), feed.with_suffix(".json.sig").read_bytes(), config)
    update.verify_archive(archive, metadata)
    installed = root / "installed"
    update.install_local(extracted, installed)
    result = subprocess.run([str(installed / "current/launch"), "--help"], text=True, capture_output=True, check=True)
    assert "Usage: freemind-linux" in result.stdout, result.stdout + result.stderr
    assert list((installed / "current/lib").glob("libswiftCore.so*"))
    assert (installed / "current/freemind-helper").is_file()
    assert (installed / "current/integrate.py").is_file()

    # Run the exact self-contained Bash payload used by curl | bash. Only the
    # network transport is substituted; signatures, extraction, runtime checks,
    # installation and desktop registration execute for real in a temporary home.
    spec = importlib.util.spec_from_file_location("installer", ROOT / "Scripts/build-linux-installer.py")
    installer = importlib.util.module_from_spec(spec); spec.loader.exec_module(installer)
    script = installer.build(root / "install.sh", env)
    home = root / "home"; home.mkdir()
    routes = {f"https://github.com/example/freemind/releases/download/v0.0.1/{path.name}": str(path) for path in (archive, feed, feed.with_suffix(".json.sig"))}
    transport = root / "transport"; transport.mkdir()
    (transport / "sitecustomize.py").write_text(
        "from pathlib import Path\nimport urllib.request\n"
        f"routes = {routes!r}\n"
        "def fixture_open(self, request, *args, **kwargs):\n"
        "    url = request.full_url if hasattr(request, 'full_url') else request\n"
        "    if url not in routes: raise AssertionError('Unexpected download: ' + url)\n"
        "    return Path(routes[url]).open('rb')\n"
        "urllib.request.OpenerDirector.open = fixture_open\n"
    )
    process_env = dict(os.environ, HOME=str(home), XDG_DATA_HOME=str(home / "data"), PYTHONPATH=str(transport))
    for _ in range(2):
        subprocess.run(["bash", "-s", "--", "--no-deps"], input=script.read_text(), cwd=home, env=process_env, capture_output=True, text=True, check=True)
    assert (home / "data/freemind/current/freemind-linux").is_file()
    assert (home / "data/applications/dev.freemind.Linux.desktop").is_file()
    assert (home / ".local/bin/freemind").is_symlink()
    print("PASS: real native archive, signed manifest, extracted runtime, standalone piped installer, repeat installation and desktop launcher.")
