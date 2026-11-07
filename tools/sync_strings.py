#!/usr/bin/env python3
"""Prüft l10n/Localizable.xcstrings, schreibt ihn normalisiert zurück und erzeugt
Sources/KlimacontrolCore/StringsData.swift (eingebetteter Katalog plus Zugriffe `L.…`).

  python3 tools/sync_strings.py            prüfen, Katalog normalisieren, StringsData.swift erzeugen
  python3 tools/sync_strings.py --check    nur prüfen (Exit 1 bei Regelverstoß oder veraltetem Stand), schreibt nichts
  --catalog <Pfad> --output <Pfad>         andere Dateien (für Proben)
"""
import argparse
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
KEY_RE = re.compile(r"^[a-z][A-Za-z0-9]*(\.[a-z][A-Za-z0-9]*)+$")
PLACEHOLDER_RE = re.compile(r"\{([a-z][A-Za-z0-9]*)\}")
LANGS = ["de", "en"]
PLURAL_CASES = ["zero", "one", "two", "few", "many", "other"]
FORBIDDEN_ENUMS = {"L", "Localizer", "StringsData", "String", "Int"}
SWIFT_KEYWORDS = set(
    "default case class func in for if else let var return self true false nil struct enum init import internal "
    "public private static where while repeat switch throw throws try do is as super protocol extension operator "
    "subscript deinit".split()
)


def placeholders(text):
    """Platzhalter in Reihenfolge des ersten Vorkommens."""
    seen = []
    for name in PLACEHOLDER_RE.findall(text):
        if name not in seen:
            seen.append(name)
    return seen


def check_text(key, where, value, errors):
    if not isinstance(value, str) or not value.strip():
        errors.append(f"{key}: {where}: Wert fehlt oder ist leer")
        return None
    rest = PLACEHOLDER_RE.sub("", value)
    if "{" in rest or "}" in rest:
        errors.append(f"{key}: {where}: lose geschweifte Klammer außerhalb eines Platzhalters")
    names = placeholders(value)
    for n in names:
        if n in SWIFT_KEYWORDS:
            errors.append(f"{key}: {where}: Platzhalter {{{n}}} ist ein Swift-Schlüsselwort")
    return names


def unit_value(key, where, unit, errors):
    if not isinstance(unit, dict) or "stringUnit" not in unit:
        errors.append(f"{key}: {where}: stringUnit fehlt")
        return None
    su = unit["stringUnit"]
    if not isinstance(su, dict):
        errors.append(f"{key}: {where}: stringUnit ist kein Objekt")
        return None
    if su.get("state") != "translated":
        errors.append(f"{key}: {where}: state muss 'translated' sein")
    return su.get("value")


def validate(catalog):
    """Gibt (Fehlerliste, Signaturen, Doku-Zeilen) zurück."""
    errors = []
    sigs, docs = {}, {}
    if not isinstance(catalog, dict):
        return ["Katalog ist kein Objekt"], sigs, docs
    if catalog.get("sourceLanguage") != "en":
        errors.append("Kopf: sourceLanguage muss 'en' sein")
    if catalog.get("version") != "1.0":
        errors.append("Kopf: version muss '1.0' sein")
    strings = catalog.get("strings")
    if not isinstance(strings, dict):
        return errors + ["Kopf: strings muss ein Objekt sein"], sigs, docs

    keys = sorted(strings)
    for k in keys:
        if not KEY_RE.match(k):
            errors.append(f"{k}: Schlüssel entspricht nicht dem Schema")
            continue
        for part in k.split("."):
            if part[0].upper() + part[1:] in FORBIDDEN_ENUMS:
                errors.append(f"{k}: Teil '{part}' kollidiert im erzeugten Code")
    valid = [k for k in keys if KEY_RE.match(k)]
    for a in valid:
        for b in valid:
            if a != b and b.startswith(a + "."):
                errors.append(f"{a}: ist Präfix von {b}")

    for k in valid:
        entry = strings[k]
        if not isinstance(entry, dict):
            errors.append(f"{k}: Eintrag ist kein Objekt")
            continue
        if not isinstance(entry.get("comment"), str) or not entry["comment"].strip():
            errors.append(f"{k}: comment fehlt oder ist leer")
        locs = entry.get("localizations")
        if not isinstance(locs, dict):
            errors.append(f"{k}: localizations fehlt")
            continue
        for lang in locs:
            if lang not in LANGS:
                errors.append(f"{k}: Sprache '{lang}' wird noch nicht unterstützt")
        kinds, sets, firsts = {}, {}, {}
        for lang in LANGS:
            loc = locs.get(lang)
            if loc is None:
                errors.append(f"{k}: Übersetzung '{lang}' fehlt")
                continue
            if not isinstance(loc, dict):
                errors.append(f"{k}: {lang}: kein Objekt")
                continue
            has_unit, has_var = "stringUnit" in loc, "variations" in loc
            if has_unit and has_var:
                errors.append(f"{k}: {lang}: stringUnit und variations gleichzeitig")
                continue
            if has_unit:
                kinds[lang] = "text"
                v = unit_value(k, lang, loc, errors)
                names = check_text(k, lang, v, errors)
                if names is not None:
                    sets[lang] = [set(names)]
                    firsts[lang] = (v, names)
            elif has_var:
                plural = loc["variations"].get("plural") if isinstance(loc["variations"], dict) else None
                if not isinstance(plural, dict):
                    errors.append(f"{k}: {lang}: variations.plural fehlt")
                    continue
                kinds[lang] = "plural"
                if "other" not in plural:
                    errors.append(f"{k}: {lang}: Mehrzahlfall 'other' fehlt")
                lang_sets = []
                for case, unit in plural.items():
                    if case not in PLURAL_CASES:
                        errors.append(f"{k}: {lang}: unbekannter Mehrzahlfall '{case}'")
                        continue
                    v = unit_value(k, f"{lang}/{case}", unit, errors)
                    names = check_text(k, f"{lang}/{case}", v, errors)
                    if names is None:
                        continue
                    if "count" not in names:
                        errors.append(f"{k}: {lang}/{case}: {{count}} fehlt")
                    lang_sets.append(set(names))
                    if case == "other":
                        firsts[lang] = (v, names)
                sets[lang] = lang_sets
            else:
                errors.append(f"{k}: {lang}: weder stringUnit noch variations")
        if len(set(kinds.values())) > 1:
            errors.append(f"{k}: Art unterscheidet sich zwischen den Sprachen (Text/Mehrzahl)")
        allsets = [s for lst in sets.values() for s in lst]
        if allsets and any(s != allsets[0] for s in allsets):
            errors.append(f"{k}: Platzhalter sind nicht in allen Sprachen und Fällen gleich")
        if "en" in firsts and kinds.get("en") is not None:
            value, names = firsts["en"]
            if kinds["en"] == "plural":
                names = ["count"] + [n for n in names if n != "count"]
            sigs[k] = names
            docs[k] = value
    return errors, sigs, docs


def normalize(catalog):
    for entry in catalog["strings"].values():
        entry["extractionState"] = "manual"
    return json.dumps(catalog, ensure_ascii=False, indent=2, sort_keys=True, separators=(",", " : ")) + "\n"


def swift_ident(name):
    return f"`{name}`" if name in SWIFT_KEYWORDS else name


def doc_line(value):
    flat = " ".join(value.split())
    return flat if len(flat) <= 100 else flat[:99] + "…"


def render_tree(tree, indent, lines):
    pad = "    " * indent
    for name in sorted(tree):
        node = tree[name]
        if isinstance(node, dict):
            lines.append(f"{pad}public enum {name[0].upper() + name[1:]} {{")
            render_tree(node, indent + 1, lines)
            lines.append(f"{pad}}}")
        else:
            key, sig, doc, plural = node
            ident = swift_ident(name)
            lines.append(f"{pad}/// {doc_line(doc)}")
            if plural:
                extra = sig[1:]
                params = ", ".join(["count: Int"] + [f"{p}: String" for p in extra])
                args = (", [" + ", ".join(f'"{p}": {p}' for p in extra) + "]") if extra else ""
                lines.append(f'{pad}public static func {ident}({params}) -> String {{ Localizer.plural("{key}", count: count{args}) }}')
            elif sig:
                params = ", ".join(f"{p}: String" for p in sig)
                args = ", ".join(f'"{p}": {p}' for p in sig)
                lines.append(f'{pad}public static func {ident}({params}) -> String {{ Localizer.text("{key}", [{args}]) }}')
            else:
                lines.append(f'{pad}public static var {ident}: String {{ Localizer.text("{key}") }}')


def generate(catalog, normalized, sigs, docs):
    text = normalized.rstrip("\n")
    hashes = 1
    while '"""' + "#" * hashes in text or "\\" + "#" * hashes in text:
        hashes += 1
    mark = "#" * hashes
    keys = sorted(sigs)
    tree = {}
    for k in keys:
        parts = k.split(".")
        node = tree
        for p in parts[:-1]:
            node = node.setdefault(p, {})
        plural = "variations" in catalog["strings"][k]["localizations"]["en"]
        node[parts[-1]] = (k, sigs[k], docs[k], plural)

    out = [
        "// Erzeugt von tools/sync_strings.py aus l10n/Localizable.xcstrings – nicht von Hand ändern.",
        "",
        "extension StringsData {",
        f'    static let catalog = {mark}"""',
        text,
        f'"""{mark}',
        "",
        "    static let allKeys: [String] = [",
    ]
    out += [f'        "{k}",' for k in keys]
    out += [
        "    ]",
        "",
        '    /// Platzhalter je Schlüssel in der Reihenfolge der Parameter (Mehrzahl: zuerst "count").',
        "    static let signatures: [String: [String]] = [",
    ]
    for k in keys:
        items = ", ".join(f'"{p}"' for p in sigs[k])
        out.append(f'        "{k}": [{items}],')
    out += ["    ]", "}", "", "/// Texte der Oberfläche, je Schlüssel des Katalogs ein Zugriff.", "public enum L {"]
    render_tree(tree, 1, out)
    out += ["}", ""]
    return "\n".join(out)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--catalog", type=pathlib.Path, default=ROOT / "l10n/Localizable.xcstrings")
    ap.add_argument("--output", type=pathlib.Path, default=ROOT / "Sources/KlimacontrolCore/StringsData.swift")
    args = ap.parse_args()

    try:
        raw = args.catalog.read_text(encoding="utf-8")
        catalog = json.loads(raw)
    except (OSError, ValueError) as e:
        print(f"Fehler: Katalog nicht lesbar: {e}", file=sys.stderr)
        return 1
    errors, sigs, docs = validate(catalog)
    if errors:
        for e in errors:
            print(f"Fehler: {e}", file=sys.stderr)
        return 1

    normalized = normalize(catalog)
    swift = generate(catalog, normalized, sigs, docs)
    if args.check:
        stale = []
        if raw.replace("\r\n", "\n") != normalized:
            stale.append(str(args.catalog))
        try:
            current = args.output.read_text(encoding="utf-8")
        except OSError:
            current = None
        if current != swift:
            stale.append(str(args.output))
        if stale:
            print("Fehler: nicht auf dem erzeugten Stand: " + ", ".join(stale) + ". Neu erzeugen: python3 tools/sync_strings.py",
                  file=sys.stderr)
            return 1
        return 0

    with open(args.catalog, "w", encoding="utf-8", newline="\n") as f:
        f.write(normalized)
    with open(args.output, "w", encoding="utf-8", newline="\n") as f:
        f.write(swift)
    print(f"{args.catalog.relative_to(ROOT) if args.catalog.is_relative_to(ROOT) else args.catalog}: {len(sigs)} Texte")
    print(f"{args.output.relative_to(ROOT) if args.output.is_relative_to(ROOT) else args.output} geschrieben")
    return 0


if __name__ == "__main__":
    sys.exit(main())
