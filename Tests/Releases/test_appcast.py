import base64
import importlib.util
import pathlib
import plistlib
import tempfile
import unittest
import xml.etree.ElementTree as ET

ROOT = pathlib.Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("appcast", ROOT / "scripts/appcast.py")
appcast = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(appcast)


class AppcastTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.feed = pathlib.Path(self.directory.name) / "appcast.xml"
        self.feed.write_text('<rss version="2.0"><channel><title>Watt</title></channel></rss>')
        self.signature = base64.b64encode(bytes(range(64))).decode()

    def add(self, build="6", version="1.0.1"):
        appcast.add_release(self.feed, version, build,
            f"https://github.com/grahamgilbert/watt/releases/download/v{version}/Watt-{version}.dmg",
            f'sparkle:edSignature="{self.signature}" length="12345"')

    def test_feed_keeps_marketing_version_and_monotonic_build_separate(self):
        self.add()
        item = ET.parse(self.feed).find("channel/item")
        self.assertEqual(item.findtext(f"{{{appcast.SPARKLE}}}version"), "6")
        self.assertEqual(item.findtext(f"{{{appcast.SPARKLE}}}shortVersionString"), "1.0.1")
        self.assertEqual(item.findtext(f"{{{appcast.SPARKLE}}}minimumSystemVersion"), "14.0")
        self.assertEqual(item.find("enclosure").get(f"{{{appcast.SPARKLE}}}edSignature"), self.signature)

    def test_retry_does_not_duplicate_the_release_and_older_builds_are_rejected(self):
        self.add()
        self.add()
        self.assertEqual(len(ET.parse(self.feed).findall("channel/item")), 1)
        with self.assertRaises(ValueError):
            self.add(build="5", version="1.0.2")

    def test_promotion_preserves_the_original_archive_signature(self):
        self.add()
        stable = pathlib.Path(self.directory.name) / "stable.xml"
        stable.write_text('<rss version="2.0"><channel><title>Stable</title></channel></rss>')
        appcast.promote(self.feed, stable, "1.0.1")
        appcast.promote(self.feed, stable, "1.0.1")
        items = ET.parse(stable).findall("channel/item")
        self.assertEqual(len(items), 1)
        self.assertEqual(items[0].find("enclosure").get(f"{{{appcast.SPARKLE}}}edSignature"), self.signature)
        with self.assertRaises(ValueError):
            appcast.promote(self.feed, stable, "9.9.9")

    def test_invalid_signatures_are_rejected(self):
        for signature in ['sparkle:edSignature="invalid!" length="10"',
                          f'sparkle:edSignature="{self.signature}" length="0"']:
            with self.assertRaises(ValueError):
                appcast.signature_attributes(signature)

    def test_release_notes_escape_markup(self):
        result = appcast.release_notes('## Changes\n- <script>alert(1)</script>', "1.0.1")
        self.assertNotIn("<script>", result)
        self.assertIn("&lt;script&gt;", result)

    def test_app_requires_signed_feeds_and_checks_hourly(self):
        with (ROOT / "Config/Updates.plist").open("rb") as stream:
            info = plistlib.load(stream)
        self.assertEqual(info["SUScheduledCheckInterval"], 3600)
        self.assertTrue(info["SURequireSignedFeed"])
        self.assertTrue(info["SUVerifyUpdateBeforeExtraction"])
        self.assertEqual(len(base64.b64decode(info["SUPublicEDKey"])), 32)

    def test_promotion_cannot_downgrade_the_stable_channel(self):
        self.add(build="6",version="1.0.1")
        stable=pathlib.Path(self.directory.name)/"stable.xml"
        stable.write_text('<rss version="2.0"><channel><title>Stable</title></channel></rss>')
        appcast.add_release(stable,"1.0.2","7",
            "https://github.com/grahamgilbert/watt/releases/download/v1.0.2/Watt-1.0.2.dmg",
            f'sparkle:edSignature="{self.signature}" length="12345"')
        with self.assertRaises(ValueError):
            appcast.promote(self.feed,stable,"1.0.1")

    def test_notes_use_signed_namespace_and_reject_other_repositories(self):
        args=(self.feed,"1.0.1","6",
              "https://github.com/grahamgilbert/watt/releases/download/v1.0.1/Watt-1.0.1.dmg",
              f'sparkle:edSignature="{self.signature}" length="12345"')
        appcast.add_release(*args,"https://github.com/grahamgilbert/watt/releases/download/v1.0.1/notes.html",self.signature,"42")
        notes=ET.parse(self.feed).find(f"channel/item/{{{appcast.SPARKLE}}}releaseNotesLink")
        self.assertEqual(notes.get(f"{{{appcast.SPARKLE}}}length"),"42")
        with self.assertRaises(ValueError):
            appcast.add_release(*args,"https://example.com/notes.html",self.signature,"42")
