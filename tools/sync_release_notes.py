#!/usr/bin/env python3
"""Schreibt Sources/KlimacontrolCore/ReleaseNotesData.swift neu aus CHANGELOG.md und CHANGELOG.en.md (eingebetteter Text für „Neu in dieser Version“)."""
import pathlib

root = pathlib.Path(__file__).resolve().parent.parent


def literal(name, text, indent="    "):
    hashes = 1
    while '"""' + "#" * hashes in text or "\\" + "#" * hashes in text:
        hashes += 1
    mark = "#" * hashes
    return f'{indent}static let {name} = {mark}"""\n{text}\n"""{mark}\n'


def read(path):
    return path.read_text(encoding="utf-8").replace("\r\n", "\n").rstrip("\n")


german = read(root / "CHANGELOG.md")
en_path = root / "CHANGELOG.en.md"
english = read(en_path) if en_path.exists() else ""

if english:
    en_block = literal("changelogEnglish", english)
else:
    en_block = '    static let changelogEnglish = ""\n'

out = (
    "// Erzeugt von tools/sync_release_notes.py aus CHANGELOG.md und CHANGELOG.en.md – nicht von Hand ändern.\n"
    "\n"
    "extension ReleaseNotes {\n"
    + literal("changelog", german)
    + "\n    /// Leer, solange es CHANGELOG.en.md nicht gibt.\n"
    + en_block
    + "}\n"
)
target = root / "Sources/KlimacontrolCore/ReleaseNotesData.swift"
with open(target, "w", encoding="utf-8", newline="\n") as f:
    f.write(out)
print(f"{target.relative_to(root)} geschrieben ({'mit' if english else 'ohne'} CHANGELOG.en.md)")
