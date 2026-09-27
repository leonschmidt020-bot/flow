#!/bin/bash
# Release-Tor: Rückweg-Logik aus scripts/install_lib.sh gegen eine Schein-App in einem Temp-Ordner (~10 s).
#
#   tests/lib/rollback_test.sh     → „N/M ok“, Exit 1 bei einem Fehler
#
# Nie ~/Applications, nie launchctl, nie die echte App: APP liegt im Temp-Ordner, inst_stop_app / inst_start_app /
# inst_notify sind Attrappen (protokollieren nur), codesign ist ein Shim im PATH. Jedes Szenario läuft wie build.sh
# in einer eigenen Subshell mit set -e und EXIT-Trap.
set -euo pipefail
SRC="$(cd "$(dirname "$0")/../.." && pwd)"
W="$(mktemp -d "${TMPDIR:-/tmp}/flow-rollback.XXXXXX")"
trap 'rm -rf "$W"' EXIT
PASS=0; FAIL=0
ok() {   # ok <0|sonst> <was> [detail]
  if [ "$1" = "0" ]; then PASS=$((PASS + 1)); echo "  ok      $2"
  else FAIL=$((FAIL + 1)); echo "  FEHLER  $2${3:+ – ${3}}"; fi
}
is() { [ "$1" = "$2" ] && echo 0 || echo 1; }

# codesign-Shim: scheitert, wenn $W/codesign-kaputt existiert
mkdir -p "$W/bin"
printf '#!/bin/bash\n[ -e "%s/codesign-kaputt" ] && exit 1\nexit 0\n' "$W" > "$W/bin/codesign"
chmod +x "$W/bin/codesign"
export PATH="$W/bin:$PATH"

# Schein-Bundle: Info.plist + „Binary“, die auf --version antwortet wie die echte
mkapp() {   # $1 = Pfad, $2 = Version, $3 = Build
  mkdir -p "$1/Contents/MacOS"
  cat > "$1/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleShortVersionString</key><string>$2</string>
  <key>CFBundleVersion</key><string>$3</string>
  <key>FlowHealthVersion</key><integer>1</integer>
</dict></plist>
PL
  printf '#!/bin/bash\necho "Flow %s (test, %s)"\n' "$2" "$3" > "$1/Contents/MacOS/Flow"
  chmod +x "$1/Contents/MacOS/Flow"
}
ver() { /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$1/Contents/Info.plist" 2>/dev/null || echo "–"; }
health() {   # $1 = Build, $2 = pid, $3 = busy
  local n; n="$(date +%s)"
  printf '{"pid":%s,"version":"x","build":"%s","bundle":"x","startedAt":%s,"lastHeartbeat":%s,"busy":%s,"cleanExit":false,"uncleanExits":0,"crashReports":0,"lastCrashScan":%s}\n' \
    "$2" "$1" "$n" "$n" "$3" "$n" > "$D/data/health.json"
}

# Neues Szenario: v1 installiert (Build 1), v2 fertig im Staging (Build 2)
setup() {
  D="$W/s$1"; mkdir -p "$D/Applications" "$D/data"
  APP_T="$D/Applications/Flow.app"; STAGE_T="$D/Applications/.Flow.staging/Flow.app"
  mkapp "$APP_T" 1.0.0 1
  mkapp "$STAGE_T" 2.0.0 2
  : > "$D/calls"
  rm -f "$W/codesign-kaputt"
}
# Wie build.sh: set -e, EXIT-Trap, Aufruf von inst_install_staged. $1 = gesund (1/leer), $2 = Abbruch im Health-Gate (1/leer)
run_install() {
  set +e
  (
    set -euo pipefail
    APP="$APP_T"; DATA="$D/data"; BUNDLE_ID="test.rollback"; PLIST="/dev/null"; APP_NAME="Flow"
    case "$APP" in "$HOME/Applications"*) echo "Schutz: echter App-Ordner"; exit 99 ;; esac
    # shellcheck source=/dev/null
    source "$SRC/scripts/install_lib.sh"
    GOOD="${1:-}"; ABORT="${2:-}"
    inst_stop_app() { echo stop >> "$D/calls"; }
    inst_start_app() {
      echo "start $(ver "$APP")" >> "$D/calls"
      # „gesunde“ neue Version: schreibt ihr Lebenszeichen (pid = diese Test-Shell, lebt)
      if [ -n "$GOOD" ] && [ "$(ver "$APP")" = "2.0.0" ]; then health 2 $$ false; fi
      return 0
    }
    inst_notify() { echo "notify $1" >> "$D/calls"; }
    if [ -n "$ABORT" ]; then inst_wait_healthy() { false; exit 1; }; fi    # simuliert einen set-e-Abbruch mitten drin
    trap inst_on_exit EXIT
    inst_install_staged "$STAGE_T" 2.0.0 2
  ) > "$D/out" 2>&1
  RC=$?
  set -e
}
calls() { tr '\n' ',' < "$D/calls" | sed 's/,$//'; }
export FLOW_HEALTH_MINUP=0 FLOW_HEALTH_TIMEOUT=3 FLOW_BUSY_WAIT=2

echo "Rückweg-Test (Temp: ${W})"

# 1) gesundes Update
setup 1; run_install 1
ok "$([ $RC -eq 0 ] && [ "$(ver "$APP_T")" = 2.0.0 ] && [ "$(ver "$APP_T.previous")" = 1.0.0 ] && echo 0 || echo 1)" \
  "gesundes Update: neue Version aktiv, vorige als .previous" "rc=${RC} aktiv=$(ver "$APP_T") vorige=$(ver "$APP_T.previous")"
ok "$(is "$(calls)" "stop,start 2.0.0")" "gesundes Update: einmal stoppen, einmal starten" "$(calls)"
ok "$([ ! -e "$STAGE_T" ] && echo 0 || echo 1)" "Staging-Bundle ist verschoben (kein Kopieren)"

# 2) codesign scheitert → nichts gestoppt, nichts getauscht
setup 2; touch "$W/codesign-kaputt"; run_install 1
ok "$([ $RC -eq 1 ] && [ "$(ver "$APP_T")" = 1.0.0 ] && [ ! -e "$APP_T.previous" ] && echo 0 || echo 1)" \
  "codesign scheitert: installierte App unverändert, Exit 1" "rc=${RC} aktiv=$(ver "$APP_T")"
ok "$(is "$(calls)" "")" "codesign scheitert: App wurde nie gestoppt" "$(calls)"
ok "$(grep -q "Signatur des neuen Bundles ungültig" "$D/out" && echo 0 || echo 1)" "codesign scheitert: Grund steht in der Ausgabe"

# 3) kein Lebenszeichen (alte health.json von Build 1 mit frischem Heartbeat zählt NICHT) → automatisch zurück
setup 3; health 1 $$ false; run_install
ok "$([ $RC -eq 3 ] && [ "$(ver "$APP_T")" = 1.0.0 ] && [ "$(ver "$APP_T.failed")" = 2.0.0 ] && echo 0 || echo 1)" \
  "kein Heartbeat: zurück auf 1.0.0, 2.0.0 liegt als .failed" "rc=${RC} aktiv=$(ver "$APP_T") failed=$(ver "$APP_T.failed")"
ok "$(is "$(calls)" "stop,start 2.0.0,stop,start 1.0.0,notify Update zurückgenommen")" "kein Heartbeat: vorige Version neu gestartet + Meldung" "$(calls)"
ok "$(grep -q "Update zurückgenommen: Flow 2.0.0 lief nicht stabil" "$D/data/flow.log" && echo 0 || echo 1)" "kein Heartbeat: Zeile im flow.log" \
  "$(tail -1 "$D/data/flow.log" 2>/dev/null)"

# 4) Abbruch (set -e) nach dem Stoppen → EXIT-Trap stellt her
setup 4; run_install 1 1
ok "$([ $RC -ne 0 ] && [ "$(ver "$APP_T")" = 1.0.0 ] && echo 0 || echo 1)" "Abbruch nach dem Stoppen: EXIT-Trap holt 1.0.0 zurück" "rc=${RC} aktiv=$(ver "$APP_T")"
ok "$(is "$(calls | sed 's/.*,//')" "start 1.0.0")" "Abbruch nach dem Stoppen: App läuft wieder (zuletzt gestartet: 1.0.0)" "$(calls)"

# 5) Aufnahme läuft (busy von einem lebenden „Flow“-Prozess) → verschoben, nichts angefasst
setup 5
printf '#!/bin/bash\nsleep 30\n' > "$W/Flow"; chmod +x "$W/Flow"   # Prozess, dessen Befehlszeile „Flow“ enthält
"$W/Flow" >/dev/null 2>&1 & BUSY_PID=$!
health 1 "$BUSY_PID" true; run_install 1
pkill -P "$BUSY_PID" 2>/dev/null || true; kill "$BUSY_PID" 2>/dev/null || true; wait "$BUSY_PID" 2>/dev/null || true
ok "$([ $RC -eq 75 ] && [ "$(ver "$APP_T")" = 1.0.0 ] && [ -z "$(calls)" ] && echo 0 || echo 1)" \
  "Aufnahme läuft: Update verschoben (Exit 75), App nicht gestoppt" "rc=${RC} calls=$(calls)"

# 6) busy aus einer alten health.json, deren PID nicht (mehr) Flow ist → kein Warten
setup 6; health 1 $$ true; run_install 1
ok "$([ $RC -eq 0 ] && echo 0 || echo 1)" "veraltetes busy (PID gehört nicht zu Flow) blockiert nicht" "rc=${RC}"

# 7) erste Installation ohne vorige Fassung, kein Lebenszeichen → startet trotzdem wieder (nie tot liegen lassen)
setup 7; rm -rf "$APP_T"; run_install
ok "$([ $RC -eq 3 ] && [ -d "$APP_T" ] && [ "$(calls | sed 's/.*start/start/' | cut -d, -f1)" = "start 2.0.0" ] && echo 0 || echo 1)" \
  "ohne vorige Fassung: App bleibt da und wird neu gestartet" "rc=${RC} $(calls)"

# 8) update.sh --rollback: aktive ↔ vorige tauschen, zweimal = wieder vorwärts
setup 8; run_install 1
roll() {
  (
    APP="$APP_T"; DATA="$D/data"; BUNDLE_ID="test.rollback"; PLIST="/dev/null"; APP_NAME="Flow"
    # shellcheck source=/dev/null
    source "$SRC/scripts/install_lib.sh"
    inst_stop_app() { echo stop >> "$D/calls"; }
    inst_start_app() { echo "start $(ver "$APP")" >> "$D/calls"; }
    inst_rollback_manual
  ) >> "$D/out" 2>&1
}
set +e; roll; r1=$?; a1="$(ver "$APP_T")/$(ver "$APP_T.previous")"; roll; r2=$?; a2="$(ver "$APP_T")/$(ver "$APP_T.previous")"; set -e
ok "$([ $r1 -eq 0 ] && [ "$a1" = "1.0.0/2.0.0" ] && [ $r2 -eq 0 ] && [ "$a2" = "2.0.0/1.0.0" ] && echo 0 || echo 1)" \
  "--rollback tauscht aktiv ↔ vorige (zweimal = wieder vorwärts)" "${a1} → ${a2}"
rm -rf "$APP_T.previous"; set +e; roll; r3=$?; set -e
ok "$([ $r3 -eq 1 ] && [ "$(ver "$APP_T")" = 2.0.0 ] && echo 0 || echo 1)" "--rollback ohne vorige Fassung: Fehler, App unverändert" "rc=${r3}"

echo "Rückweg: ${PASS}/$((PASS + FAIL)) ok"
[ $FAIL -eq 0 ]
