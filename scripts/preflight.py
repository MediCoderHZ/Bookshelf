#!/usr/bin/env python3
"""Read-only checks. --submission also checks decisions/signing, not App Review."""
import argparse
import json
import plistlib
import re
import struct
import subprocess
from pathlib import Path
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument("--app", type=Path, help="Built .app to inspect")
parser.add_argument("--submission", action="store_true")
args = parser.parse_args()
errors, pending = [], []

def check(condition, message):
    if not condition:
        errors.append(message)

def load_plist(path):
    with path.open("rb") as handle:
        return plistlib.load(handle)

def public_url(value):
    parsed = urlparse(value)
    return (parsed.scheme == "https" and parsed.hostname and not parsed.username
            and not any(s in value.lower() for s in ("replace", "example.", "localhost", "$(")))

def real_value(value):
    return bool(value and not any(s in value.lower() for s in ("replace", "待定", "$(")))

try:
    entitlements = load_plist(ROOT / "Bookshelf/Support/Bookshelf.entitlements")
    check(entitlements.get("com.apple.security.app-sandbox") is True, "App Sandbox 未开启")
    check(entitlements.get("com.apple.security.network.client") is True, "缺少主动网络访问权限")
    check(entitlements.get("com.apple.security.files.user-selected.read-write") is True, "缺少用户所选文件访问权限")
    check(entitlements.get("com.apple.security.files.bookmarks.app-scope") is True, "缺少自定义数据目录的持久访问权限")
    check(set(entitlements) == {
        "com.apple.security.app-sandbox", "com.apple.security.network.client",
        "com.apple.security.files.user-selected.read-write",
        "com.apple.security.files.bookmarks.app-scope",
        "com.apple.security.temporary-exception.mach-lookup.global-name"}, "出现未预期的沙盒权限")
    check(entitlements.get("com.apple.security.temporary-exception.mach-lookup.global-name") == [
        "$(PRODUCT_BUNDLE_IDENTIFIER)-spks", "$(PRODUCT_BUNDLE_IDENTIFIER)-spki"],
        "Sparkle 安装服务的沙盒通信权限不匹配")
    privacy_path = ROOT / "Bookshelf/Resources/PrivacyInfo.xcprivacy"
    privacy = load_plist(privacy_path)
    check(privacy.get("NSPrivacyTracking") is False, "跟踪声明与当前设计不一致")
    check(privacy.get("NSPrivacyTrackingDomains") == [], "出现了新的跟踪域名")
    check(any(item.get("NSPrivacyAccessedAPIType") == "NSPrivacyAccessedAPICategoryUserDefaults"
              and "CA92.1" in item.get("NSPrivacyAccessedAPITypeReasons", [])
              for item in privacy.get("NSPrivacyAccessedAPITypes", [])),
          "缺少应用内偏好设置的 UserDefaults 使用理由")
    icon_dir = ROOT / "Bookshelf/Resources/Assets.xcassets/AppIcon.appiconset"
    icons = json.loads((icon_dir / "Contents.json").read_text())
    expected = {(size, scale) for size in (16, 32, 128, 256, 512) for scale in (1, 2)}
    actual = set()
    for item in icons["images"]:
        size = int(item["size"].split("x")[0])
        scale = int(item["scale"][:-1])
        actual.add((size, scale))
        image = (icon_dir / item["filename"]).read_bytes()
        check(image[:8] == b"\x89PNG\r\n\x1a\n", "AppIcon 不是 PNG")
        check(struct.unpack(">II", image[16:24]) == (size * scale, size * scale),
              "AppIcon 像素尺寸不匹配：" + item["filename"])
    check(expected <= actual, "AppIcon 尺寸集不完整")
    # Historical App Store material is not a requirement for GitHub distribution.
    if args.submission:
        metadata = json.loads((ROOT / "AppStore/metadata.zh-Hans.json").read_text())
        for key, maximum in {"name": 30, "subtitle": 30, "promotionalText": 170,
                             "description": 4000, "keywords": 100}.items():
            check(bool(metadata.get(key)) and len(metadata[key]) <= maximum,
                  f"商店文案 {key} 为空或超长")
        check(len(metadata["keywords"].encode("utf-8")) <= 100, "关键词超过保守的 100 字节限制")
        checklist = json.loads((ROOT / "AppStore/submission-checklist.json").read_text())
        for key, item in checklist.items():
            if item["confirmed"] is not True:
                pending.append(item["description"])

    if args.app:
        app = args.app.resolve()
        info = load_plist(app / "Contents/Info.plist")
        check((app / "Contents/Resources/AppIcon.icns").is_file(), "产物缺少编译后的图标")
        embedded = load_plist(app / "Contents/Resources/PrivacyInfo.xcprivacy")
        check(embedded == privacy, "产物缺少或使用了旧版隐私清单")
        framework = app / "Contents/Frameworks/Sparkle.framework"
        check((framework / "Sparkle").is_file(), "产物缺少 Sparkle.framework")
        check((framework / "XPCServices/Installer.xpc").is_dir(), "缺少 Sparkle 沙盒安装服务")
        check((app / "Contents/Resources/ThirdPartyNotices.txt").is_file(), "缺少第三方许可声明")
        check((app / "Contents/Resources/relaunch.sh").is_file(), "缺少自动重启组件")
        check((app / "Contents/Resources/reading-notes.json").is_file(), "缺少阅读笔记示例插件")
        for name in ("douban-books", "goodreads-books", "open-library"):
            script = Path("Translators") / (name + ".js")
            source = ROOT / "Bookshelf/Resources" / script
            bundled = app / "Contents/Resources" / script
            check(bundled.is_file() and bundled.read_bytes() == source.read_bytes(), "产物缺少或使用了旧版解析器：" + name)
        for language in ("zh-Hans", "en"):
            check((app / "Contents/Resources" / (language + ".lproj") / "Localizable.strings").is_file(),
                  "产物缺少界面语言资源：" + language)
            check((app / "Contents/Resources" / (language + ".lproj") / "InfoPlist.strings").is_file(),
                  "产物缺少本地化应用名称：" + language)
        check(info.get("SUEnableInstallerLauncherService") is True, "未启用 Sparkle 沙盒安装服务")
        check(info.get("SUEnableSystemProfiling") is False, "更新系统分析必须默认关闭")
        check(info.get("SUVerifyUpdateBeforeExtraction") is True, "更新包必须在解压前验证签名")
        check(info.get("LSMinimumSystemVersion") == "14.0", "最低系统版本发生变化，需更新文案")
        check(bool(re.fullmatch(r"\d+\.\d+(\.\d+)?", info.get("CFBundleShortVersionString", ""))), "版本号无效")
        check(bool(re.fullmatch(r"\d+(\.\d+){0,2}", info.get("CFBundleVersion", ""))), "构建号无效")
        executable = app / "Contents/MacOS" / info["CFBundleExecutable"]
        arches = subprocess.check_output(["lipo", "-archs", str(executable)], text=True).strip()
        check({"arm64", "x86_64"} <= set(arches.split()), "Release 产物不是双架构")
        print("架构:", arches)
        print("版本:", info.get("CFBundleShortVersionString"), "构建:", info.get("CFBundleVersion"))
        bundle_id = info.get("CFBundleIdentifier", "")
        if bundle_id.startswith("com.example.") or not real_value(bundle_id):
            pending.append("替换占位 Bundle ID，并在开发者账号中注册")
        for key, label in (("BookshelfSupportURL", "配置公开支持网址"),
                           ("BookshelfPrivacyURL", "配置公开隐私政策网址")):
            if not public_url(info.get(key, "")):
                pending.append(label)
        copyright_text = info.get("NSHumanReadableCopyright", "")
        if not real_value(copyright_text) or copyright_text == "Copyright © 2026. All rights reserved.":
            pending.append("补齐版权主体")
        contact = info.get("BookshelfMetadataContact", "")
        if not real_value(contact) or not re.fullmatch(r"[^@\s]+@[^@\s]+\.[^@\s]+", contact):
            pending.append("配置 Open Library 请求中的开发者联系邮箱")
        if args.submission:
            result = subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)],
                                    capture_output=True, text=True)
            check(result.returncode == 0, "签名验证失败")
            signature = subprocess.run(["codesign", "-dv", "--verbose=4", str(app)],
                                       capture_output=True, text=True)
            details = signature.stderr + signature.stdout
            check("Signature=adhoc" not in details and "TeamIdentifier=not set" not in details,
                  "临时签名不能用于商店提交")
            check("Authority=Apple Distribution:" in details
                  or "Authority=3rd Party Mac Developer Application:" in details,
                  "未检测到 Mac App Store 分发签名")
            signed = subprocess.run(["codesign", "-d", "--entitlements", ":-", str(app)],
                                    capture_output=True)
            start = signed.stdout.find(b"<?xml")
            if start >= 0:
                signed_plist = plistlib.loads(signed.stdout[start:])
                check(signed_plist.get("com.apple.security.app-sandbox") is True, "实际签名未包含沙盒权限")
                check(not signed_plist.get("com.apple.security.get-task-allow"), "分发包允许调试")
            else:
                errors.append("未能读取实际签名权限")
    elif args.submission:
        errors.append("--submission 必须传入待提交的 --app")
except (OSError, ValueError, KeyError, subprocess.SubprocessError, plistlib.InvalidFileException) as exc:
    errors.append(str(exc))

for message in errors:
    print("FAIL:", message)
for message in dict.fromkeys(pending):
    print("待办:", message)
if errors or (args.submission and pending):
    print("技术检查未通过。")
    raise SystemExit(1)
print("本地技术检查通过；正式 GitHub 分发另需运行 check-update-config.py --distribution。")
