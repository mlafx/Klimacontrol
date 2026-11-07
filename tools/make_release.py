#!/usr/bin/env python3
"""Release-Ordner für GitHub zusammenstellen (am Mac, nach tools/build_app.sh und ggf. dem Windows-Bau).

    python3 tools/make_release.py [--key-file <Datei>] [--publish]

Legt releases/v<Version>/ an mit allem, was an das GitHub-Release gehört:
  Klimacontrol-<Version>-mac.dmg (Mac), Klimacontrol-Windows-<Version>-Setup.exe (Windows), updateinfo-mac.xml,
  updateinfo-win.xml, SHA256SUMS.txt – und RELEASE_NOTES.md als Beschreibungstext (wird nicht angehängt).
Bricht ab, wenn das DMG oder die App darin nicht notarisiert und geheftet ist, oder wenn das Setup fehlt.
DMG und Setup werden mit demselben EdDSA-Schlüssel signiert (Sparkles sign_update): ohne --key-file aus dem
Schlüsselbund (Konto „klimacontrol“), sonst aus der Datei. Die Versionshinweise der Appcasts kommen aus dem
CHANGELOG-Abschnitt, ohne die Zeilen der jeweils anderen Plattform.

GitHub erkennt Releases nicht selbst: Entweder den Ordnerinhalt im Release-Formular hochladen (Tag v<Version>, kein
Vorabrelease, Text aus RELEASE_NOTES.md) oder mit --publish per GitHub CLI (`gh`, angemeldet) anlegen. Die Apps lesen
den Appcast über releases/latest/download/…, darum nie als Vorabrelease veröffentlichen.
"""

import argparse
import email.utils
import html
import os
import hashlib
import plistlib
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
REPO = "https://github.com/mlafx/Klimacontrol"
KEY_ACCOUNT = "klimacontrol"
# Inno Setup: ohne Rückfragen, laufende App schließen; WinSparkle startet den Installer nach dem Beenden der App.
WINDOWS_INSTALLER_ARGS = "/SILENT /SP- /SUPPRESSMSGBOXES /NORESTART /CLOSEAPPLICATIONS"


def fail(text):
    print(f"Abbruch: {text}", file=sys.stderr)
    sys.exit(1)


def read_text(rel):
    try:
        return (ROOT / rel).read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as e:
        fail(f"{rel} nicht lesbar: {e}")


def version_key(text):
    """„2.10.1“ → (2, 10, 1); nicht lesbare Teile zählen als 0, damit kein Stand den Vergleich abbricht."""
    return tuple(int(p) if p.isdigit() else 0 for p in re.split(r"[.\-]", text or ""))


def sparkle_version(sign_update):
    """Version des Sparkle-Stands, zu dem sign_update gehört (Info.plist des Frameworks daneben)."""
    for info in sorted(sign_update.parent.parent.glob("Sparkle.xcframework/*/Sparkle.framework/Versions/*/Resources/Info.plist")):
        try:
            with info.open("rb") as f:
                v = plistlib.load(f).get("CFBundleShortVersionString")
        except (OSError, plistlib.InvalidFileException, ValueError):
            continue
        if isinstance(v, str) and v:
            return v
    return ""


def sign_update_tool():
    scratch = Path(os.environ.get("KLIMACONTROL_SCRATCH") or Path.home() / "Library/Caches/Klimacontrol-build")
    found = [p for p in scratch.glob("artifacts/*/Sparkle/bin/sign_update") if os.access(p, os.X_OK)]
    if not found:
        fail(f"sign_update nicht gefunden unter {scratch}/artifacts – erst tools/build_app.sh ausführen.")
    # Mehrere Stände (z. B. nach einem Sparkle-Update oder aus einem zweiten Klon): bevorzugt der in Package.swift
    # festgelegte, sonst der neueste – nie der alphabetisch erste.
    versions = {p: sparkle_version(p) for p in found}
    m = re.search(r"sparkle-project/Sparkle/releases/download/([^/\s\"]+)/", read_text("Package.swift"))
    pinned = [p for p, v in versions.items() if m and v == m.group(1)]
    if pinned:
        return sorted(pinned)[0]
    best = max(found, key=lambda p: (version_key(versions[p]), str(p)))
    if len(found) > 1 or m:
        print(f"Hinweis: kein sign_update zu Sparkle {m.group(1) if m else '?'} gefunden – nehme "
              f"{versions[best] or 'unbekannte Version'} ({best}).", file=sys.stderr)
    return best


def sign(tool, path, key_file):
    cmd = [str(tool)]
    cmd += ["--ed-key-file", str(key_file)] if key_file else ["--account", KEY_ACCOUNT]
    try:
        out = subprocess.run(cmd + [str(path)], capture_output=True, text=True)
    except OSError as e:
        fail(f"sign_update ließ sich nicht starten: {e}")
    m = re.search(r'sparkle:edSignature="([^"]+)"\s+length="(\d+)"', out.stdout)
    if out.returncode != 0 or not m:
        fail(f"Signieren von {path.name} fehlgeschlagen: {out.stderr.strip() or out.stdout.strip()}")
    return m.group(1), int(m.group(2))


def changelog_section(version):
    text = read_text("CHANGELOG.md")
    m = re.search(rf"^## \[{re.escape(version)}\][^\n]*\n(.*?)(?=^## \[|\Z)", text, re.M | re.S)
    if not m:
        fail(f"Kein CHANGELOG-Eintrag für {version}.")
    return m.group(1)


def inline(text):
    t = html.escape(text, quote=False)
    t = re.sub(r"\[([^\]]+)\]\((https?://[^)]+)\)", r'<a href="\2">\1</a>', t)
    t = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", t)
    return re.sub(r"`([^`]+)`", r"<code>\1</code>", t)


def notes_html(section, platform):
    """Markdown des Abschnitts als einfaches HTML; Zeilen „Windows:“ fehlen am Mac und „Mac:“ unter Windows."""
    other = "Windows:" if platform == "mac" else "Mac:"
    blocks, item = [], None
    for line in section.splitlines():
        if line.startswith("  ") and item is not None:
            item.append(line.strip())
            continue
        if item is not None:
            blocks.append(("li", " ".join(item)))
            item = None
        if line.startswith("- "):
            item = [line[2:].strip()]
        elif line.startswith("### "):
            blocks.append(("h3", line[4:].strip()))
        elif line.strip():
            blocks.append(("p", line.strip()))
    if item is not None:
        blocks.append(("li", " ".join(item)))
    blocks = [(k, v) for k, v in blocks if not (k == "li" and v.startswith(other))]
    # Überschriften ohne Punkte darunter weglassen (z. B. nur Windows-Zeilen unter „Behoben“).
    out, i = [], 0
    while i < len(blocks):
        kind, value = blocks[i]
        if kind == "h3":
            j = i + 1
            items = []
            while j < len(blocks) and blocks[j][0] == "li":
                items.append(blocks[j][1])
                j += 1
            if items:
                out.append(f"<h3>{inline(value)}</h3>\n<ul>\n" + "".join(f"<li>{inline(x)}</li>\n" for x in items) + "</ul>")
            i = j
            continue
        if kind == "li":
            out.append(f"<ul><li>{inline(value)}</li></ul>")
        else:
            out.append(f"<p>{inline(value)}</p>")
        i += 1
    return "\n".join(out)


# Entspricht AppUpdate.firstAutoInstallVersion im Kern (AppUpdateTests prüft das). Mac: Fassungen darunter zeigen das
# Update als kritisch (ohne "Überspringen"); ab dieser Version installiert die Mac-App selbst still.
FIRST_AUTO_INSTALL_VERSION = "1.0.1.0"
# Windows: Jedes Update ist kritisch. WinSparkle blendet dann "Diese Version überspringen" und "Später erinnern" aus;
# übrig bleiben "Installieren" und das Schließen des Fensters (vorerst nicht, die App fragt beim nächsten Mal wieder).
WINDOWS_CRITICAL = "\n      <sparkle:criticalUpdate></sparkle:criticalUpdate>"


def appcast(version, platform, url, signature, length, notes, extra_enclosure="", extra_item=""):
    return f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Klimacontrol</title>
    <link>{REPO}</link>
    <description>Updates für Klimacontrol ({platform})</description>
    <language>de</language>
    <item>
      <title>Klimacontrol {version}</title>
      <pubDate>{email.utils.formatdate(localtime=True)}</pubDate>
      <sparkle:version>{version}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>{extra_item}
      <link>{REPO}/releases/tag/v{version}</link>
      <description><![CDATA[
{notes}
]]></description>
      <enclosure url="{url}" length="{length}" type="application/octet-stream" sparkle:edSignature="{signature}"{extra_enclosure} />
    </item>
  </channel>
</rss>
"""


def sha256(path):
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def check_notarized(dmg):
    """DMG und die App darin müssen notarisiert und geheftet sein – sonst warnt Gatekeeper beim Öffnen."""
    def ok(cmd):
        try:
            return subprocess.run(cmd, capture_output=True, text=True)
        except OSError as e:
            fail(f"{cmd[0]} ließ sich nicht starten: {e}")
    r = ok(["xcrun", "stapler", "validate", str(dmg)])
    if r.returncode != 0:
        fail(f"{dmg.name}: kein Notarisierungs-Ticket angeheftet – KLIMACONTROL_NOTARY_PROFILE=klimacontrol tools/build_app.sh")
    r = ok(["spctl", "--assess", "--type", "open", "--context", "context:primary-signature", "-v", str(dmg)])
    if r.returncode != 0 or "Notarized Developer ID" not in r.stderr:
        fail(f"{dmg.name}: Gatekeeper nimmt das DMG nicht als notarisiert an: {r.stderr.strip()}")
    mount = ok(["hdiutil", "attach", "-nobrowse", "-readonly", "-plist", str(dmg)])
    if mount.returncode != 0:
        fail(f"{dmg.name}: ließ sich nicht öffnen.")
    point = [html.unescape(p) for p in re.findall(r"<key>mount-point</key>\s*<string>([^<]+)</string>", mount.stdout)]
    if not point:
        fail(f"{dmg.name}: kein Laufwerk nach dem Öffnen.")
    try:
        app = Path(point[0]) / "Klimacontrol.app"
        r = ok(["spctl", "--assess", "--type", "execute", "-v", str(app)])
        if r.returncode != 0 or "Notarized Developer ID" not in r.stderr:
            fail(f"Die App im DMG ist nicht notarisiert: {r.stderr.strip()}")
        if ok(["xcrun", "stapler", "validate", str(app)]).returncode != 0:
            fail("Der App im DMG fehlt das angeheftete Ticket.")
    finally:
        ok(["hdiutil", "detach", "-quiet", point[0]])
    print(f"Notarisiert und geheftet: {dmg.name} und Klimacontrol.app darin")


def release_notes(version, section, files):
    lines = [section.strip(), "", "### Downloads", "",
             "| Datei | Für |", "|---|---|"]
    purpose = {
        f"Klimacontrol-{version}-mac.dmg": "Mac: öffnen und Klimacontrol auf „Programme“ ziehen",
        f"Klimacontrol-Windows-{version}-Setup.exe": "Windows: Setup starten (ohne Administratorrechte)",
    }
    for f in files:
        if f.name in purpose:
            lines.append(f"| `{f.name}` | {purpose[f.name]} |")
    lines += ["", "Das Windows-Setup ist nicht signiert, Windows zeigt beim ersten Start deshalb einen SmartScreen-Hinweis",
              "(„Weitere Informationen“ → „Trotzdem ausführen“).", "",
              "Prüfsummen (SHA-256) stehen in `SHA256SUMS.txt`. `updateinfo-*.xml` lesen die Apps für ihre Updates.", ""]
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=(__doc__ or "Release-Ordner zusammenstellen.").strip().splitlines()[0])
    parser.add_argument("--key-file", type=Path, help="privater EdDSA-Schlüssel als Datei statt aus dem Schlüsselbund")
    parser.add_argument("--publish", action="store_true", help="Release v<Version> per GitHub CLI anlegen und hochladen")
    args = parser.parse_args()
    if args.key_file and not args.key_file.is_file():
        fail(f"Schlüsseldatei {args.key_file} fehlt.")

    version = read_text("tools/VERSION").strip()
    if not re.fullmatch(r"\d+(\.\d+){3}", version):
        fail(f"tools/VERSION enthält keine Version der Form a.b.c.d: {version!r}")
    section = changelog_section(version)
    tool = sign_update_tool()
    release = f"{REPO}/releases/download/v{version}"
    m = re.search(r"<key>LSMinimumSystemVersion</key><string>([^<]+)</string>", read_text("tools/build_app.sh"))
    if not m:
        fail("LSMinimumSystemVersion nicht in tools/build_app.sh gefunden (Info.plist-Vorlage geändert?).")
    min_macos = m.group(1)

    dmg = ROOT / f"dist/mac/Klimacontrol-{version}-mac.dmg"
    setup = ROOT / f"dist/windows/Klimacontrol-Windows-{version}-Setup.exe"
    if not dmg.is_file():
        fail(f"{dmg.relative_to(ROOT)} fehlt – erst KLIMACONTROL_NOTARY_PROFILE=klimacontrol tools/build_app.sh.")
    if not setup.is_file():
        fail(f"{setup.relative_to(ROOT)} fehlt – erst unter Windows tools\\build_windows.ps1 -Setup.")
    check_notarized(dmg)

    out = ROOT / "releases" / f"v{version}"
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)

    files = []
    for src_file in [dmg, setup]:
        shutil.copy2(src_file, out / src_file.name)
        files.append(out / src_file.name)

    signature, length = sign(tool, out / dmg.name, args.key_file)
    (out / "updateinfo-mac.xml").write_text(appcast(
        version, "Mac", f"{release}/{dmg.name}", signature, length, notes_html(section, "mac"),
        extra_item=f"\n      <sparkle:criticalUpdate sparkle:version=\"{FIRST_AUTO_INSTALL_VERSION}\"></sparkle:criticalUpdate>"
                   f"\n      <sparkle:minimumSystemVersion>{min_macos}</sparkle:minimumSystemVersion>"), encoding="utf-8")
    files.append(out / "updateinfo-mac.xml")

    signature, length = sign(tool, out / setup.name, args.key_file)
    (out / "updateinfo-win.xml").write_text(appcast(
        version, "Windows", f"{release}/{setup.name}", signature, length, notes_html(section, "windows"),
        extra_enclosure=f' sparkle:os="windows" sparkle:installerArguments="{WINDOWS_INSTALLER_ARGS}"',
        extra_item=WINDOWS_CRITICAL),
        encoding="utf-8")
    files.append(out / "updateinfo-win.xml")

    sums = "".join(f"{sha256(f)}  {f.name}\n" for f in files)
    (out / "SHA256SUMS.txt").write_text(sums, encoding="utf-8")
    files.append(out / "SHA256SUMS.txt")
    (out / "RELEASE_NOTES.md").write_text(release_notes(version, section, files), encoding="utf-8")

    print(f"Release-Ordner: {out.relative_to(ROOT)}")
    for f in files:
        print(f"  {f.name}")
    print(f"  RELEASE_NOTES.md (Beschreibung, nicht anhängen)")

    if args.publish:
        gh = shutil.which("gh")
        if not gh:
            fail("GitHub CLI fehlt (brew install gh, danach gh auth login) – oder den Ordner im Browser hochladen.")
        cmd = [gh, "release", "create", f"v{version}", "--repo", "mlafx/Klimacontrol", "--target", "main",
               "--title", f"Klimacontrol {version}", "--notes-file", str(out / "RELEASE_NOTES.md"), "--latest"]
        try:
            subprocess.run(cmd + [str(f) for f in files], check=True)
        except (OSError, subprocess.CalledProcessError) as e:
            fail(f"Veröffentlichen fehlgeschlagen ({e}); der Release-Ordner {out.relative_to(ROOT)} ist vollständig.")
        print(f"Veröffentlicht: {REPO}/releases/tag/v{version}")
    else:
        print(f"Hochladen: {REPO}/releases/new?tag=v{version} – Dateien oben anhängen, Text aus RELEASE_NOTES.md,"
              " „Set as the latest release“, kein Vorabrelease. Oder: python3 tools/make_release.py --publish")


if __name__ == "__main__":
    try:
        main()
    except OSError as e:
        fail(f"{e.strerror or e}{f': {e.filename}' if e.filename else ''}")
