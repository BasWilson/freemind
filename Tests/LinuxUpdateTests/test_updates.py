import base64
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("update", ROOT / "Linux/Support/update.py")
update = importlib.util.module_from_spec(spec); spec.loader.exec_module(update)


class UpdateTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="freemind-update-test-")
        self.addCleanup(self.temporary.cleanup)
        self.folder = Path(self.temporary.name)
        self.private = self.folder / "key.pem"
        subprocess.run(["openssl", "genpkey", "-algorithm", "ED25519", "-out", str(self.private)], check=True, capture_output=True)
        raw = subprocess.run(["openssl", "pkey", "-in", str(self.private), "-pubout", "-outform", "DER"], check=True, capture_output=True).stdout[-32:]
        self.config = {"schemaVersion": 1, "version": "1.0.0", "architecture": update.architecture(), "repository": "example/freemind", "publicKey": base64.b64encode(raw).decode()}
        self.root = self.folder / "installed"; self.root.mkdir()
        old = self.root / "versions/1.0.0"; old.mkdir(parents=True)
        self.make_release(old, "1.0.0")
        (self.root / "current").symlink_to("versions/1.0.0")
        (self.root / "install.json").write_text(json.dumps(self.config))

    def make_release(self, folder, number):
        for name in ("freemind-linux", "freemind-helper", "launch", "update.py"):
            (folder / name).write_text("test " + number); (folder / name).chmod(0o755)
        (folder / "release.json").write_text(json.dumps(dict(self.config, version=number)))

    def sign(self, payload):
        data = self.folder / "data"; data.write_bytes(payload)
        return subprocess.run(["openssl", "pkeyutl", "-sign", "-rawin", "-inkey", str(self.private), "-in", str(data)], check=True, capture_output=True).stdout

    def release(self, number="1.1.0", entries=None, **overrides):
        archive = self.folder / ("archive-" + number + ".tar.gz")
        source = self.folder / ("source-" + number); source.mkdir(exist_ok=True); self.make_release(source, number)
        with tarfile.open(archive, "w:gz") as tar:
            for file in source.iterdir(): tar.add(file, arcname=file.name)
            for entry, contents in entries or []: tar.addfile(entry, io.BytesIO(contents))
        metadata = dict(schemaVersion=1, version=number, architecture=self.config["architecture"], archive=f"Freemind-{number}-Linux-{self.config['architecture']}.tar.gz", size=archive.stat().st_size, sha256=hashlib.sha256(archive.read_bytes()).hexdigest())
        metadata.update(overrides)
        payload = json.dumps(metadata).encode(); signature = self.sign(payload)
        return archive, metadata, payload, signature

    def pending(self, release):
        archive, metadata, payload, signature = release
        target = self.root / ".updates" / metadata["version"]; target.mkdir(parents=True)
        shutil.copy(archive, target / "archive.tar.gz")
        (target / "manifest.json").write_bytes(payload); (target / "manifest.sig").write_bytes(signature)
        (target.parent / "pending").write_text(metadata["version"])
        return target

    def test_signed_update_installs_atomically_and_preserves_old_helpers(self):
        self.pending(self.release())
        result = update.install_pending(self.root, self.config)
        self.assertTrue(result["installed"])
        self.assertEqual((self.root / "current").resolve().name, "1.1.0")
        self.assertTrue((self.root / "versions/1.0.0/freemind-helper").exists())
        self.assertFalse((self.root / ".updates/pending").exists())

    def test_tampered_feed_and_wrong_signing_key_are_rejected(self):
        _, _, payload, signature = self.release()
        with self.assertRaises(ValueError): update.manifest(payload + b" ", signature, self.config)
        with self.assertRaises(ValueError): update.manifest(payload, signature, dict(self.config, publicKey=base64.b64encode(bytes(32)).decode()))

    def test_cross_architecture_and_archive_path_are_rejected(self):
        for fields in ({"architecture": "wrong"}, {"archive": "../../app.tar.gz"}, {"size": update.MAX_ARCHIVE + 1}, {"version": "1.1.0-beta"}):
            archive, metadata, payload, signature = self.release(**fields)
            with self.assertRaises(ValueError): update.manifest(payload, signature, self.config)

    def test_tampered_archive_keeps_current_version(self):
        target = self.pending(self.release())
        with (target / "archive.tar.gz").open("ab") as stream: stream.write(b"tampered")
        with self.assertRaises(ValueError): update.install_pending(self.root, self.config)
        self.assertEqual((self.root / "current").resolve().name, "1.0.0")

    def test_archive_rejects_traversal_symlinks_and_devices(self):
        for name, kind in [("../escape", tarfile.REGTYPE), ("/tmp/escape", tarfile.REGTYPE), ("link", tarfile.SYMTYPE), ("device", tarfile.CHRTYPE)]:
            with self.subTest(name=name):
                entry = tarfile.TarInfo(name); entry.type = kind; entry.linkname = "/tmp/escape"
                release = self.release(entries=[(entry, b"")])
                self.pending(release)
                with self.assertRaises(ValueError): update.install_pending(self.root, self.config)
                self.assertEqual((self.root / "current").resolve().name, "1.0.0")
                shutil.rmtree(self.root / ".updates")

    def test_replayed_older_release_does_not_downgrade(self):
        self.pending(self.release("0.9.0"))
        self.assertFalse(update.install_pending(self.root, self.config)["installed"])
        self.assertEqual((self.root / "current").resolve().name, "1.0.0")

    def test_signed_archive_identity_must_match(self):
        release = self.release()
        # Substitute a correctly signed archive whose embedded identity changed.
        source = self.folder / "source-1.1.0/release.json"
        source.write_text(json.dumps(dict(self.config, version="9.9.9")))
        archive, metadata, _, _ = release
        with tarfile.open(archive, "w:gz") as tar:
            for file in source.parent.iterdir(): tar.add(file, arcname=file.name)
        metadata["size"] = archive.stat().st_size; metadata["sha256"] = hashlib.sha256(archive.read_bytes()).hexdigest()
        payload = json.dumps(metadata).encode()
        self.pending((archive, metadata, payload, self.sign(payload)))
        with self.assertRaises(ValueError): update.install_pending(self.root, self.config)
        self.assertEqual((self.root / "current").resolve().name, "1.0.0")

    def test_package_managed_and_untrusted_installations_are_not_mutated(self):
        with self.assertRaises(ValueError): update.install_root(self.folder, self.config)
        (self.root / "install.json").write_text("{}")
        with self.assertRaises(ValueError): update.install_root(self.root / "current", self.config)

    def test_download_is_bounded_verified_and_installs_without_network(self):
        archive, metadata, payload, signature = self.release()
        def fetch(url, destination, limit):
            contents = signature if url.endswith(".sig") else payload if url.endswith(".json") else archive.read_bytes()
            self.assertLessEqual(len(contents), limit); destination.write_bytes(contents)
        with patch.object(update, "fetch", side_effect=fetch):
            self.assertTrue(update.stage(self.root, self.config)["pending"])
        with patch.object(update, "fetch", side_effect=AssertionError("Install must be offline")):
            self.assertTrue(update.install_pending(self.root, self.config)["installed"])

    def test_existing_version_directory_is_never_overwritten(self):
        target = self.root / "versions/1.1.0"; target.mkdir(); (target / "keep").write_text("running helper")
        self.pending(self.release())
        with self.assertRaises(ValueError): update.install_pending(self.root, self.config)
        self.assertEqual((target / "keep").read_text(), "running helper")
        self.assertEqual((self.root / "current").resolve().name, "1.0.0")


if __name__ == "__main__": unittest.main()
