#!/bin/bash
# Flow – Release-Tor: prüft den Arbeitsstand vollständig und veröffentlicht NUR, wenn alles grün ist.
#
#   scripts/release.sh 1.5.7 -m "Kurzbeschreibung"   prüfen → bei PASS: VERSION, ./build.sh, commit, tag, push
#   scripts/release.sh 1.5.7 --dry-run               nur prüfen (nichts wird geändert, gebaut-installiert oder gepusht)
#   scripts/release.sh --quick                        schnell (< 90 s): Build, CLI-Schutz, Wort-Lerner, Render, Sync-Kurztest
#                                                     (immer nur prüfen – ein Release braucht den vollen Lauf)
# Weitere Schalter:
#   --full-update-build    im Update-Test wirklich neu kompilieren (sonst: fertige Binary aus Schritt 1, ~2,5 Min. gespart)
#   --clipvault-worktree   (ohne Wirkung, nur Kompatibilität – ClipVault wird immer aus dem Arbeitsstand mac/clipvault getestet)
#   --rebaseline           Erkennungs-Baseline neu schreiben (tests/baseline/recognition.json, nur mit Absicht!) – nur prüfen
#
# Schritte (Details: README.md › Release):
#   1 Build            swift build -c release ohne Fehler · frisches --bundle-only-Bundle (Signatur, Version) ·
#                      build.sh lässt git status unverändert · Bash-Skripte: bash -n + „$NAME vor Mehrbyte-Zeichen“
#   1b Update-Sicherheit  Staging-Prüfung wie beim Update (codesign --deep --strict + --version) · Zertifikat ≥ 30 Tage
#                      (nur Warnung) · Rückweg-Test gegen eine Schein-App (tests/lib/rollback_test.sh) · --selftest-health
#   2 CLI-Schutz       unbekannter Befehl = Exit 2 · Binary ohne Bundle verweigert den App-Modus · app.lock · Test-Schutz
#   3 Wort-Lerner      CorrectionLearner + AliasLearner (Fälle aus der Geschichte) · Maus-Ziel-Logik (--selftest-mouse-target) ·
#                      Agent-Prompt (--selftest-agent-prompt: Auslöser, Erkennung, Regel-Rückfall, Schein-Claude, Verlauf, Original zuerst, ohne Claude-CLI,
#                      Ersetzen beim „Einfügen“ mit Schein-Box/-Feld, „abgeschickt?“) · --agent-prompt-latency (Einfügen → Karte < 1 s)
#   3b Oberfläche      --pill-ring-render, --shared-inbox-render, --update-badge-render (+ Fehler-Karte), --agent-prompt-render
#                      (alle Karten-Zustände) (+ --render-hub im vollen Lauf)
#   4 Erkennung        TTS-Testset durch die echte Pipeline: WER/Namen (+1,5 Punkte), Latenz (+30 %), Stimmabgleich
#   5 Sync + Teilen    lokaler wrangler dev, zwei Test-Geräte, Text/Bild/5-MB-Datei in beide Richtungen, grüner Punkt,
#                      gemeinsame Namen (PartnerVocab), kein Klartext auf dem Server
#   6 Update-Weg       Temp-Remote + Klon „als Freund“ mit lokalen Änderungen, genau der Befehl des Updaters
# Bericht: Tabelle auf dem Terminal + tests/last-release.txt. Bei FAIL wird nichts gepusht.
#
# Sicherheit: die Dev-Binary läuft nur mit CLI-Befehlen und immer mit FLOW_HOME/CLIPVAULT_HOME in Temp-Ordnern;
# eine installierte Flow.app, ~/.config/flow, ~/.config/flow-clipvault, der echte Tresor und die Zwischenablage bleiben unberührt.
# Monorepo: dieses Skript liegt in mac/flow/scripts; geprüft und veröffentlicht wird nur der Mac-Teil (mac/ + .gitignore).
# Mac-Tags heißen v<X.Y.Z> (Windows-Tags brauchen ein anderes Präfix, z. B. win-v…).
set -euo pipefail
cd "$(dirname "$0")/.."
SRC="$(pwd)"
ROOT="$(git rev-parse --show-toplevel)"
PRE="$(git rev-parse --show-prefix)"          # z. B. „mac/flow/“
MACDIR="$(cd "$SRC/.." && pwd)"
PY=/usr/bin/python3
[ -x "$PY" ] || PY="$(command -v python3)"
BIN="$SRC/.build/release/Flow"
TRAILER="Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"

usage() { sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; }
VERSION_NEW=""; DRY=0; QUICK=0; FULL_UPDATE=0; REBASE=0; CV_WORKTREE=0; MSG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --quick) QUICK=1; DRY=1 ;;
    --full-update-build) FULL_UPDATE=1 ;;
    --clipvault-worktree) CV_WORKTREE=1 ;;
    --rebaseline) REBASE=1; DRY=1 ;;
    -m|--message) MSG="${2:?Text fehlt}"; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "Unbekannte Option: $1"; usage; exit 2 ;;
    *) [ -z "$VERSION_NEW" ] || { echo "Nur eine Version angeben"; exit 2; }; VERSION_NEW="$1" ;;
  esac
  shift
done

CUR="$(tr -d '[:space:]' < VERSION)"
if [ -z "$VERSION_NEW" ]; then
  [ $DRY -eq 1 ] || { usage; exit 2; }
  VERSION_NEW="$("$PY" -c 'import sys; a=sys.argv[1].split("."); a[-1]=str(int(a[-1])+1); print(".".join(a))' "$CUR")"
fi
RE='^[0-9]+\.[0-9]+\.[0-9]+$'
[[ "$VERSION_NEW" =~ $RE ]] || { echo "✗ Version muss X.Y.Z sein (bekommen: ${VERSION_NEW})"; exit 2; }
newer="$("$PY" -c 'import sys; f=lambda s: tuple(int(x) for x in s.split(".")); print(int(f(sys.argv[1]) > f(sys.argv[2])))' "$VERSION_NEW" "$CUR")"
MODE="dry-run"; [ $QUICK -eq 1 ] && MODE="quick"; [ $REBASE -eq 1 ] && MODE="rebaseline"; [ $DRY -eq 0 ] && MODE="RELEASE"

# --- Vorbedingungen für ein echtes Release (schnell scheitern, bevor irgendetwas läuft) ---
if [ $DRY -eq 0 ]; then
  [ -n "$MSG" ] || { echo "✗ Beschreibung fehlt: -m \"…\" (wird zu „Flow ${VERSION_NEW}: …“)"; exit 2; }
  [ "$newer" = "1" ] || { echo "✗ ${VERSION_NEW} ist nicht neuer als ${CUR}"; exit 2; }
  [ "$(git rev-parse --abbrev-ref HEAD)" = "main" ] || { echo "✗ Release nur von main"; exit 2; }
  git rev-parse -q --verify "refs/tags/v${VERSION_NEW}" >/dev/null && { echo "✗ Tag v${VERSION_NEW} gibt es schon"; exit 2; }
  git fetch -q origin
  git ls-remote --exit-code --tags origin "refs/tags/v${VERSION_NEW}" >/dev/null 2>&1 && { echo "✗ Tag v${VERSION_NEW} liegt schon auf GitHub"; exit 2; }
  git merge-base --is-ancestor origin/main HEAD || { echo "✗ origin/main ist weiter als HEAD – erst git pull"; exit 2; }
fi

# --- nur ein Tor-Lauf gleichzeitig ---
LOCKDIR="${TMPDIR:-/tmp}/flow-release-gate.lock"
if ! mkdir "$LOCKDIR" 2>/dev/null; then
  if [ -f "$LOCKDIR/pid" ] && kill -0 "$(cat "$LOCKDIR/pid")" 2>/dev/null; then echo "✗ Release-Tor läuft schon (PID $(cat "$LOCKDIR/pid"))"; exit 2; fi
  rm -rf "$LOCKDIR"; mkdir "$LOCKDIR"
fi
echo $$ > "$LOCKDIR/pid"
T="$(mktemp -d "${TMPDIR:-/tmp}/flow-gate.XXXXXX")"
KEEP_T=0
cleanup() {
  "$PY" "$SRC/tests/lib/gatelib.py" sweep "$BIN" >/dev/null 2>&1 || true
  rm -rf "$LOCKDIR"
  [ $KEEP_T -eq 1 ] || rm -rf "$T"
}
trap cleanup EXIT
STEPS="$T/steps.tsv"; ROWS="$T/rows.tsv"; : > "$STEPS"; : > "$ROWS"

now() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }
T_START="$(now)"
# row <ok|FAIL|info> <prüfung> [detail]
row() {
  local d; d="$(printf '%s' "${3:-}" | tr '\t\n' '  ' | cut -c1-400)"
  printf '%s\t%s\t%s\t%s\n' "$STEP_ID" "$1" "$2" "$d" >> "$ROWS"
  local mark="ok  "; [ "$1" = "FAIL" ] && mark="FAIL"; [ "$1" = "info" ] && mark="info"
  echo "  ${mark} $2${d:+ – ${d}}"
}
check() { if [ "$1" = "0" ]; then row ok "$2" "${3:-}"; else row FAIL "$2" "${3:-}"; fi; }   # check <0|sonst> <name> [detail]
step_begin() { STEP_ID="$1"; STEP_TITLE="$2"; STEP_T0="$(now)"; echo; echo "== ${STEP_TITLE}"; }
step_end() {   # [SKIP]
  local st="PASS" secs
  secs="$("$PY" -c 'import sys; print(round(float(sys.argv[1]) - float(sys.argv[2]), 1))' "$(now)" "$STEP_T0")"
  if [ "${1:-}" = "SKIP" ]; then st="SKIP"
  elif grep -q "^${STEP_ID}	FAIL	" "$ROWS" || ! grep -q "^${STEP_ID}	ok	" "$ROWS"; then st="FAIL"; fi
  printf '%s\t%s\t%s\t%s\n' "$STEP_ID" "$STEP_TITLE" "$st" "$secs" >> "$STEPS"
  echo "   → ${st} (${secs} s)"
}
sweep() {
  local out; out="$("$PY" "$SRC/tests/lib/gatelib.py" sweep "$BIN" 2>/dev/null || true)"
  [ -z "$out" ] || row info "Reste beendet" "$out"
}
# Zeitlimit ohne coreutils: SIGALRM → Exit 142
with_timeout() { local s="$1"; shift; perl -e 'alarm shift @ARGV; exec @ARGV or exit 127' "$s" "$@"; }
# Baum-Hash des Arbeitsstands (versioniert + neu, ohne Ignoriertes) mit VERSION = neue Version – ohne den echten Index anzufassen
tree_hash() {
  local idx="$T/tree.idx" blob
  rm -f "$idx"
  GIT_INDEX_FILE="$idx" git -C "$ROOT" read-tree HEAD
  # nur der Mac-Teil: windows/ schreiben andere – deren Arbeit darf den Baum-Vergleich nicht stören
  GIT_INDEX_FILE="$idx" git -C "$ROOT" add -A -- mac .gitignore
  blob="$(printf '%s\n' "$VERSION_NEW" | git hash-object -w --stdin)"
  GIT_INDEX_FILE="$idx" git -C "$ROOT" update-index --cacheinfo "100644,${blob},${PRE}VERSION"
  # nur der Teilbaum mac/ zählt (andere Agents committen windows/ oder Wurzel-Dateien parallel)
  git -C "$ROOT" rev-parse "$(GIT_INDEX_FILE="$idx" git -C "$ROOT" write-tree):mac"
}

PREV_TAG="$(git describe --tags --match 'v[0-9]*' --abbrev=0 HEAD 2>/dev/null || echo "")"
TREE0="$(tree_hash)"
echo "Flow Release-Tor · ${CUR} → ${VERSION_NEW} · ${MODE} · Stand $(git describe --tags --match 'v[0-9]*' --always --dirty) · Baum ${TREE0:0:10}"
echo "Temp: ${T}"

# ───────────────────────── 1 Build ─────────────────────────
step_begin 1 "1 Build"
set +e
swift build -c release > "$T/swift-build.log" 2>&1; rc=$?
set -e
nerr="$(grep -c "error:" "$T/swift-build.log" || true)"; nwarn="$(grep -c "warning:" "$T/swift-build.log" || true)"
check "$([ $rc -eq 0 ] && [ "$nerr" = "0" ] && [ -x "$BIN" ] && echo 0 || echo 1)" "swift build -c release ohne Fehler" \
  "${nerr} Fehler, ${nwarn} Warnungen$([ $rc -ne 0 ] && echo "; $(grep "error:" "$T/swift-build.log" | head -3 | tr '\n' ' ')")"
if [ -x "$BIN" ] && [ $rc -eq 0 ]; then
  before="$(git status --porcelain -- "$MACDIR")"
  set +e; ./build.sh --bundle-only "$T/bundle" > "$T/bundle.log" 2>&1; brc=$?; set -e
  after="$(git status --porcelain -- "$MACDIR")"
  APP="$T/bundle/Flow.app"
  check "$brc" "frisches Bundle (build.sh --bundle-only in Temp-Ordner)" "$(tail -1 "$T/bundle.log")"
  if [ "$before" = "$after" ]; then row ok "build.sh lässt git status unverändert (Icon-Regression)"
  else row FAIL "build.sh lässt git status unverändert (Icon-Regression)" "$(diff <(echo "$before") <(echo "$after") | grep '^[<>]' | head -3 | tr '\n' ' ')"; fi
  pv="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo "?")"
  check "$([ "$pv" = "$CUR" ] && echo 0 || echo 1)" "Info.plist-Version = VERSION (${CUR})" "$pv"
  check "$(codesign --verify --strict "$APP" >/dev/null 2>&1; echo $?)" "Signatur des Bundles gültig" "$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
  vout="$(FLOW_HOME="$T/h-bundle" with_timeout 20 "$APP/Contents/MacOS/Flow" --version 2>&1 || true)"
  check "$(echo "$vout" | grep -q "$CUR" && echo 0 || echo 1)" "Bundle-Binary im CLI-Modus (--version)" "$vout"
fi
set +e; lint="$("$PY" tests/lib/bash_lint.py "$MACDIR" 2>&1)"; lrc=$?; set -e
check "$lrc" "Bash-Skripte (mac/): bash -n (3.2) + kein \$NAME direkt vor Mehrbyte-Zeichen" "$(echo "$lint" | tail -4 | tr '\n' ' ')"
# Update-Quelle steht an EINER Stelle (mac/flow.conf); install-mac.sh muss denselben Standard tragen
u_conf="$(sed -n 's/^FLOW_REPO_URL="\(.*\)"$/\1/p' "$MACDIR/flow.conf")"
u_inst="$(sed -n 's/^FLOW_REPO_URL_DEFAULT="\(.*\)"$/\1/p' "$MACDIR/install-mac.sh")"
check "$([ -n "$u_conf" ] && [ "$u_conf" = "$u_inst" ] && echo 0 || echo 1)" "FLOW_REPO_URL: mac/flow.conf = install-mac.sh" "${u_conf}"
case "$u_conf" in *FLOW_OWNER*) row info "FLOW_REPO_URL ist noch der Platzhalter" "vor der Veröffentlichung in mac/flow.conf + install-mac.sh setzen" ;; esac
sweep
step_end
BUILD_OK=1
grep -q "^1	FAIL	swift build" "$ROWS" && BUILD_OK=0

# ───────────────────────── 1b Update-Sicherheit ─────────────────────────
# Stabilitätsplan #1/#4: der sichere Installationsweg (scripts/install_lib.sh) und das Lebenszeichen – alles billig (~12 s)
step_begin 1b "1b Update-Sicherheit (Staging, Zertifikat, Rückweg)"
APP="${APP:-}"
if [ $BUILD_OK -eq 1 ] && [ -d "$APP" ]; then
  # genau die Prüfung, die build.sh vor dem Stoppen der App macht
  set +e
  vr="$(APP_NAME="Flow" DATA="$T/h-verify" bash -c 'source scripts/install_lib.sh; inst_verify "$1" "$2" || { echo "$INST_REASON"; exit 1; }' _ "$APP" "$CUR" 2>&1)"; rc=$?
  set -e
  check "$rc" "Staging-Prüfung wie beim Update (codesign --verify --deep --strict + --version)" "$vr"
  check "$(grep -q "Staging geprüft" "$T/bundle.log" && echo 0 || echo 1)" "build.sh prüft das Staging-Bundle vor dem Tausch" "$(grep -m1 "Staging" "$T/bundle.log" || true)"
  # Zertifikat: in < 30 Tagen abgelaufen = alle Updates scheitern beim Signieren → rechtzeitig warnen (kein FAIL)
  mkdir -p "$T/cert"
  if (cd "$T/cert" && codesign -d --extract-certificates "$APP" >/dev/null 2>&1) && [ -s "$T/cert/codesign0" ]; then
    cend="$(openssl x509 -inform DER -in "$T/cert/codesign0" -noout -enddate 2>/dev/null | sed 's/^notAfter=//')"
    if openssl x509 -inform DER -in "$T/cert/codesign0" -noout -checkend $((30 * 86400)) >/dev/null 2>&1; then
      row ok "Signatur-Zertifikat noch mindestens 30 Tage gültig" "bis ${cend}"
    else
      row info "WARNUNG: Signatur-Zertifikat läuft in weniger als 30 Tagen ab" "bis ${cend} – neues Zertifikat anlegen (Xcode › Accounts), Freigaben hängen daran"
    fi
  else
    row info "Signatur-Zertifikat nicht lesbar (ad-hoc signiert?)"
  fi
  # Rückweg: codesign kaputt, kein Heartbeat, Abbruch nach dem Stoppen, Aufnahme läuft, --rollback – gegen eine Schein-App
  set +e; rb="$(with_timeout 120 bash tests/lib/rollback_test.sh 2>&1)"; rc=$?; set -e
  echo "$rb" > "$T/rollback.out"
  check "$rc" "Rückweg-Logik gegen eine Schein-App im Temp-Ordner (tests/lib/rollback_test.sh)" "$(echo "$rb" | tail -1)"
  { echo "$rb" | grep "FEHLER" || true; } | while IFS= read -r l; do row FAIL "$(echo "$l" | sed 's/^ *FEHLER *//')"; done
  # Lebenszeichen + Absturz-Erkennung der App, und dass das Health-Gate (plutil) liest, was die App schreibt
  set +e; hs="$(FLOW_HOME="$T/h-health" with_timeout 30 "$BIN" --selftest-health 2>&1)"; rc=$?; set -e
  check "$rc" "health.json: Heartbeat, unsauberes Ende, Absturzberichte (--selftest-health)" "$(echo "$hs" | tail -1)"
  { echo "$hs" | grep "FEHLER" || true; } | while IFS= read -r l; do row FAIL "$(echo "$l" | sed 's/^ *FEHLER *//')"; done
  hp="$(plutil -extract pid raw -o - "$T/h-health/health.json" 2>/dev/null || true)"
  hb="$(plutil -extract lastHeartbeat raw -o - "$T/h-health/health.json" 2>/dev/null || true)"
  check "$([ -n "$hp" ] && [ -n "$hb" ] && echo 0 || echo 1)" "Health-Gate liest die health.json der App (plutil)" "pid ${hp}, lastHeartbeat ${hb%%.*}"
  check "$(grep -q "<key>ThrottleInterval</key><integer>10</integer>" build.sh && grep -q "<key>StandardErrorPath</key>" build.sh && echo 0 || echo 1)" \
    "LaunchAgent: ThrottleInterval 10 + StandardErrorPath"
  sweep
  step_end
else
  row FAIL "übersprungen – kein Build"; step_end
fi

# ───────────────────────── 2 CLI-Schutz ─────────────────────────
step_begin 2 "2 CLI-Schutz + eine Instanz"
if [ $BUILD_OK -eq 1 ]; then
  H="$T/h-cli"; mkdir -p "$H"
  set +e
  FLOW_HOME="$H" with_timeout 20 "$BIN" --release-gate-unbekannt > "$T/unk.out" 2>&1; rc=$?
  set -e
  check "$([ $rc -eq 2 ] && echo 0 || echo 1)" "unbekannter Befehl → Exit 2 (startet nie die App)" "exit ${rc}: $(head -1 "$T/unk.out")"
  # App-Modus mit der Dev-Binary: Sperre wird VORHER gehalten – falls der Bundle-Schutz versagt, stoppt spätestens app.lock
  FLOW_HOME="$H" "$BIN" --selftest-lock-probe "$H/app.lock" hold > "$T/holder.out" 2>&1 &
  HOLDER=$!
  for _ in $(seq 1 50); do grep -q frei "$T/holder.out" 2>/dev/null && break; sleep 0.1; done
  if grep -q frei "$T/holder.out"; then
    for args in "" "-psn_0_4711"; do
      set +e
      # shellcheck disable=SC2086
      env -u FLOW_DEV FLOW_HOME="$H" perl -e 'alarm 15; exec @ARGV' "$BIN" $args > "$T/app.out" 2>&1; rc=$?
      set -e
      what="Binary ohne App-Bundle verweigert den App-Modus${args:+ (${args})}"
      if [ $rc -eq 2 ] && grep -q "Kein App-Bundle" "$T/app.out"; then row ok "$what" "exit 2"
      elif [ $rc -eq 1 ]; then row FAIL "$what" "Bundle-Prüfung fehlt – nur app.lock hat den Start verhindert"
      else row FAIL "$what" "exit ${rc}: $(head -2 "$T/app.out" | tr '\n' ' ')"; fi
    done
  else
    row FAIL "Sperre für den App-Modus-Test halten" "$(cat "$T/holder.out")"
  fi
  kill "$HOLDER" 2>/dev/null || true; wait "$HOLDER" 2>/dev/null || true
  set +e
  lk="$(FLOW_HOME="$H/lock" with_timeout 30 "$BIN" --selftest-lock 2>&1)"; rc=$?
  set -e
  check "$rc" "app.lock: zweite Instanz abgewiesen, frei nach Ende/Absturz" "$(echo "$lk" | tail -1)"
  [ $rc -eq 0 ] || row info "app.lock-Ausgabe" "$(echo "$lk" | grep FEHLER | head -3)"
  set +e
  env -u FLOW_HOME perl -e 'alarm 20; exec @ARGV' "$BIN" --selftest-guard >/dev/null 2>&1; r1=$?
  FLOW_HOME="$HOME/.config/flow" with_timeout 20 "$BIN" --selftest-guard >/dev/null 2>&1; r2=$?
  FLOW_HOME="$H/guard" with_timeout 20 "$BIN" --selftest-guard >/dev/null 2>&1; r3=$?
  set -e
  check "$([ $r1 -eq 3 ] && [ $r2 -eq 3 ] && [ $r3 -eq 0 ] && echo 0 || echo 1)" "Selbsttests verweigern echte Daten (ohne/mit ~/.config/flow → Exit 3)" "${r1}/${r2}/${r3}"
  sweep
  step_end
else
  row FAIL "übersprungen – kein Build"; step_end
fi

# ───────────────────────── 3 Wort-Lerner ─────────────────────────
step_begin 3 "3 Wort-Lerner"
if [ $BUILD_OK -eq 1 ]; then
  set +e
  lo="$(FLOW_HOME="$T/h-learn" with_timeout 60 "$BIN" --selftest-learner 2>&1)"; rc=$?
  set -e
  echo "$lo" > "$T/learner.out"
  check "$rc" "CorrectionLearner + AliasLearner" "$(echo "$lo" | tail -1)"
  { echo "$lo" | grep "FEHLER" || true; } | while IFS= read -r l; do row FAIL "$(echo "$l" | sed 's/^ *FEHLER *//')"; done
  # „Text dorthin, wo die Maus ist“: reine Logik (Fensterliste, Koordinaten mehrerer Bildschirme, eigene Fenster,
  # Textfeld-Erkennung, Klick nur im Terminal, Enter-Liste) – keine Fenster, kein Fokus, keine Zwischenablage, < 1 s
  set +e
  mo="$(FLOW_HOME="$T/h-mouse" with_timeout 30 "$BIN" --selftest-mouse-target 2>&1)"; rc=$?
  set -e
  echo "$mo" > "$T/mouse-target.out"
  check "$rc" "Maus-Ziel (--selftest-mouse-target)" "$(echo "$mo" | tail -1)"
  { echo "$mo" | grep "FEHLER" || true; } | while IFS= read -r l; do row FAIL "Maus-Ziel: $(echo "$l" | sed 's/^ *FEHLER *//')"; done
  # Agent-Prompt: reine Logik + Ablauf mit Schein-Claude und Schein-Zwischenablage (kein echter Claude-Aufruf, < 15 s)
  set +e
  ao="$(FLOW_HOME="$T/h-agentprompt" with_timeout 60 "$BIN" --selftest-agent-prompt 2>&1)"; rc=$?
  set -e
  echo "$ao" > "$T/agent-prompt.out"
  check "$rc" "Agent-Prompt (--selftest-agent-prompt)" "$(echo "$ao" | tail -1)"
  { echo "$ao" | grep "FEHLER" || true; } | while IFS= read -r l; do row FAIL "Agent-Prompt: $(echo "$l" | sed 's/^ *FEHLER *//')"; done
  # Vorschlags-Karte: Einfügen → lesbar (offscreen gemessen, Exit 0 nur unter 1 s)
  set +e
  lo="$(FLOW_HOME="$T/h-aplat" with_timeout 60 "$BIN" --agent-prompt-latency 2>&1)"; rc=$?
  set -e
  check "$rc" "Agent-Prompt-Vorschlag: Einfügen → Karte < 1 s (--agent-prompt-latency)" "$(echo "$lo" | grep '^NACHHER' | sed 's/^NACHHER *//')"
  sweep
  step_end
else
  row FAIL "übersprungen – kein Build"; step_end
fi

# ───────────────────────── 3b Oberfläche rendern ─────────────────────────
step_begin 3b "3b Oberfläche rendern (offscreen)"
if [ $BUILD_OK -eq 1 ]; then
  RD="$T/render"; mkdir -p "$RD/cv"
  # png_ok <datei> → 0, wenn ein echtes PNG mit Inhalt (> 4 KB) entstanden ist
  png_ok() { [ -s "$1" ] && [ "$(head -c 4 "$1" | od -An -c | tr -d ' ')" = "211PNG" ] && [ "$(wc -c < "$1")" -gt 4096 ]; }
  for r in "pill-ring-render:ring.png:Pillen-Rahmen" "shared-inbox-render:inbox.png:Neu-Liste (grüner Punkt)" "update-badge-render:update.png:Update-Karte"; do
    flag="${r%%:*}"; rest="${r#*:}"; file="${rest%%:*}"; label="${rest#*:}"
    set +e; FLOW_HOME="$RD/h" CLIPVAULT_HOME="$RD/cv" with_timeout 60 "$BIN" "--${flag}" "$RD/${file}" > "$RD/${flag}.log" 2>&1; rc=$?; set -e
    check "$([ $rc -eq 0 ] && png_ok "$RD/${file}" && echo 0 || echo 1)" "--${flag}: ${label}" "exit ${rc}, $(wc -c < "$RD/${file}" 2>/dev/null | tr -d ' ') Bytes"
  done
  set +e; FLOW_HOME="$RD/h" CLIPVAULT_HOME="$RD/cv" with_timeout 60 "$BIN" --update-badge-render "$RD/update-failed.png" failed > "$RD/update-failed.log" 2>&1; rc=$?; set -e
  check "$([ $rc -eq 0 ] && png_ok "$RD/update-failed.png" && echo 0 || echo 1)" "--update-badge-render failed: Fehler-Karte „Nochmal versuchen“" \
    "exit ${rc}, $(wc -c < "$RD/update-failed.png" 2>/dev/null | tr -d ' ') Bytes"
  # Agent-Prompt-Karten: Vorschlag, wird gebaut, fertig (+ Hover, Original, EN, Regeln), abgebrochen, fehlgeschlagen, Hub
  set +e; FLOW_HOME="$RD/h-ap" with_timeout 90 "$BIN" --agent-prompt-render "$RD/agent-prompt" > "$RD/agent-prompt.log" 2>&1; rc=$?; set -e
  bad=""
  for f in 1_vorschlag 1b_vorschlag_verblasst 2b_baut_live 3a_fertig 3c_fertig_original 3f_fertig_abgeschickt 4a_abgebrochen 4b_fehlgeschlagen 6_hub_prompts 7b_ohne_claude_fertig; do png_ok "$RD/agent-prompt/$f.png" || bad="$bad $f"; done
  check "$([ $rc -eq 0 ] && [ -z "$bad" ] && echo 0 || echo 1)" "--agent-prompt-render: Karten-Zustände + Hub" "exit ${rc}, $(ls "$RD/agent-prompt"/*.png 2>/dev/null | wc -l | tr -d ' ') Bilder${bad:+, fehlen/leer:${bad}}"
  if [ $QUICK -eq 0 ]; then
    set +e; FLOW_HOME="$RD/h" CLIPVAULT_HOME="$RD/cv" with_timeout 240 "$BIN" --render-hub "$RD/hub" demo > "$RD/hub.log" 2>&1; rc=$?; set -e
    n="$(ls "$RD/hub"/*.png 2>/dev/null | wc -l | tr -d ' ')"; bad=""
    for f in 1_diktat 6_einstellungen_modal 6b_einstellungen_klein 7_insights_stimme; do png_ok "$RD/hub/$f.png" || bad="$bad $f"; done
    check "$([ $rc -eq 0 ] && [ -z "$bad" ] && echo 0 || echo 1)" "--render-hub demo (inkl. 6b_einstellungen_klein = kleiner Bildschirm)" "exit ${rc}, ${n} Bilder${bad:+, fehlen/leer:${bad}}"
  else
    row info "--render-hub im Schnellmodus ausgelassen"
  fi
  sweep
  step_end
else
  row FAIL "übersprungen – kein Build"; step_end
fi

# ───────────────────────── 4 Erkennung ─────────────────────────
step_begin 4 "4 Erkennung (WER, Namen, Latenz, Stimme)"
if [ $QUICK -eq 1 ]; then
  row info "im Schnellmodus ausgelassen"; step_end SKIP
elif [ $BUILD_OK -eq 1 ]; then
  set +e
  "$PY" tests/lib/recognition.py --bin "$BIN" --work "$T/rec" --out "$T/rec.json" $([ $REBASE -eq 1 ] && echo --rebaseline); set -e
  "$PY" tests/lib/report.py add-json "$ROWS" 4 "$T/rec.json"
  sweep
  step_end
else
  row FAIL "übersprungen – kein Build"; step_end
fi

# ───────────────────────── 5 Sync + Teilen ─────────────────────────
step_begin 5 "5 Sync + Teilen (ClipVault)"
CVREPO="$MACDIR"
WRANGLER="$CVREPO/clipvault/sync-worker/node_modules/.bin/wrangler"
if [ $BUILD_OK -ne 1 ]; then
  row FAIL "übersprungen – kein Build"; step_end
elif [ ! -f "$CVREPO/clipvault/main.swift" ]; then
  row FAIL "ClipVault neben flow/ gefunden" "${CVREPO}/clipvault fehlt"; step_end
elif [ ! -x "$WRANGLER" ]; then
  row FAIL "wrangler vorhanden" "fehlt: (cd ../clipvault/sync-worker && npm install)"; step_end
else
  mkdir -p "$T/cv-src"
  # Monorepo: ClipVault gehört zum geprüften Arbeitsstand (wie Flow) – immer aus mac/clipvault
  rsync -a --exclude node_modules --exclude .wrangler "$CVREPO/clipvault" "$T/cv-src/"
  key="wt-$(cat "$T/cv-src/clipvault/"*.swift | shasum | cut -c1-16)"; cvdesc="Arbeitsstand mac/clipvault ($(git -C "$CVREPO" status --porcelain -- clipvault | wc -l | tr -d ' ') Änderungen)"
  CACHE="$HOME/Library/Caches/flow-release-gate"; mkdir -p "$CACHE"
  CV="$CACHE/cvgate-${key}"
  if [ ! -x "$CV" ]; then
    echo "  … baue ClipVault-Testbinary (${cvdesc})"
    set +e; swiftc -O "$T/cv-src/clipvault/"*.swift -o "$CV.tmp" > "$T/cv-build.log" 2>&1; crc=$?; set -e
    if [ $crc -eq 0 ]; then mv "$CV.tmp" "$CV"; else rm -f "$CV.tmp"; fi
    ls -t "$CACHE"/cvgate-* 2>/dev/null | tail -n +6 | xargs rm -f 2>/dev/null || true    # höchstens 5 behalten
  fi
  if [ -x "$CV" ]; then
    row info "ClipVault-Stand" "$cvdesc"
    set +e
    "$PY" tests/lib/sync_test.py --cv "$CV" --flow "$BIN" --worker "$T/cv-src/clipvault/sync-worker" --wrangler "$WRANGLER" \
      --work "$T/sync" --out "$T/sync.json" $([ $QUICK -eq 1 ] && echo --quick)
    set -e
    "$PY" tests/lib/report.py add-json "$ROWS" 5 "$T/sync.json"
  else
    row FAIL "ClipVault baut (swiftc -O)" "$(grep error: "$T/cv-build.log" | head -2 | tr '\n' ' ')"
  fi
  sweep
  step_end
fi

# ───────────────────────── 6 Update-Weg ─────────────────────────
step_begin 6 "6 Update-Weg (als Freund)"
if [ $QUICK -eq 1 ]; then
  row info "im Schnellmodus ausgelassen"; step_end SKIP
elif [ $BUILD_OK -ne 1 ]; then
  row FAIL "übersprungen – kein Build"; step_end
elif [ -z "$PREV_TAG" ]; then
  row FAIL "vorheriger Tag gefunden"; step_end
else
  set +e
  "$PY" tests/lib/update_test.py --src "$SRC" --flow "$BIN" --prev "$PREV_TAG" --version "$VERSION_NEW" --work "$T/update" \
    --out "$T/update.json" $([ $FULL_UPDATE -eq 1 ] && echo --full-build)
  set -e
  "$PY" tests/lib/report.py add-json "$ROWS" 6 "$T/update.json"
  sweep
  step_end
fi

# ───────────────────────── Bericht ─────────────────────────
TREE1="$(tree_hash)"
STEP_ID=0; STEP_T0="$(now)"
if [ "$TREE1" != "$TREE0" ]; then
  row FAIL "Arbeitsstand während der Prüfung unverändert" "Baum ${TREE0:0:10} → ${TREE1:0:10} (andere Agents?) – bitte neu starten"
  printf '0\t0 Arbeitsstand\tFAIL\t0\n' >> "$STEPS"
fi
TOTAL="$("$PY" -c 'import sys; print(round(float(sys.argv[1]) - float(sys.argv[2]), 1))' "$(now)" "$T_START")"
HEADER="Flow Release-Tor · ${CUR} → ${VERSION_NEW} · ${MODE} · $(date '+%Y-%m-%d %H:%M') · $(git describe --tags --match 'v[0-9]*' --always --dirty) · Baum ${TREE0:0:10} · ${TOTAL} s"
echo
set +e; "$PY" tests/lib/report.py render "$STEPS" "$ROWS" "$SRC/tests/last-release.txt" "$HEADER"; RC=$?; set -e

if [ $RC -ne 0 ]; then
  KEEP_T=1
  echo; echo "✗ FAIL – nichts veröffentlicht. Temp-Ordner mit Protokollen bleibt: ${T}"
  exit 1
fi
if [ $DRY -eq 1 ]; then echo; echo "✓ PASS (${MODE}) – nichts veröffentlicht."; exit 0; fi

# ───────────────────────── Release ─────────────────────────
echo; echo "== Release ${VERSION_NEW}"
echo "$VERSION_NEW" > VERSION
./build.sh
if [ "$(tree_hash)" != "$TREE0" ]; then
  echo "✗ Nach build.sh weicht der Stand vom geprüften ab – nichts committet/gepusht. (git status ansehen)"
  exit 1
fi
git -C "$ROOT" add -A -- mac .gitignore
git commit -q -m "Flow (macOS) ${VERSION_NEW}: ${MSG}" -m "$TRAILER"
if [ "$(git -C "$ROOT" rev-parse 'HEAD:mac')" != "$TREE0" ]; then
  echo "✗ Commit enthält nicht genau den geprüften Stand – nichts gepusht. Rückgängig: git reset --soft HEAD~1"
  exit 1
fi
git tag "v${VERSION_NEW}"
git push -q origin main
git push -q origin "v${VERSION_NEW}"
{ echo; echo "Veröffentlicht: v${VERSION_NEW} ($(git rev-parse --short HEAD)) $(date '+%Y-%m-%d %H:%M')"; } >> "$SRC/tests/last-release.txt"
echo "✓ Flow ${VERSION_NEW} veröffentlicht ($(git rev-parse --short HEAD)) – installierte Apps zeigen in ~1 Min. den roten Punkt."
