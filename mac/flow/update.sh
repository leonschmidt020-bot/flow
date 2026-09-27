#!/bin/bash
# Flow aktualisieren: neuesten Stand holen, bauen, neu starten.
# Deine Daten (~/.config/flow: Einstellungen, Wörterbuch, Stimme, Meetings, Statistik) liegen NICHT im Repo
# und werden nicht angefasst.
#
#   ./update.sh              holen (nur fast-forward) + bauen + neu starten (sicher: build.sh prüft erst, tauscht dann,
#                            und nimmt das Update automatisch zurück, wenn die neue Version nicht gesund startet)
#   ./update.sh --check      nur zeigen, was neu wäre
#   ./update.sh --force      auch ohne neue Commits neu bauen
#   ./update.sh --rollback   zurück auf die vorige Version (~/Applications/Flow.app.previous); nochmal = wieder vor
#   ./update.sh --pin v1.7.8 auf diesem Stand festhalten (baut ihn, der Updater schweigt danach)
#   ./update.sh --unpin      Festhalten aufheben und auf den neuesten Stand aktualisieren
#
# Scheitert der Bau oder wird zurückgenommen, merkt sich update.sh den Commit in ~/.config/flow/update-failed.json:
# die Pille zeigt dann „Update hat nicht geklappt“ mit „Nochmal versuchen“ (statt fälschlich „aktuell“), und der
# nächste Lauf baut auch ohne neue Commits noch einmal.
set -euo pipefail
cd "$(dirname "$0")"
CHECK=0; FORCE=0; ROLLBACK=0; PIN=""; UNPIN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --check) CHECK=1 ;;
    --force) FORCE=1 ;;
    --rollback) ROLLBACK=1 ;;
    --pin) PIN="${2:?Tag fehlt, z. B. --pin v1.7.8}"; shift ;;
    --unpin) UNPIN=1 ;;
    *) echo "Unbekannte Option: $1"; exit 2 ;;
  esac
  shift
done

APP_NAME="Flow"
BUNDLE_ID="${BUNDLE_ID:-app.flowdictation.flow}"
DATA="${FLOW_HOME:-$HOME/.config/flow}"
if [ -n "${FLOW_TEST_APP_DIR:-}" ]; then APP="$FLOW_TEST_APP_DIR/$APP_NAME.app"; INST_TEST=1; else APP="$HOME/Applications/$APP_NAME.app"; fi
PLIST="$HOME/Library/LaunchAgents/$BUNDLE_ID.plist"
FAILED="$DATA/update-failed.json"
PINFILE="$DATA/update-pin"
source scripts/install_lib.sh

# Gescheitertes Update merken (für die Karte an der Pille). $1 = Grund, $2 = zurückgenommen, $3 = von Hand
remember_failed() {
  local r; r="$(printf '%s' "$1" | tr -d '"\\' | tr '\n\t' '  ')"
  mkdir -p "$DATA"
  printf '{"commit":"%s","version":"%s","reason":"%s","rolledBack":%s,"manual":%s,"at":%s}\n' \
    "$(git rev-parse HEAD)" "$(tr -d '[:space:]' < VERSION)" "$r" "$2" "$3" "$(date +%s)" > "$FAILED.tmp"
  mv "$FAILED.tmp" "$FAILED"
}

# --- Zurück auf die vorige Version ---
if [ $ROLLBACK -eq 1 ]; then
  set +e; inst_rollback_manual; rc=$?; set -e
  [ $rc -eq 0 ] || exit $rc
  # Läuft jetzt wieder der Stand des Repos (zweites --rollback = wieder vor)? Dann ist nichts offen.
  if [ "$(inst_plist_get "$APP" FlowGitCommit)" = "$(git rev-parse HEAD)" ]; then rm -f "$FAILED"
  else remember_failed "von Hand zurückgenommen (./update.sh --rollback)" true true; fi
  echo "✓ Aktiv: Flow $(inst_plist_get "$APP" CFBundleShortVersionString) – vorige: $(inst_plist_get "$APP.previous" CFBundleShortVersionString)"
  echo "  Tipp: ./update.sh --pin <tag> hält einen Stand fest, damit der Updater ihn nicht wieder ersetzt."
  exit 0
fi

# Mit DIESEM build.sh bauen, auch wenn gleich ein älterer Stand ausgecheckt wird (alte Stände kennen den sicheren Weg nicht)
TOOLS=""
cleanup_tools() { [ -z "$TOOLS" ] || rm -rf "$TOOLS"; }
trap cleanup_tools EXIT
copy_tools() {
  TOOLS="$(mktemp -d "${TMPDIR:-/tmp}/flow-tools.XXXXXX")"
  mkdir -p "$TOOLS/scripts"
  cp build.sh "$TOOLS/"; cp scripts/install_lib.sh scripts/signing.sh "$TOOLS/scripts/"
}

# Lokale Änderungen würden „git pull“ blockieren → sicher beiseitelegen (git stash, nichts geht verloren)
stash_dirty() {  # $1 = Repo-Ordner
  if [ -n "$(git -C "$1" status --porcelain --untracked-files=no)" ]; then
    local tag="update.sh $(date '+%Y-%m-%d %H:%M')"
    git -C "$1" stash push --quiet -m "$tag" && echo "⚠︎  Lokale Änderungen in $(basename "$1") beiseitegelegt: git stash list („${tag}“)"
  fi
}

# --- Festhalten ---
if [ -n "$PIN" ]; then
  git fetch --quiet --tags origin 2>/dev/null || true
  git rev-parse -q --verify "refs/tags/${PIN}^{commit}" >/dev/null || { echo "✗ Tag ${PIN} gibt es nicht (git tag -l)"; exit 2; }
  branch="$(git rev-parse --abbrev-ref HEAD)"
  if [ "$branch" = "HEAD" ]; then branch="$(sed -n 2p "$PINFILE" 2>/dev/null || true)"; [ -n "$branch" ] || branch=main; fi
  stash_dirty .
  copy_tools
  git checkout --quiet --detach "$PIN"
  mkdir -p "$DATA"; printf '%s\n%s\n' "$PIN" "$branch" > "$PINFILE"
  echo "» Festgehalten auf ${PIN} (vorher Branch ${branch}) – baue diesen Stand …"
  set +e; FLOW_SRC_DIR="$(pwd)" "$TOOLS/build.sh"; rc=$?; set -e
  [ $rc -eq 0 ] && rm -f "$FAILED"
  echo "  Aufheben: cd '$(pwd)' && git checkout -q ${branch} && ./update.sh --unpin"
  exit $rc
fi
if [ $UNPIN -eq 1 ]; then
  if [ -f "$PINFILE" ]; then
    branch="$(sed -n 2p "$PINFILE")"; [ -n "$branch" ] || branch=main
    stash_dirty .
    git checkout --quiet "$branch"
    rm -f "$PINFILE"
    echo "» Festhalten aufgehoben – zurück auf ${branch}"
  fi
  FORCE=1
elif [ -f "$PINFILE" ] && [ $CHECK -eq 0 ]; then
  echo "  Festgehalten auf $(head -1 "$PINFILE") – kein Update. Aufheben: ./update.sh --unpin"
  exit 0
fi

before="$(git describe --tags --always --dirty 2>/dev/null || echo '?')"
branch="$(git rev-parse --abbrev-ref HEAD)"
HEAD_BEFORE="$(git rev-parse HEAD)"
echo "» Flow: $before (Branch $branch)"
git fetch --quiet origin
# Nur Änderungen am Mac-Teil zählen (mac/flow + mac/clipvault) – Commits nur für Windows lösen kein Mac-Update aus
new="$(git log --oneline HEAD..@{u} -- . ../clipvault 2>/dev/null || true)"
if [ -z "$new" ]; then echo "  Schon aktuell."; else echo "  Neu:"; echo "$new" | sed 's/^/    /'; fi
[ $CHECK -eq 1 ] && exit 0

if [ -n "$new" ]; then
  stash_dirty .
  git pull --ff-only --quiet || { echo "✗ Update nicht automatisch möglich (lokale Commits?). Bitte „git status“ ansehen."; exit 1; }
fi

# ClipVault liegt im selben Repo (mac/clipvault): neu bauen, wenn sich dort etwas geändert hat und ClipVault
# installiert ist (sichere Reihenfolge in ../clipvault/build.sh)
CV_CHANGED=0
if [ -n "$new" ] && ! git diff --quiet "$HEAD_BEFORE" HEAD -- ../clipvault 2>/dev/null; then CV_CHANGED=1; fi
if [ $CV_CHANGED -eq 1 ] && [ -n "${FLOW_TEST_APP_DIR:-}" ]; then
  echo "  Testmodus: ClipVault wird nicht installiert"
elif [ $CV_CHANGED -eq 1 ] && [ -x ../clipvault/build.sh ] && [ -e "$HOME/.config/flow-clipvault/clipvault" ]; then
  echo "» ClipVault neu bauen …"
  (cd ../clipvault && ./build.sh install) || echo "⚠︎  ClipVault-Build fehlgeschlagen – Flow wird trotzdem aktualisiert."
fi

# Letztes Update gescheitert (Build-Fehler oder zurückgenommen)? Dann auch ohne neue Commits nochmal bauen –
# sonst stünde das Repo auf dem neuen Stand, die App wäre alt, und alles hieße „aktuell“.
if [ -z "$new" ] && [ $FORCE -eq 0 ] && [ -f "$FAILED" ]; then
  echo "  Letztes Update hat nicht geklappt – versuche es noch einmal."
  FORCE=1
fi
if [ -z "$new" ] && [ $FORCE -eq 0 ]; then echo "  Nichts zu bauen (--force baut trotzdem neu)."; exit 0; fi

OUT="$(mktemp "${TMPDIR:-/tmp}/flow-build.XXXXXX")"
set +e; ./build.sh 2>&1 | tee "$OUT"; rc=${PIPESTATUS[0]}; set -e
reason="$({ grep '^✗' "$OUT" || true; } | tail -1 | sed -e 's/^✗ *//' -e 's/ – stelle die vorige Version wieder her$//')"
rm -f "$OUT"
case $rc in
  0)  rm -f "$FAILED"
      echo "✓ $before → $(git describe --tags --always --dirty 2>/dev/null)" ;;
  75) echo "» Update verschoben – eine Aufnahme läuft noch."; exit 75 ;;
  3)  remember_failed "${reason:-neue Version lief nicht stabil}" true false
      echo "✗ Update zurückgenommen – die vorige Version läuft wieder."; exit 3 ;;
  *)  remember_failed "${reason:-Build fehlgeschlagen (Exit ${rc})}" false false
      echo "✗ Update fehlgeschlagen – die bisherige Version läuft weiter."; exit "$rc" ;;
esac
