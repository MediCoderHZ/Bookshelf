import importlib.util
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("local_backup", Path(__file__).resolve().parents[1] / "lib/backup_local_library.py")
backup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(backup)


class LocalUpgradeBackupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / "default.store"
        self.output = self.root / "Backups"
        self.db = sqlite3.connect(self.source)
        self.addCleanup(self.db.close)
        self.db.executescript("PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; CREATE TABLE notes(body TEXT); INSERT INTO notes VALUES('newest');")
        self.db.commit()

    def test_snapshot_includes_wal_and_preserves_source_and_recovery(self):
        draft = self.root / "Bookshelf/NoteDraftRecovery/test.json"
        draft.parent.mkdir(parents=True)
        draft.write_text('{"body":"unsaved"}')
        path = backup.create_backup(self.source, self.output, "0.1.0 (1)")
        with sqlite3.connect(path / "default.store") as restored:
            self.assertEqual(restored.execute("SELECT body FROM notes").fetchall(), [("newest",)])
        self.assertEqual(self.db.execute("SELECT body FROM notes").fetchall(), [("newest",)])
        self.assertEqual((path / "Recovery/NoteDraftRecovery/test.json").read_bytes(), draft.read_bytes())
        self.assertEqual(backup.validate(path)["kind"], "beforeUpdate")

    def test_corrupt_source_stops_install_and_preserves_previous_backup(self):
        old = backup.create_backup(self.source, self.output, "1")
        broken = self.root / "broken.store"
        broken.write_bytes(b"not sqlite")
        with self.assertRaises(sqlite3.DatabaseError):
            backup.create_backup(broken, self.output, "2")
        self.assertTrue(old.exists())
        self.assertFalse(list(self.output.glob(".pending-*")))

    def test_unwritable_destination_fails_before_install(self):
        self.output.write_text("blocker")
        with self.assertRaises(OSError):
            backup.create_backup(self.source, self.output, "1")
        self.assertEqual(self.db.execute("SELECT COUNT(*) FROM notes").fetchone()[0], 1)

    def test_upgrade_retention_preserves_regular_and_unknown_data(self):
        for i in range(12):
            backup.create_backup(self.source, self.output, "1", now=i)
        self.assertEqual(len(list(self.output.glob("Bookshelf-*"))), 10)
        regular = backup.create_backup(self.source, self.output, "1", now=20)
        manifest = json.loads((regular / "manifest.json").read_text())
        manifest["kind"] = "scheduled"
        (regular / "manifest.json").write_text(json.dumps(manifest))
        unknown = self.output / "Bookshelf-unrecognized"
        unknown.mkdir(); (unknown / "important.txt").write_text("keep")
        backup.prune_upgrades(self.output, limit=1)
        self.assertTrue(regular.exists()); self.assertTrue(unknown.exists())
        self.assertEqual(len(list(self.output.glob("Bookshelf-*"))), 3)

    def test_checksum_and_path_traversal_are_rejected(self):
        path = backup.create_backup(self.source, self.output, "1")
        original = (path / "manifest.json").read_text()
        manifest = json.loads(original)
        manifest["files"]["../default.store"] = "anything"
        (path / "manifest.json").write_text(json.dumps(manifest))
        with self.assertRaises(ValueError):
            backup.validate(path)
        (path / "manifest.json").write_text(original)
        (path / "default.store").write_bytes(b"tampered")
        with self.assertRaises(ValueError):
            backup.validate(path)
        backup.prune_upgrades(self.output, limit=1)
        self.assertTrue(path.exists())

    def test_fresh_install_does_not_create_empty_fake_backup(self):
        self.assertIsNone(backup.create_backup(self.root / "missing.store", self.output, "1"))
        self.assertFalse(self.output.exists())

    def test_custom_location_is_backed_up_and_recovery_stays_in_app_support(self):
        custom = self.root / "Custom"
        custom.mkdir()
        source = custom / "default.store"
        with sqlite3.connect(source) as db:
            db.execute("CREATE TABLE notes(body TEXT)")
            db.execute("INSERT INTO notes VALUES('custom newest')")
        config = self.root / "LibraryLocation.json"
        config.write_text(json.dumps({"formatVersion": 1, "active": {"path": str(custom)}, "pending": {"path": "ignored"}}))
        selected = backup.configured_store(self.source, config)
        self.assertEqual(selected, source)
        recovery = self.root / "AppSupport"
        draft = recovery / "NoteDraftRecovery/draft.json"
        draft.parent.mkdir(parents=True)
        draft.write_text('{"body":"unsaved"}')
        snapshot = backup.create_backup(selected, self.output, "2", recovery_root=recovery)
        with sqlite3.connect(snapshot / "default.store") as db:
            self.assertEqual(db.execute("SELECT body FROM notes").fetchall(), [("custom newest",)])
        self.assertEqual((snapshot / "Recovery/NoteDraftRecovery/draft.json").read_bytes(), draft.read_bytes())

    def test_missing_custom_library_or_bad_config_never_falls_back(self):
        config = self.root / "LibraryLocation.json"
        self.assertEqual(backup.configured_store(self.source, config), self.source)
        config.write_text(json.dumps({"formatVersion": 1, "pending": {"path": "pending only"}}))
        self.assertEqual(backup.configured_store(self.source, config), self.source)
        for value in [{"formatVersion": 1, "active": {"path": str(self.root / "missing")}}, {"formatVersion": 1, "active": {"path": "relative"}}, {"formatVersion": 2}]:
            config.write_text(json.dumps(value))
            with self.assertRaises(ValueError):
                backup.configured_store(self.source, config)
        config.write_text(json.dumps({"formatVersion": 1, "initialized": True}))
        with self.assertRaises(ValueError):
            backup.configured_store(self.root / "missing-default.store", config)
