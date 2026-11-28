"""Prepare Sparkle metadata for Bookshelf's two stapled drag-to-install disk images."""
import argparse
import hashlib
import os
import plistlib
import re
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from email.utils import format_datetime
from pathlib import Path
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[2]
FEED = ROOT / "Distribution/Updates/appcast.xml"
FEED_URL = "https://raw.githubusercontent.com/MediCoderHZ/Bookshelf/main/Distribution/Updates/appcast.xml"
RELEASES = "https://github.com/MediCoderHZ/Bookshelf/releases"
BUNDLE_ID = "io.github.medicoderhz.bookshelf"
SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
NS = "{" + SPARKLE + "}"
ET.register_namespace("sparkle", SPARKLE)


def output(*args):
    return subprocess.check_output(args, text=True).strip()


def image_info(image, architecture, public_key):
    subprocess.run(["codesign", "--verify", "--strict", image], check=True)
    subprocess.run(["xcrun", "stapler", "validate", image], check=True)
    with tempfile.TemporaryDirectory(prefix="bookshelf-mount-") as directory:
        mount = Path(directory) / "volume"
        mount.mkdir()
        subprocess.run(["hdiutil", "attach", "-readonly", "-nobrowse", "-noautoopen",
                        "-mountpoint", mount, image], check=True)
        try:
            app = mount / "Bookshelf.app"
            info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
            if info.get("CFBundleIdentifier") != BUNDLE_ID or info.get("SUPublicEDKey") != public_key:
                raise ValueError(f"Unexpected bundle identifier or Sparkle public key in {image.name}")
            arch = output("lipo", "-archs", app / "Contents/MacOS/Bookshelf")
            if arch != {"arm64": "arm64", "x64": "x86_64"}[architecture]:
                raise ValueError(f"Unexpected executable architecture {arch} in {image.name}")
            subprocess.run([sys.executable, ROOT / "scripts/check-update-config.py",
                            "--app", app, "--distribution", "--expected-feed", FEED_URL,
                            "--appcast", FEED], check=True)
            version = info["CFBundleShortVersionString"]
            if not re.fullmatch(r"\d+(?:\.\d+){0,2}", version) or image.name != f"Bookshelf-{version}-macos-{architecture}.dmg":
                raise ValueError(f"Disk image filename does not match its version and architecture: {image.name}")
            return version, info["CFBundleVersion"], info["LSMinimumSystemVersion"]
        finally:
            subprocess.run(["hdiutil", "detach", mount], check=True)


def append_release(feed, version, build, minimum_system, packages):
    channel = feed.find("channel")
    if channel is None:
        raise ValueError("Missing RSS channel")
    first = channel.find("item")
    index = len(channel) if first is None else list(channel).index(first)
    published = format_datetime(datetime.now(timezone.utc), usegmt=True)
    # Sparkle 2.10 picks the first compatible item for equal builds. Intel skips
    # the arm64 requirement, and Apple silicon selects it, including under Rosetta.
    for offset, architecture in enumerate(("arm64", "x64")):
        name, signature, length = packages[architecture]
        item = ET.Element("item")
        ET.SubElement(item, "title").text = f"Bookshelf {version}"
        ET.SubElement(item, "link").text = f"{RELEASES}/tag/v{version}"
        ET.SubElement(item, "pubDate").text = published
        ET.SubElement(item, NS + "version").text = build
        ET.SubElement(item, NS + "shortVersionString").text = version
        ET.SubElement(item, NS + "minimumSystemVersion").text = minimum_system
        if architecture == "arm64":
            ET.SubElement(item, NS + "hardwareRequirements").text = architecture
        ET.SubElement(item, "enclosure", {"url": f"{RELEASES}/download/v{version}/{name}",
                      "length": str(length), "type": "application/octet-stream", NS + "edSignature": signature})
        channel.insert(index + offset, item)


def prepare(arm64_image, x64_image, destination):
    if destination.exists():
        raise ValueError(f"Output directory already exists: {destination}")
    tools = Path(os.environ.get("SPARKLE_BIN") or
                 Path(os.environ["BOOKSHELF_BUILD_ROOT"]) / "SwiftPMBuild/artifacts/sparkle/Sparkle/bin")
    account = os.environ.get("BOOKSHELF_SPARKLE_ACCOUNT", BUNDLE_ID)
    public_key = output(tools / "generate_keys", "--account", account, "-p")
    signer = [tools / "sign_update", "--account", account]
    images = {"arm64": arm64_image, "x64": x64_image}
    versions = {image_info(path, arch, public_key) for arch, path in images.items()}
    if len(versions) != 1:
        raise ValueError("Both images must contain the same release, build and minimum system version")
    version, build, minimum_system = versions.pop()
    feed = ET.parse(FEED)
    packages = {}
    checksums = []
    for arch, path in images.items():
        signature = output(*signer, "-p", path)
        subprocess.run([*signer, "--verify", path, signature], check=True)
        packages[arch] = (path.name, signature, path.stat().st_size)
        digest = hashlib.sha256()
        with path.open("rb") as file:
            for chunk in iter(lambda: file.read(1024 * 1024), b""):
                digest.update(chunk)
        checksums.append(f"{digest.hexdigest()}  {path.name}\n")
    append_release(feed, version, build, minimum_system, packages)
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".bookshelf-feed-", dir=destination.parent) as staging:
        result = Path(staging) / "result"
        result.mkdir()
        xml = result / "appcast.xml"
        ET.indent(feed)
        feed.write(xml, encoding="utf-8", xml_declaration=True)
        subprocess.run([*signer, xml], check=True)
        subprocess.run([*signer, "--verify", xml], check=True)
        (result / "SHA256SUMS.txt").write_text("".join(checksums), encoding="utf-8")
        result.rename(destination)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("arm64_image", type=Path)
    parser.add_argument("x64_image", type=Path)
    parser.add_argument("new_output_directory", type=Path)
    args = parser.parse_args()
    try:
        prepare(args.arm64_image.resolve(), args.x64_image.resolve(), args.new_output_directory.resolve())
    except (OSError, KeyError, ValueError, subprocess.CalledProcessError) as exc:
        sys.exit(f"Update preparation failed: {exc}")
