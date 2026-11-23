#!/usr/bin/env python3
"""Create a verified, immutable snapshot before replacing the local application.

Format 1 matches AutomaticBackupManifest in the application. No source database
or recovery draft is modified. A failed backup must abort the caller's install.
"""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import shutil
import sqlite3
import time
import uuid


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def validate(folder):
    if folder.is_symlink() or (folder / "manifest.json").is_symlink():
        raise ValueError("Symbolic-link backup rejected")
    data = json.loads((folder / "manifest.json").read_text())
    if (data.get("formatVersion") != 1 or folder.name != "Bookshelf-" + str(uuid.UUID(data["id"])).upper()
            or not math.isfinite(data["createdAt"]) or not data.get("files")
            or not ({"default.store", "library.json"} & set(data["files"]))):
        raise ValueError("Invalid backup manifest")
    for relative, expected in data["files"].items():
        parts = relative.split("/")
        if any(p in ("", ".", "..") for p in parts):
            raise ValueError("Invalid backup path")
        path = folder
        for part in parts:
            path = path / part
            if path.is_symlink():
                raise ValueError("Symbolic-link backup payload rejected")
        if digest(path) != expected:
            raise ValueError("Backup checksum mismatch")
    return data


def prune_upgrades(directory, limit=10):
    valid = []
    for folder in directory.glob("Bookshelf-*"):
        try:
            data = validate(folder)
            if data["kind"] in ("beforeUpdate", "beforeMigration"):
                valid.append((data["createdAt"], folder.name, folder))
        except (OSError, ValueError, KeyError, TypeError):
            continue  # Never remove unfamiliar or damaged backups.
    for _, _, folder in sorted(valid, reverse=True)[max(1, limit):]:
        validate(folder)
        shutil.rmtree(folder)


def configured_store(default_store, configuration):
    """Use only the committed location. Pending moves still back up the source."""
    if not configuration.exists():
        return default_store
    data = json.loads(configuration.read_text())
    if data.get("formatVersion") != 1:
        raise ValueError("Unsupported library location configuration; installation stopped")
    active = data.get("active")
    if active is None:
        if data.get("initialized") is True and not default_store.is_file():
            raise ValueError("Existing default library is missing; installation stopped")
        return default_store
    if not isinstance(active, dict) or not isinstance(active.get("path"), str) or not Path(active["path"]).is_absolute():
        raise ValueError("Invalid custom data directory; installation stopped")
    source = Path(active["path"]) / "default.store"
    if not source.is_file():
        raise ValueError("Custom library is unavailable; connect its disk and reopen Bookshelf before installing")
    return source


def create_backup(source, directory, version, now=None, recovery_root=None):
    source, directory = Path(source), Path(directory)
    if not source.exists():
        return None
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    identity = str(uuid.uuid4()).upper()
    staging = directory / (".pending-" + identity)
    completed = directory / ("Bookshelf-" + identity)
    staging.mkdir(mode=0o700)
    try:
        started = time.monotonic()
        def progress(status, remaining, total):
            if time.monotonic() - started > 15:
                raise TimeoutError("Database is busy; local installation was stopped")
        src = sqlite3.connect(source.resolve().as_uri() + "?mode=ro", uri=True, timeout=1.5)
        try:
            dst = sqlite3.connect(staging / "default.store")
            try:
                src.backup(dst, pages=256, progress=progress, sleep=0.05)
                if dst.execute("PRAGMA integrity_check").fetchall() != [("ok",)]:
                    raise ValueError("Database integrity check failed")
                dst.execute("PRAGMA journal_mode=DELETE")
            finally:
                dst.close()
        finally:
            src.close()
        files = {"default.store": digest(staging / "default.store")}
        attachments = source.parent / "attachments"
        if attachments.is_symlink():
            raise ValueError("Symbolic-link attachment directory rejected")
        if attachments.exists():
            for obj in attachments.iterdir():
                if obj.name.startswith("."):
                    continue
                uuid.UUID(obj.name)
                if obj.is_symlink() or not obj.is_dir():
                    raise ValueError("Invalid attachment directory")
                for item in obj.rglob("*"):
                    if item.is_symlink():
                        raise ValueError("Symbolic-link attachment rejected")
                    if item.is_dir():
                        continue
                    if not item.is_file():
                        raise ValueError("Invalid attachment file")
                    relative = item.relative_to(source.parent).as_posix()
                    target = staging / relative
                    target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
                    shutil.copyfile(item, target)
                    files[relative] = digest(item)
        for name in ("NoteDraftRecovery", "MetadataDraftRecovery"):
            recovery = (Path(recovery_root) if recovery_root else source.parent / "Bookshelf") / name
            if not recovery.exists():
                continue
            if recovery.is_symlink():
                raise ValueError("Symbolic-link recovery directory rejected")
            for item in recovery.glob("*.json"):
                if item.is_symlink() or not item.is_file():
                    continue
                relative = "Recovery/" + name + "/" + item.name
                target = staging / relative
                target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
                shutil.copyfile(item, target)
                files[relative] = digest(target)
        manifest = {"formatVersion": 1, "id": identity, "createdAt": time.time() if now is None else now,
                    "kind": "beforeUpdate", "appVersion": version, "files": files}
        (staging / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
        for path in staging.rglob("*"):
            if path.is_file():
                path.chmod(0o600)
                with path.open("rb") as handle:
                    os.fsync(handle.fileno())
        # Verify bytes before publishing. The temporary name is the only relaxed invariant.
        for relative, expected in files.items():
            if digest(staging / relative) != expected:
                raise ValueError("Backup checksum mismatch")
        staging.rename(completed)
        validate(completed)
        try:
            prune_upgrades(directory)
        except OSError as error:
            print("Backup succeeded; old-version cleanup deferred:", error)
        return completed
    finally:
        if staging.exists():
            shutil.rmtree(staging)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--store", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--location-config", type=Path)
    parser.add_argument("--recovery-root", type=Path)
    args = parser.parse_args()
    source = configured_store(args.store, args.location_config) if args.location_config else args.store
    result = create_backup(source, args.output, args.version, recovery_root=args.recovery_root)
    print("Verified pre-install library backup:", result if result else "no existing library")
