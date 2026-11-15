#!/bin/bash
# Maintain one local application identity and installation path. Never opens an app.
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
if [[ "${1:-}" == --help ]]; then
  printf 'Usage: bash scripts/install-local.sh [--app /path/to/Bookshelf.app]\n'
  printf 'Builds (unless --app is supplied), locally signs, and installs ~/Applications/Bookshelf.app. Quit Bookshelf first.\n'
  exit 0
fi
source "$project_root/scripts/lib/build-environment.sh"
bookshelf_prepare_build_environment
if [[ $# -eq 0 ]]; then
  bash scripts/build-release.sh
  app_path="${BOOKSHELF_DERIVED_DATA:-$BOOKSHELF_BUILD_ROOT/ReleaseCheck}/Build/Products/Release/Bookshelf.app"
elif [[ $# -eq 2 && "$1" == --app ]]; then
  app_path="$2"
else
  printf 'Invalid arguments. Use --help.\n' >&2
  exit 2
fi
python3 scripts/preflight.py --app "$app_path"
python3 - "$app_path" "$project_root" "$BOOKSHELF_BUILD_ROOT" <<'PY'
from pathlib import Path
import datetime
import plistlib
import shutil
import subprocess
import sys
import tempfile

source, project, build_root = map(Path, sys.argv[1:])
bundle_id = 'io.github.medicoderhz.bookshelf'
destination = Path.home() / 'Applications/Bookshelf.app'
info = plistlib.loads((source / 'Contents/Info.plist').read_bytes())
if info.get('CFBundleIdentifier') != bundle_id:
    raise SystemExit('Refusing a validation/debug identity. Build the standard Release configuration.')
if destination.exists():
    installed = plistlib.loads((destination / 'Contents/Info.plist').read_bytes())
    if installed.get('CFBundleIdentifier') != bundle_id:
        raise SystemExit('The destination belongs to a different application; it was not changed.')
    executable = destination / 'Contents/MacOS' / installed['CFBundleExecutable']
    running = subprocess.run(['/usr/sbin/lsof', '-t', str(executable)], capture_output=True, text=True)
    if running.stdout.strip():
        raise SystemExit('Quit the installed Bookshelf before replacing it. Your library was not changed.')

library_support = Path.home() / 'Library/Containers' / bundle_id / 'Data/Library/Application Support'
previous_info = installed if destination.exists() else info
subprocess.run([sys.executable, str(project / 'scripts/lib/backup_local_library.py'),
                '--store', str(library_support / 'default.store'),
                '--output', str(library_support / 'Bookshelf/Backups'),
                '--version', f"{previous_info.get('CFBundleShortVersionString', '')} ({previous_info.get('CFBundleVersion', '')})"], check=True)

with tempfile.TemporaryDirectory(prefix='Bookshelf-local-', dir=build_root) as staging:
    staging = Path(staging)
    app = staging / 'Bookshelf.app'
    subprocess.run(['ditto', str(source), str(app)], check=True)
    framework = app / 'Contents/Frameworks/Sparkle.framework'
    version = framework / 'Versions/Current'
    for target in (version / 'Autoupdate', version / 'Updater.app',
                   version / 'XPCServices/Downloader.xpc', version / 'XPCServices/Installer.xpc', framework):
        subprocess.run(['codesign', '--force', '--sign', '-', '--options', '0',
                        '--preserve-metadata=entitlements', str(target)], check=True)
    entitlements = plistlib.loads((project / 'Bookshelf/Support/Bookshelf.entitlements').read_bytes())
    entitlements['com.apple.security.temporary-exception.mach-lookup.global-name'] = [bundle_id + '-spks', bundle_id + '-spki']
    entitlements_path = staging / 'local.entitlements'
    entitlements_path.write_bytes(plistlib.dumps(entitlements))
    # Local launch only; the original hardened Release product remains unchanged.
    subprocess.run(['codesign', '--force', '--sign', '-', '--options', '0',
                    '--entitlements', str(entitlements_path), str(app)], check=True)
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    destination.parent.mkdir(parents=True, exist_ok=True)
    backup = None
    if destination.exists():
        backup_dir = project / 'work/LocalAppBackups' / datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f')
        backup_dir.mkdir(parents=True)
        backup = backup_dir / 'Bookshelf.app'
        shutil.move(str(destination), str(backup))
    try:
        subprocess.run(['ditto', str(app), str(destination)], check=True)
        subprocess.run(['codesign', '--verify', '--deep', '--strict', str(destination)], check=True)
    except Exception:
        if destination.exists():
            shutil.rmtree(destination)
        if backup:
            shutil.move(str(backup), str(destination))
        raise
print(f'Installed local application: {destination}')
print(f'Stable data identity: {bundle_id}')
print('The library was not modified. This local signature is not for public distribution.')
PY
