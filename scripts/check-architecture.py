#!/usr/bin/env python3
"""Guard the boundaries of the native, book-focused Zotero-style architecture."""
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[1]
base = root / "Bookshelf"
errors = []
for path in (base / "Views").rglob("*.swift"):
    if re.search(r"(?:modelContext|context)\.(?:save|insert|delete|rollback)\(", path.read_text()):
        errors.append(f"{path.relative_to(root)}: view writes the database directly")
for directory in ["Domain", "Application", "Persistence", "Translation"]:
    for path in (base / directory).rglob("*.swift"):
        text = path.read_text()
        if "import SwiftUI" in text:
            errors.append(f"{path.relative_to(root)}: non-window code imports SwiftUI")
        if directory == "Translation" and "import SwiftData" in text:
            errors.append(f"{path.relative_to(root)}: translator code can access the database")
project = (root / "Bookshelf.xcodeproj/project.pbxproj").read_text()
for path in base.rglob("*.swift"):
    if f"/* {path.name} in Sources */ =" not in project:
        errors.append(f"{path.relative_to(root)}: absent from Xcode Sources")
for path in (base / "Views").rglob("*.swift"):
    if "LibraryHistory.shared" in path.read_text():
        errors.append(f"{path.relative_to(root)}: process-wide undo history")
if errors:
    print("\n".join(errors), file=sys.stderr)
    raise SystemExit(1)
print("Architecture boundaries passed: UI commands, non-window core, database-free translators, Xcode source coverage.")
