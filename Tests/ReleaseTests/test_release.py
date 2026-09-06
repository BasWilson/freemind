import base64
import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parents[2]


def load_script(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / "Scripts" / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


configure = load_script("configure-release").configure
verify = load_script("verify-appcast").verify
PUBLIC_KEY = base64.b64encode(bytes(range(32))).decode()
ENVIRONMENT = {
    "FREEMIND_RELEASE_VERSION": "1.2.3",
    "FREEMIND_UPDATE_REPOSITORY": "example/Freemind",
    "SPARKLE_PUBLIC_ED_KEY": PUBLIC_KEY,
}


class ReleaseConfigurationTests(unittest.TestCase):
    def test_local_build_removes_release_configuration(self):
        info = configure({"CFBundleVersion": "12", "SUFeedURL": "stale", "SUPublicEDKey": "stale"}, {}, "arm64")
        self.assertNotIn("SUFeedURL", info)
        self.assertNotIn("SUPublicEDKey", info)
        self.assertEqual(info["CFBundleVersion"], "12")

    def test_version_is_independent_of_local_build_counter(self):
        info = configure({"CFBundleVersion": "99999"}, ENVIRONMENT, "arm64")
        self.assertEqual(info["CFBundleVersion"], "1.2.3")
        self.assertEqual(info["CFBundleShortVersionString"], "1.2.3")

    def test_each_architecture_has_its_own_feed(self):
        for architecture in ("arm64", "x86_64"):
            info = configure({}, ENVIRONMENT, architecture)
            self.assertEqual(info["SUFeedURL"], f"https://github.com/example/Freemind/releases/latest/download/appcast-{architecture}.xml")

    def test_rejects_partial_update_configuration(self):
        for missing in ENVIRONMENT:
            with self.subTest(missing=missing), self.assertRaises(ValueError):
                configure({}, {k: v for k, v in ENVIRONMENT.items() if k != missing}, "arm64")

    def test_rejects_invalid_or_prerelease_versions(self):
        for version in ("v1.2.3", "1.2", "1.2.3-beta", "01.2.3", "1.2.3\n", "$(id)"):
            with self.subTest(version=version), self.assertRaises(ValueError):
                configure({}, {**ENVIRONMENT, "FREEMIND_RELEASE_VERSION": version}, "arm64")

    def test_rejects_invalid_repositories(self):
        for repository in ("https://github.com/owner/repo", "owner/repo/extra", "owner/..", "owner/repo?x=1"):
            with self.subTest(repository=repository), self.assertRaises(ValueError):
                configure({}, {**ENVIRONMENT, "FREEMIND_UPDATE_REPOSITORY": repository}, "arm64")

    def test_rejects_invalid_signing_keys(self):
        for key in ("bad key!", base64.b64encode(b"short").decode(), PUBLIC_KEY + "\n"):
            with self.subTest(key=key), self.assertRaises(ValueError):
                configure({}, {**ENVIRONMENT, "SPARKLE_PUBLIC_ED_KEY": key}, "arm64")

    def test_rejects_unknown_architecture(self):
        with self.assertRaises(ValueError):
            configure({}, ENVIRONMENT, "universal")


class FeedValidationTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.archive = Path(self.directory.name) / "Freemind-1.2.3-macOS-arm64-update.zip"
        self.feed = Path(self.directory.name) / "appcast-arm64.xml"
        info = plistlib.loads((ROOT / "Resources/Info.plist").read_bytes())
        self.info = configure(info, ENVIRONMENT, "arm64")
        self.write_archive()
        self.tree = ET.fromstring(f'''<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>
            <sparkle:version>1.2.3</sparkle:version>
            <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
            <enclosure url="https://github.com/example/Freemind/releases/download/v1.2.3/{self.archive.name}"
                length="{self.archive.stat().st_size}" sparkle:edSignature="{base64.b64encode(bytes(64)).decode()}" />
            </item></channel></rss>''')

    def write_archive(self):
        with zipfile.ZipFile(self.archive, "w") as zipped:
            zipped.writestr("Freemind.app/Contents/Info.plist", plistlib.dumps(self.info))

    def validate(self):
        ET.ElementTree(self.tree).write(self.feed)
        verify(self.feed, self.archive, "1.2.3", "example/Freemind", PUBLIC_KEY, "arm64")

    def test_accepts_matching_metadata(self):
        # Cryptographic verification is performed by Sparkle in the signing smoke test.
        self.validate()

    def test_rejects_download_from_wrong_tag(self):
        self.tree.find("./channel/item/enclosure").set("url", "https://github.com/example/Freemind/releases/download/v1.0.0/app.zip")
        with self.assertRaises(ValueError):
            self.validate()

    def test_rejects_archive_changed_after_signing(self):
        with self.archive.open("ab") as file:
            file.write(b"unexpected bytes")
        with self.assertRaises(ValueError):
            self.validate()

    def test_rejects_missing_signature(self):
        self.tree.find("./channel/item/enclosure").attrib.pop("{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature")
        with self.assertRaises(ValueError):
            self.validate()

    def test_rejects_wrong_embedded_configuration(self):
        for key, value in (("SUPublicEDKey", base64.b64encode(bytes(32)).decode()),
                           ("SUFeedURL", "https://github.com/example/Freemind/releases/latest/download/appcast-x86_64.xml"),
                           ("CFBundleVersion", "99"), ("SURequireSignedFeed", False)):
            with self.subTest(key=key):
                original = self.info[key]
                self.info[key] = value
                self.write_archive()
                self.tree.find("./channel/item/enclosure").set("length", str(self.archive.stat().st_size))
                with self.assertRaises(ValueError):
                    self.validate()
                self.info[key] = original


if __name__ == "__main__":
    unittest.main()
