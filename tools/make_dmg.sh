#!/bin/zsh
# Installations-DMG: nur Klimacontrol.app und die Verknüpfung „Programme“ vor einem Hintergrund mit Anleitung.
# Aufruf aus build_app.sh: zsh tools/make_dmg.sh <App> <Ziel.dmg> <Arbeitsordner>, vorab zsh tools/make_dmg.sh --prepare
# Die Finder-Ansicht schreibt dmgbuild (MIT, nur Bauwerkzeug, nicht in der App) direkt; den Finder per AppleScript zu
# steuern geht seit macOS 26 nicht mehr (er verwirft Hintergrund und Symbolgröße). dmgbuild liegt in einer eigenen
# Python-Umgebung im Build-Cache und wird beim ersten Bau aus PyPI installiert – nur die Versionen und Prüfsummen aus
# tools/dmg_requirements.txt. Ändert sich die Datei, wird die Umgebung neu eingerichtet. Python 3.10+ wählt das Skript
# selbst (KLIMACONTROL_PYTHON=<Pfad> erzwingt einen Interpreter).
set -e -o pipefail
# --prepare: nur die dmgbuild-Umgebung einrichten (Vorprüfung am Anfang von build_app.sh, vor dem langen Bau).
PREPARE=0
if [ "${1:-}" = "--prepare" ] && [ $# -eq 1 ]; then
  PREPARE=1
else
  [ $# -eq 3 ] && [ -d "$1" ] && [ -n "$2" ] && [ -n "$3" ] || { echo "Aufruf: make_dmg.sh <App> <Ziel.dmg> <Arbeitsordner> | --prepare" >&2; exit 2; }
  # Absolut machen, bevor das Skript in den Projektordner wechselt (sonst zeigten relative Angaben ins Leere).
  APP=${1:a} TARGET=${2:a} WORK=${3:a}
  case "$WORK" in
    /|"$HOME"|"$HOME"/|"${0:A:h:h}"|"${0:A:h:h}"/*) echo "Abbruch: ungeeigneter Arbeitsordner $WORK (wird gelöscht)." >&2; exit 2 ;;
  esac
fi
cd "${0:A:h}/.."
REQS=tools/dmg_requirements.txt
VENV="${KLIMACONTROL_SCRATCH:-$HOME/Library/Caches/Klimacontrol-build}/venv-dmg"
STAMP="$VENV/.dmg_requirements.sha256"
WANT=$(shasum -a 256 "$REQS" | awk '{ print $1 }')
HAVE=$(cat "$STAMP" 2>/dev/null || true)
# dmgbuild 1.6.7 braucht Python 3.10 oder neuer; das erste python3 im Pfad ist am Mac oft /usr/bin/python3 (3.9).
PY_OK='import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)'
py_version() { "$1" -I -c 'import sys; print("%d.%d.%d" % sys.version_info[:3])' 2>/dev/null || echo "?"; }
find_python() {
  local cand
  if [ -n "${KLIMACONTROL_PYTHON:-}" ]; then
    if "$KLIMACONTROL_PYTHON" -I -c "$PY_OK" 2>/dev/null; then print -r -- "$KLIMACONTROL_PYTHON"; return 0; fi
    echo "Abbruch: KLIMACONTROL_PYTHON=$KLIMACONTROL_PYTHON ist kein Python 3.10 oder neuer (gefunden: $(py_version "$KLIMACONTROL_PYTHON"))." >&2
    return 1
  fi
  for cand in python3.14 python3.13 python3.12 python3.11 python3.10 python3.15 \
      /opt/homebrew/bin/python3 /usr/local/bin/python3 python3; do
    command -v "$cand" >/dev/null 2>&1 || [ -x "$cand" ] || continue
    if "$cand" -I -c "$PY_OK" 2>/dev/null; then command -v "$cand"; return 0; fi
  done
  echo "Abbruch: Für dmgbuild fehlt Python 3.10 oder neuer (python3 im Pfad: $(command -v python3 || echo keins), Version $(py_version python3))." >&2
  echo "Python installieren (z. B. brew install python) oder KLIMACONTROL_PYTHON=<Pfad> setzen." >&2
  return 1
}
if [ "$HAVE" != "$WANT" ] || ! "$VENV/bin/python3" -I -c "$PY_OK" 2>/dev/null \
    || ! "$VENV/bin/python3" -I -c 'import dmgbuild' 2>/dev/null; then
  PY=$(find_python) || exit 1
  PYV=$(py_version "$PY")
  echo "Richte dmgbuild ein mit Python $PYV ($PY), aus PyPI, Versionen und Prüfsummen aus $REQS …"
  rm -rf "$VENV"
  if ! "$PY" -m venv "$VENV"; then
    rm -rf "$VENV"
    echo "Abbruch: Python-Umgebung für dmgbuild ließ sich mit Python $PYV ($PY) nicht anlegen." >&2
    exit 1
  fi
  if ! "$VENV/bin/python3" -I -m pip install -q --disable-pip-version-check --no-input \
      --require-hashes --only-binary :all: -r "$REQS"; then
    rm -rf "$VENV"
    echo "Abbruch: dmgbuild ließ sich mit Python $PYV ($PY) nicht installieren (Netz, PyPI oder abweichende Prüfsumme in $REQS)." >&2
    exit 1
  fi
  print -r -- "$WANT" > "$STAMP"
fi
[ "$PREPARE" = 1 ] && { echo "dmgbuild bereit (Python $(py_version "$VENV/bin/python3"))."; exit 0; }

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
