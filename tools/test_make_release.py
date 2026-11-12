#!/usr/bin/env python3
"""Selbsttest für tools/make_release.py mit Probedateien und einem nachgebildeten sign_update.

    python3 -I tools/test_make_release.py

Fasst weder den echten Schlüssel noch den Schlüsselbund, das Netz oder GitHub an. Alles läuft in Temp-Ordnern.
"""

import contextlib
import io
import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import make_release as mr  # noqa: E402

FAKE_SIGN_UPDATE = '''#!{python}
import hashlib, sys
MARK = "<!-- sparkle-signatures:\\n"
a = sys.argv[1:]
verify = "--verify" in a
args, i = [], 0
while i < len(a):
    if a[i] in ("--account", "--ed-key-file"):
        i += 2
    elif a[i] == "--verify":
        i += 1
    else:
        args.append(a[i])
        i += 1
path = args[0]
data = open(path, "rb").read()
if path.endswith(".xml"):
    mark = MARK.encode()
    if verify:
        pos = data.rfind(mark)
        if pos < 0:
            sys.exit(1)
        body, tail = data[:pos], data[pos:].decode()
        want = MARK + "edSignature: " + hashlib.sha256(body).hexdigest() + "\\nlength: " + str(len(body)) + "\\n-->\\n"
        sys.exit(0 if tail == want else 1)
    with open(path, "ab") as f:
        f.write((MARK + "edSignature: " + hashlib.sha256(data).hexdigest() + "\\nlength: " + str(len(data)) + "\\n-->\\n").encode())
    sys.exit(0)
sig = hashlib.sha256(data).hexdigest()
if verify:
    sys.exit(0 if len(args) > 1 and args[1] == sig else 1)
print('sparkle:edSignature="' + sig + '" length="' + str(len(data)) + '"')
'''


def changelog(*sections):
    return "# Changelog\n\n" + "\n".join(f"## [{v}] – {d}\n\n### Hinzugefügt\n- {t}\n" for v, d, t in sections)


class Probe:
    """Probe-Projektordner mit allem, was build_release liest."""

    def __init__(self, tmp):
        self.root = Path(tmp) / "proj"
        for d in ("tools", "dist/mac", "dist/windows"):
            (self.root / d).mkdir(parents=True)
        (self.root / "tools/build_app.sh").write_text(
            "  <key>LSMinimumSystemVersion</key><string>15.0</string>\n", encoding="utf-8")
        (self.root / "Package.swift").write_text("// Sparkle-2.9.0.xcframework.zip\n", encoding="utf-8")
        self.tool = Path(tmp) / "sign_update"
        self.tool.write_text(FAKE_SIGN_UPDATE.format(python=sys.executable), encoding="utf-8")
        self.tool.chmod(0o755)
        self.key_args = ["--ed-key-file", str(Path(tmp) / "kein-schluessel.txt")]

    def version(self, v):
        (self.root / "tools/VERSION").write_text(v + "\n", encoding="utf-8")

    def changelogs(self, de, en):
        (self.root / "CHANGELOG.md").write_text(changelog(*de), encoding="utf-8")
        (self.root / "CHANGELOG.en.md").write_text(changelog(*en), encoding="utf-8")

    def archives(self, tag, setup_version=None):
        (self.root / f"dist/mac/Klimacontrol-{tag}-mac.dmg").write_bytes(b"dmg-" + tag.encode())
        if setup_version:
            (self.root / f"dist/windows/Klimacontrol-Windows-{setup_version}-Setup.exe").write_bytes(b"setup-" + setup_version.encode())

    def build(self, version, **kw):
        return mr.build_release(self.root, self.tool, self.key_args, version, notarized_check=lambda dmg: None, **kw)

    def verify(self, out, version, beta=None):
        mr.verify_release_dir(out, version, beta, self.tool, self.key_args, "15.0")


def run_failing(fn, *a, **kw):
    err = io.StringIO()
    with contextlib.redirect_stderr(err), contextlib.redirect_stdout(io.StringIO()):
        try:
            fn(*a, **kw)
        except SystemExit as e:
            return e.code, err.getvalue()
    raise AssertionError("erwarteter Abbruch blieb aus")


def quiet(fn, *a, **kw):
    with contextlib.redirect_stdout(io.StringIO()):
        return fn(*a, **kw)


class ReleaseScriptTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.p = Probe(self._tmp.name)

    def stable(self, version="1.2.0.0", date="2026-11-20", en_date=None):
        self.p.version(version)
        self.p.changelogs([(version, date, "Neuer Punkt")], [(version, en_date or date, "New item")])
        self.p.archives(version, version)
        return quiet(self.p.build, version)

    def test_version_order(self):
        order = ["1.1.0.0", "1.2.0.0b1", "1.2.0.0b2", "1.2.0.0b10", "1.2.0.0", "1.2.0.1"]
        keys = [mr.version_order(v) for v in order]
        self.assertEqual(keys, sorted(keys))
        self.assertEqual(len(set(keys)), len(keys))
        with self.assertRaises(ValueError):
            mr.parse_version("1.2.0")

    def test_stable_run_creates_exactly_the_expected_signed_files(self):
        out, files = self.stable()
        names = {p.name for p in out.iterdir()}
        self.assertEqual(names, {
            "Klimacontrol-1.2.0.0-mac.dmg", "Klimacontrol-Windows-1.2.0.0-Setup.exe", "Klimacontrol-mac.dmg",
            "Klimacontrol-Windows-Setup.exe", "updateinfo-mac.xml", "updateinfo-win.xml", "SHA256SUMS.txt",
            "RELEASE_NOTES.md"})
        self.assertEqual(len(files), 7, "sieben Dateien am Release")
        self.assertNotIn("RELEASE_NOTES.md", {f.name for f in files})
        for feed in ("updateinfo-mac.xml", "updateinfo-win.xml"):
            text = (out / feed).read_text(encoding="utf-8")
            self.assertTrue(text.rstrip().endswith("-->"), feed)
            self.assertEqual(text.count("sparkle-signatures"), 1, feed)
            mr.verify_feed(self.p.tool, self.p.key_args, out / feed)
        self.p.verify(out, "1.2.0.0")

    def test_fixed_name_copies_are_byte_identical_and_feeds_keep_versioned_names(self):
        out, _ = self.stable()
        self.assertEqual((out / mr.LATEST_MAC_DMG).read_bytes(), (out / "Klimacontrol-1.2.0.0-mac.dmg").read_bytes())
        self.assertEqual((out / mr.LATEST_WINDOWS_SETUP).read_bytes(),
                         (out / "Klimacontrol-Windows-1.2.0.0-Setup.exe").read_bytes())
        for feed, name in (("updateinfo-mac.xml", "Klimacontrol-1.2.0.0-mac.dmg"),
                           ("updateinfo-win.xml", "Klimacontrol-Windows-1.2.0.0-Setup.exe")):
            text = (out / feed).read_text(encoding="utf-8")
            self.assertIn(f"{mr.REPO}/releases/download/v1.2.0.0/{name}", text)
            self.assertNotIn(mr.LATEST_MAC_DMG, text)
            self.assertNotIn(mr.LATEST_WINDOWS_SETUP, text)
            self.assertNotIn("/latest/", text)

    def test_checksums_list_copies_with_the_same_digest(self):
        out, _ = self.stable()
        sums = dict(reversed(line.split("  ", 1)) for line in (out / "SHA256SUMS.txt").read_text(encoding="utf-8").splitlines())
        self.assertEqual(len(sums), 6)
        self.assertEqual(sums[mr.LATEST_MAC_DMG], sums["Klimacontrol-1.2.0.0-mac.dmg"])
        self.assertEqual(sums[mr.LATEST_WINDOWS_SETUP], sums["Klimacontrol-Windows-1.2.0.0-Setup.exe"])

    def test_missing_copy_is_detected(self):
        out, _ = self.stable()
        (out / mr.LATEST_WINDOWS_SETUP).rename(self.p.root / "beiseite.exe")
        code, err = run_failing(self.p.verify, out, "1.2.0.0")
        self.assertEqual(code, 1)
        self.assertIn(f"fehlende Datei: {mr.LATEST_WINDOWS_SETUP}", err)

    def test_different_copy_is_detected(self):
        out, _ = self.stable()
        (out / mr.LATEST_MAC_DMG).write_bytes(b"anderes dmg")
        code, err = run_failing(self.p.verify, out, "1.2.0.0")
        self.assertEqual(code, 1)
        self.assertIn(f"{mr.LATEST_MAC_DMG} ist keine gleiche Kopie", err)

    def test_checksum_line_of_copy_must_match_original(self):
        out, _ = self.stable()
        sums = out / "SHA256SUMS.txt"
        lines = sums.read_text(encoding="utf-8").splitlines()
        lines = [("0" * 64 + "  " + mr.LATEST_MAC_DMG) if line.endswith("  " + mr.LATEST_MAC_DMG) else line for line in lines]
        sums.write_text("\n".join(lines) + "\n", encoding="utf-8")
        code, err = run_failing(self.p.verify, out, "1.2.0.0")
        self.assertEqual(code, 1)
        self.assertIn("dieselbe Prüfsumme", err)

    def test_release_notes_table_shows_versioned_names(self):
        out, _ = self.stable()
        notes = (out / "RELEASE_NOTES.md").read_text(encoding="utf-8")
        table = [line for line in notes.splitlines() if line.startswith("| `")]
        self.assertEqual(table, ["| `Klimacontrol-1.2.0.0-mac.dmg` | Mac: öffnen und Klimacontrol auf „Programme“ ziehen |",
                                 "| `Klimacontrol-Windows-1.2.0.0-Setup.exe` | Windows: Setup starten (ohne Administratorrechte) |"])

    def test_windows_notes_have_colors_for_light_and_dark_mac_notes_do_not(self):
        import re
        import xml.etree.ElementTree as ET
        out, _ = self.stable()
        win = (out / "updateinfo-win.xml").read_text(encoding="utf-8")
        mac = (out / "updateinfo-mac.xml").read_text(encoding="utf-8")
        description = ET.parse(out / "updateinfo-win.xml").getroot().find(".//item/description").text.strip()
        self.assertTrue(description.startswith(mr.WINDOWS_NOTES_STYLE), "Stil-Block am Anfang der Beschreibung")
        self.assertIn("Neuer Punkt", description)
        self.assertEqual(win.count("<style"), 1)
        self.assertNotIn("<style", mac)
        style = mr.WINDOWS_NOTES_STYLE.lower()
        self.assertIn("prefers-color-scheme: dark", style)
        for forbidden in ("http", "url(", "@import", "<script", "javascript:", "expression(", "]]>"):
            self.assertNotIn(forbidden, style, "Stil-Block lädt nichts nach")
        colors = re.findall(r"#[0-9a-f]{6}", style)
        self.assertEqual(len(colors), 6)
        self.assertEqual(mr.with_windows_style(mr.with_windows_style("<p>x</p>")), mr.WINDOWS_NOTES_STYLE + "<p>x</p>")
        mr.verify_feed(self.p.tool, self.p.key_args, out / "updateinfo-win.xml")
        self.p.verify(out, "1.2.0.0")

    def test_style_contrast_meets_wcag_aa(self):
        import re

        def lum(h):
            c = [int(h[i:i + 2], 16) / 255 for i in (1, 3, 5)]
            c = [x / 12.92 if x <= 0.03928 else ((x + 0.055) / 1.055) ** 2.4 for x in c]
            return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]

        def ratio(a, b):
            hi, lo = sorted((lum(a), lum(b)), reverse=True)
            return (hi + 0.05) / (lo + 0.05)

        light, dark = mr.WINDOWS_NOTES_STYLE.split("@media")
        for part in (light, dark):
            bg = re.search(r"background:(#[0-9a-f]{6})", part).group(1)
            fg = re.search(r";color:(#[0-9a-f]{6})", part).group(1)
            link = re.search(r"a\{color:(#[0-9a-f]{6})", part).group(1)
            self.assertGreaterEqual(ratio(fg, bg), 7.0, part)
            self.assertGreaterEqual(ratio(link, bg), 4.5, part)

    def test_missing_or_misplaced_style_is_detected(self):
        out, _ = self.stable()
        for feed, change, expected in (
                ("updateinfo-win.xml", lambda t: t.replace(mr.WINDOWS_NOTES_STYLE, ""), "Farben für hell und dunkel fehlen"),
                ("updateinfo-mac.xml", lambda t: t.replace("<![CDATA[\n", "<![CDATA[\n" + mr.WINDOWS_NOTES_STYLE, 1),
                 "nur in die Windows-Update-Datei")):
            path = out / feed
            original = path.read_text(encoding="utf-8")
            path.write_text(change(original), encoding="utf-8")
            code, err = run_failing(self.p.verify, out, "1.2.0.0")
            self.assertEqual(code, 1)
            self.assertIn(expected, err)
            path.write_text(original, encoding="utf-8")

    def test_change_after_signing_is_detected(self):
        out, _ = self.stable()
        feed = out / "updateinfo-win.xml"
        feed.write_text(feed.read_text(encoding="utf-8").replace("Klimacontrol 1.2.0.0", "Klimacontrol 9.9"), encoding="utf-8")
        code, err = run_failing(self.p.verify, out, "1.2.0.0")
        self.assertEqual(code, 1)
        self.assertIn("updateinfo-win.xml", err)

    def test_changed_archive_is_detected(self):
        out, _ = self.stable()
        with (out / "Klimacontrol-1.2.0.0-mac.dmg").open("ab") as f:
            f.write(b"x")
        code, err = run_failing(self.p.verify, out, "1.2.0.0")
        self.assertEqual(code, 1)
        self.assertIn("Prüfsumme", err)

    def test_beta_below_stable_aborts(self):
        self.stable("1.2.0.0")
        self.p.archives("1.2.0.0b1")
        code, err = run_failing(self.p.build, "1.2.0.0", beta=1)
        self.assertEqual(code, 1)
        self.assertIn("nicht kleiner", err)

    def test_beta_run_has_no_public_feeds_and_orders_entries(self):
        self.stable("1.2.0.0")
        self.p.version("1.3.0.0")
        self.p.changelogs([("1.3.0.0", "in Arbeit", "Später"), ("1.2.0.0", "2026-11-20", "Neuer Punkt")],
                          [("1.3.0.0", "in progress", "Later"), ("1.2.0.0", "2026-11-20", "New item")])
        self.p.archives("1.3.0.0b1")
        out, files = quiet(self.p.build, "1.3.0.0", beta=1)
        self.assertEqual({p.name for p in out.iterdir()},
                         {"Klimacontrol-1.3.0.0b1-mac.dmg", "updateinfo-mac-beta.xml", "SHA256SUMS.txt", "RELEASE_NOTES.md"})
        self.assertFalse((out / "updateinfo-mac.xml").exists() or (out / "updateinfo-win.xml").exists())
        self.assertFalse((out / mr.LATEST_MAC_DMG).exists() or (out / mr.LATEST_WINDOWS_SETUP).exists(),
                         "Beta ohne Kopien mit festem Namen")
        versions = [mr.item_version(i) for i in mr.extract_items((out / "updateinfo-mac-beta.xml").read_text(encoding="utf-8"))]
        self.assertEqual(versions, ["1.2.0.0", "1.3.0.0b1"])
        self.p.verify(out, "1.3.0.0", 1)

    def test_stable_run_creates_no_beta_feed(self):
        out, files = self.stable()
        self.assertFalse((out / "updateinfo-mac-beta.xml").exists())
        self.assertNotIn("updateinfo-mac-beta.xml", {f.name for f in files})

    def test_in_progress_aborts_stable_but_not_beta(self):
        self.p.version("1.2.0.0")
        self.p.changelogs([("1.2.0.0", "in Arbeit", "x")], [("1.2.0.0", "in progress", "x")])
        self.p.archives("1.2.0.0", "1.2.0.0")
        code, err = run_failing(self.p.build, "1.2.0.0")
        self.assertEqual(code, 1)
        self.assertIn("Datum", err)
        self.p.version("1.1.0.0")
        self.p.changelogs([("1.1.0.0", "2026-10-01", "x")], [("1.1.0.0", "2026-10-01", "x")])
        self.p.archives("1.1.0.0", "1.1.0.0")
        feed = quiet(self.p.build, "1.1.0.0")[0] / "updateinfo-mac.xml"
        self.p.version("1.2.0.0")
        self.p.changelogs([("1.2.0.0", "in Arbeit", "x")], [("1.2.0.0", "in progress", "x")])
        self.p.archives("1.2.0.0b1")
        out, _ = quiet(self.p.build, "1.2.0.0", beta=1, stable_feed=feed)
        self.assertTrue(out.is_dir())

    def test_missing_english_section_aborts_from_1_2_0_0(self):
        self.p.version("1.2.0.0")
        self.p.changelogs([("1.2.0.0", "2026-11-20", "x")], [("1.1.0.0", "2026-10-01", "x")])
        self.p.archives("1.2.0.0", "1.2.0.0")
        code, err = run_failing(self.p.build, "1.2.0.0")
        self.assertEqual(code, 1)
        self.assertIn("1.2.0.0", err)

    def test_english_date_must_match(self):
        self.p.version("1.2.0.0")
        self.p.changelogs([("1.2.0.0", "2026-11-20", "x")], [("1.2.0.0", "2026-11-21", "x")])
        self.p.archives("1.2.0.0", "1.2.0.0")
        code, err = run_failing(self.p.build, "1.2.0.0")
        self.assertEqual(code, 1)
        self.assertIn("Datum", err)

    def test_existing_output_folder_is_renamed_not_deleted(self):
        old = self.p.root / "releases/v1.2.0.0"
        old.mkdir(parents=True)
        (old / "marker.txt").write_text("alt", encoding="utf-8")
        out, _ = self.stable()
        self.assertFalse((out / "marker.txt").exists())
        moved = [d for d in (self.p.root / "releases").iterdir() if d.name.startswith("v1.2.0.0.alt-")]
        self.assertEqual(len(moved), 1)
        self.assertEqual((moved[0] / "marker.txt").read_text(encoding="utf-8"), "alt")

    def test_release_notes_are_bilingual(self):
        out, _ = self.stable()
        notes = (out / "RELEASE_NOTES.md").read_text(encoding="utf-8")
        self.assertIn("Neuer Punkt", notes)
        self.assertIn("## English", notes)
        self.assertIn("New item", notes)
        self.assertLess(notes.index("Neuer Punkt"), notes.index("## English"))
        self.assertLess(notes.index("## English"), notes.index("New item"))

    def test_rollback_without_execute_runs_nothing(self):
        original = mr.subprocess_run
        mr.subprocess_run = lambda cmd: self.fail("darf nichts ausführen")
        self.addCleanup(setattr, mr, "subprocess_run", original)
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            mr.rollback("1.2.0.0", "v1.1.0.0", execute=False)
        text = buf.getvalue()
        self.assertIn("gh release edit v1.2.0.0 --repo mlafx/Klimacontrol --prerelease", text)
        self.assertIn("gh release edit v1.1.0.0 --repo mlafx/Klimacontrol --latest", text)
        self.assertIn("Nichts ausgeführt", text)

    def test_http_head_keeps_head_after_redirect(self):
        import urllib.request
        handler = mr._KeepHeadOnRedirect()
        req = urllib.request.Request("https://example.com/a", method="HEAD")
        new = handler.redirect_request(req, None, 302, "Found", {}, "https://example.com/b")
        self.assertEqual(new.get_method(), "HEAD")
        get = urllib.request.Request("https://example.com/a")
        self.assertEqual(handler.redirect_request(get, None, 302, "Found", {}, "https://example.com/b").get_method(), "GET")

    def test_rollback_rejects_bad_tags(self):
        code, _ = run_failing(mr.rollback_commands, "main", "v1.1.0.0")
        self.assertEqual(code, 1)

    def test_publish_plan_flags(self):
        out, files = self.stable()
        plan = mr.publish_plan(out, "1.2.0.0", None, files, True)
        mr.check_publish_plan(plan, None)
        first = plan[0]
        self.assertIn("--latest", first)
        self.assertNotIn("--prerelease", first)
        self.assertFalse(any(a.endswith("updateinfo-mac-beta.xml") for a in first))
        self.assertEqual(len(plan), 1, "stabil: kein Release beta, keine Beta-Datei")
        self.assertFalse(any("beta" in c for c in plan[1:]))
        attached = {Path(a).name for a in first}
        self.assertTrue({mr.LATEST_MAC_DMG, mr.LATEST_WINDOWS_SETUP} <= attached)
        attachments = first[first.index("--latest") + 1:]
        self.assertEqual(len(attachments), 7, "sieben Dateien am Release")
        self.assertNotIn("RELEASE_NOTES.md", {Path(a).name for a in attachments})
        bad = [first + ["--prerelease"]]
        self.assertEqual(run_failing(mr.check_publish_plan, bad, None)[0], 1)
        without_copy = [[a for a in first if not a.endswith(mr.LATEST_MAC_DMG)]]
        code, err = run_failing(mr.check_publish_plan, without_copy, None)
        self.assertEqual(code, 1)
        self.assertIn(mr.LATEST_MAC_DMG, err)

    def _published(self, version, feeds, missing=()):
        """check_published mit nachgebildetem Netz: feeds = {Dateiname: [Versionen]}, missing = Adressen mit HEAD 404."""
        def body(versions):
            items = "".join(f'<item><sparkle:version>{v}</sparkle:version><enclosure url="https://example.com/{v}.dmg"/></item>'
                            for v in versions)
            return (f'<rss xmlns:sparkle="{mr.SPARKLE_NS}"><channel>{items}</channel></rss>'
                    "<!-- sparkle-signatures:\n-->").encode()

        class Done:
            returncode = 0

        def get(url):
            name = url.rsplit("/", 1)[-1]
            return (200, body(feeds[name])) if name in feeds else (404, b"")

        heads = []

        def head(url):
            heads.append(url)
            return 404 if url in missing else 200

        self.heads = heads
        saved = (mr.http_get, mr.http_head, mr.run_tool)
        mr.http_get, mr.http_head, mr.run_tool = get, head, lambda cmd: Done()
        try:
            return quiet(mr.check_published, version, self.p.tool, self.p.key_args)
        finally:
            mr.http_get, mr.http_head, mr.run_tool = saved

    def test_check_published_stable(self):
        feeds = {"updateinfo-mac.xml": ["1.2.0.0"], "updateinfo-win.xml": ["1.2.0.0"]}
        self.assertEqual(self._published("1.2.0.0", feeds), 0, "ohne Beta-Kanal kein Fehler")
        feeds[mr.BETA_FEED] = ["1.2.0.0"]
        self.assertEqual(self._published("1.2.0.0", feeds), 0)
        del feeds[mr.BETA_FEED]
        del feeds["updateinfo-mac.xml"]
        self.assertGreater(self._published("1.2.0.0", feeds), 0, "Update-Datei fehlt")
        feeds["updateinfo-mac.xml"] = ["1.2.0.0"]
        feeds["updateinfo-win.xml"] = ["1.1.0.0"]
        self.assertGreater(self._published("1.2.0.0", feeds), 0)

    def test_check_published_stable_checks_readme_download_links_by_head(self):
        feeds = {"updateinfo-mac.xml": ["1.2.0.0"], "updateinfo-win.xml": ["1.2.0.0"]}
        latest = [f"{mr.REPO}/releases/latest/download/{n}" for n in (mr.LATEST_MAC_DMG, mr.LATEST_WINDOWS_SETUP)]
        self.assertEqual(self._published("1.2.0.0", feeds), 0)
        for url in latest:
            self.assertIn(url, self.heads)
        for url in latest:
            self.assertEqual(self._published("1.2.0.0", feeds, missing={url}), 1, url)

    def test_publish_plan_beta_creates_beta_release_and_uploads_feed(self):
        self.stable("1.2.0.0")
        self.p.version("1.3.0.0")
        self.p.changelogs([("1.3.0.0", "in Arbeit", "Später"), ("1.2.0.0", "2026-11-20", "Neuer Punkt")],
                          [("1.3.0.0", "in progress", "Later"), ("1.2.0.0", "2026-11-20", "New item")])
        self.p.archives("1.3.0.0b1")
        out, files = quiet(self.p.build, "1.3.0.0", beta=1)
        plan = mr.publish_plan(out, "1.3.0.0", 1, files, False)
        mr.check_publish_plan(plan, 1)
        self.assertFalse(any(a.endswith((mr.LATEST_MAC_DMG, mr.LATEST_WINDOWS_SETUP)) for c in plan for a in c))
        copy = out / mr.LATEST_MAC_DMG
        bad = [plan[0] + [str(copy)]] + plan[1:]
        self.assertEqual(run_failing(mr.check_publish_plan, bad, 1)[0], 1)
        self.assertEqual(len(plan), 3)
        self.assertIn("create", plan[1])
        self.assertIn("upload", plan[2])
        self.assertEqual(len(mr.publish_plan(out, "1.3.0.0", 1, files, True)), 2)

    def test_check_published_beta_checks_only_beta_feed_for_the_version(self):
        feeds = {"updateinfo-mac.xml": ["1.1.0.0"], "updateinfo-win.xml": ["1.1.0.0"], mr.BETA_FEED: ["1.1.0.0", "1.2.0.0b1"]}
        self.assertEqual(self._published("1.2.0.0b1", feeds), 0)
        feeds[mr.BETA_FEED] = ["1.1.0.0"]
        self.assertGreater(self._published("1.2.0.0b1", feeds), 0)
        feeds[mr.BETA_FEED] = ["1.2.0.0b1"]
        self.assertGreater(self._published("1.2.0.0b1", feeds), 0, "stabiler Eintrag fehlt")
        self.assertEqual(self._published("1.2.0.0b1", {"updateinfo-mac.xml": ["1.1.0.0"],
                                                        "updateinfo-win.xml": ["1.1.0.0"],
                                                        mr.BETA_FEED: ["1.1.0.0", "1.2.0.0b1"]}), 0)
        self.assertFalse(any(u.endswith(mr.LATEST_MAC_DMG) for u in self.heads), "Beta prüft die Download-Knöpfe nicht")
        feeds[mr.BETA_FEED] = ["1.1.0.0", "1.2.0.0b1"]
        feeds["updateinfo-mac.xml"] = ["1.2.0.0b1"]
        self.assertGreater(self._published("1.2.0.0b1", feeds), 0, "Beta darf nicht in der öffentlichen Datei stehen")


if __name__ == "__main__":
    unittest.main()
