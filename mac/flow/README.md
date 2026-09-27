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
`--render-hub <ordner>`, `--pages-test`.

## Optionale Teile (Standard aus, ohne sie läuft alles andere)

| Teil | braucht | ohne |
|---|---|---|
| Whisper large-v3-turbo | `brew install whisper-cpp` + Modell (`./setup.sh --with-whisper`) | Parakeet allein (Standard-Engine wird automatisch Parakeet) |
| Meeting-Zusammenfassung, Fragen ans Meeting (auch mit Bildern), „Gründlich“-Feinschliff, Command Mode (fn + ⌃) | Claude-CLI (`claude`) | Schalter ausgegraut; fn + ⌃ = normales Diktat; Meeting-Fragen antworten mit Hinweis |
| Feinschliff „Schnell“ mit Apple Intelligence | Apple Intelligence eingeschaltet | nur Regeln (QuickPolish) |
| ClipVault teilen | eigener Worker (`../clipvault/sync-worker/README.md`) | ClipVault lokal |

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
| 3 Wort-Lerner | `--selftest-learner`, `--selftest-mouse-target` |
| 3b Oberfläche | Offscreen-Renders (Pille, Neu-Liste, Update-Karte, Hub) |
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
