#!/usr/bin/env python3
"""Schreibt Sources/KlimacontrolCore/ReleaseNotesData.swift neu aus CHANGELOG.md (eingebetteter Text für „Neu in dieser Version“)."""
import pathlib

root = pathlib.Path(__file__).resolve().parent.parent
text = (root / "CHANGELOG.md").read_text(encoding="utf-8").replace("\r\n", "\n").rstrip("\n")

hashes = 1
while '"""' + "#" * hashes in text or "\\" + "#" * hashes in text:
    hashes += 1
mark = "#" * hashes

out = (
    "// Erzeugt von tools/sync_release_notes.py aus CHANGELOG.md – nicht von Hand ändern.\n"
    "\n"
    "extension ReleaseNotes {\n"
    f'    static let changelog = {mark}"""\n'
    f"{text}\n"
    f'"""{mark}\n'
    "}\n"
)
target = root / "Sources/KlimacontrolCore/ReleaseNotesData.swift"
target.write_text(out, encoding="utf-8")
print(f"{target.relative_to(root)} geschrieben")
