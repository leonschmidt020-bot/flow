#!/bin/bash
# Baut Flow, legt ~/Applications/Flow.app an, signiert STABIL und startet neu (LaunchAgent des aktuellen Benutzers).
#
#   ./build.sh                     bauen + installieren + starten
#   ./build.sh --bundle-only DIR   nur DIR/Flow.app bauen + signieren (nichts installieren, nichts beenden/starten)
#
# Sicherer Weg (scripts/install_lib.sh): erst komplett in einen Staging-Ordner bauen, signieren und prüfen – die laufende
# App wird erst danach gestoppt. Die bisherige Fassung bleibt als „Flow.app.previous“ liegen. Scheitert danach
# irgendetwas oder meldet die neue Version binnen 120 s kein gesundes Lebenszeichen (health.json), kommt automatisch
# die vorige zurück. Nie während einer Aufnahme (wartet bis zu 10 Min., sonst Exit 75 = verschoben).
# Exit: 0 ok · 1 Fehler, installierte App unverändert · 3 zurückgenommen, vorige Version läuft · 75 verschoben
#
# Umgebung:
#   BUNDLE_ID              Bundle-ID + LaunchAgent-Label (Standard app.flowdictation.flow – NICHT ändern, wenn schon installiert:
#                          eine neue ID ist für macOS eine neue App → alle Freigaben neu erteilen)
#   FLOW_SIGN_IDENTITY   Signatur erzwingen (SHA-1/Name; „-“ = ad-hoc, nicht empfohlen)
#   FLOW_HOME            Datenordner (Standard ~/.config/flow) – dorthin kommt bin/flow
# Nur für das Release-Tor (scripts/release.sh, Update-Test) – nie für echte Installationen:
#   FLOW_TEST_APP_DIR    wie --bundle-only: App nach <ordner>/Flow.app, KEIN launchctl/pkill/LaunchAgent,
#                          flow nicht in den Datenordner (so kann update.sh gefahrlos durchlaufen)
#   FLOW_TEST_PREBUILT   (nur mit FLOW_TEST_APP_DIR) fertiger Ordner .build/release statt swift build
# Nur für update.sh --pin: FLOW_SRC_DIR = Quellordner (ein älterer Stand), gebaut wird mit DIESEM build.sh
# Signatur-Wahl und warum nicht ad-hoc: siehe scripts/signing.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "${FLOW_SRC_DIR:-$HERE}"
SRC="$(pwd)"

BUNDLE_ONLY=""
if [ "${1:-}" = "--bundle-only" ]; then BUNDLE_ONLY="${2:?Ordner fehlt}"; fi
PREBUILT="${FLOW_TEST_PREBUILT:-}"
if [ -n "${FLOW_TEST_APP_DIR:-}" ]; then
  BUNDLE_ONLY="$FLOW_TEST_APP_DIR"
  echo "» Testmodus: App nur nach ${BUNDLE_ONLY} (nichts installieren, nichts beenden/starten)"
elif [ -n "$PREBUILT" ]; then
  echo "✗ FLOW_TEST_PREBUILT geht nur zusammen mit FLOW_TEST_APP_DIR"; exit 2
fi

BUNDLE_ID="${BUNDLE_ID:-app.flowdictation.flow}"
APP_NAME="Flow"
if [ -n "$BUNDLE_ONLY" ]; then APP="$BUNDLE_ONLY/$APP_NAME.app"; else APP="$HOME/Applications/$APP_NAME.app"; fi
INSTALLED="$HOME/Applications/$APP_NAME.app"
PLIST="$HOME/Library/LaunchAgents/$BUNDLE_ID.plist"
DATA="${FLOW_HOME:-$HOME/.config/flow}"

# --- Version: VERSION-Datei + git describe (in die Info.plist) ---
VERSION="$(tr -d '[:space:]' < VERSION 2>/dev/null || echo 0.0.0)"
GIT_DESC="$(git describe --tags --match 'v[0-9]*' --always --dirty 2>/dev/null || echo "ohne-git")"
BUILD_NO="$(date +%Y%m%d%H%M)"
GIT_COMMIT="$(git rev-parse HEAD 2>/dev/null || echo "")"
# Stände mit health.json-Lebenszeichen (ab 1.7.10) bekommen das Health-Gate; ältere (--pin) nur „läuft der Prozess?“
HEALTH_KEY=""
[ -f Sources/Flow/VoiceFlow/Runtime/Health.swift ] && HEALTH_KEY="<key>FlowHealthVersion</key><integer>1</integer>"

# --- Signatur-Identität (stabil!) + sicherer Installationsweg ---
source "$HERE/scripts/signing.sh"
source "$HERE/scripts/install_lib.sh"
[ -n "${FLOW_TEST_APP_DIR:-}" ] && INST_TEST=1
STAGE_ROOT="$(dirname "$APP")/.${APP_NAME}.staging"
STAGE="$STAGE_ROOT/$APP_NAME.app"
build_exit() {
  inst_on_exit                 # Abbruch nach dem Stoppen → vorige Fassung zurück und starten
  sign_keychain_end
  rm -rf "$STAGE_ROOT"
}
trap build_exit EXIT
trap 'exit 143' TERM INT
if ! choose_sign_identity "$INSTALLED"; then
  # Notlösung statt Abbruch: ad-hoc signieren (läuft, aber Freigaben gehen bei jedem Neubau verloren)
  SIGN_IDENTITY="-"; SIGN_LABEL="ad-hoc (kein lokales Zertifikat anlegbar)"
fi
[ "$SIGN_IDENTITY" = "-" ] && warn_adhoc "$APP_NAME"

# --- Bauen (Fehler NICHT verschlucken: sonst würde eine alte Binary installiert) ---
RELDIR=".build/release"
if [ -n "$PREBUILT" ]; then
  echo "» Testmodus: fertige Binary aus ${PREBUILT} (kein swift build) – Flow ${VERSION} (${GIT_DESC})"
  RELDIR="$PREBUILT"
  mkdir -p .build
  if [ -x "$PREBUILT/../flow-cli" ]; then cp "$PREBUILT/../flow-cli" .build/flow-cli; fi
else
  echo "» Baue Flow $VERSION ($GIT_DESC) …"
  # Die reinen Command Line Tools haben die SwiftUI-Makros nicht („plugin for module 'SwiftUIMacros' not found“) –
  # zeigt xcode-select dorthin und ist ein volles Xcode installiert, nimmt der Bau dieses (nur für diesen Lauf).
  if [ -z "${DEVELOPER_DIR:-}" ]; then
    _dev="$(xcode-select -p 2>/dev/null || true)"
    _plug="Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib"
    if [ ! -e "$_dev/$_plug" ] && [ ! -e "$_dev/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib" ]; then
      for _x in /Applications/Xcode.app /Applications/Xcode*.app "$HOME/Applications/Xcode.app"; do
        if [ -e "$_x/Contents/Developer/$_plug" ]; then
          export DEVELOPER_DIR="$_x/Contents/Developer"
          echo "  (baue mit $(basename "$_x") – xcode-select zeigt auf ${_dev:-?}, dort fehlen die SwiftUI-Makros)"
          break
        fi
      done
    fi
  fi
  # Leerzeichen im Pfad (z. B. iCloud-„Dokumente – <Mac>“) kann swift build abbrechen lassen
  case "$(pwd)" in *" "*) echo "⚠︎ Projektpfad enthält Leerzeichen ($(pwd)) – swift build kann daran scheitern. Besser z. B. nach ~/Developer verschieben.";; esac
  set +e
  swift build -c release > .build-log.txt 2>&1
  rc=$?
  set -e
  grep -E "error:|Build complete" .build-log.txt | tail -20 || true
  if [ $rc -ne 0 ]; then echo "✗ Build fehlgeschlagen (swift build, Details: ${SRC}/.build-log.txt)"; exit 1; fi
  # flow (Kommandozeile/Fernsteuerung) – kleine eigene Binary
  swiftc -O tools/flow.swift -o .build/flow-cli 2>/dev/null || echo "⚠︎  Kommandozeile „flow“ nicht gebaut (weiter ohne)"
fi
BIN="$RELDIR/Flow"
[ -x "$BIN" ] || { echo "✗ Build fehlgeschlagen (keine Binary)"; exit 1; }

# Neues Bundle komplett im Staging-Ordner zusammenbauen – die laufende App bleibt bis zum geprüften Tausch unberührt
# (nie über die laufende Binary kopieren → Signatur kaputt)
mkdir -p "$(dirname "$APP")"
rm -rf "$STAGE_ROOT"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp "$BIN" "$STAGE/Contents/MacOS/$APP_NAME"
# Bilder, Schriften
[ -d Resources/Assets ] && cp -R Resources/Assets "$STAGE/Contents/Resources/Assets"
# FluidAudio-Ressourcen (nur TTS, wird nicht genutzt) – trotzdem mitliefern
cp -R "$RELDIR/FluidAudio_FluidAudio.bundle" "$STAGE/Contents/Resources/" 2>/dev/null || true
# App-Icon im macOS-26-Format (Resources/AppIcon.icon → Assets.car, hell/dunkel/getönt + Glas).
# Mit Xcode wird neu kompiliert; ohne Xcode (z. B. nur Command Line Tools) wird das mitgelieferte Assets.car benutzt.
if [ -d Resources/AppIcon.icon ] && xcrun --find actool >/dev/null 2>&1; then
  ICONTMP="$(mktemp -d)"
  if xcrun actool --compile "$ICONTMP" --platform macosx --minimum-deployment-target 26.0 --app-icon AppIcon \
       --output-partial-info-plist "$ICONTMP/p.plist" Resources/AppIcon.icon >/dev/null 2>&1; then
    ICON_BUILT="$ICONTMP"
  fi
fi
# Frisch kompiliertes Icon NUR ins App-Bundle – nie nach Resources/ (sonst ist das Repo nach jedem Build „dirty“
# und git pull --ff-only beim Auto-Update bricht ab). Resources/ enthält die mitgelieferte Fassung für Macs ohne Xcode.
ICON_SRC="${ICON_BUILT:-Resources}"
cp "$ICON_SRC/AppIcon.icns" "$STAGE/Contents/Resources/" 2>/dev/null || true
cp "$ICON_SRC/Assets.car" "$STAGE/Contents/Resources/" 2>/dev/null || true
[ -n "${ICONTMP:-}" ] && rm -rf "$ICONTMP"

cat > "$STAGE/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NO</string>
  <key>FlowGitDescribe</key><string>$GIT_DESC</string>
  <key>FlowGitCommit</key><string>$GIT_COMMIT</string>
  $HEALTH_KEY
  <key>FlowSourceDir</key><string>$(pwd)</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>LSEnvironment</key><dict><key>MallocLargeCache</key><string>0</string></dict>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Flow hört zu, solange du die Diktier-Taste hältst oder ein Meeting aufnimmst. Alles bleibt auf dem Mac.</string>
  <key>NSAudioCaptureUsageDescription</key><string>Flow nimmt im Meeting-Modus den Ton der anderen Teilnehmer auf, damit das Transkript vollständig ist.</string>
  <key>NSRemindersFullAccessUsageDescription</key><string>Flow legt Erinnerungen an – aus deinen Meetings, wenn du bei einem Vorschlag „Übernehmen“ klickst, oder per Sprachbefehl („Erinner mich morgen um 9 an …“).</string>
  <key>CFBundleDocumentTypes</key><array>
    <dict><key>CFBundleTypeName</key><string>Audiodatei</string><key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key><array><string>public.audio</string><string>com.apple.quicktime-audio</string><string>org.xiph.ogg-audio</string><string>org.xiph.opus</string><string>org.xiph.flac</string></array></dict>
    <dict><key>CFBundleTypeName</key><string>Video (Tonspur)</string><key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key><array><string>public.movie</string></array></dict>
  </array>
  <key>CFBundleURLTypes</key><array><dict><key>CFBundleURLName</key><string>$BUNDLE_ID</string>
    <key>CFBundleURLSchemes</key><array><string>flowdictation</string></array></dict></array>
  <key>NSCalendarsFullAccessUsageDescription</key><string>Flow zeigt dir im Notetaker deine heutigen Meetings und trägt per Sprachbefehl Termine ein („Termin Freitag 14 Uhr …“).</string>
</dict></plist>
PL

sign_keychain_begin
# Kontrollzentrum-Knopf „Bildschirm aufnehmen (Flow)“ (WidgetKit-Steuerelement, macOS 26) – optional:
# klappt der Bau nicht (andere Werkzeuge), läuft Flow ganz normal ohne den Knopf (⌃⌥R geht immer).
CTRL_SRC="Extensions/FlowControls/Controls.swift"
CTRL_BIN=".build/flowcontrols/FlowControls"
if [ -f "$CTRL_SRC" ]; then
  mkdir -p "$(dirname "$CTRL_BIN")"
  if [ ! -x "$CTRL_BIN" ] || [ "$CTRL_SRC" -nt "$CTRL_BIN" ] || [ build.sh -nt "$CTRL_BIN" ] || { [ ! -d .build/flowcontrols/meta/Metadata.appintents ] && [ -z "${FLOW_NO_APPINTENTS_TOOL:-}" ]; }; then
    # Einstieg wie bei Xcode-Erweiterungen: _NSExtensionMain (mit dem normalen main beendet sich die Erweiterung sofort)
    # + Swift-Konstanten für die AppIntents-Metadaten (ohne sie tut ein Druck auf den Knopf nichts: „action intent without linkAction“)
    CTRL_DIR="$(pwd)/.build/flowcontrols"
    rm -rf "$CTRL_DIR/meta"
    xcrun swiftc -parse-as-library -target "$(uname -m)-apple-macos26.0" -O -wmo -module-name FlowControls "$CTRL_SRC" -o "$CTRL_BIN" \
      -Xlinker -e -Xlinker _NSExtensionMain \
      -emit-const-values -emit-const-values-path "$CTRL_DIR/Controls.swiftconstvalues" \
      -Xfrontend -const-gather-protocols-file -Xfrontend "$(pwd)/Extensions/FlowControls/appintents-protocols.json" > "$CTRL_DIR/build.log" 2>&1 || rm -f "$CTRL_BIN"
    TC="$(dirname "$(dirname "$(dirname "$(xcrun --find swiftc)")")")"   # …/XcodeDefault.xctoolchain
    if [ -x "$CTRL_BIN" ] && [ -x "$TC/usr/bin/appintentsmetadataprocessor" ] && [ -z "${FLOW_NO_APPINTENTS_TOOL:-}" ]; then
      echo "$(pwd)/$CTRL_SRC" > "$CTRL_DIR/src.list"; echo "$CTRL_DIR/Controls.swiftconstvalues" > "$CTRL_DIR/cv.list"
      "$TC/usr/bin/appintentsmetadataprocessor" --output "$CTRL_DIR/meta" --toolchain-dir "$TC" --module-name FlowControls \
        --sdk-root "$(xcrun --show-sdk-path)" --xcode-version "$(xcodebuild -version 2>/dev/null | tail -1 | awk '{print $3}')" \
        --platform-family macOS --deployment-target 26.0 --target-triple "$(uname -m)-apple-macos26.0" \
        --source-file-list "$CTRL_DIR/src.list" --swift-const-vals-list "$CTRL_DIR/cv.list" --binary-file "$CTRL_BIN" >> "$CTRL_DIR/build.log" 2>&1 || true
    fi
  fi
  if [ -x "$CTRL_BIN" ]; then
    EXT="$STAGE/Contents/PlugIns/FlowControls.appex"
    mkdir -p "$EXT/Contents/MacOS"
    cp "$CTRL_BIN" "$EXT/Contents/MacOS/FlowControls"
    if [ -d .build/flowcontrols/meta/Metadata.appintents ]; then
      mkdir -p "$EXT/Contents/Resources"; cp -R .build/flowcontrols/meta/Metadata.appintents "$EXT/Contents/Resources/"
      # frisch erzeugte Fassung auch ins Repo (Macs ohne volles Xcode haben appintentsmetadataprocessor nicht) –
      # NUR bei der Veröffentlichung (release.sh setzt FLOW_UPDATE_METADATA): sonst wäre das Repo nach jedem Bau „verändert“
      if [ -n "${FLOW_UPDATE_METADATA:-}" ] && ! diff -rq .build/flowcontrols/meta/Metadata.appintents Extensions/FlowControls/Metadata.appintents >/dev/null 2>&1; then
        rm -rf Extensions/FlowControls/Metadata.appintents; cp -R .build/flowcontrols/meta/Metadata.appintents Extensions/FlowControls/
        echo "  (Extensions/FlowControls/Metadata.appintents aktualisiert – mit committen)"
      fi
    elif [ -d Extensions/FlowControls/Metadata.appintents ]; then
      # nur Command Line Tools: mitgelieferte Metadaten aus dem Repo
      mkdir -p "$EXT/Contents/Resources"; cp -R Extensions/FlowControls/Metadata.appintents "$EXT/Contents/Resources/"
      echo "  (Kontrollzentrum-Knopf: AppIntents-Metadaten aus dem Repo – kein Xcode-Werkzeug auf diesem Mac)"
    else
      echo "⚠︎ Kontrollzentrum-Knopf ohne AppIntents-Metadaten (Druck darauf tut nichts) – .build/flowcontrols/build.log"
    fi
    cat > "$EXT/Contents/Info.plist" <<XPL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID.controls</string>
  <key>CFBundleExecutable</key><string>FlowControls</string>
  <key>CFBundleName</key><string>FlowControls</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundlePackageType</key><string>XPC!</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NO</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSExtension</key><dict><key>NSExtensionPointIdentifier</key><string>com.apple.widgetkit-extension</string></dict>
</dict></plist>
XPL
    if codesign --force --options runtime --entitlements Extensions/FlowControls/FlowControls.entitlements --sign "$SIGN_IDENTITY" "$EXT" 2>/dev/null; then
      echo "✓ Kontrollzentrum-Knopf „Bildschirm aufnehmen (Flow)“ eingebaut"
    else
      rm -rf "$STAGE/Contents/PlugIns"; echo "⚠︎ Kontrollzentrum-Knopf nicht signiert – Flow läuft ohne ihn"
    fi
  else
    echo "⚠︎ Kontrollzentrum-Knopf nicht gebaut (.build/flowcontrols/build.log) – Flow läuft ohne ihn"
  fi
fi
if ! codesign --force --options runtime --entitlements voiceflow.entitlements --sign "$SIGN_IDENTITY" --identifier "$BUNDLE_ID" "$STAGE"; then
  echo "✗ Signieren fehlgeschlagen (Schlüsselbund gesperrt?) – die installierte App bleibt unverändert"; exit 1
fi
echo "✓ Signiert: $SIGN_LABEL"
echo "  Freigaben hängen an: $(codesign -d -r- "$STAGE" 2>&1 | grep designated | sed 's/^designated => //')"

if [ -n "$BUNDLE_ONLY" ]; then
  # Testmodus/--bundle-only: dieselbe Prüfung + derselbe Tausch, aber ohne Stoppen/Starten
  INST_TEST=1
  set +e; inst_install_staged "$STAGE" "$VERSION" "$BUILD_NO"; rc=$?; set -e
  [ $rc -eq 0 ] || exit $rc
  [ -x .build/flow-cli ] && cp .build/flow-cli "$BUNDLE_ONLY/flow"
  echo "✓ Nur gebaut: $APP (nichts installiert)"
  exit 0
fi

# LaunchAgent-Datei schon vor dem Stoppen schreiben – jeder Start (auch der Rückweg) nutzt dieselbe.
# ThrottleInterval: nach einem Absturz frühestens 10 s später neu starten (keine Schleife im Sekundentakt);
# StandardErrorPath: fatalError-/precondition-Texte und AppKit-Ausnahmen landen sonst im Nichts (App kürzt ab 1 MB).
mkdir -p "$HOME/Library/LaunchAgents" "$DATA"
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$BUNDLE_ID</string>
  <key>ProgramArguments</key><array><string>$APP/Contents/MacOS/$APP_NAME</string></array>
  <key>RunAtLoad</key><true/>
  <key>AbandonProcessGroup</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>StandardErrorPath</key><string>$DATA/stderr.log</string>
  <key>ProcessType</key><string>Interactive</string>
  <key>EnvironmentVariables</key><dict><key>MallocLargeCache</key><string>0</string></dict>
</dict></plist>
PL

# Prüfen → (warten, falls Aufnahme) → stoppen → tauschen → starten → Health-Gate (bei Fehler: zurück)
set +e; inst_install_staged "$STAGE" "$VERSION" "$BUILD_NO"; rc=$?; set -e
[ $rc -eq 0 ] || exit $rc

# Kommandozeile „flow“ in den Datenordner (nie über eine laufende Datei kopieren: erst löschen)
if [ -x .build/flow-cli ]; then
  mkdir -p "$DATA/bin"; chmod 700 "$DATA" "$DATA/bin" 2>/dev/null || true
  rm -f "$DATA/bin/flow"; cp .build/flow-cli "$DATA/bin/flow"; chmod 700 "$DATA/bin/flow"
fi
# Kontrollzentrum-Knopf: nach dem Tausch kennt macOS die Erweiterung nur noch unter dem ALTEN Pfad (jetzt
# „….previous“) → „action intent without linkAction“, ein Druck tut nichts. Neu eintragen, alte abmelden, laufenden
# Erweiterungs-Prozess DIESER App beenden (startet beim nächsten Öffnen des Kontrollzentrums aus der neuen App).
if [ -d "$APP/Contents/PlugIns/FlowControls.appex" ]; then
  LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
  pluginkit -r "${APP}.previous/Contents/PlugIns/FlowControls.appex" >/dev/null 2>&1 || true
  "$LSREG" -u "${APP}.previous" >/dev/null 2>&1 || true
  "$LSREG" -f -R "$APP" >/dev/null 2>&1 || true
  pluginkit -a "$APP/Contents/PlugIns/FlowControls.appex" >/dev/null 2>&1 || true
  pkill -f "$APP/Contents/PlugIns/FlowControls.appex/" >/dev/null 2>&1 || true
fi
echo "✓ Flow $VERSION läuft ($GIT_DESC). Vorige Fassung: ${APP}.previous (./update.sh --rollback)"
