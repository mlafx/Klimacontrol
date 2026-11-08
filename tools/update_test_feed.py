#!/usr/bin/env python3
"""Lokaler Testaufbau für Mac-Updates (D3/1 und D3/3 vor dem Release). Führt selbst nichts an der App aus.

    python3 tools/update_test_feed.py --dmg <DMG> [--version <V>] [--port 8765] [--key-file <Datei>]
                                      [--unsigned] [--serve] [--base-url <URL>]
    python3 tools/update_test_feed.py --serve-only <Ordner> [--port 8765]    # vorhandenen Ordner nur ausliefern

Legt ~/Library/Caches/Klimacontrol-update-test/ an (ein vorhandener Ordner wird beiseite gelegt, nicht gelöscht), kopiert
das DMG hinein, signiert es mit Sparkles sign_update, schreibt updateinfo-mac.xml (Enclosure <base-url>/<DMG>, Hinweise aus
CHANGELOG.md, falls es die Version dort gibt), signiert die Update-Datei als letzten Schritt und prüft sie. Danach druckt
es die Anleitung. Mit --serve liefert es den Ordner über http.server, nur an 127.0.0.1, bis Strg+C.

    D3/1  originales DMG 1.1.0.0 installieren, --dmg <neues DMG 1.2.0.0>: 1.1.0.0 soll still auf 1.2.0.0 aktualisieren.
    D3/3  1.2.0.0 installiert, --dmg <DMG> --version 1.2.0.1 (Probefassung): "Jetzt neu starten · Später".
          Dasselbe mit --unsigned: Die Update-Datei hat keine eingebettete Signatur, 1.2 muss sie ablehnen. Das DMG im
          Enclosure bleibt signiert; abgelehnt werden soll die Update-Datei.

Ohne --key-file liest sign_update den Schlüssel aus dem Schlüsselbund (Konto "klimacontrol"); das fragt macOS evtl.
nach. --sign-tool gibt es nur für Proben mit einem nachgebildeten sign_update.

Geklärt aus Quellen (nicht an der App ausprobiert; endgültig zeigt es erst der Test in Phase 7):

1. Reihenfolge der Update-Adresse in Sparkle: Delegate (feedURLStringForUpdater:) vor SUFeedURL in den Einstellungen
   (defaults write) vor SUFeedURL der Info.plist. Beleg: Warntext im Sparkle-2.10.1-Binärcode ("A feed URL was found
   stored in user defaults ... If the feed url was set via a defaults write command for testing purposes, then please
   ignore this warning.") und SPUUpdaterDelegate.h. Ab 1.2 liefert der Delegate ohne Beta nil (Phase 3a); sonst wirkte
   defaults write nicht. 1.1.0.0 hat keinen Delegate, dort gilt die Umleitung ohnehin.

2. http://127.0.0.1 statt HTTPS ist ohne Info.plist-Ausnahme zulässig:
   - Apple (Information Property List Key Reference, NSAppTransportSecurity, "Availability of ATS for Remote and Local
     Connections"): "App Transport Security (ATS) applies only to connections made to public host names. The system does
     not provide ATS protection to connections made to: Internet protocol (IP) addresses; Unqualified host names; Local
     hosts employing the .local top-level domain (TLD)." NSAllowsLocalNetworking (ab macOS 10.12) wird laut Apple nur für
     unqualifizierte Namen und .local verlangt: "To connect to an unqualified host name or to a .local domain, you must
     set the value of the NSAllowsLocalNetworking key to YES." Eine IP-Adresse ist also ausgenommen. Folge: die Adresse
     muss 127.0.0.1 lauten, NICHT "localhost" (unqualifizierter Name, bräuchte NSAllowsLocalNetworking, die Info.plist
     von 1.1.0.0 hat keine ATS-Ausnahme).
   - Sparkle 2.10.1 (SPUUpdater.m, checkIfConfiguredProperlyAndRequireFeedURL) blockiert http nicht, sondern loggt nur
     "The feed URL (%@) may need to change to use HTTPS. If the feed URL is using local networking for testing, this
     warning may be incorrect and ignored however." (wenn die App kein NSAppTransportSecurity hat). Das Protokoll von
     Sparkle enthält diese Zeile also; sie ist hier zu ignorieren. Vorbehalt: Apples Seite ist nur als Dokument, nicht
     durch Ausprobieren belegt.

3. Rückfälle, falls der Test doch an ATS scheitert (Fehler "App Transport Security policy requires the use of a secure
   connection" im Sparkle-Protokoll):
   (a) file://: Für die Update-Datei selbst unbelegt; für das DMG im Enclosure ausgeschlossen: Sparkle 2.10.1 meldet
       "The download request URL must use http or https (%@)". Also kein Rückfall.
   (b) Lokales HTTPS mit eigenem Zertifikat (--base-url https://127.0.0.1:<port>): Markus muss das Zertifikat in seinem
       Anmelde-Schlüsselbund als vertrauenswürdig für SSL eintragen (Schlüsselbundverwaltung, Vertrauen,
       "Immer vertrauen"); das Skript liefert nur HTTP und braucht dafür einen TLS-Proxy (z. B. `caddy reverse-proxy
       --from https://127.0.0.1:8443 --to 127.0.0.1:8765` mit `tls internal`) oder man startet http.server selbst mit
       ssl.wrap_socket. Das Zertifikat danach wieder aus dem Schlüsselbund entfernen.
   (c) Gegenprobe ohne neue Datei: In der Anleitung unten wird nichts an der Info.plist der installierten App geändert;
       diese Ausnahme nicht eintragen (würde die Signatur der App brechen).
"""

import argparse
import functools
import http.server
import importlib.util
import shutil
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
CACHE = Path.home() / "Library/Caches/Klimacontrol-update-test"
BUNDLE_ID = "de.mlafx.klimacontrol"


def load_release_tools():
    spec = importlib.util.spec_from_file_location("make_release_for_feed", HERE / "make_release.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def notes_for(mr, version):
    try:
        text = mr.read_text(ROOT, "CHANGELOG.md")
    except SystemExit:
        text = ""
    section = mr.changelog_section(text, version, required=False) if text else None
    if section:
        return mr.notes_html(section[1], "mac")
    return f"<p>Probefassung {version} für den lokalen Update-Test. Kein Eintrag im CHANGELOG.</p>"


def build_feed_dir(mr, tool, key_args, dmg, version, base_url, unsigned, out=CACHE):
    """Ordner mit DMG und updateinfo-mac.xml erzeugen. Gibt (Ordner, Pfad der Update-Datei) zurück."""
    if not dmg.is_file():
        mr.fail(f"{dmg} fehlt.")
    try:
        mr.parse_version(version)
    except ValueError as e:
        mr.fail(str(e))
    mr.rotate_existing(out)
    out.mkdir(parents=True)
    target = out / dmg.name
    shutil.copy2(dmg, target)
    signature, length = mr.sign(tool, target, key_args)
    min_macos = mr.read_min_macos(ROOT)
    feed = out / "updateinfo-mac.xml"
    mr.write_text(feed, mr.appcast(
        version, "Mac", f"{base_url}/{dmg.name}", signature, length, notes_for(mr, version),
        extra_item=f"\n      <sparkle:criticalUpdate sparkle:version=\"{mr.FIRST_AUTO_INSTALL_VERSION}\"></sparkle:criticalUpdate>"
                   f"\n      <sparkle:minimumSystemVersion>{min_macos}</sparkle:minimumSystemVersion>"))
    if not unsigned:
        mr.sign_feed(tool, key_args, feed)  # letzter Schreibschritt, prüft sich selbst
    elif "sparkle-signatures" in feed.read_text(encoding="utf-8"):
        mr.fail("--unsigned: die Update-Datei enthält unerwartet eine Signatur.")
    return out, feed


def instructions(feed_url, version, unsigned):
    d3 = ("D3/3 (unsignierte Update-Datei): Es darf KEIN Update erscheinen; im Sparkle-Protokoll steht ein Fehler zur "
          "fehlenden bzw. ungültigen Signatur der Update-Datei." if unsigned else "")
    return f"""
Anleitung (nichts davon hat das Skript ausgeführt):

1. Server läuft (--serve) oder in einem zweiten Terminal:  python3 tools/update_test_feed.py --dmg <DMG> --serve
2. Update-Adresse nur zum Test umleiten:
       defaults write {BUNDLE_ID} SUFeedURL {feed_url}
3. Klimacontrol starten bzw. Menü Klimacontrol -> "Nach Updates suchen ...". Mitlesen:
       tail -f ~/Library/Application\\ Support/Klimacontrol/klimacontrol.log
       log stream --predicate 'subsystem BEGINSWITH "org.sparkle-project"'
   (Die Warnung "may need to change to use HTTPS ... local networking for testing" ist hier zu ignorieren.)
4. DANACH IMMER:
       defaults delete {BUNDLE_ID} SUFeedURL
5. Prüfliste ({version}):
   D3/1  still installiert, App startet neu, "Neu in Klimacontrol ..." erscheint, Einstellungen (Anlage, Verbindung,
         Darstellung) erhalten, keine neuen Rückfragen (Netzwerk, Schlüsselbund, Anmeldeobjekt).
   D3/3  Hinweis "Jetzt neu starten · Später"; mit --unsigned: kein Update, Fehler im Sparkle-Protokoll.
   {d3}
"""


def serve(directory, port):
    handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=str(directory))
    with http.server.ThreadingHTTPServer(("127.0.0.1", port), handler) as httpd:
        print(f"Server: http://127.0.0.1:{port}/ (nur diese Adresse), Ordner {directory}. Beenden mit Strg+C.")
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            print("\nServer beendet. Nicht vergessen: defaults delete " + BUNDLE_ID + " SUFeedURL")


def main(argv=None):
    parser = argparse.ArgumentParser(description="Lokale Update-Datei für den Update-Test D3/1 und D3/3.")
    parser.add_argument("--dmg", type=Path, help="DMG, auf das aktualisiert werden soll (außer mit --serve-only)")
    parser.add_argument("--serve-only", type=Path, metavar="ORDNER",
                        help="vorhandenen Ordner nur ausliefern (127.0.0.1), nichts bauen oder signieren")
    parser.add_argument("--version", help="Version in der Update-Datei (Standard: tools/VERSION)")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--key-file", type=Path, help="privater EdDSA-Schlüssel als Datei statt aus dem Schlüsselbund")
    parser.add_argument("--unsigned", action="store_true", help="Update-Datei ohne eingebettete Signatur (D3/3)")
    parser.add_argument("--serve", action="store_true", help="Ordner über http.server auf 127.0.0.1 ausliefern")
    parser.add_argument("--base-url", help="Adresse des Ordners statt http://127.0.0.1:<port> (z. B. lokales HTTPS)")
    parser.add_argument("--sign-tool", type=Path, help="nur für Proben: nachgebildetes sign_update")
    parser.add_argument("--out-dir", type=Path, default=CACHE, help="nur für Proben: anderer Ausgabeordner")
    args = parser.parse_args(argv)
    if args.serve_only:
        if not args.serve_only.is_dir():
            parser.error(f"Ordner {args.serve_only} fehlt.")
        serve(args.serve_only, args.port)
        return
    if not args.dmg:
        parser.error("--dmg fehlt (oder --serve-only <Ordner>).")
    mr = load_release_tools()
    if args.key_file and not args.key_file.is_file():
        mr.fail(f"Schlüsseldatei {args.key_file} fehlt.")
    version = args.version or mr.read_text(ROOT, "tools/VERSION").strip()
    base_url = (args.base_url or f"http://127.0.0.1:{args.port}").rstrip("/")
    tool = args.sign_tool or mr.sign_update_tool(ROOT)
    out, feed = build_feed_dir(mr, tool, mr.key_args_for(args.key_file), args.dmg, version, base_url,
                               args.unsigned, args.out_dir)
    print(f"Ordner: {out}")
    for f in sorted(out.iterdir()):
        print(f"  {f.name}")
    print(instructions(f"{base_url}/{feed.name}", version, args.unsigned))
    if args.serve:
        serve(out, args.port)
    else:
        print("Zum Ausliefern dieselbe Zeile mit --serve noch einmal starten.")


if __name__ == "__main__":
    try:
        main()
    except OSError as e:
        print(f"Abbruch: {e.strerror or e}{f': {e.filename}' if e.filename else ''}", file=sys.stderr)
        sys.exit(1)
