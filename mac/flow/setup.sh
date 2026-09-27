#!/bin/bash
# ============================================================
#  Flow – Einrichtung auf einem Mac (Diktat + optional ClipVault)
#  Idempotent: beliebig oft ausführbar, erledigt nur, was fehlt.
#
#   ./setup.sh                 einrichten (fragt nur, wo es nicht anders geht)
#   ./setup.sh --check         nur prüfen, NICHTS ändern (Trockenlauf)
#   ./setup.sh --with-whisper  zusätzlich Whisper (Homebrew whisper-cpp + Modell ~550 MB) – optional, genauer bei Namen
#   ./setup.sh --no-clipvault  ClipVault (Zwischenablage-Verlauf) nicht installieren
#   ./setup.sh --no-panes      Systemeinstellungen am Ende nicht öffnen
#
#  Kein sudo. Ausnahme nur mit --with-whisper: der offizielle Homebrew-Installer fragt selbst nach dem Passwort,
#  falls Homebrew noch fehlt.
# ============================================================
set -uo pipefail
cd "$(dirname "$0")"
SRC="$(pwd)"

CHECK=0; PANES=1; WHISPER=0; CLIPVAULT=1
for a in "$@"; do
  case "$a" in
    --check|--dry-run) CHECK=1 ;;
    --no-panes) PANES=0 ;;
    --with-whisper) WHISPER=1 ;;
    --no-clipvault) CLIPVAULT=0 ;;
    -h|--help) sed -n 2,14p "$0"; exit 0 ;;
    *) echo "Unbekannte Option: $a"; exit 2 ;;
  esac
done

if [ -t 1 ]; then GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; DIM='\033[2m'; NC='\033[0m'
else GREEN=''; YELLOW=''; RED=''; DIM=''; NC=''; fi
ok()   { echo -e "  ${GREEN}✓${NC} $1"; CHECKLIST+=("✓ $1"); }
todo() { echo -e "  ${YELLOW}○${NC} $1"; CHECKLIST+=("○ $1"); }
bad()  { echo -e "  ${RED}✗${NC} $1"; CHECKLIST+=("✗ $1"); FAILED=1; }
info() { echo -e "  ${DIM}$1${NC}"; }
step() { echo; echo -e "${YELLOW}▸ $1${NC}"; }
CHECKLIST=(); FAILED=0

BUNDLE_ID="${BUNDLE_ID:-app.flowdictation.flow}"
APP="$HOME/Applications/Flow.app"
DATA="${FLOW_HOME:-$HOME/.config/flow}"
MODEL_DIR="$HOME/.cache/whisper-cpp/models"
MODEL_FILE="ggml-large-v3-turbo-q5_0.bin"
MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$MODEL_FILE"
MODEL_SHA256="394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2"
MODEL_SIZE=574041195

echo "============================================================"
echo "  Flow – Einrichtung$([ $CHECK -eq 1 ] && echo '  (NUR PRÜFEN)')"
echo "============================================================"

# ------------------------------------------------------------
step "1/8  Mac & Werkzeuge"
if [ "$(uname -m)" = "arm64" ]; then ok "Apple Silicon"; else bad "Kein Apple-Silicon-Mac – die Sprachmodelle (Parakeet/CoreML) brauchen M1 oder neuer"; fi
OSV="$(sw_vers -productVersion)"
if [ "${OSV%%.*}" -ge 26 ]; then ok "macOS $OSV"; else bad "macOS $OSV – Flow braucht macOS 26 (Tahoe) oder neuer (Package.swift: .macOS(\"26.0\"))"; fi
if xcode-select -p >/dev/null 2>&1 && command -v swift >/dev/null 2>&1; then
  SV="$(swift --version 2>/dev/null | grep -oE 'Swift version [0-9.]+' | head -1)"
  SDK="$(xcrun --show-sdk-version 2>/dev/null || echo ?)"
  if [ "${SDK%%.*}" -ge 26 ] 2>/dev/null; then ok "Xcode-Werkzeuge ($SV, macOS-SDK $SDK)"
  else bad "macOS-SDK $SDK zu alt – Softwareupdate → Command Line Tools für macOS 26 installieren"; fi
else
  bad "Xcode Command Line Tools fehlen"
  if [ $CHECK -eq 0 ]; then
    xcode-select --install 2>/dev/null || true
    echo "    → Es öffnet sich ein Fenster „Installieren“. Danach ./setup.sh noch einmal starten."
    exit 1
  fi
fi
FREE_GB="$(df -g "$HOME" | awk 'NR==2 {print $4}')"
if [ "${FREE_GB:-0}" -ge 5 ]; then ok "Freier Speicher: ${FREE_GB} GB (gebraucht: ~2 GB Build + ~0,6 GB Modelle, mit Whisper +0,6 GB)"
else bad "Nur ${FREE_GB} GB frei – bitte mindestens 5 GB freimachen"; fi

# ------------------------------------------------------------
step "2/8  Whisper (optional, --with-whisper)"
HAVE_WHISPER=0
if [ -x /opt/homebrew/bin/whisper-server ] || [ -x /usr/local/bin/whisper-server ]; then HAVE_WHISPER=1; fi
model_ok() { [ -f "$1" ] && [ "$(shasum -a 256 "$1" | awk '{print $1}')" = "$MODEL_SHA256" ]; }
if [ $WHISPER -eq 0 ]; then
  if [ $HAVE_WHISPER -eq 1 ] && [ -f "$MODEL_DIR/$MODEL_FILE" ]; then ok "Whisper schon vorhanden – Flow nutzt es (genauer bei Namen)"
  else info "übersprungen – Flow diktiert mit Parakeet (läuft ohne Homebrew). Später: ./setup.sh --with-whisper"; fi
else
  if command -v brew >/dev/null 2>&1 || [ -x /opt/homebrew/bin/brew ]; then
    eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null || true)"
    ok "Homebrew ($(brew --version | head -1))"
  elif [ $CHECK -eq 1 ]; then todo "Homebrew fehlt (würde den offiziellen Installer starten)"
  else
    echo "  Homebrew fehlt – starte den offiziellen Installer (fragt einmal nach dem Mac-Passwort) …"
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || { bad "Homebrew-Installation fehlgeschlagen"; }
    eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null || true)"
  fi
  if [ $HAVE_WHISPER -eq 1 ]; then ok "whisper-server vorhanden"
  elif [ $CHECK -eq 1 ]; then todo "whisper-server fehlt (würde: brew install whisper-cpp)"
  elif command -v brew >/dev/null 2>&1; then brew install whisper-cpp && ok "whisper-cpp installiert" || bad "brew install whisper-cpp fehlgeschlagen"; fi
  if [ -f "$MODEL_DIR/$MODEL_FILE" ] && model_ok "$MODEL_DIR/$MODEL_FILE"; then ok "Whisper-Modell $MODEL_FILE (SHA-256 stimmt)"
  elif [ $CHECK -eq 1 ]; then todo "Whisper-Modell fehlt (würde ~550 MB laden + SHA-256 prüfen)"
  else
    mkdir -p "$MODEL_DIR"
    [ -f "$MODEL_DIR/$MODEL_FILE" ] && mv "$MODEL_DIR/$MODEL_FILE" "$MODEL_DIR/$MODEL_FILE.kaputt"
    [ -f "$MODEL_DIR/$MODEL_FILE.part" ] && [ "$(stat -f %z "$MODEL_DIR/$MODEL_FILE.part")" -ge "$MODEL_SIZE" ] && rm -f "$MODEL_DIR/$MODEL_FILE.part"
    echo "  lade $MODEL_URL"
    if curl -L --fail --retry 3 -C - -o "$MODEL_DIR/$MODEL_FILE.part" "$MODEL_URL" \
       && [ "$(stat -f %z "$MODEL_DIR/$MODEL_FILE.part")" = "$MODEL_SIZE" ] && model_ok "$MODEL_DIR/$MODEL_FILE.part"; then
      mv "$MODEL_DIR/$MODEL_FILE.part" "$MODEL_DIR/$MODEL_FILE"; ok "Whisper-Modell geladen, SHA-256 stimmt"
    else bad "Modell-Download/Prüfsumme fehlgeschlagen (Teil-Datei bleibt liegen, erneut ./setup.sh --with-whisper setzt fort)"; fi
  fi
fi

# ------------------------------------------------------------
step "3/8  Claude-CLI (optional: Zusammenfassungen, Fragen ans Meeting, Command Mode)"
CLAUDE=""
for p in "$HOME/.local/bin/claude" "$HOME/.claude/local/claude" /opt/homebrew/bin/claude /usr/local/bin/claude; do [ -x "$p" ] && { CLAUDE="$p"; break; }; done
if [ -n "$CLAUDE" ]; then ok "Claude-CLI gefunden: $CLAUDE (in den Einstellungen einschaltbar, Standard aus)"
else info "nicht gefunden – optional. Diktat, Transkripte, Wörterbuch und ClipVault gehen ohne. Die Funktionen bleiben aus."; fi

# ------------------------------------------------------------
step "4/8  Signatur (damit macOS die Freigaben über Updates behält)"
source "$SRC/scripts/signing.sh"
if [ $CHECK -eq 1 ]; then
  if choose_sign_identity "$APP" nocreate; then ok "Signatur: $SIGN_LABEL"; else todo "Signatur: $SIGN_LABEL"; fi
elif choose_sign_identity "$APP"; then ok "Signatur: $SIGN_LABEL"
else todo "Kein lokales Zertifikat anlegbar – es wird ad-hoc signiert (Freigaben nach jedem Update neu erteilen)"; fi
export FLOW_SIGN_IDENTITY="${FLOW_SIGN_IDENTITY:-${SIGN_IDENTITY:--}}"

# ------------------------------------------------------------
step "5/8  Bauen"
if [ $CHECK -eq 1 ]; then info "(Trockenlauf) würde: swift build -c release (~3–5 Min. beim ersten Mal)"
else
  echo "  swift build -c release (beim ersten Mal ~3–5 Minuten, lädt das Paket FluidAudio von GitHub) …"
  if swift build -c release > .build-log.txt 2>&1; then ok "Kompiliert"; else bad "Kompilieren fehlgeschlagen – siehe $SRC/.build-log.txt"; exit 1; fi
fi

step "6/8  Sprachmodelle vorladen (FluidAudio: Parakeet, Stimmprofil, Sprechertrennung ~0,6 GB von Hugging Face)"
FA="$HOME/Library/Application Support/FluidAudio/Models"
have() { ls "$FA/$1" 2>/dev/null | grep -q '\.mlmodelc$'; }
if have parakeet-ultra && have campplus && have speaker-diarization; then ok "FluidAudio-Modelle vorhanden ($FA)"
elif [ $CHECK -eq 1 ]; then todo "FluidAudio-Modelle fehlen (würde: Flow --prewarm-models)"
else
  echo "  lade + kompiliere einmal (je nach Netz 1–5 Minuten) …"
  if FLOW_HOME="$DATA" .build/release/Flow --prewarm-models; then ok "FluidAudio-Modelle bereit"
  else todo "Vorladen fehlgeschlagen – macht die App beim ersten Start selbst"; fi
fi

step "7/8  Installieren + starten"
if [ $CHECK -eq 1 ]; then
  if [ -d "$APP" ]; then ok "Installiert: $APP ($(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist" 2>/dev/null || echo '?'))"
  else todo "App noch nicht installiert (würde: ./build.sh)"; fi
else
  if ./build.sh; then ok "Flow installiert + gestartet (LaunchAgent $BUNDLE_ID)"; else bad "./build.sh fehlgeschlagen"; fi
fi
if [ $CLIPVAULT -eq 1 ] && [ -x ../clipvault/build.sh ]; then
  if [ $CHECK -eq 1 ]; then
    if [ -x "$HOME/.config/flow-clipvault/clipvault" ]; then ok "ClipVault installiert"; else todo "ClipVault noch nicht installiert (würde: ../clipvault/build.sh install)"; fi
  elif (cd ../clipvault && ./build.sh install); then ok "ClipVault installiert + gestartet (⌘⇧V)"
  else bad "ClipVault-Installation fehlgeschlagen (../clipvault/build.sh install)"; fi
fi

# ------------------------------------------------------------
step "8/8  fn-Taste, Kommandozeile, Freigaben"
FN="$(defaults read com.apple.HIToolbox AppleFnUsageType 2>/dev/null || echo unset)"
if [ "$FN" = "0" ]; then ok "fn-Taste steht auf „Nichts tun“"
elif [ $CHECK -eq 1 ]; then todo "fn-Taste = $FN (würde auf „Nichts tun“ stellen, damit fn nicht das Emoji-Fenster öffnet)"
else defaults write com.apple.HIToolbox AppleFnUsageType -int 0; killall TextInputSwitcher 2>/dev/null || true; ok "fn-Taste auf „Nichts tun“ gestellt"; fi
if [ -x "$DATA/bin/flow" ]; then
  if [ -e "$HOME/.local/bin/flow" ]; then ok "Kommandozeile: flow ($HOME/.local/bin/flow)"
  elif [ $CHECK -eq 1 ]; then todo "Verknüpfung ~/.local/bin/flow (würde anlegen)"
  else mkdir -p "$HOME/.local/bin"; ln -sf "$DATA/bin/flow" "$HOME/.local/bin/flow"; ok "Kommandozeile: ~/.local/bin/flow (flow status, flow open …)"; fi
else todo "Kommandozeile „flow“ kommt mit ./build.sh"; fi

STATUS_BIN=""; [ -x .build/release/Flow ] && STATUS_BIN=.build/release/Flow
[ -z "$STATUS_BIN" ] && [ -x "$APP/Contents/MacOS/Flow" ] && STATUS_BIN="$APP/Contents/MacOS/Flow"
# Trockenlauf: nie den echten Datenordner anlegen → Status gegen einen leeren Temp-Ordner
STATUS_HOME="$DATA"; [ $CHECK -eq 1 ] && [ ! -d "$DATA" ] && STATUS_HOME="$(mktemp -d "${TMPDIR:-/tmp}/flow-check.XXXXXX")"
[ -n "$STATUS_BIN" ] && FLOW_HOME="$STATUS_HOME" "$STATUS_BIN" --setup-status 2>/dev/null | sed 's/^/    /'
[ "$STATUS_HOME" != "$DATA" ] && rm -rf "$STATUS_HOME"
cat <<TXT
    Beim ersten Start öffnet Flow ein Willkommen mit Live-Häkchen. Dort bzw. hier:
      1. Mikrofon            → „Erlauben“ klicken, wenn macOS fragt
      2. Bedienungshilfen    → Flow in der Liste einschalten (Schalter blau)
      3. Eingabeüberwachung  → Flow einschalten; danach fn einmal drücken
      4. Bildschirm- & Systemaudioaufnahme (nur für Meetings) → beim ersten Meeting „Erlauben“
TXT
if [ $CHECK -eq 0 ] && [ $PANES -eq 1 ] && [ -t 0 ]; then
  for pane in Privacy_Microphone Privacy_Accessibility Privacy_ListenEvent; do
    read -r -p "    Enter = Systemeinstellungen „${pane#Privacy_}“ öffnen (s = überspringen): " ans
    [ "$ans" = "s" ] && continue
    open "x-apple.systempreferences:com.apple.preference.security?$pane"
  done
fi

# ------------------------------------------------------------
echo
echo "============================================================"
echo "  CHECKLISTE$([ $CHECK -eq 1 ] && echo ' (Trockenlauf – nichts geändert)')"
echo "============================================================"
for l in "${CHECKLIST[@]}"; do echo "  $l"; done
cat <<TXT

  Noch von Hand:
    □ Freigaben erteilen (siehe oben) – dann fn halten und sprechen
    □ Optional: im Hub → Training die eigene Stimme einlernen
    □ Optional: ClipVault mit einem Freund/Partner teilen – eigener Worker, siehe ../clipvault/sync-worker/README.md

  Deine Daten (privat, nur dieser Mac): $DATA
  Updates: roter Punkt an der Pille → „Installieren“ (oder ./update.sh)
TXT
exit $FAILED
