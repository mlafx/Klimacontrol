#!/usr/bin/env python3
"""Sucht Spuren des Bau-Rechners in fertigen Paketen (App-Bundle, Ordner, ZIP, DMG, Einzeldatei).

    python3 -I tools/check_traces.py [--extra Art=Text …] <Pfad> …

Gesucht wird in allen Dateien (auch Info.plist, Resources, Frameworks, Symlink-Ziele und Dateinamen), jeweils als
UTF-8/Latin-1 und als UTF-16 LE/BE, ohne Groß-/Kleinschreibung, nach: Benutzerordner und /Users/<Benutzername>
(danach kein weiteres Namenszeichen – fremde Namen von Apple-/Sparkle-Bauservern schlagen nicht an), Rechnername
(hostname, ComputerName, LocalHostName), OneDrive-Ordner („OneDrive-…“), Build-Ordner „Klimacontrol-build“ und
Projektordner. ZIP-Einträge werden entpackt gelesen, ein DMG wird schreibgeschützt eingehängt und zusätzlich roh
durchsucht. Ausgabe nur Datei, Art und Anzahl, nie der Fundtext.
Rückgabe: 0 keine Spuren, 1 Spuren gefunden, 2 Aufruf- oder Lesefehler.
"""

import argparse
import os
import plistlib
import pwd
import re
import socket
import stat
import subprocess
import sys
import tempfile
import unicodedata
import zipfile
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
NAME_CHARS = b"A-Za-z0-9._-"
# Standardnamen (ggf. mit „-2“ bzw. „ (2)“) stehen in unzähligen fremden Texten – sie zu suchen, brächte nur Fehltreffer.
GENERIC_HOST = re.compile(r"^(localhost|i?mac|macbook([ -]?(air|pro))?|mac[ -]?(mini|studio|pro))([ -]\(?\d+\)?)?$", re.I)
MIN_HOST_LEN = 4


def die(text):
    print(f"check_traces: {text}", file=sys.stderr)
    sys.exit(2)


def scutil(key):
    try:
        r = subprocess.run(["scutil", "--get", key], capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return ""
    return r.stdout.strip() if r.returncode == 0 else ""


def patterns(extra):
    """Liste (Art, Text, Namensgrenze) – Namensgrenze: danach darf kein Namenszeichen folgen."""
    user = os.environ.get("USER") or pwd.getpwuid(os.getuid()).pw_name
    home = os.path.realpath(os.path.expanduser("~"))
    found = [("Benutzerordner", home.rstrip("/"), True)]
    if home.rstrip("/").lower() != f"/users/{user}".lower():
        found.append(("Benutzername als Pfad", f"/Users/{user}", True))
    found += [("OneDrive-Ordner", "OneDrive-", False),
             ("Build-Ordner", "Klimacontrol-build", False),
             ("Projektordner", str(ROOT), False)]
    skipped = 0
    hosts = {socket.gethostname().split(".")[0], scutil("ComputerName"), scutil("LocalHostName")}
    for host in sorted(h for h in hosts if h):
        if len(host) < MIN_HOST_LEN or GENERIC_HOST.match(host):
            skipped += 1
        else:
            found.append(("Rechnername", host, True))
    for item in extra:
        label, sep, text = item.partition("=")
        if not sep or not label or not text:
            die("--extra erwartet Art=Text")
        found.append((label, text.rstrip("/"), False))
    return found, skipped


def compile_patterns(specs):
    """Je Art und Kodierung ein Ausdruck; gesucht wird in kleingeschriebenen Daten (ASCII-Buchstaben)."""
    compiled, seen = [], set()
    for label, text, boundary in specs:
        variants = {unicodedata.normalize(f, text) for f in ("NFC", "NFD")}
        for variant in variants:
            forms = [("UTF-8", variant.encode("utf-8"))]
            try:
                latin = variant.encode("latin-1")
                if latin != forms[0][1]:
                    forms.append(("Latin-1", latin))
            except UnicodeEncodeError:
                pass
            forms += [("UTF-16 LE", variant.encode("utf-16-le")), ("UTF-16 BE", variant.encode("utf-16-be"))]
            for enc, raw in forms:
                raw = raw.lower()
                tail = b""
                if boundary:
                    tail = {"UTF-16 LE": b"(?![" + NAME_CHARS + b"]\x00)",
                            "UTF-16 BE": b"(?!\x00[" + NAME_CHARS + b"])"}.get(enc, b"(?![" + NAME_CHARS + b"])")
                key = (label, raw, tail)
                if key in seen:
                    continue
                seen.add(key)
                compiled.append((label, enc, re.compile(re.escape(raw) + tail)))
    return compiled


class Scanner:
    def __init__(self, compiled):
        self.compiled = compiled
        self.names = [(label, rx) for label, enc, rx in compiled if enc in ("UTF-8", "Latin-1")]
        self.hits = Counter()
        self.files = 0

    def redact(self, name):
        """Pfad für die Ausgabe – Fundstellen darin werden durch „[…]“ ersetzt."""
        raw = name.encode("utf-8", "surrogateescape")
        spans = sorted(m.span() for _, rx in self.names for m in rx.finditer(raw.lower()))
        if not spans:
            return name
        out, pos = b"", 0
        for start, end in spans:
            if end <= pos:
                continue
            out += raw[pos:max(start, pos)] + "[…]".encode()
            pos = end
        return (out + raw[pos:]).decode("utf-8", "replace")

    def scan(self, name, data):
        self.files += 1
        low = data.lower()
        for label, enc, rx in self.compiled:
            n = sum(1 for _ in rx.finditer(low))
            if n:
                self.hits[(self.redact(name), label, enc)] += n

    def scan_name(self, name):
        data = name.encode("utf-8", "surrogateescape").lower()
        for label, rx in self.names:
            if rx.search(data):
                self.hits[(self.redact(name), f"{label} im Dateinamen", "UTF-8")] += 1


def scan_tree(scanner, root, prefix):
    root = Path(root)
    entries = [root]
    if root.is_dir() and not root.is_symlink():
        for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
            for n in dirnames + filenames:
                entries.append(Path(dirpath) / n)
    for p in entries:
        rel = f"{prefix}{p.relative_to(root.parent)}"
        scanner.scan_name(str(p.relative_to(root.parent)))
        try:
            st = p.lstat()
            if stat.S_ISLNK(st.st_mode):
                scanner.scan(f"{rel} (Symlink-Ziel)", os.fsencode(os.readlink(p)))
            elif stat.S_ISREG(st.st_mode):
                scanner.scan(rel, p.read_bytes())
        except OSError as e:
            die(f"{scanner.redact(rel)} nicht lesbar ({e.strerror or type(e).__name__})")


def scan_zip(scanner, path):
    try:
        with zipfile.ZipFile(path) as z:
            for info in z.infolist():
                rel = f"{path.name}:{info.filename}"
                scanner.scan_name(info.filename)
                if info.is_dir():
                    continue
                is_link = stat.S_ISLNK(info.external_attr >> 16)
                scanner.scan(f"{rel} (Symlink-Ziel)" if is_link else rel, z.read(info))
    except (zipfile.BadZipFile, OSError, RuntimeError) as e:
        die(f"{path.name}: ZIP nicht lesbar ({e})")


def scan_dmg(scanner, path):
    scanner.scan(f"{path.name} (roh)", path.read_bytes())
    base = tempfile.mkdtemp(prefix="klimacontrol-traces.")
    try:
        r = subprocess.run(["hdiutil", "attach", "-readonly", "-nobrowse", "-noautoopen", "-plist",
                            "-mountrandom", base, str(path)], capture_output=True, timeout=300)
        if r.returncode != 0:
            die(f"{path.name}: ließ sich nicht einhängen ({r.stderr.decode(errors='replace').strip()})")
        try:
            points = [e["mount-point"] for e in plistlib.loads(r.stdout).get("system-entities", [])
                      if "mount-point" in e]
        except (plistlib.InvalidFileException, ValueError, TypeError, KeyError):
            points = []
        if not points:
            die(f"{path.name}: kein Laufwerk nach dem Einhängen.")
        try:
            for point in points:
                for child in sorted(Path(point).iterdir()):
                    scan_tree(scanner, child, f"{path.name}:")
        finally:
            for point in points:
                d = subprocess.run(["hdiutil", "detach", "-quiet", point], capture_output=True)
                if d.returncode != 0:
                    subprocess.run(["hdiutil", "detach", "-quiet", "-force", point], capture_output=True)
    finally:
        try:
            os.rmdir(base)
        except OSError:
            pass


def main():
    parser = argparse.ArgumentParser(description="Spuren des Bau-Rechners in Paketen suchen.")
    parser.add_argument("--extra", action="append", default=[], metavar="Art=Text",
                        help="zusätzliches Suchmuster (fester Text), z. B. ein eigener Build-Ordner")
    parser.add_argument("paths", nargs="+", type=Path)
    args = parser.parse_args()

    specs, skipped = patterns(args.extra)
    scanner = Scanner(compile_patterns(specs))
    for path in args.paths:
        if not path.exists() and not path.is_symlink():
            die(f"{path.name} fehlt.")
        if path.is_dir():
            scan_tree(scanner, path.resolve(), "")
        elif path.suffix.lower() == ".zip":
            scan_zip(scanner, path)
        elif path.suffix.lower() == ".dmg":
            scan_dmg(scanner, path)
        else:
            scanner.scan(path.name, path.read_bytes())

    names = ", ".join(p.name for p in args.paths)
    if skipped:
        print(f"Hinweis: {skipped} Rechnername(n) zu allgemein (Standardname oder kürzer als {MIN_HOST_LEN} Zeichen) "
              "– nicht gesucht.")
    if scanner.hits:
        print(f"Spuren des Bau-Rechners in {names}:", file=sys.stderr)
        for (name, label, enc), n in sorted(scanner.hits.items()):
            print(f"  {name}: {label} ({enc}), {n}×", file=sys.stderr)
        sys.exit(1)
    print(f"Keine Spuren des Bau-Rechners: {names} ({scanner.files} Dateien, {len(specs)} Muster).")


if __name__ == "__main__":
    try:
        main()
    except OSError as e:
        die(f"Lesefehler: {e.strerror or type(e).__name__}")
