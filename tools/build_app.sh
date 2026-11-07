#!/bin/zsh
# Baut Klimacontrol.app als Universal-Programm (Apple Silicon + Intel, Release) und legt nach ./dist/mac/
# Klimacontrol-<VERSION>-mac.dmg (Installation und Sparkle-Updates), Klimacontrol-<VERSION>-mac.zip und LIESMICH.txt.
# Die App selbst bleibt im Build-Ordner (<Build-Ordner>/app/Klimacontrol.app): Ein App-Bundle mit Framework im
# OneDrive-Ordner zerlegt der Sync (Symlinks, Konfliktkopien). dist/windows/ gehört Windows. Den Appcast erzeugt danach
# tools/make_release.py.
# Voraussetzungen: macOS 15+, Xcode 27 oder neuer mit Swift 6.4 oder neuer. Build-Ordner überschreibbar mit
# KLIMACONTROL_SCRATCH=<Pfad> (parallele Builds); Standard ~/Library/Caches/Klimacontrol-build.
# Vor dem Bauen laufen alle Tests (wie tools\build_windows.ps1); --no-test überspringt sie (z. B. direkt nach test.sh).
set -e -o pipefail
cd "$(dirname "$0")/.."
RUN_TESTS=1
for arg in "$@"; do
  case "$arg" in
    --no-test) RUN_TESTS=0 ;;
    *) echo "Unbekannte Angabe: $arg (erlaubt: --no-test)" >&2; exit 2 ;;
  esac
done

# OneDrive-Ordner wird mit Windows geteilt: ein echter .build-Ordner (statt Symlink) stammt von einem nackten
# `swift build` oder von Windows; ein fehlender .build (frischer Klon) ist in Ordnung.
if [ -d .build ] && [ ! -L .build ]; then
  echo "Abbruch: .build ist ein echter Ordner statt eines Symlinks – vermutlich hat OneDrive einen Build-Ordner von Windows hergeholt."
  echo "Prüfen, dann: Ordner .build in den Papierkorb legen und  ln -s ~/Library/Caches/Klimacontrol-build .build"
  exit 1
fi
conflicts=$(find Sources Tests -type f \( -name '*-*.swift' -o -name '* *' \) 2>/dev/null)
if [ -n "$conflicts" ]; then
  echo "Abbruch: mögliche OneDrive-Konfliktkopien (würden mitkompiliert):"
  echo "$conflicts"
  exit 1
fi
# Absprache zwischen zwei Rechnern im selben Sync-Ordner (nur beim Autor vorhanden): aktive Sperre mit frischem Puls.
other_lock=_privat/sperre/windows.txt
if [ -f "$other_lock" ] && grep -q "status=aktiv" "$other_lock"; then
  pulse=$(sed -nE 's/.*puls=([0-9TZ:-]+).*/\1/p' "$other_lock")
  pulse_s=$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$pulse" +%s 2>/dev/null || echo 0)
  if (( $(date +%s) - pulse_s < 7200 )); then
    echo "Hinweis: Auf dem anderen Rechner wird gerade gearbeitet:"
    cat "$other_lock"
  fi
fi
if [ -f .agent-lock ] && ! grep -q "plattform=mac" .agent-lock; then
  echo "Hinweis: .agent-lock vom anderen Rechner vorhanden – dort wird gerade gearbeitet:"
  cat .agent-lock
fi

if [ "$RUN_TESTS" = 1 ]; then
  echo "Tests …"
  if ! zsh tools/test.sh > "${TMPDIR:-/tmp}/klimacontrol-build-tests.log" 2>&1; then
    tail -40 "${TMPDIR:-/tmp}/klimacontrol-build-tests.log"
    echo "Abbruch: Tests fehlgeschlagen (ganzes Protokoll: ${TMPDIR:-/tmp}/klimacontrol-build-tests.log)." >&2
    exit 1
  fi
fi

VERSION=$(tr -d '[:space:]' < tools/VERSION)
UPDATE_KEY=$(tr -d '[:space:]' < tools/UPDATE_PUBLIC_KEY)
# Build nach ~/Library/Caches: im OneDrive-Ordner scheitert das Schreiben der SPM-Metadaten.
SCRATCH="${KLIMACONTROL_SCRATCH:-$HOME/Library/Caches/Klimacontrol-build}"
ARCHS=(--arch arm64 --arch x86_64)
swift build -c release "${ARCHS[@]}" --scratch-path "$SCRATCH"
BIN=$(swift build -c release "${ARCHS[@]}" --scratch-path "$SCRATCH" --show-bin-path)

# Das Programm muss beide Architekturen enthalten (LIESMICH verspricht Apple Silicon und Intel).
for exe in "$BIN/KlimacontrolApp"; do
  info=$(lipo -info "$exe")
  echo "$info"
  if [[ "$info" != *arm64* || "$info" != *x86_64* ]]; then
    echo "Abbruch: $exe ist nicht universal (arm64 + x86_64)."
    exit 1
  fi
done

OUT=dist/mac
# Zusammensetzen und Signieren außerhalb des Projekts: OneDrive hängt Dateiattribute an, an denen codesign scheitert
# („resource fork, Finder information, or similar detritus“).
APP="$SCRATCH/app/Klimacontrol.app"
rm -rf "$SCRATCH/app"
mkdir -p "$OUT" "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/KlimacontrolApp" "$APP/Contents/MacOS/Klimacontrol"
# Symbole entfernen (rund 2 MB kleiner, lädt schneller); Absturzberichte bleiben über die Adressen lesbar.
strip -rSTx "$APP/Contents/MacOS/Klimacontrol"
# Sparkle nach Contents/Frameworks. Die XPC-Dienste braucht nur eine App in der Sandbox (Klimacontrol ist keine).
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
mkdir -p "$APP/Contents/Frameworks"
ditto --noextattr --noqtn "$BIN/Sparkle.framework" "$SPARKLE"
rm -rf "$SPARKLE/Versions/B/XPCServices" "$SPARKLE/XPCServices"
# rpath auf Contents/Frameworks; absolute Pfade in den Build-Ordner entfernen (sie enthielten den Benutzerordner).
EXE="$APP/Contents/MacOS/Klimacontrol"
# rpath_tool <-add_rpath|-delete_rpath> <rpath> <harmlose Meldung>: install_name_tool meldet je Architektur einen schon
# vorhandenen (add) bzw. fehlenden (delete) rpath als Fehler – nur das ist erwartbar, alles andere bricht ab.
rpath_tool() {
  local err line
  if err=$(install_name_tool "$1" "$2" "$EXE" 2>&1); then
    return 0
  fi
  for line in "${(@f)err}"; do
    if [[ "$line" == *error* && "$line" != *"$3"* ]]; then
      print -r -- "$err" >&2
      echo "Abbruch: install_name_tool $1 $2 fehlgeschlagen." >&2
      exit 1
    fi
  done
}
rpath_tool -add_rpath @executable_path/../Frameworks "would duplicate path"
RPATHS=$(otool -l "$EXE" | awk '/cmd LC_RPATH/ { getline; getline; sub(/^[ \t]*path /, ""); sub(/ \(offset [0-9]+\)$/, ""); print }' | sort -u)
for rp in "${(@f)RPATHS}"; do
  case "$rp" in
    "$HOME"/*|/Users/*|"$SCRATCH"/*) rpath_tool -delete_rpath "$rp" "no LC_RPATH load command with path" ;;
  esac
done
RPATHS=$(otool -l "$EXE" | grep -A2 'cmd LC_RPATH')
if [[ "$RPATHS" == *"$HOME"* || "$RPATHS" == */Users/* || "$RPATHS" == *"$SCRATCH"* ]]; then
  echo "Abbruch: Das Programm enthält noch einen rpath im Benutzer- oder Build-Ordner." >&2
  exit 1
fi
# Keine Spuren des Bau-Rechners im Paket (wie tools\build_windows.ps1): tools/check_traces.py durchsucht jede Datei von
# App, ZIP und DMG (auch als UTF-16) nach Benutzerordner, Benutzername als Pfad, Rechnername, OneDrive- und Build-Ordner
# und nennt nur Datei, Art und Anzahl.
check_traces() {
  if ! python3 -I tools/check_traces.py --extra "Build-Ordner=$SCRATCH" "$@"; then
    echo "Abbruch: Spuren des Bau-Rechners im Paket (siehe oben)." >&2
    exit 1
  fi
}
# notarize <Datei>: reicht bei Apple ein, wartet und bricht ab, wenn Apple die Datei nicht annimmt („Accepted“);
# dann steht Apples Prüfprotokoll darunter.
notarize() {
  local out rc=0 parsed id nstate
  echo "Notarisieren: $(basename "$1") …"
  out=$(xcrun notarytool submit "$1" --keychain-profile "$KLIMACONTROL_NOTARY_PROFILE" --wait --output-format json) || rc=$?
  parsed=$(print -r -- "$out" | python3 -I -c '
import json, sys
try:
    d = json.loads(sys.stdin.read())
except ValueError:
    d = {}
print(str(d.get("id", "")) + "\t" + str(d.get("status", "")))') || parsed=$'\t'
  id=${parsed%%$'\t'*}
  nstate=${parsed#*$'\t'}
  if [ "$nstate" = "Accepted" ] && [ "$rc" = 0 ]; then
    echo "Notarisiert: $(basename "$1") (Vorgang $id)"
    return 0
  fi
  print -r -- "$out" >&2
  echo "Abbruch: Apple hat $(basename "$1") nicht notarisiert (Status: ${nstate:-unbekannt}, notarytool: $rc)." >&2
  if [ -n "$id" ]; then
    xcrun notarytool log "$id" --keychain-profile "$KLIMACONTROL_NOTARY_PROFILE" >&2 || true
  fi
  exit 1
}
cp docs/THIRD_PARTY_NOTICES.md LICENSE "$OUT/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Klimacontrol</string>
  <key>CFBundleDisplayName</key><string>Klimacontrol</string>
  <key>CFBundleIdentifier</key><string>de.mlafx.klimacontrol</string>
  <key>CFBundleExecutable</key><string>Klimacontrol</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>CFBundleDevelopmentRegion</key><string>de</string>
  <key>NSLocalNetworkUsageDescription</key><string>Klimacontrol steuert deine Klimaanlage direkt im WLAN – ohne Cloud.</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>SUFeedURL</key><string>https://github.com/mlafx/Klimacontrol/releases/latest/download/updateinfo-mac.xml</string>
  <key>SUPublicEDKey</key><string>$UPDATE_KEY</string>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>SUAutomaticallyUpdate</key><true/>
  <key>SUAllowsAutomaticUpdates</key><true/>
  <key>SUScheduledCheckInterval</key><integer>86400</integer>
</dict></plist>
PLIST
if [ -f tools/AppIcon.icns ]; then cp tools/AppIcon.icns "$APP/Contents/Resources/"; fi
# Lizenzhinweise der Quellen (MIT/Apache 2.0 verlangen, sie mitzugeben) – auch in der App unter Einstellungen.
cp docs/THIRD_PARTY_NOTICES.md LICENSE "$APP/Contents/Resources/"

# Signieren: KLIMACONTROL_SIGN_IDENTITY (z. B. "-" für ad hoc), sonst „Developer ID Application“ vor „Apple Development“
# vor ad hoc. Mit fester Identität fragt macOS Freigaben (Lokales Netzwerk, Schlüsselbund) nach neuem Bau nicht erneut.
IDENTITY="${KLIMACONTROL_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  IDS=$(security find-identity -v -p codesigning 2>/dev/null) || IDS=""
  # awk liest alles und nimmt den ersten Treffer (kein head: mit pipefail bräche ein vorzeitig beendetes Lesen ab).
  IDENTITY=$(print -r -- "$IDS" | awk -F'"' '$2 ~ /^Developer ID Application: / && !n++ { print $2 }')
  [ -z "$IDENTITY" ] && IDENTITY=$(print -r -- "$IDS" | awk -F'"' '$2 ~ /^Apple Development: / && !n++ { print $2 }')
  [ -z "$IDENTITY" ] && IDENTITY="-"
fi
if [ "$IDENTITY" = "-" ]; then
  echo "Signatur: ad hoc (kein Zertifikat gefunden – läuft nur auf diesem Mac ohne Warnung)."
  SIGNOPTS=(--force --sign -)
else
  echo "Signatur: $IDENTITY"
  # Hardened Runtime und Zeitstempel verlangt die Notarisierung; schadet bei „Apple Development“ nicht.
  SIGNOPTS=(--force --options runtime --timestamp --sign "$IDENTITY")
fi
# Von innen nach außen, ohne --deep: erst Sparkles Helfer, dann das Framework, zuletzt die App.
codesign "${SIGNOPTS[@]}" "$SPARKLE/Versions/B/Autoupdate"
codesign "${SIGNOPTS[@]}" "$SPARKLE/Versions/B/Updater.app"
codesign "${SIGNOPTS[@]}" "$SPARKLE"
codesign "${SIGNOPTS[@]}" "$APP"
codesign --verify --strict --deep "$APP"
check_traces "$APP"

# LIESMICH für Endnutzer – Version immer aus VERSION, nie von Hand pflegen. Notarisiert öffnet macOS die App ohne
# Umweg; nur ohne Notarisierung braucht es „Dennoch öffnen“.
if [ -n "${KLIMACONTROL_NOTARY_PROFILE:-}" ]; then
  GATEKEEPER="2. Beim ersten Öffnen fragt macOS, ob du die aus dem Internet geladene App öffnen willst: „Öffnen“."
else
  GATEKEEPER="2. Beim ersten Öffnen meldet macOS, dass der Entwickler nicht verifiziert ist. Dann:
   Systemeinstellungen → Datenschutz & Sicherheit → ganz unten bei Klimacontrol auf „Dennoch öffnen“."
fi
cat > "$OUT/LIESMICH.txt" <<LIESMICH
Klimacontrol $VERSION für macOS

Voraussetzungen: Mac mit macOS 15 oder neuer (Apple Silicon oder Intel), Midea-PortaSplit-Klimaanlage im selben WLAN.

1. Klimacontrol-$VERSION-mac.dmg öffnen und Klimacontrol.app auf „Programme“ ziehen
   (oder Klimacontrol-$VERSION-mac.zip entpacken und Klimacontrol.app in den Ordner „Programme“ legen).
$GATEKEEPER
3. Zugriff auf das lokale Netzwerk erlauben.
4. Einrichtung – einen der drei Wege wählen:
   - Mit Midea-Konto (empfohlen): Die App sucht die Anlage im WLAN und holt Token und Schlüssel einmal über das
     Midea-Konto. Das Passwort wird nur im macOS-Schlüsselbund gespeichert, damit sich Klimacontrol neu anmelden
     kann. Es verlässt den Mac nur zur Anmeldung bei Midea.
   - Zugangsdaten eingeben (ohne Konto): Token und Schlüssel von Hand eingeben oder einfügen.
   - Sicherung einlesen: eine zuvor mit „Zugangsdaten sichern …“ gespeicherte Datei.
5. Danach unter Einstellungen → Anlage „Zugangsdaten sichern …“ wählen und die Datei gut aufheben.

Updates: Klimacontrol sucht einmal am Tag nach einer neuen Version und fragt, bevor es sie installiert
(Einstellungen → Allgemein → Updates, oder im Menü Klimacontrol → „Nach Updates suchen …“).


Klimacontrol baut auf Open-Source-Projekten auf (msmart-ng, midea-beautiful-air, midea_ac_lan; MIT). Lizenzen und
Quellen: in der App unter Einstellungen → „Lizenzen“ und in THIRD_PARTY_NOTICES.md (liegt neben dieser Datei).
LIESMICH

# ZIP aus einem sauberen Zwischenordner (ditto: keine __MACOSX-/._-Dateien, Rechte und Signatur bleiben erhalten).
ZIPNAME="Klimacontrol-$VERSION-mac"
STAGE="$SCRATCH/zip/$ZIPNAME"
rm -rf "$SCRATCH/zip"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Klimacontrol.app"
cp "$OUT/LIESMICH.txt" "$OUT/THIRD_PARTY_NOTICES.md" "$OUT/LICENSE" "$STAGE/"
chmod 644 "$STAGE/LIESMICH.txt" "$STAGE/THIRD_PARTY_NOTICES.md" "$STAGE/LICENSE"
rm -f "$OUT"/Klimacontrol-*-mac.zip(N)
ditto -c -k --keepParent "$STAGE" "$OUT/$ZIPNAME.zip"
check_traces "$OUT/$ZIPNAME.zip"
# Notarisieren (nur mit „Developer ID Application“ und einem gespeicherten notarytool-Profil, siehe README):
# KLIMACONTROL_NOTARY_PROFILE=<Profilname> tools/build_app.sh – lädt das ZIP zu Apple, heftet das Ticket an die App
# und baut das ZIP neu. Ohne Profil bleibt es beim signierten, nicht notarisierten Paket.
if [ -n "${KLIMACONTROL_NOTARY_PROFILE:-}" ]; then
  if [[ "$IDENTITY" != "Developer ID Application:"* ]]; then
    echo "Abbruch: Notarisieren geht nur mit einem Zertifikat „Developer ID Application“ (gefunden: $IDENTITY)."
    exit 1
  fi
  notarize "$OUT/$ZIPNAME.zip"
  xcrun stapler staple "$APP"
  rm -rf "$STAGE/Klimacontrol.app" && ditto "$APP" "$STAGE/Klimacontrol.app"
  rm -f "$OUT/$ZIPNAME.zip" && ditto -c -k --keepParent "$STAGE" "$OUT/$ZIPNAME.zip"
  check_traces "$OUT/$ZIPNAME.zip"
  spctl --assess --type execute --verbose "$APP"
fi
rm -rf "$SCRATCH/zip"

# DMG zum Installieren, zugleich das Archiv für Sparkle-Updates: nur App und „Programme“ mit Anleitung
# (tools/make_dmg.sh). Erst nach dem Anheften des Tickets an die App bauen, damit die App im DMG schon notarisiert ist.
DMGNAME="Klimacontrol-$VERSION-mac"
rm -f "$OUT"/Klimacontrol-*-mac.dmg(N)
zsh tools/make_dmg.sh "$APP" "$OUT/$DMGNAME.dmg" "$SCRATCH/dmg"
if [ "$IDENTITY" != "-" ]; then
  codesign --force --timestamp --sign "$IDENTITY" "$OUT/$DMGNAME.dmg"
fi
check_traces "$OUT/$DMGNAME.dmg"
if [ -n "${KLIMACONTROL_NOTARY_PROFILE:-}" ]; then
  notarize "$OUT/$DMGNAME.dmg"
  xcrun stapler staple "$OUT/$DMGNAME.dmg"
  spctl --assess --type open --context context:primary-signature --verbose "$OUT/$DMGNAME.dmg"
fi
# Ältere Fassungen legten die App selbst nach dist/mac; die würde dort nur veralten.
rm -rf "$OUT/Klimacontrol.app"
echo "Fertig: $APP"
echo "        $PWD/$OUT/$DMGNAME.dmg"
echo "        $PWD/$OUT/$ZIPNAME.zip"
echo "Release-Ordner (Appcasts, Prüfsummen, Text): python3 tools/make_release.py"
