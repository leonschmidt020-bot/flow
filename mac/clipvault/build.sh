#!/bin/bash
# ClipVault (Zwischenablage-Verlauf, ⌘⇧V) bauen und sicher installieren.
#   ./build.sh           bauen + Test (nichts installieren)
#   ./build.sh install   bauen, NUR diese ClipVault-Installation stoppen, Binary tauschen, signieren, neu starten
#   ./build.sh uninstall LaunchAgent entfernen und stoppen (Daten in ~/.config/flow-clipvault bleiben)
# Reihenfolge ist wichtig: NIE über die laufende Binary kopieren (macOS beendet sie sonst mit
# OS_REASON_CODESIGNING) -> erst stoppen, dann rm, dann mv, dann codesign.
# Signatur: dieselbe stabile Identität wie Flow (../flow/scripts/signing.sh, „Flow Local Signing“), sonst ad-hoc mit Warnung.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABEL="app.flowdictation.clipvault"
DATA="$HOME/.config/flow-clipvault"
DEST="$DATA/clipvault"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

stop_ours() {
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  # nur genau diese Binary (voller Pfad) – nie eine andere ClipVault-Kopie auf demselben Mac
  pkill -f "^$DEST( |\$)" 2>/dev/null || true
  sleep 1
}

if [ "${1:-}" = "uninstall" ]; then
  stop_ours; rm -f "$PLIST"; echo "✓ ClipVault gestoppt, LaunchAgent entfernt (Daten bleiben in $DATA)"; exit 0
fi

TMP="$(mktemp -t flow-clipvault)" && rm -f "$TMP"
swiftc -O "$DIR"/*.swift -o "$TMP"
echo "gebaut: $TMP"
[ "${1:-}" = "install" ] || { rm -f "$TMP"; echo "(nur Test-Build — mit 'install' wird installiert)"; exit 0; }

# Signatur-Identität wie bei Flow (stabil = Bedienungshilfen-Freigabe bleibt über Updates)
SIGN="-"
if [ -f "$DIR/../flow/scripts/signing.sh" ]; then
  # shellcheck disable=SC1091
  source "$DIR/../flow/scripts/signing.sh"
  if choose_sign_identity "$DEST"; then SIGN="$SIGN_IDENTITY"; fi
fi
[ "$SIGN" = "-" ] && { declare -F warn_adhoc >/dev/null && warn_adhoc "ClipVault" || echo "⚠︎  ClipVault wird ad-hoc signiert"; }

stop_ours
mkdir -p "$DATA"; chmod 700 "$DATA"
rm -f "$DEST"
mv "$TMP" "$DEST"
declare -F sign_keychain_begin >/dev/null && sign_keychain_begin
codesign -f -s "$SIGN" --identifier "$LABEL" "$DEST" 2>/dev/null || codesign -f -s - --identifier "$LABEL" "$DEST"
declare -F sign_keychain_end >/dev/null && sign_keychain_end
chmod 700 "$DEST"
cp "$DIR/assets/"*.png "$DATA/" 2>/dev/null || true

mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$DEST</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>StandardErrorPath</key><string>$DATA/stderr.log</string>
  <key>ProcessType</key><string>Interactive</string>
</dict></plist>
PL
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "✓ ClipVault läuft ($LABEL) – ⌘⇧V öffnet den Verlauf. Selbsttest: $DEST doctor"
