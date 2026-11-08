#!/bin/zsh
# Führt die Tests (MideaKit + KlimacontrolCore) aus. Argumente gehen an `swift test` durch, z. B.
#   tools/test.sh --filter TransportTests
# Scratch-Pfad außerhalb von OneDrive (dort scheitert das Schreiben der SPM-Metadaten); überschreibbar mit
# KLIMACONTROL_SCRATCH=<Pfad>. Protokoll in einen frischen Temp-Ordner, nie ins echte klimacontrol.log.
# Echter Schlüsselbund nur mit KLIMACONTROL_REAL_SECRETS=1, Live-Scan im WLAN nur mit KLIMACONTROL_LIVE_SCAN=1.
set -e -o pipefail
cd "$(dirname "$0")/.."
# Eingebettete Texte müssen zu Katalog und CHANGELOG passen, sonst bauen wir einen veralteten Stand.
if command -v python3 >/dev/null 2>&1; then
  python3 tools/sync_strings.py --check || { echo "FEHLER: Text-Katalog und StringsData.swift weichen ab. Bitte 'python3 tools/sync_strings.py' ausführen." >&2; exit 1; }
  python3 tools/sync_release_notes.py --check || { echo "FEHLER: ReleaseNotesData.swift ist veraltet. Bitte 'python3 tools/sync_release_notes.py' ausführen." >&2; exit 1; }
fi
if [ -z "${KLIMACONTROL_LOG_DIR:-}" ]; then
  # Getrennt von export: `export X=$(…)` meldet den Erfolg von export, ein gescheitertes mktemp fiele nicht auf.
  KLIMACONTROL_LOG_DIR=$(mktemp -d "${TMPDIR:-/tmp}/klimacontrol-test-log.XXXXXX")
  export KLIMACONTROL_LOG_DIR
fi
exec swift test --scratch-path "${KLIMACONTROL_SCRATCH:-$HOME/Library/Caches/Klimacontrol-build}" "$@"
