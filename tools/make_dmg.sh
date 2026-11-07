#!/bin/zsh
# Installations-DMG: nur Klimacontrol.app und die Verknüpfung „Programme“ vor einem Hintergrund mit Anleitung.
# Aufruf aus build_app.sh: zsh tools/make_dmg.sh <App> <Ziel.dmg> <Arbeitsordner>
# Die Finder-Ansicht schreibt dmgbuild (MIT, nur Bauwerkzeug, nicht in der App) direkt; den Finder per AppleScript zu
# steuern geht seit macOS 26 nicht mehr (er verwirft Hintergrund und Symbolgröße). dmgbuild liegt in einer eigenen
# Python-Umgebung im Build-Cache und wird beim ersten Bau aus PyPI installiert – nur die Versionen und Prüfsummen aus
# tools/dmg_requirements.txt. Ändert sich die Datei, wird die Umgebung neu eingerichtet.
set -e -o pipefail
[ $# -eq 3 ] && [ -d "$1" ] && [ -n "$2" ] && [ -n "$3" ] || { echo "Aufruf: make_dmg.sh <App> <Ziel.dmg> <Arbeitsordner>" >&2; exit 2; }
# Absolut machen, bevor das Skript in den Projektordner wechselt (sonst zeigten relative Angaben ins Leere).
APP=${1:a} TARGET=${2:a} WORK=${3:a}
case "$WORK" in
  /|"$HOME"|"$HOME"/|"${0:A:h:h}"|"${0:A:h:h}"/*) echo "Abbruch: ungeeigneter Arbeitsordner $WORK (wird gelöscht)." >&2; exit 2 ;;
esac
cd "${0:A:h}/.."
REQS=tools/dmg_requirements.txt
VENV="${KLIMACONTROL_SCRATCH:-$HOME/Library/Caches/Klimacontrol-build}/venv-dmg"
STAMP="$VENV/.dmg_requirements.sha256"
WANT=$(shasum -a 256 "$REQS" | awk '{ print $1 }')
HAVE=$(cat "$STAMP" 2>/dev/null || true)
if [ "$HAVE" != "$WANT" ] || ! "$VENV/bin/python3" -I -c 'import dmgbuild' 2>/dev/null; then
  echo "Richte dmgbuild ein (aus PyPI, Versionen und Prüfsummen aus $REQS) …"
  rm -rf "$VENV"
  python3 -m venv "$VENV"
  if ! "$VENV/bin/python3" -I -m pip install -q --disable-pip-version-check --no-input \
      --require-hashes --only-binary :all: -r "$REQS"; then
    rm -rf "$VENV"
    echo "Abbruch: dmgbuild ließ sich nicht installieren (Netz, PyPI oder abweichende Prüfsumme)." >&2
    exit 1
  fi
  print -r -- "$WANT" > "$STAMP"
fi

rm -rf "$WORK"
mkdir -p "$WORK"
swift tools/make_dmg_background.swift "$WORK/hintergrund.png" 1
swift tools/make_dmg_background.swift "$WORK/hintergrund@2x.png" 2
rm -f "$TARGET"
mkdir -p "${TARGET:h}"
"$VENV/bin/dmgbuild" -s tools/dmg_settings.py -D app="$APP" -D background="$WORK/hintergrund.png" \
  -D icon=tools/AppIcon.icns "Klimacontrol" "$TARGET" >/dev/null
[ -s "$TARGET" ] || { echo "Abbruch: dmgbuild hat kein DMG angelegt." >&2; exit 1; }
rm -rf "$WORK"
