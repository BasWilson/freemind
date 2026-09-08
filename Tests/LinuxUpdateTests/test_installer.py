import base64
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


update = load("freemind_update", "Linux/Support/update.py")
integrate = load("freemind_integrate", "Linux/Support/integrate.py")
bootstrap = load("freemind_bootstrap", "Scripts/linux-bootstrap.py")
builder = load("installer_builder", "Scripts/build-linux-installer.py")
setup = load("signing_setup", "Scripts/setup-linux-updates.py")


class InstallerTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="freemind-installer-test-")
        self.addCleanup(temporary.cleanup)
        self.folder = Path(temporary.name)
        self.home = self.folder / "home"
        self.home.mkdir()
        self.root = self.home / "Apps/Freemind with spaces"
        self.share = self.home / "data"
        self.environment = patch.dict(os.environ, HOME=str(self.home), XDG_DATA_HOME=str(self.share))
        self.environment.start()
        self.addCleanup(self.environment.stop)
        self.key = self.folder / "key.pem"
        subprocess.run(["openssl", "genpkey", "-algorithm", "ED25519", "-out", str(self.key)], check=True, capture_output=True)
        raw = subprocess.run(["openssl", "pkey", "-in", str(self.key), "-pubout", "-outform", "DER"], check=True, capture_output=True).stdout[-32:]
        self.config = dict(schemaVersion=1, version="1.0.0", architecture=update.architecture(), repository="example/freemind", publicKey=base64.b64encode(raw).decode())
        self.served = {}

    def serve(self, config=None, archive_edit=None):
        config = config or self.config
        source = self.folder / ("source-" + config["version"])
        source.mkdir(exist_ok=True)
        for name in ("freemind-linux", "freemind-helper", "launch"):
            (source / name).write_text("#!/bin/sh\nprintf 'Usage: freemind-linux\\n'\n")
            (source / name).chmod(0o755)
        (source / "release.json").write_text(json.dumps(config))
        (source / "update.py").write_text("# test fixture\n")
        (source / "dev.freemind.Linux.svg").write_text("<svg/>\n")
        archive = self.folder / (config["version"] + ".tar.gz")
        if archive_edit:
            archive_edit(source)
        with tarfile.open(archive, "w:gz") as tar:
            for item in source.iterdir():
                tar.add(item, arcname=item.name)
        content = archive.read_bytes()
        data = dict(schemaVersion=1, version=config["version"], architecture=config["architecture"], archive=f"Freemind-{config['version']}-Linux-{config['architecture']}.tar.gz", size=len(content), sha256=hashlib.sha256(content).hexdigest())
        payload = json.dumps(data).encode()
        manifest = self.folder / "manifest"
        manifest.write_bytes(payload)
        signature = subprocess.run(["openssl", "pkeyutl", "-sign", "-rawin", "-inkey", str(self.key), "-in", str(manifest)], check=True, capture_output=True).stdout
        base = f"https://github.com/{config['repository']}/releases/download/v{config['version']}/"
        self.served[base + f"linux-{config['architecture']}.json"] = payload
        self.served[base + f"linux-{config['architecture']}.json.sig"] = signature
        self.served[base + data["archive"]] = content

    def fetch(self, url, destination, limit):
        self.assertIn(url, self.served, "Downloads must be pinned to this installer version")
        content = self.served[url]
        self.assertLessEqual(len(content), limit)
        destination.write_bytes(content)

    def install(self, config=None):
        with patch.object(update, "fetch", side_effect=self.fetch), patch("sys.stdout", new=io.StringIO()):
            bootstrap.install(config or self.config, self.root)

    def test_fresh_install_creates_working_command_and_desktop_then_reruns_offline(self):
        self.serve()
        self.install()
        command = self.home / ".local/bin/freemind"
        self.assertEqual(command.resolve(), (self.root / "versions/1.0.0/launch").resolve())
        output = subprocess.run([str(command), "--help"], capture_output=True, check=True, text=True).stdout
        self.assertIn("Usage: freemind-linux", output)
        desktop = self.share / "applications/dev.freemind.Linux.desktop"
        self.assertIn(f'Exec="{self.root}/current/launch" %f', desktop.read_text())
        if shutil.which("desktop-file-validate"):
            subprocess.run(["desktop-file-validate", str(desktop)], check=True, capture_output=True)
        desktop.unlink()
        self.served.clear()
        self.install()
        self.assertTrue(desktop.is_file())

    def test_upgrade_preserves_old_helpers_and_user_data_and_refuses_downgrade(self):
        self.serve()
        self.install()
        user_data = self.home / "workspace/.freemind/notes/keep.md"
        user_data.parent.mkdir(parents=True)
        user_data.write_text("Keep my notes")
        newer = dict(self.config, version="1.1.0")
        self.serve(newer)
        self.install(newer)
        self.assertEqual((self.root / "current").resolve().name, "1.1.0")
        self.assertTrue((self.root / "versions/1.0.0/freemind-helper").exists())
        self.assertEqual(user_data.read_text(), "Keep my notes")
        self.served.clear()
        self.install()
        self.assertEqual((self.root / "current").resolve().name, "1.1.0")

    def test_existing_command_is_preserved_but_desktop_registration_succeeds(self):
        existing = self.home / ".local/bin/freemind"
        existing.parent.mkdir(parents=True)
        existing.write_text("My own command")
        self.serve()
        self.install()
        self.assertEqual(existing.read_text(), "My own command")
        desktop = (self.share / "applications/dev.freemind.Linux.desktop").read_text()
        self.assertIn(str(self.root / "current/launch"), desktop)
        self.assertNotIn(str(existing), desktop)

    def test_tampering_rejected_before_creating_installation(self):
        self.serve()
        archive = next(key for key in self.served if key.endswith(".tar.gz"))
        original = self.served[archive]
        self.served[archive] = original[:-1] + bytes([original[-1] ^ 1])
        with self.assertRaisesRegex(ValueError, "checksum"):
            self.install()
        self.assertFalse(self.root.exists())

    def test_signed_archive_identity_and_broken_runtime_rejected_before_installation(self):
        def wrong_identity(source):
            (source / "release.json").write_text(json.dumps(dict(self.config, repository="wrong/repository")))
        self.serve(archive_edit=wrong_identity)
        with self.assertRaisesRegex(ValueError, "identity"):
            self.install()
        self.assertFalse(self.root.exists())
        def broken_runtime(source):
            (source / "launch").write_text("#!/bin/sh\necho missing-library >&2\nexit 127\n")
        self.serve(archive_edit=broken_runtime)
        with self.assertRaisesRegex(ValueError, "missing-library"):
            self.install()
        self.assertFalse(self.root.exists())

    def test_no_deps_never_invokes_sudo_or_package_manager(self):
        with patch.object(bootstrap, "missing_dependencies", return_value=["VTE for GTK4"]), patch.object(subprocess, "run", side_effect=AssertionError("Must not run a command")), patch("sys.stdout", new=io.StringIO()):
            with self.assertRaisesRegex(ValueError, "missing packages"):
                bootstrap.dependencies(no_deps=True)

    def test_generated_script_is_standalone_and_supports_piped_help(self):
        script = builder.build(self.folder / "install.sh", {"FREEMIND_RELEASE_VERSION": "1.0.0", "FREEMIND_UPDATE_REPOSITORY": self.config["repository"], "LINUX_PUBLIC_ED_KEY": self.config["publicKey"]})
        subprocess.run(["bash", "-n", str(script)], check=True)
        result = subprocess.run(["bash", "-s", "--", "--help"], input=script.read_text(), cwd=self.home, capture_output=True, text=True, check=True)
        self.assertIn("--no-deps", result.stdout)
        self.assertIn("--prefix", result.stdout)
        self.assertFalse(self.root.exists())

    def test_signing_setup_refuses_rotation_when_existing_key_is_not_on_machine(self):
        responses = [json.dumps({"visibility": "PUBLIC", "nameWithOwner": "example/freemind"}), json.dumps([{"name": "LINUX_PUBLIC_ED_KEY", "value": self.config["publicKey"]}]), "[]"]
        key = self.folder / "backup.key"
        with patch.object(setup, "gh", side_effect=responses) as gh:
            with self.assertRaisesRegex(ValueError, "Restore its original private key"):
                setup.setup("example/freemind", key)
        self.assertFalse(key.exists())
        self.assertFalse(any(call.args[1] == "set" for call in gh.call_args_list))

    def test_signing_setup_reuses_key_and_uploads_secret_through_stdin_only(self):
        raw = subprocess.run(["openssl", "pkey", "-in", str(self.key), "-outform", "DER"], check=True, capture_output=True).stdout[-32:]
        encoded = base64.b64encode(raw).decode()
        key = self.folder / "backup.key"
        key.write_text(encoded)
        key.chmod(0o600)
        responses = [json.dumps({"visibility": "PUBLIC", "nameWithOwner": "example/freemind"}), json.dumps([{"name": "LINUX_PUBLIC_ED_KEY", "value": self.config["publicKey"]}]), "", ""]
        with patch.object(setup, "gh", side_effect=responses) as gh, patch("sys.stdout", new=io.StringIO()) as output:
            setup.setup("example/freemind", key)
        self.assertEqual(key.read_text(), encoded)
        self.assertNotIn(encoded, output.getvalue())
        upload = next(call for call in gh.call_args_list if call.args[:2] == ("secret", "set"))
        self.assertEqual(upload.kwargs["input"], encoded)
        self.assertNotIn(encoded, upload.args)


if __name__ == "__main__":
    unittest.main()
