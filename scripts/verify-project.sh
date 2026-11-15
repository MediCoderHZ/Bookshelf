#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"

if [[ "${1:-}" == --help ]]; then
  cat <<'USAGE'
Usage: bash scripts/verify-project.sh [swift test options]
Runs architecture checks, local preflight, and SwiftPM tests.
Requires full Xcode; does not change the global selected toolchain.
Build files and caches default to a project-specific directory in /private/tmp.
Override with BOOKSHELF_BUILD_ROOT. Set DEVELOPER_DIR for a nondefault Xcode.
For an already sandboxed runner, pass --disable-sandbox if manifest execution fails.
Create an unsigned universal .app separately with: bash scripts/build-release.sh
USAGE
  exit 0
fi

python3 scripts/check-architecture.py
python3 scripts/preflight.py
source "$project_root/scripts/lib/build-environment.sh"
bookshelf_prepare_build_environment

xcrun swift test \
  --scratch-path "$BOOKSHELF_BUILD_ROOT/SwiftPMBuild" \
  --cache-path "$BOOKSHELF_BUILD_ROOT/SwiftPMCache" \
  --config-path "$BOOKSHELF_BUILD_ROOT/SwiftPMConfig" \
  --security-path "$BOOKSHELF_BUILD_ROOT/SwiftPMSecurity" \
  "$@"
