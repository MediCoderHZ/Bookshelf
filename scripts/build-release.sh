#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
python3 scripts/check-architecture.py
source "$project_root/scripts/lib/build-environment.sh"
bookshelf_prepare_build_environment
derived_data="${BOOKSHELF_DERIVED_DATA:-$BOOKSHELF_BUILD_ROOT/ReleaseCheck}"
# Local verification only: no login, signing, upload, or distribution.
xcodebuild -quiet -project Bookshelf.xcodeproj -scheme Bookshelf \
  -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath "$derived_data" \
  ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO build
app_path="$derived_data/Build/Products/Release/Bookshelf.app"
python3 scripts/preflight.py --app "$app_path"
printf '已生成本地未签名应用：%s\n' "$app_path"
