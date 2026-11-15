#!/bin/bash
# Package an already signed/notarized app. Does not upload or publish anything.
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
if [[ $# -ne 2 || "${1:-}" == --help ]]; then
  printf 'Usage: bash scripts/prepare-update.sh /path/to/Bookshelf.app /path/to/new-output-directory\n'
  printf 'Requires a Developer ID-signed, stapled app with updates enabled. Output must not exist.\n'
  if [[ "${1:-}" == --help ]]; then exit 0; else exit 2; fi
fi
app_path="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
output_dir="$2"
if [[ -e "$output_dir" ]]; then
  printf '拒绝覆盖已有发布目录：%s\n' "$output_dir" >&2
  exit 1
fi
if [[ "$(basename "$app_path")" != Bookshelf.app ]]; then
  printf '正式更新包内的应用必须保持 Bookshelf.app 名称。\n' >&2
  exit 1
fi
source "$project_root/scripts/lib/build-environment.sh"
bookshelf_prepare_build_environment
python3 scripts/preflight.py --app "$app_path"
python3 scripts/check-update-config.py --app "$app_path" --distribution --appcast Distribution/Updates/appcast.xml

sparkle_bin="${SPARKLE_BIN:-$BOOKSHELF_BUILD_ROOT/SwiftPMBuild/artifacts/sparkle/Sparkle/bin}"
for tool in generate_keys generate_appcast sign_update; do
  if [[ ! -x "$sparkle_bin/$tool" ]]; then
    printf '缺少 Sparkle 工具 %s；请先运行 verify-project.sh，或设置 SPARKLE_BIN。\n' "$tool" >&2
    exit 1
  fi
done
key_account="${BOOKSHELF_SPARKLE_ACCOUNT:-io.github.medicoderhz.bookshelf}"
public_key="$("$sparkle_bin/generate_keys" --account "$key_account" -p)"
embedded_key="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$app_path/Contents/Info.plist")"
if [[ "$public_key" != "$embedded_key" ]]; then
  printf '钥匙串中的签名密钥与应用公钥不匹配，停止打包。\n' >&2
  exit 1
fi
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_path/Contents/Info.plist")"
build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app_path/Contents/Info.plist")"
archive_name="Bookshelf-$version-$build.zip"
download_prefix="https://github.com/MediCoderHZ/Bookshelf/releases/download/v$version/"
mkdir -p "$(dirname "$output_dir")"
staging_dir="$(mktemp -d "$(dirname "$output_dir")/.bookshelf-release.XXXXXX")"
trap 'rm -rf "$staging_dir"' EXIT
ditto -c -k --sequesterRsrc --keepParent "$app_path" "$staging_dir/$archive_name"
cp Distribution/Updates/appcast.xml "$staging_dir/appcast.xml"
"$sparkle_bin/generate_appcast" --account "$key_account" \
  --download-url-prefix "$download_prefix" --versions "$build" \
  --maximum-versions 0 --maximum-deltas 0 \
  --link "https://github.com/MediCoderHZ/Bookshelf/releases/tag/v$version" "$staging_dir"
signature="$(python3 - "$staging_dir/appcast.xml" "$download_prefix$archive_name" "$build" <<'PY'
import sys
import xml.etree.ElementTree as E
root = E.parse(sys.argv[1]).getroot()
ns = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
items = [i for i in root.findall('./channel/item') if i.findtext(ns + 'version') == sys.argv[3]
         or (i.find('enclosure') is not None and i.find('enclosure').get(ns + 'version') == sys.argv[3])]
if len(items) != 1:
    raise SystemExit('未生成唯一的当前构建更新条目')
enclosure = items[0].find('enclosure')
if enclosure is None or enclosure.get('url') != sys.argv[2] or not enclosure.get(ns + 'edSignature'):
    raise SystemExit('更新包下载地址或签名无效')
print(enclosure.get(ns + 'edSignature'))
PY
)"
"$sparkle_bin/sign_update" --account "$key_account" --verify "$staging_dir/$archive_name" "$signature"
(cd "$staging_dir" && shasum -a 256 "$archive_name" > SHA256SUMS.txt)
mv "$staging_dir" "$output_dir"
trap - EXIT
printf '已准备并验证：%s\n' "$output_dir"
printf '先上传 ZIP 和 SHA256SUMS.txt 到 v%s 的 GitHub Release，再发布 appcast.xml。\n' "$version"
