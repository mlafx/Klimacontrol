#!/usr/bin/env python3
"""Release-Ordner für GitHub zusammenstellen, prüfen und veröffentlichen (am Mac, nach tools/build_app.sh).

    python3 tools/make_release.py [--key-file <Datei>]                 # stabile Fassung aus tools/VERSION
    python3 tools/make_release.py --beta <n> [--key-file <Datei>]      # Beta <VERSION>b<n> (nur Mac)
    python3 tools/make_release.py [...] --publish                      # zusätzlich veröffentlichen (nur auf Auftrag)
    python3 tools/make_release.py --check-published [<Version>]        # nach dem Veröffentlichen prüfen (liest nur)
    python3 tools/make_release.py --rollback <kaputt> <vorige>         # Notbremse: zeigt die Befehle (--execute: ausführen)

Stabile Fassung: legt releases/v<Version>/ an mit Klimacontrol-<Version>-mac.dmg, Klimacontrol-Windows-<Version>-Setup.exe,
updateinfo-mac.xml, updateinfo-win.xml, updateinfo-mac-beta.xml, SHA256SUMS.txt und RELEASE_NOTES.md (Beschreibungstext,
zweisprachig, wird nicht angehängt). Voraussetzungen: tools/VERSION, CHANGELOG.md und CHANGELOG.en.md (ab 1.2.0.0) tragen
für die Version ein Datum (nicht „in Arbeit“), DMG und App darin sind notarisiert und geheftet, das Setup liegt vor.

Beta (--beta <n>): Tag v<Version>b<n>, DMG aus dist/mac (gebaut mit tools/build_app.sh --beta <n>), keine Setup-Datei und
nie die öffentlichen Update-Dateien. Der Ordner enthält DMG, updateinfo-mac-beta.xml (neueste stabile Fassung plus diese
Beta), SHA256SUMS.txt, RELEASE_NOTES.md. Die stabile Fassung kommt aus --stable-feed <Datei>, sonst aus der höchsten
lokalen releases/v<a.b.c.d>/updateinfo-mac.xml, sonst nur mit --fetch-stable aus dem veröffentlichten latest-Release.

Signatur: DMG und Setup werden mit Sparkles sign_update signiert und sofort geprüft. Die drei Update-Dateien werden als
letzter Schreibschritt signiert (Signatur eingebettet) und erneut geprüft; danach ändert nichts mehr an ihnen etwas.
Ohne --key-file liest sign_update den Schlüssel aus dem Schlüsselbund (Konto „klimacontrol“), sonst aus der Datei.
Zum Schluss prüft verify_release_dir() den Ordner vollständig (Dateinamen, Adressen, Größen, Signaturen, Prüfsummen).

--publish (nur auf ausdrücklichen Auftrag): prüft, dass der Tag noch nicht existiert, gibt jeden gh-Befehl vor dem Ausführen
aus und legt das Release an. Stabil: --latest, ohne Update-Datei der Beta. Beta: --prerelease --latest=false. Die Beta-Update-
Datei hängt immer am festen Vorabrelease „beta“ (wird bei Bedarf einmal angelegt, die Datei dort ersetzt).

--check-published prüft nach dem Veröffentlichen die Adressen, die die Apps lesen (latest und beta): Status, Version,
Signatur, Erreichbarkeit der Archive. Es braucht den Schlüssel (nur Markus führt es aus) und liest nur.

--rollback ist die Notbremse: kaputtes Release auf „Vorabrelease“ stellen, vorige Fassung wieder zum neuesten machen.
Nichts wird gelöscht, keine Tags werden verschoben; die Korrektur erscheint als nächste Fehlerbehebungs-Version.

GitHub erkennt Releases nicht selbst: Entweder den Ordnerinhalt im Release-Formular hochladen oder --publish (GitHub CLI
`gh`, angemeldet). Die Apps lesen die Update-Dateien über releases/latest/download/… bzw. releases/download/beta/….
"""

import argparse
import datetime
import email.utils
import hashlib
import html
import os
import plistlib
import re
import subprocess
import sys
import shutil
import tempfile
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
REPO = "https://github.com/mlafx/Klimacontrol"
GH_REPO = "mlafx/Klimacontrol"
KEY_ACCOUNT = "klimacontrol"
SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
# Inno Setup: ohne Rückfragen, laufende App schließen; WinSparkle startet den Installer nach dem Beenden der App.
WINDOWS_INSTALLER_ARGS = "/SILENT /SP- /SUPPRESSMSGBOXES /NORESTART /CLOSEAPPLICATIONS"
# Ab dieser Version ist der englische CHANGELOG-Abschnitt Pflicht.
FIRST_ENGLISH_VERSION = "1.2.0.0"
BETA_FEED = "updateinfo-mac-beta.xml"
_NO_BETA = 10**9


def fail(text):
    print(f"Abbruch: {text}", file=sys.stderr)
    sys.exit(1)


def read_text(root, rel):
    try:
        return (root / rel).read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as e:
        fail(f"{rel} nicht lesbar: {e}")


def version_key(text):
    """„2.10.1“ → (2, 10, 1); nicht lesbare Teile zählen als 0, damit kein Stand den Vergleich abbricht."""
    return tuple(int(p) if p.isdigit() else 0 for p in re.split(r"[.\-]", text or ""))


def parse_version(text):
    """„1.2.0.0“ oder „1.2.0.0b3“ → (1, 2, 0, 0, 3 bzw. None); sonst ValueError."""
    m = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)\.(\d+)(?:b(\d+))?", text or "")
    if not m:
        raise ValueError(f"keine Version der Form a.b.c.d[b<n>]: {text!r}")
    nums = [int(x) for x in m.groups()[:4]]
    return (*nums, int(m.group(5)) if m.group(5) else None)


def version_order(text):
    """Sortierschlüssel wie AppVersion: vier Zahlen, „b<n>“ ist kleiner als dieselbe Version ohne Kennung."""
    *nums, beta = parse_version(text)
    return (*nums, _NO_BETA if beta is None else beta)


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


def sign_update_tool(root=ROOT):
    scratch = Path(os.environ.get("KLIMACONTROL_SCRATCH") or Path.home() / "Library/Caches/Klimacontrol-build")
    found = [p for p in scratch.glob("artifacts/*/Sparkle/bin/sign_update") if os.access(p, os.X_OK)]
    if not found:
        fail(f"sign_update nicht gefunden unter {scratch}/artifacts – erst tools/build_app.sh ausführen.")
    # Mehrere Stände (z. B. nach einem Sparkle-Update oder aus einem zweiten Klon): bevorzugt der in Package.swift
    # festgelegte, sonst der neueste – nie der alphabetisch erste.
    versions = {p: sparkle_version(p) for p in found}
    m = re.search(r"sparkle-project/Sparkle/releases/download/([^/\s\"]+)/", read_text(root, "Package.swift"))
    pinned = [p for p, v in versions.items() if m and v == m.group(1)]
    if pinned:
        return sorted(pinned)[0]
    best = max(found, key=lambda p: (version_key(versions[p]), str(p)))
    if len(found) > 1 or m:
        print(f"Hinweis: kein sign_update zu Sparkle {m.group(1) if m else '?'} gefunden – nehme "
              f"{versions[best] or 'unbekannte Version'} ({best}).", file=sys.stderr)
    return best


def key_args_for(key_file):
    return ["--ed-key-file", str(key_file)] if key_file else ["--account", KEY_ACCOUNT]


def run_tool(cmd):
    try:
        return subprocess.run(cmd, capture_output=True, text=True)
    except OSError as e:
        fail(f"{Path(cmd[0]).name} ließ sich nicht starten: {e}")


def sign(tool, path, key_args):
    """Archiv signieren und die Signatur sofort mit sign_update --verify prüfen."""
    out = run_tool([str(tool), *key_args, str(path)])
    m = re.search(r'sparkle:edSignature="([^"]+)"\s+length="(\d+)"', out.stdout)
    if out.returncode != 0 or not m:
        fail(f"Signieren von {path.name} fehlgeschlagen: {out.stderr.strip() or out.stdout.strip()}")
    verify_archive(tool, key_args, path, m.group(1))
    return m.group(1), int(m.group(2))


def verify_archive(tool, key_args, path, signature):
    r = run_tool([str(tool), *key_args, "--verify", str(path), signature])
    if r.returncode != 0:
        fail(f"Signatur von {path.name} stimmt nicht: {r.stderr.strip() or r.stdout.strip()}")


def verify_feed(tool, key_args, path):
    """Eingebettete Signatur einer Update-Datei prüfen."""
    if "sparkle-signatures" not in path.read_text(encoding="utf-8"):
        fail(f"{path.name}: keine eingebettete Signatur.")
    r = run_tool([str(tool), *key_args, "--verify", str(path)])
    if r.returncode != 0:
        fail(f"Signatur von {path.name} stimmt nicht: {r.stderr.strip() or r.stdout.strip()}")


def sign_feed(tool, key_args, path):
    """Update-Datei signieren (Signatur wird eingebettet) und prüfen. Danach darf die Datei nicht mehr geändert werden."""
    r = run_tool([str(tool), *key_args, str(path)])
    if r.returncode != 0:
        fail(f"Signieren von {path.name} fehlgeschlagen: {r.stderr.strip() or r.stdout.strip()}")
    verify_feed(tool, key_args, path)


def changelog_section(text, version, required=True):
    """(Kopfzeile, Text) des Abschnitts `## [version] …`; ohne Abschnitt Abbruch bzw. None."""
    m = re.search(rf"^(## \[{re.escape(version)}\][^\n]*)\n(.*?)(?=^## \[|\Z)", text, re.M | re.S)
    if not m:
        if required:
            fail(f"Kein CHANGELOG-Eintrag für {version}.")
        return None
    return m.group(1), m.group(2)


def section_date(heading):
    """Datum JJJJ-MM-TT aus der Kopfzeile, None bei „in Arbeit“ / „in progress“."""
    m = re.search(r"\b(\d{4}-\d{2}-\d{2})\b", heading)
    return m.group(1) if m else None


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
# Update als kritisch (ohne "Überspringen"); ab dieser Version installiert die Mac-App selbst still. 1.1.0.0 ist die
# erste Fassung mit vollständig automatischen Updates.
FIRST_AUTO_INSTALL_VERSION = "1.1.0.0"
# Windows: Jedes Update ist kritisch. WinSparkle blendet dann "Diese Version überspringen" und "Später erinnern" aus;
# übrig bleiben "Installieren" und das Schließen des Fensters (vorerst nicht, die App fragt beim nächsten Mal wieder).
WINDOWS_CRITICAL = "\n      <sparkle:criticalUpdate></sparkle:criticalUpdate>"


def appcast_item(version, url, signature, length, notes, extra_enclosure="", extra_item="", title=None):
    return f"""    <item>
      <title>{title or f"Klimacontrol {version}"}</title>
      <pubDate>{email.utils.formatdate(localtime=True)}</pubDate>
      <sparkle:version>{version}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>{extra_item}
      <link>{REPO}/releases/tag/v{version}</link>
      <description><![CDATA[
{notes}
]]></description>
      <enclosure url="{url}" length="{length}" type="application/octet-stream" sparkle:edSignature="{signature}"{extra_enclosure} />
    </item>
"""


def feed_text(platform, items):
    return f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="{SPARKLE_NS}">
  <channel>
    <title>Klimacontrol</title>
    <link>{REPO}</link>
    <description>Updates für Klimacontrol ({platform})</description>
    <language>de</language>
{"".join(items)}  </channel>
</rss>
"""


def appcast(version, platform, url, signature, length, notes, extra_enclosure="", extra_item=""):
    return feed_text(platform, [appcast_item(version, url, signature, length, notes, extra_enclosure, extra_item)])


def extract_items(xml_text):
    """Alle <item>-Blöcke einer Update-Datei (Text, eingebettete Signatur bleibt außen vor)."""
    return [m.group(0).rstrip(" \t") + ("" if m.group(0).endswith("\n") else "\n")
            for m in re.finditer(r"[ \t]*<item>.*?</item>[ \t]*\n?", xml_text, re.S)]


def item_version(item):
    m = re.search(r"<sparkle:version>([^<]+)</sparkle:version>", item)
    if not m:
        fail("Eintrag ohne sparkle:version in der Update-Datei.")
    return m.group(1).strip()


def sha256(path):
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def write_text(path, text):
    path.write_text(text, encoding="utf-8", newline="\n")


def rotate_existing(out, now=None):
    """Vorhandenen Release-Ordner nicht löschen, sondern beiseite legen (…alt-JJJJMMTT-HHMMSS)."""
    if not out.exists():
        return None
    stamp = (now or datetime.datetime.now()).strftime("%Y%m%d-%H%M%S")
    target = out.with_name(f"{out.name}.alt-{stamp}")
    n = 1
    while target.exists():
        n += 1
        target = out.with_name(f"{out.name}.alt-{stamp}-{n}")
    out.rename(target)
    print(f"Vorhandener Ordner beiseite gelegt: {target.name}")
    return target


def read_min_macos(root):
    m = re.search(r"<key>LSMinimumSystemVersion</key><string>([^<]+)</string>", read_text(root, "tools/build_app.sh"))
    if not m:
        fail("LSMinimumSystemVersion nicht in tools/build_app.sh gefunden (Info.plist-Vorlage geändert?).")
    return m.group(1)


def check_notarized(dmg):
    """DMG und die App darin müssen notarisiert und geheftet sein – sonst warnt Gatekeeper beim Öffnen."""
    ok = run_tool
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


def release_notes(version, section, files, en_section=None, beta=None):
    """Beschreibungstext des Releases: deutsch, darunter (wenn vorhanden) englisch."""
    purpose = {
        f"Klimacontrol-{version}-mac.dmg": "Mac: öffnen und Klimacontrol auf „Programme“ ziehen",
        f"Klimacontrol-Windows-{version}-Setup.exe": "Windows: Setup starten (ohne Administratorrechte)",
    }
    tag = f"{version}b{beta}" if beta else version
    purpose[f"Klimacontrol-{tag}-mac.dmg"] = purpose[f"Klimacontrol-{version}-mac.dmg"]
    lines = []
    if beta:
        lines += [f"## Vorabversion {tag}", "",
                  "Vorabversion zum Testen (nur Mac). Sie wird nur angeboten, wenn in den Einstellungen unter Allgemein "
                  "„Vorabversionen (Beta) erhalten“ eingeschaltet ist.", ""]
    lines += [section.strip(), "", "### Downloads", "", "| Datei | Für |", "|---|---|"]
    for f in files:
        if f.name in purpose:
            lines.append(f"| `{f.name}` | {purpose[f.name]} |")
    if not beta:
        lines += ["", "Das Windows-Setup ist nicht signiert, Windows zeigt beim ersten Start deshalb einen SmartScreen-Hinweis",
                  "(„Weitere Informationen“ → „Trotzdem ausführen“)."]
    lines += ["", "Prüfsummen (SHA-256) stehen in `SHA256SUMS.txt`. `updateinfo-*.xml` lesen die Apps für ihre Updates.", ""]
    if en_section is not None:
        lines += ["---", "", "## English", ""]
        if beta:
            lines += [f"Pre-release {tag} for testing (Mac only). It is offered only if “Receive pre-release (beta) versions” "
                      "is turned on in Settings → General.", ""]
        lines += [en_section.strip(), "", "Mac: open the DMG and drag Klimacontrol to Applications."]
        if not beta:
            lines += ["", "Windows: run the setup (no administrator rights needed). The setup is not signed; Windows SmartScreen "
                      "shows a notice on first start (More info → Run anyway)."]
        lines += ["", "SHA-256 checksums are in `SHA256SUMS.txt`.", ""]
    return "\n".join(lines)


# ---------------------------------------------------------------------------------------------------------------------
# Quellen der stabilen Fassung für die Beta-Update-Datei

def local_stable_feeds(root):
    base = root / "releases"
    found = []
    if base.is_dir():
        for d in base.iterdir():
            if re.fullmatch(r"v\d+\.\d+\.\d+\.\d+", d.name) and (d / "updateinfo-mac.xml").is_file():
                found.append((version_order(d.name[1:]), d / "updateinfo-mac.xml"))
    return [p for _, p in sorted(found)]


def stable_item_from_sources(root, stable_feed=None, fetch=False):
    """Neuester stabiler <item> (unverändert) aus --stable-feed, lokalen Releases oder – nur ausdrücklich – aus dem Netz."""
    if stable_feed:
        text = Path(stable_feed).read_text(encoding="utf-8")
    elif local_stable_feeds(root):
        text = local_stable_feeds(root)[-1].read_text(encoding="utf-8")
    elif fetch:
        status, body = http_get(f"{REPO}/releases/latest/download/updateinfo-mac.xml")
        if status != 200:
            fail(f"Stabile Update-Datei nicht abrufbar (HTTP {status}).")
        text = body.decode("utf-8")
    else:
        fail("Keine stabile Update-Datei gefunden: --stable-feed <Datei> angeben, ein stabiles Release unter releases/ "
             "bereitstellen oder ausdrücklich --fetch-stable verwenden.")
    items = [i for i in extract_items(text) if "b" not in item_version(i)]
    if not items:
        fail("In der stabilen Update-Datei steht kein Eintrag.")
    return max(items, key=lambda i: version_order(item_version(i)))


def newest_local_beta_item(root):
    base = root / "releases"
    best = None
    if base.is_dir():
        for d in base.iterdir():
            f = d / BETA_FEED
            if re.fullmatch(r"v\d+\.\d+\.\d+\.\d+b\d+", d.name) and f.is_file():
                for i in extract_items(f.read_text(encoding="utf-8")):
                    v = item_version(i)
                    if "b" in v and (best is None or version_order(v) > version_order(item_version(best))):
                        best = i
    return best


# ---------------------------------------------------------------------------------------------------------------------
# Prüfung D3/7

def _q(tag):
    return f"{{{SPARKLE_NS}}}{tag}"


def _check_item(item, *, platform, local_version, local_archive, min_macos, tool, key_args, problems, label):
    v = (item.findtext(_q("version")) or "").strip()
    enc = item.find("enclosure")
    if not v or enc is None:
        problems.append(f"{label}: Eintrag ohne Version oder Archiv")
        return v
    try:
        is_beta = parse_version(v)[4] is not None
    except ValueError:
        problems.append(f"{label}: sparkle:version {v!r} ist keine Version")
        return v
    url = enc.get("url") or ""
    sig = enc.get(_q("edSignature")) or ""
    name = url.rsplit("/", 1)[-1]
    if platform == "mac":
        expected_name = f"Klimacontrol-{v}-mac.dmg"
        if name != expected_name:
            problems.append(f"{label}: Archivname {name!r} statt {expected_name!r}")
        if (item.findtext(_q("minimumSystemVersion")) or "").strip() != min_macos:
            problems.append(f"{label}: minimumSystemVersion nicht {min_macos}")
        crit = item.find(_q("criticalUpdate"))
        if is_beta:
            if crit is not None:
                problems.append(f"{label}: Beta-Eintrag darf nicht kritisch sein")
        elif crit is None:
            problems.append(f"{label}: criticalUpdate fehlt")
        elif v == local_version and crit.get(_q("version")) != FIRST_AUTO_INSTALL_VERSION:
            problems.append(f"{label}: criticalUpdate sparkle:version={FIRST_AUTO_INSTALL_VERSION} fehlt")
    else:
        expected_name = f"Klimacontrol-Windows-{v}-Setup.exe"
        if name != expected_name:
            problems.append(f"{label}: Archivname {name!r} statt {expected_name!r}")
        if item.find(_q("criticalUpdate")) is None:
            problems.append(f"{label}: criticalUpdate fehlt")
        if enc.get(_q("os")) != "windows":
            problems.append(f"{label}: sparkle:os=\"windows\" fehlt")
    if url != f"{REPO}/releases/download/v{v}/{expected_name}":
        problems.append(f"{label}: Adresse {url!r} stimmt nicht")
    if not sig:
        problems.append(f"{label}: sparkle:edSignature fehlt")
    if v == local_version and local_archive is not None:
        if not local_archive.is_file():
            problems.append(f"{label}: Archiv {local_archive.name} fehlt im Ordner")
        else:
            if enc.get("length") != str(local_archive.stat().st_size):
                problems.append(f"{label}: length stimmt nicht mit der Dateigröße überein")
            if sig:
                r = run_tool([str(tool), *key_args, "--verify", str(local_archive), sig])
                if r.returncode != 0:
                    problems.append(f"{label}: Archiv-Signatur ungültig")
    return v


def _check_feed(path, *, platform, local_version, local_archive, min_macos, tool, key_args, problems):
    label = path.name
    try:
        root_el = ET.parse(path).getroot()
    except (ET.ParseError, OSError) as e:
        problems.append(f"{label}: kein gültiges XML ({e})")
        return []
    if "sparkle-signatures" not in path.read_text(encoding="utf-8"):
        problems.append(f"{label}: keine eingebettete Signatur")
    else:
        r = run_tool([str(tool), *key_args, "--verify", str(path)])
        if r.returncode != 0:
            problems.append(f"{label}: eingebettete Signatur ungültig")
    versions = []
    for item in root_el.iter("item"):
        versions.append(_check_item(item, platform=platform, local_version=local_version, local_archive=local_archive,
                                    min_macos=min_macos, tool=tool, key_args=key_args, problems=problems, label=label))
    return versions


def verify_release_dir(out, version, beta, tool, key_args, min_macos):
    """Prüfung D3/7: bricht mit klarer Meldung ab, wenn der Release-Ordner nicht in Ordnung ist."""
    tag = f"{version}b{beta}" if beta else version
    dmg = f"Klimacontrol-{tag}-mac.dmg"
    if beta:
        expected = {dmg, BETA_FEED, "SHA256SUMS.txt", "RELEASE_NOTES.md"}
    else:
        expected = {dmg, f"Klimacontrol-Windows-{version}-Setup.exe", "updateinfo-mac.xml", "updateinfo-win.xml",
                    BETA_FEED, "SHA256SUMS.txt", "RELEASE_NOTES.md"}
    present = {p.name for p in out.iterdir()}
    problems = []
    for name in sorted(present - expected):
        problems.append(f"unerwartete Datei: {name}")
    for name in sorted(expected - present):
        problems.append(f"fehlende Datei: {name}")
    if any(n.startswith("appcast") for n in present):
        problems.append("Dateien mit Namen appcast… sind nicht vorgesehen")
    if not problems:
        archive = out / dmg
        if not beta:
            mac = _check_feed(out / "updateinfo-mac.xml", platform="mac", local_version=version, local_archive=archive,
                              min_macos=min_macos, tool=tool, key_args=key_args, problems=problems)
            if mac != [version]:
                problems.append(f"updateinfo-mac.xml: erwartet genau den Eintrag {version}, gefunden {mac}")
            win = _check_feed(out / "updateinfo-win.xml", platform="windows", local_version=version,
                              local_archive=out / f"Klimacontrol-Windows-{version}-Setup.exe", min_macos=min_macos,
                              tool=tool, key_args=key_args, problems=problems)
            if win != [version]:
                problems.append(f"updateinfo-win.xml: erwartet genau den Eintrag {version}, gefunden {win}")
        found = _check_feed(out / BETA_FEED, platform="mac", local_version=tag, local_archive=archive,
                            min_macos=min_macos, tool=tool, key_args=key_args, problems=problems)
        stables = [v for v in found if v and "b" not in v]
        betas = [v for v in found if v and "b" in v]
        if len(stables) != 1 or len(betas) > 1 or len(found) != len(stables) + len(betas):
            problems.append(f"{BETA_FEED}: erwartet einen stabilen und höchstens einen Beta-Eintrag, gefunden {found}")
        else:
            if not beta and stables != [version]:
                problems.append(f"{BETA_FEED}: stabiler Eintrag {stables[0]} statt {version}")
            for b in betas:
                if version_order(b) <= version_order(stables[0]):
                    problems.append(f"{BETA_FEED}: Beta {b} ist nicht höher als {stables[0]}")
            if beta and betas != [tag]:
                problems.append(f"{BETA_FEED}: erwartet Beta {tag}, gefunden {betas}")
        sums_path = out / "SHA256SUMS.txt"
        listed = {}
        for line in sums_path.read_text(encoding="utf-8").splitlines():
            m = re.fullmatch(r"([0-9a-f]{64})  (.+)", line)
            if m:
                listed[m.group(2)] = m.group(1)
            elif line.strip():
                problems.append(f"SHA256SUMS.txt: unlesbare Zeile {line!r}")
        want = expected - {"SHA256SUMS.txt", "RELEASE_NOTES.md"}
        if set(listed) != want:
            problems.append(f"SHA256SUMS.txt: Dateien {sorted(listed)} statt {sorted(want)}")
        for name, digest in listed.items():
            if (out / name).is_file() and sha256(out / name) != digest:
                problems.append(f"SHA256SUMS.txt: Prüfsumme von {name} stimmt nicht")
    if problems:
        fail("Prüfung des Release-Ordners fehlgeschlagen:\n  - " + "\n  - ".join(problems))
    print(f"Prüfung des Release-Ordners bestanden: {out.name}")


# ---------------------------------------------------------------------------------------------------------------------
# Zusammenstellen

def build_release(root, tool, key_args, version, beta=None, stable_feed=None, fetch_stable=False,
                  notarized_check=check_notarized):
    """Release-Ordner erzeugen, signieren und prüfen. Gibt (Ordner, Dateien zum Anhängen) zurück."""
    try:
        parse_version(version)
    except ValueError as e:
        fail(f"tools/VERSION: {e}")
    if "b" in version:
        fail(f"tools/VERSION enthält keine Version der Form a.b.c.d: {version!r}")
    tag = f"{version}b{beta}" if beta else version
    de = changelog_section(read_text(root, "CHANGELOG.md"), version)
    en_required = not beta and version_order(version) >= version_order(FIRST_ENGLISH_VERSION)
    en_path = root / "CHANGELOG.en.md"
    en = None
    if en_path.is_file() or en_required:
        en = changelog_section(read_text(root, "CHANGELOG.en.md"), version, required=en_required)
    date = section_date(de[0])
    if not beta:
        if date is None:
            fail("Erst das Datum im CHANGELOG setzen (Abschnitt steht noch auf „in Arbeit“).")
        if en is not None and section_date(en[0]) != date:
            fail(f"CHANGELOG.en.md: Abschnitt {version} trägt nicht dasselbe Datum ({date}).")
    min_macos = read_min_macos(root)
    release = f"{REPO}/releases/download/v{tag}"

    dmg = root / f"dist/mac/Klimacontrol-{tag}-mac.dmg"
    setup = root / f"dist/windows/Klimacontrol-Windows-{version}-Setup.exe"
    if not dmg.is_file():
        build = f"tools/build_app.sh --beta {beta}" if beta else "KLIMACONTROL_NOTARY_PROFILE=klimacontrol tools/build_app.sh"
        fail(f"{dmg.relative_to(root)} fehlt – erst {build}.")
    if not beta and not setup.is_file():
        fail(f"{setup.relative_to(root)} fehlt – erst unter Windows tools\\build_windows.ps1 -Setup.")
    stable_item = None
    if beta:
        stable_item = stable_item_from_sources(root, stable_feed, fetch_stable)
        if version_order(item_version(stable_item)) >= version_order(tag):
            fail(f"Die stabile Fassung {item_version(stable_item)} ist nicht kleiner als die Beta {tag}.")
    notarized_check(dmg)

    out = root / "releases" / f"v{tag}"
    rotate_existing(out)
    out.mkdir(parents=True)

    files = []
    for src_file in [dmg] if beta else [dmg, setup]:
        shutil.copy2(src_file, out / src_file.name)
        files.append(out / src_file.name)

    feeds = []
    signature, length = sign(tool, out / dmg.name, key_args)
    if beta:
        notes = f"<h3>Vorabversion {tag}</h3>\n" + notes_html(de[1], "mac")
        beta_item = appcast_item(
            tag, f"{release}/{dmg.name}", signature, length, notes,
            extra_item=f"\n      <sparkle:minimumSystemVersion>{min_macos}</sparkle:minimumSystemVersion>",
            title=f"Klimacontrol {tag} (Vorabversion)")
        (out / BETA_FEED).write_text(feed_text("Mac, Beta", [stable_item, beta_item]), encoding="utf-8", newline="\n")
        feeds.append(out / BETA_FEED)
    else:
        (out / "updateinfo-mac.xml").write_text(appcast(
            version, "Mac", f"{release}/{dmg.name}", signature, length, notes_html(de[1], "mac"),
            extra_item=f"\n      <sparkle:criticalUpdate sparkle:version=\"{FIRST_AUTO_INSTALL_VERSION}\"></sparkle:criticalUpdate>"
                       f"\n      <sparkle:minimumSystemVersion>{min_macos}</sparkle:minimumSystemVersion>"),
            encoding="utf-8", newline="\n")
        feeds.append(out / "updateinfo-mac.xml")

        signature, length = sign(tool, out / setup.name, key_args)
        (out / "updateinfo-win.xml").write_text(appcast(
            version, "Windows", f"{release}/{setup.name}", signature, length, notes_html(de[1], "windows"),
            extra_enclosure=f' sparkle:os="windows" sparkle:installerArguments="{WINDOWS_INSTALLER_ARGS}"',
            extra_item=WINDOWS_CRITICAL),
            encoding="utf-8", newline="\n")
        feeds.append(out / "updateinfo-win.xml")

        # Beta-Datei: stabiler Eintrag dieser Fassung, dazu eine Beta nur, wenn es eine höhere gibt.
        items = [extract_items((out / "updateinfo-mac.xml").read_text(encoding="utf-8"))[0]]
        newer = newest_local_beta_item(root)
        if newer is not None and version_order(item_version(newer)) > version_order(version):
            items.append(newer)
        (out / BETA_FEED).write_text(feed_text("Mac, Beta", items), encoding="utf-8", newline="\n")
        feeds.append(out / BETA_FEED)

    # Letzter Schreibschritt an den Update-Dateien: signieren. Danach nur noch lesen.
    for feed in feeds:
        sign_feed(tool, key_args, feed)
    files += feeds

    sums = "".join(f"{sha256(f)}  {f.name}\n" for f in files)
    write_text(out / "SHA256SUMS.txt", sums)
    files.append(out / "SHA256SUMS.txt")
    write_text(out / "RELEASE_NOTES.md", release_notes(version, de[1], files, en[1] if en else None, beta))

    verify_release_dir(out, version, beta, tool, key_args, min_macos)
    return out, files


# ---------------------------------------------------------------------------------------------------------------------
# Veröffentlichen

def publish_plan(out, version, beta, files, beta_release_exists, gh="gh"):
    """Die gh-Befehle in der Reihenfolge, in der sie laufen würden."""
    tag = f"{version}b{beta}" if beta else version
    base = [gh, "release"]
    notes = str(out / "RELEASE_NOTES.md")
    attach = [str(f) for f in files if f.name != BETA_FEED]
    if beta:
        a, b = parse_version(version)[:2]
        plan = [base + ["create", f"v{tag}", "--repo", GH_REPO, "--target", f"entwicklung-{a}.{b}",
                        "--title", f"Klimacontrol {tag} (Vorabversion)", "--notes-file", notes,
                        "--prerelease", "--latest=false"] + attach]
    else:
        plan = [base + ["create", f"v{tag}", "--repo", GH_REPO, "--target", "main",
                        "--title", f"Klimacontrol {tag}", "--notes-file", notes, "--latest"] + attach]
    if not beta_release_exists:
        plan.append(base + ["create", "beta", "--repo", GH_REPO, "--prerelease", "--latest=false", "--target", "main",
                            "--title", "Beta-Kanal (Mac)",
                            "--notes", "Trägt nur die Datei updateinfo-mac-beta.xml für den Beta-Kanal der Mac-App."])
    plan.append(base + ["upload", "beta", str(out / BETA_FEED), "--repo", GH_REPO, "--clobber"])
    return plan


def check_publish_plan(plan, beta):
    """Letzte Sicherung vor dem ersten gh-Aufruf: Schalter stimmen, die Beta-Datei hängt nur am Release „beta“."""
    first = plan[0]
    ok = (("--prerelease" in first and "--latest=false" in first and "--latest" not in first) if beta
          else ("--latest" in first and "--prerelease" not in first and "--latest=false" not in first))
    if not ok:
        fail("Veröffentlichungsplan hat falsche Schalter für latest/Vorabrelease.")
    if any(a.endswith(BETA_FEED) for a in first):
        fail(f"{BETA_FEED} darf nicht an das Versions-Release gehängt werden.")


def publish(out, version, beta, files):
    gh = shutil.which("gh")
    if not gh:
        fail("GitHub CLI fehlt (brew install gh, danach gh auth login) – oder den Ordner im Browser hochladen.")
    tag = f"{version}b{beta}" if beta else version
    r = run_tool([gh, "release", "view", f"v{tag}", "--repo", GH_REPO])
    if r.returncode == 0:
        fail(f"Das Release v{tag} gibt es schon; Tags sind unveränderlich. Nichts veröffentlicht.")
    if "not found" not in (r.stderr + r.stdout).lower():
        fail(f"Release v{tag} ließ sich nicht abfragen (gh angemeldet?): {r.stderr.strip() or r.stdout.strip()}")
    beta_exists = run_tool([gh, "release", "view", "beta", "--repo", GH_REPO]).returncode == 0
    plan = publish_plan(out, version, beta, files, beta_exists, gh)
    check_publish_plan(plan, beta)
    for cmd in plan:
        print("+ " + " ".join(cmd))
        r = subprocess_run(cmd)
        if r.returncode != 0:
            fail(f"gh ist fehlgeschlagen ({' '.join(cmd[:3])}); der Release-Ordner {out.name} ist vollständig.")
    print(f"Veröffentlicht: {REPO}/releases/tag/v{tag}")


def subprocess_run(cmd):
    try:
        return subprocess.run(cmd)
    except OSError as e:
        fail(f"{cmd[0]} ließ sich nicht starten: {e}")


# ---------------------------------------------------------------------------------------------------------------------
# Prüfung nach dem Veröffentlichen (D3/8) und Notbremse (D4)

def http_get(url):
    try:
        with urllib.request.urlopen(urllib.request.Request(url), timeout=20) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, b""
    except (urllib.error.URLError, OSError):
        return 0, b""


def http_head(url):
    try:
        with urllib.request.urlopen(urllib.request.Request(url, method="HEAD"), timeout=20) as r:
            return r.status
    except urllib.error.HTTPError as e:
        return e.code
    except (urllib.error.URLError, OSError):
        return 0


def check_published(version, tool, key_args):
    """Liest nur. Gibt die Anzahl der Fehler zurück."""
    errors = 0

    def report(ok, text):
        nonlocal errors
        print(f"  {'ok   ' if ok else 'FEHLT'}  {text}")
        errors += 0 if ok else 1

    feeds = [("latest Mac", f"{REPO}/releases/latest/download/updateinfo-mac.xml", version),
             ("latest Windows", f"{REPO}/releases/latest/download/updateinfo-win.xml", version),
             ("beta Mac", f"{REPO}/releases/download/beta/{BETA_FEED}", version)]
    with tempfile.TemporaryDirectory() as tmp:
        for label, url, expected in feeds:
            print(f"{label}: {url}")
            status, body = http_get(url)
            report(status == 200, f"HTTP {status}")
            if status != 200:
                continue
            path = Path(tmp) / url.rsplit("/", 1)[-1]
            path.write_bytes(body)
            try:
                items = ET.parse(path).getroot().findall(".//item")
            except ET.ParseError:
                report(False, "gültiges XML")
                continue
            versions = [(i.findtext(_q("version")) or "").strip() for i in items]
            report(expected in versions, f"Version {expected} enthalten (gefunden: {versions})")
            r = run_tool([str(tool), *key_args, "--verify", str(path)])
            report(r.returncode == 0 and b"sparkle-signatures" in body, "eingebettete Signatur gültig")
            for i in items:
                enc = i.find("enclosure")
                if enc is not None and (i.findtext(_q("version")) or "").strip() == expected:
                    report(http_head(enc.get("url") or "") == 200, f"Archiv erreichbar: {enc.get('url')}")
    print("Ergebnis: " + ("alles in Ordnung" if not errors else f"{errors} Fehler"))
    return errors


ROLLBACK_NOTE = """Hinweise:
  - Die Korrektur erscheint als nächste Fehlerbehebungs-Version (z. B. 1.2.0.1). Nichts löschen, keine Tags verschieben.
  - Fassungen ab 1.2.0.0 verlangen eine signierte Update-Datei. Die Datei von 1.1.0.0 ist nicht signiert; installierte
    1.2.0.0 lehnen sie ab. Das ist harmlos: Sie bekommen dann kein Update, bis die Korrektur erscheint."""


def rollback_commands(broken, previous):
    for t in (broken, previous):
        if not re.fullmatch(r"v?\d+\.\d+\.\d+\.\d+(b\d+)?", t):
            fail(f"{t!r} ist kein Tag der Form a.b.c.d[b<n>].")
    broken, previous = (t if t.startswith("v") else f"v{t}" for t in (broken, previous))
    return [["gh", "release", "edit", broken, "--repo", GH_REPO, "--prerelease"],
            ["gh", "release", "edit", previous, "--repo", GH_REPO, "--latest"]]


def rollback(broken, previous, execute):
    cmds = rollback_commands(broken, previous)
    print("Notbremse:")
    for c in cmds:
        print("  " + " ".join(c))
    print(ROLLBACK_NOTE)
    if not execute:
        print("Nichts ausgeführt. Mit --execute werden beide Befehle nacheinander ausgeführt.")
        return
    for c in cmds:
        print("+ " + " ".join(c))
        if subprocess_run(c).returncode != 0:
            fail(f"{' '.join(c)} ist fehlgeschlagen; weitere Befehle nicht ausgeführt.")


def main(argv=None):
    parser = argparse.ArgumentParser(description="Release-Ordner zusammenstellen, prüfen, veröffentlichen.")
    parser.add_argument("--key-file", type=Path, help="privater EdDSA-Schlüssel als Datei statt aus dem Schlüsselbund")
    parser.add_argument("--beta", type=int, metavar="N", help="Beta <VERSION>b<N> erzeugen (nur Mac)")
    parser.add_argument("--stable-feed", type=Path, help="stabile updateinfo-mac.xml für die Beta-Update-Datei")
    parser.add_argument("--fetch-stable", action="store_true", help="stabile Update-Datei notfalls aus dem Netz laden")
    parser.add_argument("--publish", action="store_true", help="Release per GitHub CLI anlegen und hochladen")
    parser.add_argument("--check-published", nargs="?", const="", metavar="VERSION",
                        help="veröffentlichte Update-Dateien prüfen (liest nur)")
    parser.add_argument("--rollback", nargs=2, metavar=("KAPUTT", "VORIGE"), help="Notbremse: Befehle anzeigen")
    parser.add_argument("--execute", action="store_true", help="mit --rollback: Befehle ausführen")
    args = parser.parse_args(argv)
    if args.key_file and not args.key_file.is_file():
        fail(f"Schlüsseldatei {args.key_file} fehlt.")
    if args.beta is not None and args.beta < 1:
        fail("--beta erwartet eine ganze Zahl ab 1.")
    if args.execute and not args.rollback:
        fail("--execute gehört nur zu --rollback.")
    if args.rollback:
        rollback(args.rollback[0], args.rollback[1], args.execute)
        return
    key_args = key_args_for(args.key_file)
    version = read_text(ROOT, "tools/VERSION").strip()
    tool = sign_update_tool(ROOT)
    if args.check_published is not None:
        expected = args.check_published or version
        try:
            parse_version(expected)
        except ValueError as e:
            fail(str(e))
        sys.exit(1 if check_published(expected, tool, key_args) else 0)

    out, files = build_release(ROOT, tool, key_args, version, args.beta, args.stable_feed, args.fetch_stable)
    print(f"Release-Ordner: {out.relative_to(ROOT)}")
    for f in files:
        print(f"  {f.name}")
    print("  RELEASE_NOTES.md (Beschreibung, nicht anhängen)")

    tag = f"{version}b{args.beta}" if args.beta else version
    if args.publish:
        publish(out, version, args.beta, files)
    else:
        print(f"Hochladen: {REPO}/releases/new?tag=v{tag} – Dateien oben anhängen, Text aus RELEASE_NOTES.md"
              + (", als Vorabrelease." if args.beta else ", „Set as the latest release“, kein Vorabrelease.")
              + " Oder: python3 tools/make_release.py --publish. "
              f"Die Datei {BETA_FEED} gehört an das Vorabrelease „beta“.")


if __name__ == "__main__":
    try:
        main()
    except OSError as e:
        fail(f"{e.strerror or e}{f': {e.filename}' if e.filename else ''}")
