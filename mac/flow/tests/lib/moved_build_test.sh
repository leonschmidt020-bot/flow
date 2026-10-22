#!/bin/bash
# Prüft inst_heal_moved_build (scripts/install_lib.sh): umgezogenes Projekt → alter .build beiseite, sonst unberührt
set -u
HERE="$(cd "$(dirname "$0")/../.." && pwd)"
source "$HERE/scripts/install_lib.sh"
T="$(mktemp -d)"; ok=0; bad=0
check() { if [ "$1" = 0 ]; then ok=$((ok+1)); echo "  ok     $2"; else bad=$((bad+1)); echo "  FEHLER $2"; fi; }
mk() { mkdir -p "$1/.build/artifacts"; printf '{\n  "object" : { "artifacts" : [ { "path" : "%s/.build/artifacts/fluidaudio/X.xcframework" } ] }\n}\n' "$2" > "$1/.build/workspace-state.json"; }
# 1) Alles am richtigen Ort → nichts passiert
P="$T/projekt"; mk "$P" "$P"
out="$(HOME="$T/home" inst_heal_moved_build "$P" 2>/dev/null)"
check "$([ -z "$out" ] && [ -f "$P/.build/workspace-state.json" ] && echo 0 || echo 1)" "richtiger Ort: .build bleibt"
# 2) Alter Ort mit Leerzeichen/Gedankenstrich (iCloud) → beiseite, in den Papierkorb
Q="$T/neu"; mk "$Q" "/Users/x/Documents/Dokumente – MacBook Air von X/flow"; mkdir -p "$T/home/.Trash"
out="$(HOME="$T/home" inst_heal_moved_build "$Q" 2>/dev/null)"
check "$([ "$out" = "/Users/x/Documents/Dokumente – MacBook Air von X/flow" ] && echo 0 || echo 1)" "alter Ort erkannt ($out)"
check "$([ ! -e "$Q/.build" ] && ls "$T/home/.Trash" | grep -q flow-build-alt && echo 0 || echo 1)" "alter .build liegt im Papierkorb"
# 3) .build als Verknüpfung (kommt vor) → Ziel beiseite, Verknüpfung bleibt gültig
R="$T/link"; C="$T/cache/.build"; mkdir -p "$R" "$(dirname "$C")"; mk "$T/cache" "/alt/ort/flow"; mv "$T/cache/.build" "$C" 2>/dev/null; ln -s "$C" "$R/.build"
out="$(HOME="$T/kein-home" inst_heal_moved_build "$R" 2>/dev/null)"
check "$([ "$out" = "/alt/ort/flow" ] && [ -L "$R/.build" ] && [ -d "$C" ] && [ ! -f "$C/workspace-state.json" ] && ls -d "$C".alt-* >/dev/null 2>&1 && echo 0 || echo 1)" "Verknüpfung: Ziel umbenannt (kein Papierkorb), Verknüpfung gültig"
rm -rf "$T"
echo "Bauordner-Umzug: $ok/$((ok+bad)) ok"
[ $bad -eq 0 ]
