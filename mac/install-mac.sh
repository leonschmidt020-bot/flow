#!/bin/bash
# Flow für macOS – Installation mit einer Zeile:
#
#   curl -fsSL <raw-url>/mac/install-mac.sh | bash
#
# Prüft macOS-Version, Apple Silicon und die Xcode Command Line Tools, klont das Repo nach
#   ~/Library/Application Support/Flow/src     (bewusst NICHT ~/Documents – iCloud würde Build-Ordner synchronisieren)
# baut Flow + ClipVault und startet das Willkommen (Onboarding). Kein sudo.
#
# Umgebung (optional):
#   FLOW_REPO_URL      anderes Repo (Fork)          FLOW_CHANNEL   Branch (Standard: main)
#   FLOW_WITH_WHISPER=1  zusätzlich Whisper (Homebrew whisper-cpp + ~550 MB Modell)
#   FLOW_NO_CLIPVAULT=1  ClipVault nicht installieren
set -euo pipefail

# Gleicher Wert wie in mac/flow.conf (das Release-Tor prüft das)
FLOW_REPO_URL_DEFAULT="https://github.com/leonschmidt020-bot/flow.git"

main() {
  local repo="${FLOW_REPO_URL:-$FLOW_REPO_URL_DEFAULT}" channel="${FLOW_CHANNEL:-main}"
  local base="$HOME/Library/Application Support/Flow" src
  src="$base/src"

  echo "============================================================"
  echo "  Flow für macOS – Installation"
  echo "============================================================"

  # --- Voraussetzungen ---
  local osv; osv="$(sw_vers -productVersion)"
  if [ "${osv%%.*}" -lt 26 ]; then
    echo "✗ macOS ${osv}: Flow braucht macOS 26 (Tahoe) oder neuer."; exit 1
  fi
  if [ "$(uname -m)" != "arm64" ]; then
    echo "✗ Flow braucht einen Mac mit Apple Silicon (M1 oder neuer)."; exit 1
  fi
  if ! xcode-select -p >/dev/null 2>&1 || ! command -v swift >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
    echo "✗ Die Xcode Command Line Tools fehlen (Swift-Compiler + git, ~1–2 GB, kostenlos von Apple)."
    xcode-select --install 2>/dev/null || true
    echo "  → Es öffnet sich ein Fenster „Installieren“. Danach diese Zeile noch einmal ausführen."
    exit 1
  fi
  local sdk; sdk="$(xcrun --show-sdk-version 2>/dev/null || echo 0)"
  if [ "${sdk%%.*}" -lt 26 ] 2>/dev/null; then
    echo "✗ macOS-SDK ${sdk} ist zu alt – Softwareupdate → „Command Line Tools für Xcode“ (macOS 26) installieren."; exit 1
  fi
  local free; free="$(df -g "$HOME" | awk 'NR==2 {print $4}')"
  if [ "${free:-0}" -lt 5 ]; then echo "✗ Nur ${free} GB frei – bitte mindestens 5 GB freimachen."; exit 1; fi
  echo "✓ macOS ${osv}, Apple Silicon, Xcode-Werkzeuge (SDK ${sdk}), ${free} GB frei"

  # --- Quellcode holen / aktualisieren ---
  mkdir -p "$base"
  if [ -d "$src/.git" ]; then
    echo "» Quellcode schon da – aktualisiere ($src)"
    git -C "$src" fetch --quiet origin
    git -C "$src" checkout --quiet "$channel"
    git -C "$src" pull --ff-only --quiet || { echo "✗ git pull nicht möglich (lokale Änderungen in $src?)"; exit 1; }
  else
    echo "» Klone ${repo} (Branch ${channel}) nach ${src}"
    git clone --quiet --branch "$channel" "$repo" "$src"
  fi
  # Nur macOS-Teile auschecken spart Platz, wenn git es kann (Windows-Ordner wird nicht gebraucht)
  git -C "$src" sparse-checkout set mac 2>/dev/null || true

  # --- Einrichten: bauen, Modelle, installieren, starten (Onboarding öffnet sich beim ersten Start) ---
  local args=()
  [ "${FLOW_WITH_WHISPER:-0}" = "1" ] && args+=(--with-whisper)
  [ "${FLOW_NO_CLIPVAULT:-0}" = "1" ] && args+=(--no-clipvault)
  # Über „curl | bash“ ist stdin das Skript selbst → Rückfragen von setup.sh an das Terminal richten
  if [ -r /dev/tty ] && [ -t 1 ]; then
    bash "$src/mac/flow/setup.sh" ${args[@]+"${args[@]}"} < /dev/tty
  else
    bash "$src/mac/flow/setup.sh" --no-panes ${args[@]+"${args[@]}"} < /dev/null
  fi
  echo
  echo "✓ Fertig. Flow läuft (Pille unten am Bildschirm) – fn halten, sprechen, loslassen."
  echo "  Quellcode + Updates: $src   ·   Entfernen: bash \"$src/mac/uninstall-mac.sh\""
}

main "$@"
