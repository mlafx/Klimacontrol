#!/usr/bin/env python3
"""Lokaler Testaufbau für Windows-Updates (D3/2 und D3/3 vor dem Release). Führt selbst nichts an der App aus.

    python tools/update_test_feed_win.py --setup <Setup.exe> --version <V> --key-file <Datei> [--port 8765]
                                         [--out <Ordner>] [--unsigned | --bad-signature] [--serve]
                                         [--public-key-file <Datei>]
    python tools/update_test_feed_win.py --serve-only <Ordner> [--port 8765]    # vorhandenen Ordner nur ausliefern
    python tools/update_test_feed_win.py --selftest                             # Ed25519 gegen RFC 8032

Legt %USERPROFILE%\\Klimacontrol-update-test an (bewusst nicht AppData: die Claude-Desktop-App virtualisiert AppData;
ein vorhandener Ordner wird in "...-alt-<UTC-Zeitstempel>" umbenannt, nie gelöscht), kopiert das Setup hinein, signiert
es mit Ed25519 (sparkle:edSignature = Base64 der Signatur über die Setup-Bytes) und schreibt updateinfo-win.xml mit der
Enclosure-Adresse http://127.0.0.1:<port>/<Setup>. Der Aufbau kommt aus tools/make_release.py (appcast, Hinweise aus
CHANGELOG.md, sparkle:os="windows", installerArguments), damit die Datei dem echten updateinfo-win.xml entspricht.
Mit --serve liefert das Skript den Ordner über http.server, nur an 127.0.0.1, bis Strg+C.

    D3/2  1.1.0.0 installieren, --setup <Setup 1.2.0.0>: 1.1.0.0 soll auf 1.2.0.0 aktualisieren. 1.1.0.0 fragt fest
          https://github.com/... und ist nicht umleitbar; dieser Test braucht daher einen anderen Weg als die Variable.
    D3/3  1.2.0.0 installiert, --setup <Setup> --version 1.2.0.1 (Probefassung), Klimacontrol.exe mit gesetzter Variable
          starten:  set KLIMACONTROL_UPDATE_TEST_FEED=http://127.0.0.1:<port>/updateinfo-win.xml
          Ab 1.2.0.0 liest Updates.cs diese Variable (nur http://127.0.0.1:<port>/..., sonst wirkungslos).
          --unsigned: Enclosure ohne sparkle:edSignature, --bad-signature: gültig aussehende, aber falsche Signatur
          (über die Setup-Bytes plus ein angehängtes Byte). In beiden Fällen muss WinSparkle die Installation ablehnen.

Schlüssel: --key-file enthält den privaten Sparkle-Schlüssel als Base64 (32 Byte Seed oder 64 Byte Seed + öffentlicher
Schlüssel). Der daraus abgeleitete öffentliche Schlüssel muss tools/UPDATE_PUBLIC_KEY entsprechen (--public-key-file nur für
Proben). Der Schlüssel wird nie ausgegeben oder geschrieben; Ausnahmen beim Einlesen werden nur allgemein gemeldet. Das
Skript schreibt nichts in das Repo. Die signierten Testdateien nach dem Test in den Papierkorb legen.
Signatur des Feeds selbst (eingebettet wie am Mac) gibt es hier nicht: WinSparkle prüft nur die Signatur des Setups.
"""

import argparse
import base64
import datetime
import functools
import hashlib
import http.server
import importlib.util
import re
import shutil
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
DEFAULT_OUT = Path.home() / "Klimacontrol-update-test"

# ---------------------------------------------------------------------------------------------------------------
# Ed25519 nach RFC 8032 (Abschnitt 5.1 und 6), reines Python mit Ganzzahlen. Nicht zeitkonstant: nur für Testdateien.

_P = 2**255 - 19
_Q = 2**252 + 27742317777372353535851937790883648493
_D = -121665 * pow(121666, _P - 2, _P) % _P
_I = pow(2, (_P - 1) // 4, _P)


def _sha512(data):
    return hashlib.sha512(data).digest()


def _inv(x):
    return pow(x, _P - 2, _P)


def _recover_x(y, sign):
    if y >= _P:
        return None
    x2 = (y * y - 1) * _inv(_D * y * y + 1) % _P
    if x2 == 0:
        return None if sign else 0
    x = pow(x2, (_P + 3) // 8, _P)
    if (x * x - x2) % _P != 0:
        x = x * _I % _P
    if (x * x - x2) % _P != 0:
        return None
    if (x & 1) != sign:
        x = _P - x
    return x


_GY = 4 * _inv(5) % _P
_GX = _recover_x(_GY, 0)
_G = (_GX, _GY, 1, _GX * _GY % _P)
_ZERO = (0, 1, 1, 0)


def _add(a, b):
    x1, y1, z1, t1 = a
    x2, y2, z2, t2 = b
    aa = (y1 - x1) * (y2 - x2) % _P
    bb = (y1 + x1) * (y2 + x2) % _P
    cc = 2 * t1 * t2 * _D % _P
    dd = 2 * z1 * z2 % _P
    e, f, g, h = bb - aa, dd - cc, dd + cc, bb + aa
    return (e * f % _P, g * h % _P, f * g % _P, e * h % _P)


def _mul(s, pt):
    r = _ZERO
    while s > 0:
        if s & 1:
            r = _add(r, pt)
        pt = _add(pt, pt)
        s >>= 1
    return r


def _equal(a, b):
    return (a[0] * b[2] - b[0] * a[2]) % _P == 0 and (a[1] * b[2] - b[1] * a[2]) % _P == 0


def _compress(pt):
    zi = _inv(pt[2])
    x, y = pt[0] * zi % _P, pt[1] * zi % _P
    return int.to_bytes(y | ((x & 1) << 255), 32, "little")


def _decompress(s):
    if len(s) != 32:
        return None
    y = int.from_bytes(s, "little")
    sign = y >> 255
    y &= (1 << 255) - 1
    x = _recover_x(y, sign)
    return None if x is None else (x, y, 1, x * y % _P)


def _expand(seed):
    h = _sha512(seed)
    a = int.from_bytes(h[:32], "little")
    a &= (1 << 254) - 8
    a |= 1 << 254
    return a, h[32:]


def public_from_seed(seed):
    a, _ = _expand(seed)
    return _compress(_mul(a, _G))


def sign(seed, msg):
    a, prefix = _expand(seed)
    pub = _compress(_mul(a, _G))
    r = int.from_bytes(_sha512(prefix + msg), "little") % _Q
    rs = _compress(_mul(r, _G))
    h = int.from_bytes(_sha512(rs + pub + msg), "little") % _Q
    s = (r + h * a) % _Q
    return rs + int.to_bytes(s, 32, "little")


def verify(pub, msg, sig):
    if len(pub) != 32 or len(sig) != 64:
        return False
    a_pt = _decompress(pub)
    r_pt = _decompress(sig[:32])
    if a_pt is None or r_pt is None:
        return False
    s = int.from_bytes(sig[32:], "little")
    if s >= _Q:
        return False
    h = int.from_bytes(_sha512(sig[:32] + pub + msg), "little") % _Q
    return _equal(_mul(s, _G), _add(r_pt, _mul(h, a_pt)))


# RFC 8032, Abschnitt 7.1, TEST 1 und TEST 2
_VECTORS = [
    ("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60",
     "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a",
     "",
     "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e06522490155"
     "5fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b"),
    ("4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb",
     "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c",
     "72",
     "92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da"
     "085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00"),
]


def selftest():
    for seed_hex, pub_hex, msg_hex, sig_hex in _VECTORS:
        seed, pub, msg, sig = (bytes.fromhex(x) for x in (seed_hex, pub_hex, msg_hex, sig_hex))
        if public_from_seed(seed) != pub:
            return "öffentlicher Schlüssel stimmt nicht mit RFC 8032 überein"
        if sign(seed, msg) != sig:
            return "Signatur stimmt nicht mit RFC 8032 überein"
        if not verify(pub, msg, sig):
            return "RFC-8032-Signatur wird nicht akzeptiert"
        if verify(pub, msg + b"x", sig):
            return "veränderte Nachricht wird akzeptiert"
    seed = hashlib.sha256(b"selftest").digest()
    msg = b"eigene Probe" * 100
    own = sign(seed, msg)
    if not verify(public_from_seed(seed), msg, own):
        return "eigene Signatur wird nicht akzeptiert"
    if verify(public_from_seed(seed), msg, own[:-1] + bytes([own[-1] ^ 1])):
        return "verfälschte Signatur wird akzeptiert"
    return None


# ---------------------------------------------------------------------------------------------------------------

def load_release_tools():
    spec = importlib.util.spec_from_file_location("make_release_for_feed", HERE / "make_release.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def load_seed(path, public_key_file):
    """Seed (32 Byte) aus der Schlüsseldatei; prüft gegen den öffentlichen Schlüssel. Meldet nie Schlüsselteile."""
    try:
        raw = base64.b64decode(re.sub(r"\s+", "", path.read_text(encoding="ascii")), validate=True)
    except Exception:  # bewusst allgemein: keine Teile des Inhalts in Meldungen oder Tracebacks
        raw = None
    if raw is None:
        fail("Schlüsseldatei nicht lesbar oder kein Base64.")
    seed = None
    if len(raw) == 32:
        seed = raw
    elif len(raw) == 64:
        seed = raw[:32]
        if public_from_seed(seed) != raw[32:]:
            fail("Schlüsseldatei ist in sich nicht stimmig.")
    else:
        fail("Schlüsselformat nicht unterstützt (erwartet: Base64 von 32 oder 64 Byte).")
    try:
        expected = public_key_file.read_text(encoding="ascii").strip()
    except (OSError, UnicodeDecodeError):
        fail(f"{public_key_file} nicht lesbar.")
    if base64.b64encode(public_from_seed(seed)).decode("ascii") != expected:
        fail("Schlüssel passt nicht zu tools/UPDATE_PUBLIC_KEY")
    return seed


def fail(text):
    print(f"Abbruch: {text}", file=sys.stderr)
    sys.exit(1)


# WinSparkle 0.9.4 zeigt die Hinweise ohne eigene Farben in WebView2 (ui.cpp, ShowReleaseNotes: SetPage(Description)).
# Im dunklen Windows-Modus wird die Fläche dort fast schwarz, der Text bleibt schwarz. Darum ausdrücklich Hinter- und
# Vordergrund für hell und dunkel (Kontrast >= 6,6:1). Gleicher Block wie im Vorschlag für make_release.py; steht er
# dort schon in den Hinweisen, wird er nicht doppelt eingefügt.
WINDOWS_NOTES_STYLE = (
    "<style>\n"
    ":root{color-scheme:light dark}\n"
    "html,body{background:#ffffff;color:#1f1f1f}\n"
    "a{color:#0f5bb5}\n"
    "@media (prefers-color-scheme: dark){html,body{background:#1f1f1f;color:#f3f3f3}a{color:#8cc4ff}}\n"
    "</style>\n"
)


def with_windows_style(notes):
    return notes if "<style" in notes else WINDOWS_NOTES_STYLE + notes


def notes_for(mr, version):
    try:
        text = (ROOT / "CHANGELOG.md").read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        text = ""
    section = mr.changelog_section(text, version, required=False) if text else None
    if section:
        return with_windows_style(mr.notes_html(section[1], "windows"))
    return with_windows_style(f"<p>Probefassung {version} für den lokalen Update-Test. Kein Eintrag im CHANGELOG.</p>")


def rotate(out):
    """Vorhandenen Ordner nicht löschen, sondern in …-alt-<UTC> umbenennen."""
    if not out.exists():
        return
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%d-%H%M%SZ")
    target = out.with_name(f"{out.name}-alt-{stamp}")
    n = 1
    while target.exists():
        n += 1
        target = out.with_name(f"{out.name}-alt-{stamp}-{n}")
    out.rename(target)
    print(f"Vorhandener Ordner beiseite gelegt: {target.name}")


def build_feed_dir(mr, setup, version, base_url, seed, pub, out, mode):
    """mode: 'signed' | 'unsigned' | 'bad'. Gibt (Ordner, Update-Datei) zurück."""
    if not setup.is_file():
        fail(f"{setup} fehlt.")
    try:
        mr.parse_version(version)
    except ValueError as e:
        fail(str(e))
    rotate(out)
    out.mkdir(parents=True)
    target = out / setup.name
    shutil.copy2(setup, target)
    data = target.read_bytes()
    signature = base64.b64encode(sign(seed, data + b"\0" if mode == "bad" else data)).decode("ascii")
    xml = mr.appcast(
        version, "Windows", f"{base_url}/{setup.name}", signature, len(data), notes_for(mr, version),
        extra_enclosure=f' sparkle:os="windows" sparkle:installerArguments="{mr.WINDOWS_INSTALLER_ARGS}"',
        extra_item=mr.WINDOWS_CRITICAL)
    if mode == "unsigned":
        xml = re.sub(r' sparkle:edSignature="[^"]*"', "", xml)
        if "edSignature" in xml:
            fail("--unsigned: die Update-Datei enthält unerwartet eine Signatur.")
    feed = out / "updateinfo-win.xml"
    mr.write_text(feed, xml)
    if mode == "signed":
        m = re.search(r'sparkle:edSignature="([^"]+)"', feed.read_text(encoding="utf-8"))
        if not m or not verify(pub, target.read_bytes(), base64.b64decode(m.group(1))):
            fail("Signatur des Setups ist ungültig.")
        print("Signatur gültig")
    return out, feed


def serve(directory, port):
    handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=str(directory))
    with http.server.ThreadingHTTPServer(("127.0.0.1", port), handler) as httpd:
        print(f"Server: http://127.0.0.1:{port}/ (nur diese Adresse), Ordner {directory}. Beenden mit Strg+C.")
        print(f"Zum Testen in der Eingabeaufforderung vor dem Start der App:  "
              f"set KLIMACONTROL_UPDATE_TEST_FEED=http://127.0.0.1:{port}/updateinfo-win.xml")
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            print("\nServer beendet.")


def main(argv=None):
    parser = argparse.ArgumentParser(description="Lokale Update-Datei für den Windows-Update-Test (D3/2, D3/3).")
    parser.add_argument("--setup", type=Path, help="Setup, auf das aktualisiert werden soll")
    parser.add_argument("--version", help="Version in der Update-Datei (Standard: tools/VERSION)")
    parser.add_argument("--key-file", type=Path, help="privater Sparkle-Schlüssel (Base64), wird nie ausgegeben")
    parser.add_argument("--public-key-file", type=Path, default=HERE / "UPDATE_PUBLIC_KEY",
                        help="nur für Proben: anderer öffentlicher Schlüssel (Standard tools/UPDATE_PUBLIC_KEY)")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT, help="Ausgabeordner (Standard %%USERPROFILE%%\\Klimacontrol-update-test)")
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--unsigned", action="store_true", help="Enclosure ohne sparkle:edSignature")
    group.add_argument("--bad-signature", action="store_true", help="gültig aussehende, aber falsche Signatur")
    parser.add_argument("--serve", action="store_true", help="Ordner über http.server auf 127.0.0.1 ausliefern")
    parser.add_argument("--serve-only", type=Path, metavar="ORDNER", help="vorhandenen Ordner nur ausliefern")
    parser.add_argument("--selftest", action="store_true", help="Ed25519 gegen RFC 8032 prüfen")
    args = parser.parse_args(argv)
    if args.selftest:
        problem = selftest()
        if problem:
            fail(f"selftest: {problem}")
        print("selftest ok")
        return
    if args.serve_only:
        if not args.serve_only.is_dir():
            parser.error(f"Ordner {args.serve_only} fehlt.")
        serve(args.serve_only, args.port)
        return
    if not args.setup:
        parser.error("--setup fehlt (oder --serve-only <Ordner>, --selftest).")
    if not args.key_file:
        parser.error("--key-file fehlt.")
    if not 1 <= args.port <= 65535:
        parser.error("--port außerhalb 1-65535.")
    if not args.key_file.is_file():
        fail(f"Schlüsseldatei {args.key_file} fehlt.")
    mr = load_release_tools()
    version = args.version or (ROOT / "tools/VERSION").read_text(encoding="utf-8").strip()
    seed = load_seed(args.key_file, args.public_key_file)
    pub = public_from_seed(seed)
    mode = "unsigned" if args.unsigned else "bad" if args.bad_signature else "signed"
    base_url = f"http://127.0.0.1:{args.port}"
    out, feed = build_feed_dir(mr, args.setup, version, base_url, seed, pub, args.out, mode)
    print(f"Ordner: {out}")
    for f in sorted(out.iterdir()):
        print(f"  {f.name}")
    print(f"""
Anleitung (nichts davon hat das Skript ausgeführt):
1. Server läuft (--serve) oder: python tools/update_test_feed_win.py --serve-only "{out}" --port {args.port}
2. In der Eingabeaufforderung: set KLIMACONTROL_UPDATE_TEST_FEED={base_url}/{feed.name}
   dann die installierte Klimacontrol.exe aus dieser Eingabeaufforderung starten (ab 1.2.0.0).
3. Prüfen ({version}, {mode}): signiert = Update wird angeboten und installiert; unsigned/bad = WinSparkle lehnt ab.
4. Danach die Variable löschen und den Ordner {out} in den Papierkorb legen.""")
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
