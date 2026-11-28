import importlib.util
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

spec = importlib.util.spec_from_file_location("dmg_update", Path(__file__).resolve().parents[1] / "lib/prepare_dmg_update.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class DMGAppcastTests(unittest.TestCase):
    def test_equal_builds_select_native_image_and_preserve_older_entries(self):
        feed = ET.fromstring("<rss><channel><title>Bookshelf</title><item><title>Old</title></item></channel></rss>")
        packages = {"x64": ("Bookshelf-0.1.1-macos-x64.dmg", "intel-signature", 200),
                    "arm64": ("Bookshelf-0.1.1-macos-arm64.dmg", "arm-signature", 100)}
        release.append_release(feed, "0.1.1", "10", "14.0", packages)
        items = feed.findall("./channel/item")
        self.assertEqual(len(items), 3)
        self.assertEqual(items[-1].findtext("title"), "Old")
        for arch, arm_capable in [("arm64", True), ("x64", False)]:
            # Mirror SUAppcastDriver's first compatible match for the highest build.
            compatible = [item for item in items if item.findtext(release.NS + "version") == "10"
                          and (arm_capable or item.findtext(release.NS + "hardwareRequirements") is None)]
            selected = compatible[0]
            self.assertEqual(selected.findtext(release.NS + "shortVersionString"), "0.1.1")
            self.assertEqual(selected.findtext(release.NS + "minimumSystemVersion"), "14.0")
            self.assertEqual(selected.findtext(release.NS + "hardwareRequirements"), "arm64" if arm_capable else None)
            self.assertEqual(selected.find("enclosure").attrib, {
                "url": f"{release.RELEASES}/download/v0.1.1/{packages[arch][0]}",
                "length": str(packages[arch][2]), "type": "application/octet-stream",
                release.NS + "edSignature": packages[arch][1]})
