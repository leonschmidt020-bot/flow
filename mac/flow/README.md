# Flow (macOS) – Entwickler-Notizen

> Nicht verbunden mit Wispr AI / not affiliated with Wispr. Nutzer-Anleitung: [../README.md](../README.md).

Swift-Paket (SwiftUI, Swift-5-Sprachmodus, **macOS 26**, Apple Silicon). Interne Typnamen (`VoiceFlow/…`, `VF…`) sind
historisch und bleiben; nach außen heißt alles „Flow“.

| | |
|---|---|
| Einrichten | `./setup.sh` (`--check` = nur prüfen, `--with-whisper`, `--no-clipvault`) |
| Bauen & installieren | `./build.sh` → `~/Applications/Flow.app`, LaunchAgent `app.flowdictation.flow` |
| Nur bauen (Test) | `./build.sh --bundle-only <ordner>` |
| Aktualisieren | `./update.sh` (git pull --ff-only + bauen; sicher: Staging prüfen → tauschen → 120 s Health-Gate → sonst zurück) |
| Zurück / Festhalten | `./update.sh --rollback` (`Flow.app.previous`), `--pin v1.7.16`, `--unpin` |
| Kommandozeile | `flow status`, `flow open training`, `flow dictate` … (`~/.config/flow/bin/flow`, Link in `~/.local/bin`) |
| Lebenszeichen | `~/.config/flow/health.json` (Heartbeat 30 s, `busy`, `cleanExit`), Log `flow.log`, `stderr.log` |
| Daten | `~/.config/flow/` (nie im Repo; `FLOW_HOME=<ordner>` für Tests) |
| Update-Quelle | `../flow.conf` (`FLOW_REPO_URL`, Kanal `main`); der Updater folgt dem `origin` des Klons |

Signatur (`scripts/signing.sh`): `FLOW_SIGN_IDENTITY` → Identität der installierten App → lokales Zertifikat
„Flow Local Signing“ (wird angelegt) → sonst ad-hoc mit Warnung.

Prüf-Befehle (nie die Dev-Binary im App-Modus starten – sie verweigert das ohne Bundle ohnehin):
`.build/release/Flow --version`, `--setup-status`, `--prewarm-models`, `--render-onboarding <ordner>`,
`--render-hub <ordner>`, `--pages-test`, `--selftest-agent-prompt`, `--agent-prompt-render <ordner>`,
`--agent-prompt-detect "Text" [Sekunden] [Bundle-ID]`, `--agent-prompt-build <text|@datei> [--rules]` (echter Claude-Aufruf),
`--screen-rec-test` (Bildschirmaufnahme, reine Logik), `--screen-rec-render <ordner>` (Karten), `--screen-rec-probe <datei.mp4> [- glow]`
(2 s echte Aufnahme ohne Ton), `--screen-rec-context <video> [system]` (Transkript + Schlüsselbilder für ein vorhandenes Video).
Alle Selbsttests/Renders mit `FLOW_HOME=<leerer Ordner>`.

## Optionale Teile (Standard aus, ohne sie läuft alles andere)

| Teil | braucht | ohne |
|---|---|---|
| Whisper large-v3-turbo | `brew install whisper-cpp` + Modell (`./setup.sh --with-whisper`) | Parakeet allein (Standard-Engine wird automatisch Parakeet) |
| Meeting-Zusammenfassung, Fragen ans Meeting (auch mit Bildern), „Gründlich“-Feinschliff, Command Mode (fn + ⌃) | Claude-CLI (`claude`) | Schalter ausgegraut; fn + ⌃ = normales Diktat; Meeting-Fragen antworten mit Hinweis |
| Agent-Prompts formulieren (Claude Sonnet, Aufwand low, live gestreamt) | Claude-CLI (`claude`) | Regel-Umbau (`APRules`: Sätze → Ziel/Kontext/Aufgabe/Akzeptanz/Regeln/Offene Punkte, nichts geht verloren); Karte zeigt leise „Prompt · ohne KI“ / „Regeln · ohne Claude-CLI“; **keine automatischen Vorschläge** (nur auf Zuruf „Prompt: …“) |
| Feinschliff „Schnell“ mit Apple Intelligence | Apple Intelligence eingeschaltet | nur Regeln (QuickPolish) |
| ClipVault teilen | eigener Worker (`../clipvault/sync-worker/README.md`) | ClipVault lokal |

Agent-Prompts (Standard „An“, Einstellungen › Diktat): ohne Claude-CLI bleiben Vorschläge bei langen Aufträgen bewusst
aus – der Regel-Umbau sortiert nur und formuliert nichts um, das lohnt keine ungefragte Unterbrechung (der Text steht
ja schon da). Wer ihn will, sagt „Prompt: …“. Mit Claude-CLI kommt der Vorschlag sofort nach dem Einfügen (< 1 s);
„Einfügen“ ersetzt dann das noch nicht abgeschickte Diktat im Eingabefeld durch den Prompt (Claude Code im Terminal:
nachgelesen über die Eingabebox, Textfelder: markiert und überschrieben – nie etwas löschen, das Flow nicht selbst
eingefügt hat). Wird das Diktat abgeschickt, geht der Vorschlag leise weg. Tempo: `--agent-prompt-latency`. Code: `Sources/Flow/VoiceFlow/AgentPrompt/`, Verlauf `~/.config/flow/prompts/`.

## Release-Tor

```bash
scripts/release.sh 1.7.17 -m "Kurzbeschreibung"   # prüft alles → nur bei PASS: VERSION, ./build.sh, commit, tag v1.7.17, push
scripts/release.sh --dry-run                       # nur prüfen, nichts ändern/pushen
scripts/release.sh --quick                         # Schnelltest < 90 s
```

Monorepo: geprüft und committet wird nur `mac/` (+ `.gitignore`). Mac-Tags heißen `v<X.Y.Z>`; Windows braucht ein
anderes Präfix. Bericht: Terminal + `tests/last-release.txt`.

| Schritt | Was |
|---|---|
| 1 Build | `swift build -c release`, frisches `--bundle-only`-Bundle (Signatur, Version), `git status` von `mac/` unverändert, Bash-Lint aller `mac/**/*.sh`, `FLOW_REPO_URL` in `flow.conf` = `install-mac.sh` |
| 1b Update-Sicherheit | Staging-Prüfung, Zertifikat ≥ 30 Tage, `tests/lib/rollback_test.sh` (Schein-App), `--selftest-health` |
| 2 CLI-Schutz | unbekannter Befehl = Exit 2, Binary ohne Bundle verweigert den App-Modus, `app.lock`, Selbsttests verweigern `~/.config/flow` |
| 3 Wort-Lerner | `--selftest-learner`, `--selftest-mouse-target`, `--selftest-agent-prompt` (Auslöser, Erkennung, Regel-Rückfall, Schein-Claude, Verlauf, ohne Claude-CLI), `--screen-rec-test` (Bildschirmaufnahme) |
| 3b Oberfläche | Offscreen-Renders (Pille, Neu-Liste, Update-Karte, Agent-Prompt-Karten, Aufnahme-Karten, Hub) |
| 4 Erkennung | TTS-Testset `tests/audio/` (nur `say`, erfundene Namen) über `--engine-bench`, `--voicemask-bench`, `--dictation-sim` gegen `tests/baseline/recognition.json` |
| 5 Sync + Teilen | lokaler `wrangler dev` mit `INIT_SECRET`, zwei Test-Geräte, Text/Bild/5-MB-Datei, Worker verweigert Tresor ohne Init-Geheimnis |
| 6 Update-Weg | Temp-Remote auf dem letzten Tag, Klon „als Freund“ mit lokalen Änderungen, genau der Befehl des Updaters |

- Nichts davon fasst eine installierte App, `~/.config/flow`, `~/.config/flow-clipvault`, einen echten Tresor oder die
  Zwischenablage an.
- Testset neu erzeugen: `python3 tests/audio/make_testset.py --force`, danach `scripts/release.sh --rebaseline` und
  `tests/baseline/recognition.json` committen. Die Baseline hängt vom Mac ab (Latenz) – auf einem neuen Mac zuerst
  `--rebaseline`.
- Schritt 4 misst auch den Hybrid-Weg und braucht darum Whisper (`./setup.sh --with-whisper`). Schritt 5 braucht Node.js und `npm install` in `../clipvault/sync-worker`.
- Signatur im Tor: ohne lokales Zertifikat legt `build.sh --bundle-only` eins an. Wer den Anmelde-Schlüsselbund nicht anfassen will: `FLOW_KEYCHAIN=<test.keychain-db> FLOW_KEYCHAIN_PASSWORD=… scripts/release.sh --dry-run` oder `FLOW_SIGN_IDENTITY=-`.
- Testmodus von `build.sh`/`update.sh` (nur für das Tor): `FLOW_TEST_APP_DIR`, `FLOW_TEST_PREBUILT`.

## Bildschirmaufnahme + Kontrollzentrum-Knopf

Code: `Sources/Flow/VoiceFlow/ScreenRec/ScreenRec.swift` (ScreenCaptureKit + `SCRecordingOutput`, H.264-MP4; eigene Fenster
per `SCContentFilter(excludingApplications:exceptingWindows:)` raus, nur das Maus-Leuchten bleibt drin). Auslöser: ⌃⌥R
(`GlobalShortcut` id 3), Menüpunkt, Adresse `flowdictation://aufnahme`.

Der Knopf liegt in `Extensions/FlowControls/` (WidgetKit-`ControlWidget`, Bundle-ID `app.flowdictation.flow.controls`) und
wird von `build.sh` mit `swiftc` gebaut – **optional**: scheitert Bau oder Signatur, läuft Flow ohne ihn.
- Einstieg `-Xlinker -e -Xlinker _NSExtensionMain` (sonst beendet sich die Erweiterung sofort).
- Die Aktion braucht AppIntents-Metadaten (`appintentsmetadataprocessor` aus vollem Xcode). Macs mit nur Command Line
  Tools nehmen die mitgelieferte Fassung `Extensions/FlowControls/Metadata.appintents`; neu geschrieben wird sie nur von
  `scripts/release.sh` (`FLOW_UPDATE_METADATA=1`), `update.sh` setzt sie vor `git pull` zurück.
- Nach dem Tausch trägt `build.sh` die App neu bei LaunchServices/pluginkit ein (sonst kennt macOS nur den alten Pfad).
- Zeigt `xcode-select` auf die Command Line Tools (ohne SwiftUI-Makros) und ist ein volles Xcode installiert, baut
  `build.sh` mit diesem (`DEVELOPER_DIR` nur für den Lauf).
