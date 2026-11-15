#!/usr/bin/env python3
"""Validate built update settings; --distribution also requires Developer ID and notarization."""
import argparse
import base64
import binascii
import plistlib
import re
import subprocess
import xml.etree.ElementTree as ET
from pathlib import Path
from urllib.parse import urlsplit


def configuration_errors(info, require_enabled=False):
    errors = []
    if require_enabled and info.get("BookshelfUpdatesEnabled") != "YES":
        errors.append("正式发行包尚未启用在线更新（BookshelfUpdatesEnabled != YES）")
    feed = info.get("SUFeedURL", "")
    try:
        url = urlsplit(feed)
        if (url.scheme != "https" or not url.hostname or url.hostname == "example.com"
                or url.username is not None or url.password is not None or url.fragment
                or "replace" in feed.lower() or "$(" in feed):
            errors.append("SUFeedURL 必须是无凭据、无占位符的 HTTPS 更新清单地址")
    except (TypeError, ValueError):
        errors.append("SUFeedURL 无效")
    key = info.get("SUPublicEDKey", "")
    try:
        raw = base64.b64decode(key, validate=True)
        if len(raw) != 32 or base64.b64encode(raw).decode() != key:
            errors.append("SUPublicEDKey 必须是 32 字节 Ed25519 公钥的标准 Base64")
    except (ValueError, TypeError, binascii.Error):
        errors.append("SUPublicEDKey 无效")
    for name, expected in (("SUEnableInstallerLauncherService", True),
                           ("SUEnableSystemProfiling", False),
                           ("SUVerifyUpdateBeforeExtraction", True)):
        if info.get(name) is not expected:
            errors.append(f"{name} 必须为 {expected}")
    if info.get("SUEnableDownloaderService"):
        errors.append("已有 network.client 权限，不应额外启用 Downloader 服务")
    return errors


def inspect_app(app, distribution=False):
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    errors = configuration_errors(info, require_enabled=distribution)
    for relative in ("Contents/Frameworks/Sparkle.framework/Sparkle",
                     "Contents/Frameworks/Sparkle.framework/XPCServices/Installer.xpc/Contents/MacOS/Installer",
                     "Contents/Resources/ThirdPartyNotices.txt"):
        if not (app / relative).is_file():
            errors.append(f"应用缺少 {relative}")
    if not distribution:
        return errors
    bundle_id = info.get("CFBundleIdentifier", "")
    if (not re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+){2,}", bundle_id)
            or bundle_id.startswith("com.example.") or bundle_id.endswith(".debug")):
        errors.append("正式发行必须使用稳定且非调试用的 Bundle Identifier")
    signature = subprocess.run(["codesign", "-dv", "--verbose=4", str(app)], capture_output=True, text=True)
    details = signature.stdout + signature.stderr
    if "Authority=Developer ID Application:" not in details or "Signature=adhoc" in details:
        errors.append("正式发行需要 Developer ID Application 签名，不能使用临时签名")
    if not re.search(r"flags=.*\bruntime\b", details):
        errors.append("正式发行必须启用 Hardened Runtime")
    verified = subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], capture_output=True)
    if verified.returncode:
        errors.append("应用或嵌套框架签名验证失败")
    signed = subprocess.run(["codesign", "-d", "--entitlements", ":-", str(app)], capture_output=True)
    payload = signed.stdout + signed.stderr
    start, end = payload.find(b"<?xml"), payload.find(b"</plist>")
    if start >= 0 and end > start:
        entitlements = plistlib.loads(payload[start:end + len(b"</plist>")])
        if entitlements.get("com.apple.security.app-sandbox") is not True:
            errors.append("实际签名缺少 App Sandbox")
        if entitlements.get("com.apple.security.network.client") is not True:
            errors.append("实际签名缺少主动网络访问权限")
        if set(entitlements.get("com.apple.security.temporary-exception.mach-lookup.global-name", [])) != {
                bundle_id + "-spks", bundle_id + "-spki"}:
            errors.append("实际签名的 Sparkle 沙盒通信权限不匹配")
        if (entitlements.get("com.apple.security.get-task-allow")
                or entitlements.get("com.apple.security.cs.disable-library-validation")):
            errors.append("正式发行不能保留调试或关闭库验证权限")
    else:
        errors.append("无法读取应用实际签名权限")
    notarized = subprocess.run(["xcrun", "stapler", "validate", str(app)], capture_output=True)
    if notarized.returncode:
        errors.append("应用没有有效的已装订公证票据；请完成公证并运行 xcrun stapler staple")
    return errors


def new_build_errors(info, feed_path):
    """Never publish a replacement or downgrade under an existing build number."""
    namespace = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"

    def parts(value):
        if not re.fullmatch(r"\d+(\.\d+){0,2}", value):
            raise ValueError(f"构建号必须由 1 至 3 段数字组成：{value}")
        result = tuple(int(p) for p in value.split("."))
        return result + (0,) * (3 - len(result))

    new_version = parts(info.get("CFBundleVersion", ""))
    for item in ET.parse(feed_path).getroot().findall("./channel/item"):
        enclosure = item.find("enclosure")
        value = item.findtext(namespace + "version")
        if value is None and enclosure is not None:
            value = enclosure.get(namespace + "version")
        if value is None:
            return ["现有更新清单包含缺少构建号的条目，请先检查清单"]
        if new_version <= parts(value):
            return [f"新构建号必须高于现有更新清单中的 {value}，不能覆盖或降级"]
    return []


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--distribution", action="store_true")
    parser.add_argument("--appcast", type=Path, help="Also require a build newer than every entry in this feed")
    args = parser.parse_args()
    try:
        errors = inspect_app(args.app.resolve(), args.distribution)
        if args.appcast:
            info = plistlib.loads((args.app / "Contents/Info.plist").read_bytes())
            errors += new_build_errors(info, args.appcast)
    except (OSError, ValueError, plistlib.InvalidFileException, ET.ParseError) as exc:
        errors = [str(exc)]
    for message in errors:
        print("FAIL:", message)
    if errors:
        raise SystemExit(1)
    print("正式分发检查通过。" if args.distribution else "Sparkle 配置和嵌入检查通过（不代表更新服务已发布）。")


if __name__ == "__main__":
    main()
