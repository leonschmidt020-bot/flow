#!/bin/bash
# Flow – sicherer Installationsweg mit Rückweg (wird von build.sh und update.sh mit `source` geladen).
# Getestet ohne echte App: tests/lib/rollback_test.sh
#
#   1. Das neue Bundle liegt fertig signiert im Staging-Ordner → inst_verify: codesign --verify --deep --strict
#      und die Binary antwortet im CLI-Modus (--version, nie App-Modus) mit der erwarteten Version.
#   2. Erst dann: warten, bis keine Aufnahme läuft (health.json › busy) → App stoppen → die bisherige Fassung
#      wird „Flow.app.previous“, die neue rückt per mv (gleiches Volume = atomar) an ihren Platz → starten.
#   3. Health-Gate: health.json muss binnen 120 s ein gesundes Lebenszeichen GENAU dieser Build-Nummer zeigen
#      (Heartbeat vom Main-Thread, mind. 15 s am Stück gelaufen). Sonst automatisch zurück auf die vorige Fassung,
#      Zeile ins flow.log, Meldung „Update zurückgenommen“.
#   Jeder Fehler NACH dem Stoppen – auch ein Abbruch durch `set -e` – stellt über inst_on_exit (EXIT-Trap) die vorige
#   Fassung wieder her und startet sie. Die App bleibt nie tot liegen, der LaunchAgent nie entladen.
#
# Erwartet: APP (Ziel-Bundle), DATA (Datenordner), BUNDLE_ID, PLIST, APP_NAME.
# Hooks (Tests überschreiben sie nach dem source): inst_stop_app, inst_start_app, inst_notify.
# INST_TEST=1: Stoppen/Starten/Melden sind No-ops (Release-Tor, FLOW_TEST_APP_DIR).
# Zeiten: FLOW_HEALTH_TIMEOUT (120 s), FLOW_HEALTH_MINUP (15 s), FLOW_BUSY_WAIT (600 s).
# Rückgabe inst_install_staged: 0 installiert · 1 nichts angefasst · 3 zurückgenommen · 75 verschoben (Aufnahme läuft)

INST_PHASE=""     # "" nichts angefasst · stopped · moved · swapped · done · restored
INST_REASON=""
APP_NAME="${APP_NAME:-Flow}"

inst_now() { date +%s; }
inst_timeout() { local s="$1"; shift; perl -e 'alarm shift @ARGV; exec @ARGV or exit 127' "$s" "$@"; }
inst_plist_get() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null || true; }
inst_json_get() { plutil -extract "$2" raw -o - "$1" 2>/dev/null || true; }

# Zeile aufs Terminal (bzw. ins update.log) und ins flow.log der App
inst_log_line() {
  echo "$1"
  mkdir -p "$DATA" 2>/dev/null || true
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "$DATA/flow.log" 2>/dev/null || true
}

# --- Hooks (Standard = echter LaunchAgent) ---
inst_stop_app() {
  [ -n "${INST_TEST:-}" ] && return 0
  launchctl bootout "gui/$(id -u)/$BUNDLE_ID" 2>/dev/null || true
  # NUR genau diese App (~/Applications/Flow.app) beenden – nie andere Diktier-Apps mit ähnlichem Namen
  pkill -f "^$HOME/Applications/$APP_NAME\.app/Contents/MacOS/" 2>/dev/null || true
  # nur Flows eigener whisper-server (geheimer Pfad /flow-<uuid>, siehe WhisperEngine.swift)
  pkill -f "whisper-server .*--request-path /flow-[0-9a-f]{8}-" 2>/dev/null || true
  sleep 0.5
}
inst_start_app() {
  [ -n "${INST_TEST:-}" ] && return 0
  local i
  for i in 1 2 3 4 5; do
    launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null && return 0
    # schon geladen (z. B. zweiter Versuch) → nur anstoßen
    if launchctl print "gui/$(id -u)/$BUNDLE_ID" >/dev/null 2>&1; then
      launchctl kickstart "gui/$(id -u)/$BUNDLE_ID" 2>/dev/null || true; return 0
    fi
    sleep 1
  done
  echo "✗ launchctl bootstrap klappt nicht (${PLIST})"
  return 1
}
# Meldung für den Fall, dass die wiederhergestellte App sie nicht selbst zeigen kann (Stände vor 1.7.10 kennen
# update-failed.json nicht). Neuere Stände zeigen „Update zurückgenommen“ selbst als Karte an der Pille.
inst_notify() {
  [ -n "${INST_TEST:-}" ] && return 0
  [ -n "$(inst_plist_get "$APP" FlowHealthVersion)" ] && return 0
  local t m
  t="$(printf '%s' "$1" | tr -d '"\\')"; m="$(printf '%s' "$2" | tr -d '"\\')"
  osascript -e "display notification \"${m}\" with title \"${t}\"" >/dev/null 2>&1 || true
}

# --- 1. Staging prüfen ---
inst_verify() {   # $1 = Bundle, $2 = erwartete Version
  local h out
  if ! codesign --verify --deep --strict "$1" >/dev/null 2>&1; then
    INST_REASON="Signatur des neuen Bundles ungültig (codesign --verify --deep --strict)"; return 1
  fi
  h="$(mktemp -d "${TMPDIR:-/tmp}/flow-verify.XXXXXX")"
  out="$(FLOW_HOME="$h" inst_timeout 20 "$1/Contents/MacOS/$APP_NAME" --version 2>&1 || true)"
  rm -rf "$h"
  case "$out" in *"$APP_NAME $2 "*|*"$APP_NAME $2") return 0 ;; esac
  INST_REASON="neue Binary antwortet nicht mit Version $2 auf --version: $(printf '%s' "$out" | head -1 | cut -c1-80)"
  return 1
}

# --- 2. Nie mitten in einer Aufnahme ---
inst_app_busy() {   # 0 = die laufende App meldet Aufnahme/Diktat/Meeting
  local h="$DATA/health.json" pid
  [ -f "$h" ] || return 1
  [ "$(inst_json_get "$h" busy)" = "true" ] || return 1
  pid="$(inst_json_get "$h" pid)"
  # nur, wenn der Prozess wirklich noch Flow ist (alte health.json + wiederverwendete PID ≠ Aufnahme)
  [ -n "$pid" ] && ps -p "$pid" -o command= 2>/dev/null | grep -q "$APP_NAME"
}
inst_wait_idle() {
  local limit="${FLOW_BUSY_WAIT:-600}" t0
  [ -n "${INST_TEST:-}" ] && return 0          # Testmodus stoppt nichts – eine laufende App ist egal
  inst_app_busy || return 0
  t0="$(inst_now)"
  echo "» Flow nimmt gerade auf – das Update wartet, bis Diktat/Meeting fertig ist …"
  while inst_app_busy; do
    if [ $(( $(inst_now) - t0 )) -ge "$limit" ]; then INST_REASON="Aufnahme läuft noch – Update verschoben"; return 1; fi
    sleep 2
  done
  return 0
}

# --- Tausch per mv (nie über ein Bundle kopieren, nie in einen vorhandenen Ordner hinein) ---
inst_swap() {   # $1 = Staging-Bundle
  rm -rf "$APP.previous"                       # die vorvorige Fassung
  [ ! -e "$APP.previous" ] || return 1
  if [ -d "$APP" ]; then mv "$APP" "$APP.previous" || return 1; fi
  INST_PHASE=moved
  [ ! -e "$APP" ] || return 1
  mv "$1" "$APP" || return 1
  INST_PHASE=swapped
}

# Vorige Fassung zurück an ihren Platz und starten. Die gescheiterte bleibt als „.failed“ zum Nachsehen liegen.
inst_restore() {   # $1 = Grund
  local phase="$INST_PHASE"
  INST_PHASE=restoring
  echo "✗ $1 – stelle die vorige Version wieder her"
  inst_stop_app
  if { [ "$phase" = moved ] || [ "$phase" = swapped ]; } && [ -d "$APP.previous" ]; then
    if [ -d "$APP" ]; then rm -rf "$APP.failed"; mv "$APP" "$APP.failed" || true; fi
    [ -e "$APP" ] || mv "$APP.previous" "$APP" || true
  fi
  inst_start_app || true
  INST_PHASE=restored
  inst_log_line "Update zurückgenommen: $1 – läuft wieder $(inst_plist_get "$APP" CFBundleShortVersionString) ($(inst_plist_get "$APP" CFBundleVersion))"
}

# EXIT-Trap: Abbruch nach dem Stoppen (set -e, Signal) → vorige Fassung zurück
inst_on_exit() {
  case "$INST_PHASE" in
    stopped|moved|swapped) inst_restore "${INST_REASON:-Abbruch beim Installieren}" ;;
  esac
}

# --- 3. Health-Gate ---
inst_health_ok() {   # $1 = Build-Nummer, $2 = Zeitpunkt des Tauschs → 0 = gesund
  local h="$DATA/health.json" pid st hb now
  [ -f "$h" ] || return 1
  [ "$(inst_json_get "$h" build)" = "$1" ] || return 1
  pid="$(inst_json_get "$h" pid)"
  { [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; } || return 1
  st="$(inst_json_get "$h" startedAt)"; st="${st%%.*}"
  hb="$(inst_json_get "$h" lastHeartbeat)"; hb="${hb%%.*}"
  [ -n "$st" ] && [ -n "$hb" ] || return 1
  now="$(inst_now)"
  [ "$st" -ge $(( $2 - 5 )) ] && [ $(( now - st )) -ge "${FLOW_HEALTH_MINUP:-15}" ] && [ $(( now - hb )) -le 45 ]
}
inst_wait_healthy() {   # $1 = Build-Nummer, $2 = Zeitpunkt des Tauschs
  local limit="${FLOW_HEALTH_TIMEOUT:-120}" t0
  t0="$(inst_now)"
  echo "» Warte auf das Lebenszeichen der neuen Version (höchstens ${limit} s) …"
  while [ $(( $(inst_now) - t0 )) -lt "$limit" ]; do
    if inst_health_ok "$1" "$2"; then echo "✓ Neue Version läuft stabil ($(( $(inst_now) - t0 )) s bis zum Lebenszeichen)"; return 0; fi
    sleep 2
  done
  return 1
}
# Stände ohne health.json (update.sh --pin auf eine Version vor 1.7.10): läuft der Prozess nach MINUP noch?
inst_wait_running() {
  sleep "${FLOW_HEALTH_MINUP:-15}"
  pgrep -f "$APP/Contents/MacOS/" >/dev/null 2>&1
}

# --- Ablauf ---
inst_install_staged() {   # $1 = Staging-Bundle, $2 = Version, $3 = Build-Nummer
  local since
  if ! inst_verify "$1" "$2"; then echo "✗ ${INST_REASON} – die installierte App bleibt unverändert"; return 1; fi
  echo "✓ Staging geprüft (codesign --deep --strict, --version = $2)"
  if ! inst_wait_idle; then echo "» ${INST_REASON}"; return 75; fi
  inst_stop_app
  INST_PHASE=stopped
  since="$(inst_now)"
  if ! inst_swap "$1"; then
    INST_REASON="Tausch der Bundles fehlgeschlagen"; inst_restore "$INST_REASON"; return 3
  fi
  if ! inst_start_app; then
    INST_REASON="Start von Flow $2 fehlgeschlagen (launchctl)"; inst_restore "$INST_REASON"
    inst_notify "Update zurückgenommen" "Flow $2 startete nicht – die vorige Version läuft wieder."; return 3
  fi
  [ -n "${INST_TEST:-}" ] && { INST_PHASE=done; return 0; }
  if [ -n "$(inst_plist_get "$APP" FlowHealthVersion)" ]; then
    if ! inst_wait_healthy "$3" "$since"; then
      INST_REASON="Flow $2 lief nicht stabil (kein Lebenszeichen binnen ${FLOW_HEALTH_TIMEOUT:-120} s, Build $3)"
      inst_restore "$INST_REASON"
      inst_notify "Update zurückgenommen" "Flow $2 lief nicht stabil – die vorige Version läuft wieder."
      return 3
    fi
  elif ! inst_wait_running; then
    INST_REASON="Flow $2 läuft nach dem Start nicht"; inst_restore "$INST_REASON"
    inst_notify "Update zurückgenommen" "Flow $2 startete nicht – die vorige Version läuft wieder."; return 3
  fi
  INST_PHASE=done
  return 0
}

# update.sh --rollback: aktive und vorige Fassung tauschen (ein zweites --rollback tauscht wieder zurück)
inst_rollback_manual() {
  [ -d "$APP.previous" ] || { echo "✗ Keine vorige Version vorhanden (${APP}.previous fehlt)"; return 1; }
  if ! inst_wait_idle; then echo "» ${INST_REASON}"; return 75; fi
  local from to
  from="$(inst_plist_get "$APP" CFBundleShortVersionString)"; to="$(inst_plist_get "$APP.previous" CFBundleShortVersionString)"
  inst_stop_app
  rm -rf "$APP.rollback-tmp"
  if [ -d "$APP" ]; then mv "$APP" "$APP.rollback-tmp" || { inst_start_app; return 1; }; fi
  if ! mv "$APP.previous" "$APP"; then mv "$APP.rollback-tmp" "$APP"; inst_start_app; return 1; fi
  [ -d "$APP.rollback-tmp" ] && mv "$APP.rollback-tmp" "$APP.previous"
  inst_start_app || true
  inst_log_line "Update von Hand zurückgenommen: ${from} → ${to} (./update.sh --rollback)"
  return 0
}
