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
            "Klimacontrol-1.2.0.0-mac.dmg", "Klimacontrol-Windows-1.2.0.0-Setup.exe", "updateinfo-mac.xml",
            "updateinfo-win.xml", "updateinfo-mac-beta.xml", "SHA256SUMS.txt", "RELEASE_NOTES.md"})
        self.assertNotIn("RELEASE_NOTES.md", {f.name for f in files})
        for feed in ("updateinfo-mac.xml", "updateinfo-win.xml", "updateinfo-mac-beta.xml"):
            text = (out / feed).read_text(encoding="utf-8")
            self.assertTrue(text.rstrip().endswith("-->"), feed)
            self.assertEqual(text.count("sparkle-signatures"), 1, feed)
            mr.verify_feed(self.p.tool, self.p.key_args, out / feed)
        self.p.verify(out, "1.2.0.0")

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
        versions = [mr.item_version(i) for i in mr.extract_items((out / "updateinfo-mac-beta.xml").read_text(encoding="utf-8"))]
        self.assertEqual(versions, ["1.2.0.0", "1.3.0.0b1"])
        self.p.verify(out, "1.3.0.0", 1)

    def test_stable_after_beta_keeps_higher_beta_in_beta_feed(self):
        self.stable("1.2.0.0")
        self.p.version("1.3.0.0")
        self.p.changelogs([("1.3.0.0", "in Arbeit", "Später"), ("1.2.0.0", "2026-11-20", "Neuer Punkt")],
                          [("1.3.0.0", "in progress", "Later"), ("1.2.0.0", "2026-11-20", "New item")])
        self.p.archives("1.3.0.0b1")
        quiet(self.p.build, "1.3.0.0", beta=1)
        out, _ = self.stable("1.2.0.1", "2026-12-01")
        versions = [mr.item_version(i) for i in mr.extract_items((out / "updateinfo-mac-beta.xml").read_text(encoding="utf-8"))]
        self.assertEqual(versions, ["1.2.0.1", "1.3.0.0b1"])

    def test_beta_feed_of_stable_run_has_only_stable_without_newer_beta(self):
        out, _ = self.stable()
        versions = [mr.item_version(i) for i in mr.extract_items((out / "updateinfo-mac-beta.xml").read_text(encoding="utf-8"))]
        self.assertEqual(versions, ["1.2.0.0"])

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
        bad = [first + ["--prerelease"]]
        self.assertEqual(run_failing(mr.check_publish_plan, bad, None)[0], 1)


if __name__ == "__main__":
    unittest.main()
