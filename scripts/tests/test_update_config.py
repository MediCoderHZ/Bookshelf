import base64
import importlib.util
import unittest
import tempfile
from pathlib import Path

spec = importlib.util.spec_from_file_location("update_config", Path(__file__).resolve().parents[1] / "check-update-config.py")
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)


class DistributionConfigurationTests(unittest.TestCase):
    def setUp(self):
        self.info = {
            "BookshelfUpdatesEnabled": "YES",
            "SUFeedURL": "https://raw.githubusercontent.com/MediCoderHZ/Bookshelf/main/Distribution/Updates/appcast.xml",
            "SUPublicEDKey": base64.b64encode(bytes(range(32))).decode(),
            "SUEnableInstallerLauncherService": True,
            "SUEnableSystemProfiling": False,
            "SUVerifyUpdateBeforeExtraction": True,
        }

    def test_complete_configuration_passes(self):
        self.assertEqual(checker.configuration_errors(self.info, True), [])

    def test_disabled_updates_are_allowed_only_for_development(self):
        self.info["BookshelfUpdatesEnabled"] = "NO"
        self.assertEqual(checker.configuration_errors(self.info), [])
        self.assertTrue(checker.configuration_errors(self.info, True))

    def test_default_release_requires_enabled_updates_at_expected_feed(self):
        expected = self.info["SUFeedURL"]
        self.assertEqual(checker.configuration_errors(self.info, expected_feed=expected), [])
        for change in ({"BookshelfUpdatesEnabled": "NO"}, {"SUFeedURL": "https://updates.test/another.xml"}):
            with self.subTest(change=change):
                self.assertTrue(checker.configuration_errors(dict(self.info, **change), expected_feed=expected))

    def test_bad_urls_cannot_be_distributed(self):
        for url in ("http://updates.test/feed", "https://user:secret@updates.test/feed",
                    "$(FEED)", "https://REPLACE_OWNER.github.io/feed", "https:///feed",
                    "https://[", "https://example.com/feed", "https://updates.test/feed#fragment"):
            with self.subTest(url=url):
                self.info["SUFeedURL"] = url
                self.assertTrue(checker.configuration_errors(self.info, True))

    def test_bad_keys_cannot_be_distributed(self):
        for key in ("", "REPLACE_PUBLIC_KEY", "not base64", base64.b64encode(bytes(31)).decode()):
            with self.subTest(key=key):
                self.info["SUPublicEDKey"] = key
                self.assertTrue(checker.configuration_errors(self.info, True))

    def test_sandbox_and_signature_checks_cannot_be_removed(self):
        for key in ("SUEnableInstallerLauncherService", "SUVerifyUpdateBeforeExtraction"):
            with self.subTest(key=key):
                changed = dict(self.info, **{key: False})
                self.assertTrue(checker.configuration_errors(changed, True))

    def test_profile_upload_and_unnecessary_downloader_are_rejected(self):
        for key in ("SUEnableSystemProfiling", "SUEnableDownloaderService"):
            with self.subTest(key=key):
                self.assertTrue(checker.configuration_errors(dict(self.info, **{key: True}), True))

    def test_update_build_number_must_increase(self):
        with tempfile.TemporaryDirectory() as directory:
            feed = Path(directory) / "appcast.xml"
            feed.write_text('<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">'
                            '<channel><item><sparkle:version>2</sparkle:version></item></channel></rss>')
            for value in ("1", "2", "2.0"):
                self.assertTrue(checker.new_build_errors({"CFBundleVersion": value}, feed))
            self.assertEqual(checker.new_build_errors({"CFBundleVersion": "3"}, feed), [])

    def test_legacy_enclosure_version_and_empty_feed(self):
        with tempfile.TemporaryDirectory() as directory:
            feed = Path(directory) / "appcast.xml"
            feed.write_text('<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">'
                            '<channel><item><enclosure sparkle:version="10" /></item></channel></rss>')
            self.assertTrue(checker.new_build_errors({"CFBundleVersion": "9"}, feed))
            feed.write_text('<rss><channel /></rss>')
            self.assertEqual(checker.new_build_errors({"CFBundleVersion": "1"}, feed), [])
