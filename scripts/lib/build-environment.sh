#!/bin/bash
# Shared by validation scripts. Keep compiler output off an external source volume.
bookshelf_prepare_build_environment() {
  if [[ -z "${DEVELOPER_DIR:-}" ]]; then
    DEVELOPER_DIR="$(xcode-select -p 2>/dev/null || true)"
    if [[ "$DEVELOPER_DIR" == */CommandLineTools && -d /Applications/Xcode.app/Contents/Developer ]]; then
      DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
    fi
    export DEVELOPER_DIR
  fi

  local xcode_version
  if ! xcode_version="$(xcodebuild -version 2>&1)"; then
    printf '%s\n' "$xcode_version" >&2
    printf '%s\n' \
      '需要完整版 Xcode：本项目使用 SwiftData/SwiftUI 宏、XCTest 和 actool。' \
      '安装并首次打开 Xcode 完成组件设置后重试。若安装在其他位置，可为本次命令指定：' \
      'DEVELOPER_DIR="/path/to/Xcode.app/Contents/Developer" bash scripts/verify-project.sh' >&2
    return 1
  fi

  local first_launch_status
  if ! first_launch_status="$(xcodebuild -checkFirstLaunchStatus 2>&1)"; then
    printf '%s\n' "$first_launch_status" >&2
    printf '%s\n' 'Xcode 已安装，但首次启动尚未完成。请打开 Xcode，查看并接受许可协议，然后完成所需组件安装后重试。' >&2
    return 1
  fi

  local tool
  for tool in swift xctest actool; do
    if ! xcrun --find "$tool" >/dev/null 2>&1; then
      printf '当前 Xcode 缺少 %s，请先打开 Xcode 完成组件安装。\n' "$tool" >&2
      return 1
    fi
  done

  local project_key
  project_key="$(printf '%s' "$project_root" | shasum -a 256 | cut -c 1-12)"
  export BOOKSHELF_BUILD_ROOT="${BOOKSHELF_BUILD_ROOT:-/private/tmp/Bookshelf-$(id -u)-$project_key}"
  mkdir -p "$BOOKSHELF_BUILD_ROOT"
  export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$BOOKSHELF_BUILD_ROOT/ModuleCache}"
  export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$BOOKSHELF_BUILD_ROOT/ModuleCache}"
  printf '%s\n' "$xcode_version" "工具链：$DEVELOPER_DIR" "构建目录：$BOOKSHELF_BUILD_ROOT"
}
