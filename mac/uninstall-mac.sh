#!/bin/bash
# Flow + ClipVault vom Mac entfernen.
#   bash uninstall-mac.sh            Apps + LaunchAgents + Kommandozeile entfernen, DEINE DATEN BLEIBEN
#   bash uninstall-mac.sh --purge    zusätzlich ~/.config/flow und ~/.config/flow-clipvault löschen (fragt nach)
# Fasst nur Flow-eigene Pfade an (app.flowdictation.*, ~/Applications/Flow.app, ~/.config/flow*).
set -uo pipefail
PURGE=0; [ "${1:-}" = "--purge" ] && PURGE=1
U="gui/$(id -u)"

for label in app.flowdictation.flow app.flowdictation.clipvault; do
  launchctl bootout "$U/$label" 2>/dev/null || true
  rm -f "$HOME/Library/LaunchAgents/$label.plist"
done
pkill -f "^$HOME/Applications/Flow\.app/Contents/MacOS/" 2>/dev/null || true
pkill -f "^$HOME/\.config/flow-clipvault/clipvault( |\$)" 2>/dev/null || true
pkill -f "whisper-server .*--request-path /flow-[0-9a-f]{8}-" 2>/dev/null || true

for p in "$HOME/Applications/Flow.app" "$HOME/Applications/Flow.app.previous" "$HOME/Applications/Flow.app.failed" \
         "$HOME/Applications/.Flow.staging"; do
  [ -e "$p" ] && rm -rf "$p"
done
[ -L "$HOME/.local/bin/flow" ] && rm -f "$HOME/.local/bin/flow"
echo "✓ Flow und ClipVault entfernt (Apps, Autostart, Kommandozeile)."

if [ $PURGE -eq 1 ]; then
  read -r -p "Wirklich ALLE Flow-Daten löschen (Wörterbuch, Stimme, Meetings, Zwischenablage-Verlauf)? [j/N] " a < /dev/tty
  if [ "$a" = "j" ] || [ "$a" = "J" ]; then
    rm -rf "$HOME/.config/flow" "$HOME/.config/flow-clipvault"
    # Schlüsselbund-Einträge des geteilten Tresors
    for acct in vault-key vault-token init-secret; do
      security delete-generic-password -s app.flowdictation.clipvault.sync -a "$acct" >/dev/null 2>&1 || true
    done
    echo "✓ Daten gelöscht."
  fi
else
  echo "  Deine Daten liegen weiter in ~/.config/flow und ~/.config/flow-clipvault (löschen: --purge)."
fi
cat <<TXT
  Noch von Hand (optional):
    • Quellcode: rm -rf "$HOME/Library/Application Support/Flow"
    • Sprachmodelle (~0,6 GB, evtl. von anderen Apps mitbenutzt): ~/Library/Application Support/FluidAudio
    • Signatur-Zertifikat „Flow Local Signing“: Schlüsselbundverwaltung → Anmeldung → Meine Zertifikate
    • Freigaben: Systemeinstellungen → Datenschutz & Sicherheit → Flow / clipvault entfernen
TXT
