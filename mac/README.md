# Flow für macOS – Diktat + ClipVault

> Nicht verbunden mit Wispr AI / not affiliated with Wispr.

**Deutsch** · [English](#english)

Flow ist eine lokale Diktier-App für den Mac: **fn halten, sprechen, loslassen** – der Text steht dort, wo dein Cursor
ist. Dazu kommt **ClipVault**, ein Zwischenablage-Verlauf (⌘⇧V). Beide laufen komplett auf deinem Mac.

## Was es kann

**Flow (Diktat)**
- Diktat in jede App: fn halten (oder doppelt tippen = Freihand). Deutsch und Englisch, auch gemischt.
- Erkennung auf dem Mac: Parakeet (FluidAudio/CoreML, ~0,1 s). Optional zusätzlich Whisper large-v3-turbo über
  Homebrew (`whisper-server`), genauer bei Namen.
- Wörterbuch (lernt aus deinen Korrekturen), Füllwörter weg, Snippets („meine Adresse“ → Text), Stil je App-Art,
  Listen und Satzzeichen per Regeln (optional Apple Intelligence auf dem Mac).
- Notetaker: Meetings aufnehmen (Mikro + Systemton), Sprechertrennung, Transkript. Audiodateien importieren.
- „Nur meine Stimme“: Stimmprofil einlernen, fremde Stimmen und Mac-Ton werden herausgefiltert.
- Sprachbefehle: „Erinner mich morgen um 9 …“, „Termin Freitag 14 Uhr …“, „Notiz: …“, „Schick <Name>: …“ (an den
  geteilten ClipVault-Tresor).
- Agent-Prompts: „Prompt: …“ sagen und frei erzählen → Flow macht daraus einen klaren Auftrag für Claude Code & Co.
  (Ziel, Kontext, Aufgabe, Prüfpunkte, Regeln, offene Punkte). Karte an der Pille mit Kopieren/Einfügen/Ansehen, dein
  Original bleibt immer erhalten, Verlauf unter Scratchpad › Agent-Prompts. Mit Claude-CLI formuliert Claude, ohne sie
  sortiert Flow lokal nach Regeln.
- Hub-Fenster mit Insights, Wörterbuch, Snippets, Stil, Transforms, Scratchpad, Training.
- Updates: roter Punkt an der Pille → „Installieren“. Sicherer Weg: prüfen → tauschen → Lebenszeichen → sonst zurück.

**ClipVault (Zwischenablage)**
- ⌘⇧V öffnet den Verlauf dort, wo die Maus ist: Text, Links (mit Vorschau), Bilder (mit Texterkennung), Dateien.
- Anheften und Bereiche (Sammlungen), zwei Tage / 200 Einträge Verlauf, Doppelte werden zusammengefasst.
- Optional: **einen Tresor mit einem Freund/Partner teilen** – Ende-zu-Ende verschlüsselt über deinen *eigenen*
  kostenlosen Cloudflare Worker ([Anleitung, 5 Minuten](clipvault/sync-worker/README.md)). Standard: aus.

## Voraussetzungen (ehrlich)

| | |
|---|---|
| macOS | **macOS 26 (Tahoe) oder neuer** – `Package.swift` verlangt `.macOS("26.0")`; ältere Versionen gehen nicht |
| Mac | Apple Silicon (M1 oder neuer) |
| Werkzeuge | Xcode Command Line Tools (kostenlos, ~1–2 GB, `xcode-select --install`), macOS-SDK 26. Kein volles Xcode nötig |
| Speicher | ~5 GB frei: Quellcode + Build ~1,5–2 GB, Sprachmodelle ~0,6 GB (FluidAudio, von Hugging Face), mit Whisper +0,6 GB |
| Netz | nur bei der Installation (Swift-Paket FluidAudio von GitHub, Modelle von Hugging Face) und für Update-Prüfungen |
| Zeit | erster Build 3–5 Minuten, Modelle je nach Netz 1–5 Minuten |
| Optional | Homebrew + `whisper-cpp` (genauer), Claude-CLI (Zusammenfassungen, Fragen ans Meeting, Command Mode, bessere Agent-Prompts), Node.js + Cloudflare-Konto (nur fürs Teilen) |

## Installieren

```bash
curl -fsSL https://raw.githubusercontent.com/leonschmidt020-bot/flow/main/mac/install-mac.sh | bash
```

Das Skript prüft macOS-Version, Apple Silicon und die Xcode-Werkzeuge, klont nach
`~/Library/Application Support/Flow/src` (nicht nach Dokumente – iCloud würde sonst Build-Ordner synchronisieren),
baut Flow und ClipVault, lädt die Sprachmodelle und startet das Willkommen.
Optional: `FLOW_WITH_WHISPER=1` (Whisper dazu), `FLOW_NO_CLIPVAULT=1` (ohne ClipVault).

Von Hand: `git clone … && cd flow/mac/flow && ./setup.sh` (`./setup.sh --check` prüft nur).

**Signatur:** `setup.sh` legt einmalig ein lokales, selbst signiertes Zertifikat „Flow Local Signing“ im
Anmelde-Schlüsselbund an (kein Apple-Konto, kein sudo). Damit behält macOS deine Freigaben über Updates hinweg.
Klappt das nicht, wird ad-hoc signiert – dann nach jedem Update die Freigaben neu erteilen (deutliche Warnung beim Bauen).

## Freigaben (macOS fragt, das Willkommen führt durch)

| Freigabe | wofür |
|---|---|
| Mikrofon | Diktat und Meetings |
| Bedienungshilfen | Text an der Cursor-Stelle einfügen, Korrekturen mitlesen (Flow und ClipVault) |
| Eingabeüberwachung | die fn-Taste erkennen |
| Bildschirm- & Systemaudioaufnahme | nur für Meetings (Ton der anderen), beim ersten Meeting |
| Kalender / Erinnerungen | nur wenn du Sprachbefehle dafür nutzt |

`setup.sh` stellt die fn-Taste auf „Nichts tun“ (sonst öffnet fn das Emoji-Fenster).

## Datenschutz

- **100 % lokal.** Stimme, Diktate, Wörterbuch, Meetings, Statistik und Zwischenablage bleiben auf dem Mac
  (`~/.config/flow`, `~/.config/flow-clipvault`, nur für dich lesbar). Keine Telemetrie, kein Konto.
- Einzige Cloud: der **optionale, selbst betriebene** Sync-Worker fürs Teilen – er sieht nur Chiffrat.
- Was trotzdem ins Netz geht: einmalig Paket- und Modell-Downloads; die Update-Prüfung fragt jede Minute das
  öffentliche Git-Repo (`git ls-remote`, abschaltbar in Einstellungen → Allgemein); ClipVault lädt für die
  Link-Vorschau die Seite eines kopierten Links.
- Optional und **standardmäßig aus**: Funktionen mit der Claude-CLI (Meeting-Zusammenfassung, Fragen ans Meeting,
  Command Mode, „Gründlich“-Feinschliff) schicken den jeweiligen Text an Anthropic – über *dein* Claude-Konto.
  Ohne installierte CLI bleiben sie ausgegraut; alles andere funktioniert.
- **Agent-Prompts** (Einstellungen › Diktat › Agent-Prompts, Standard „An“) laufen nur, wenn du „Prompt: …“ sagst oder
  auf „Prompt bauen“ klickst. Mit Claude-CLI geht dann das Diktat (bei Entwickler-Apps auch Fenstertitel und markierter
  Text, nie die Zwischenablage) über dein Claude-Konto an Anthropic; ohne CLI bleibt alles lokal (Regel-Umbau).
  Vorschläge bei langen Aufträgen („Daraus einen Agent-Prompt machen?“) gibt es nur mit Claude-CLI. „Aus“ schaltet
  alles ab, „Nur auf Zuruf“ die Vorschläge.

## Entfernen

```bash
bash "$HOME/Library/Application Support/Flow/src/mac/uninstall-mac.sh"          # Apps + Autostart, Daten bleiben
bash "$HOME/Library/Application Support/Flow/src/mac/uninstall-mac.sh" --purge  # zusätzlich alle Daten
```

Danach optional: Quellordner löschen, Zertifikat „Flow Local Signing“ in der Schlüsselbundverwaltung löschen,
Einträge in Systemeinstellungen → Datenschutz entfernen.

## Aufbau

| Ordner | Inhalt |
|---|---|
| `flow/` | Swift-Paket (SwiftUI, macOS 26): App, Kommandozeile `flow`, `setup.sh`, `build.sh`, `update.sh`, Release-Tor `scripts/release.sh` → [flow/README.md](flow/README.md) |
| `clipvault/` | ClipVault (swiftc), Protokoll `PROTOCOL.md`, Sync-Server `sync-worker/` (Cloudflare Worker) |
| `flow.conf` | Update-Quelle (`FLOW_REPO_URL`) und Kanal (`main`) |
| `install-mac.sh` / `uninstall-mac.sh` | Installation mit einer Zeile / Entfernen |

Kennungen: Bundle-IDs `app.flowdictation.flow` / `app.flowdictation.clipvault`, LaunchAgents mit denselben Namen,
App `~/Applications/Flow.app`.

## Lizenz

MIT – siehe [LICENSE](LICENSE). Mitgelieferte Schrift Instrument Serif: SIL Open Font License
(`flow/Resources/Assets/InstrumentSerif-OFL.txt`). Abhängigkeit FluidAudio: siehe deren Lizenz.

---

## English

> Not affiliated with Wispr AI.

Flow is a local dictation app for macOS: **hold fn, speak, release** – the text appears at your cursor.
**ClipVault** adds a clipboard history (⌘⇧V). Everything runs on your Mac.

**Features:** dictation into any app (German/English), on-device recognition with Parakeet (optional Whisper via
Homebrew), personal dictionary that learns from your edits, filler removal, snippets, per-app style, meeting notetaker
with speaker separation, audio import, "only my voice" filtering, voice commands (reminders, calendar, notes, send to
shared vault), agent prompts (say "Prompt: …" and ramble – Flow turns it into a structured task for a coding agent,
keeping your original), and a hub window. ClipVault: history of text/links/images/files, pinning, collections, OCR, and optional
end-to-end encrypted sharing of one vault with one friend via **your own** free Cloudflare Worker
([5-minute guide](clipvault/sync-worker/README.md)). Sharing is off by default.

**Requirements:** macOS 26 (Tahoe) or later (the Swift package targets `.macOS("26.0")`), Apple Silicon, Xcode
Command Line Tools with the macOS 26 SDK, ~5 GB free disk (build ~1.5–2 GB, models ~0.6 GB, +0.6 GB with Whisper),
network during install. First build takes 3–5 minutes.

**Install:**

```bash
curl -fsSL https://raw.githubusercontent.com/leonschmidt020-bot/flow/main/mac/install-mac.sh | bash
```

It checks the OS and tools, clones to `~/Library/Application Support/Flow/src` (not Documents, because of iCloud),
builds both apps, downloads the models and starts onboarding. A local self-signed certificate "Flow Local Signing" is
created in your login keychain so macOS keeps permissions across updates (fallback: ad-hoc signing with a warning).

**Permissions:** Microphone, Accessibility, Input Monitoring, Screen & System Audio Recording (meetings only),
Calendar/Reminders (only for those voice commands).

**Privacy:** 100 % local, no account, no telemetry. The only cloud component is the optional self-hosted sync worker,
which only sees ciphertext. Network use: package/model downloads at install, a git update check every minute
(can be turned off), link previews in ClipVault. Optional features using the Claude CLI (meeting summary, questions,
command mode) are off by default and send the relevant text to Anthropic via your own account. Agent prompts are on by
default but only run when you say "Prompt: …" or click "build prompt": with the Claude CLI the dictation is sent to
Anthropic via your account, without it a local rule-based builder is used. Automatic suggestions for long dictations
only appear when the Claude CLI is installed.

**Uninstall:** `bash "$HOME/Library/Application Support/Flow/src/mac/uninstall-mac.sh"` (add `--purge` to delete data).

**License:** MIT.
