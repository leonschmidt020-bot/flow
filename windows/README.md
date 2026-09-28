# Flow for Windows

**Flow** is a free, open-source voice dictation app. Hold a key, speak, let go – the text appears wherever your cursor is.
Speech recognition runs **100 % on your PC**: no cloud, no account, no telemetry.

> Flow is an independent project and is **not affiliated with Wispr** or Wispr Flow.

- Speech recognition: NVIDIA **Parakeet TDT 0.6B v3** (German, English + 23 more languages, detected automatically) via [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx). Optional: **Whisper large-v3-turbo**.
- Silero VAD trims silence and splits long dictations.
- Hold **Right Ctrl** (or Ctrl + Win, Right Alt, F6–F12). **Double-tap** for hands-free.
- Polish rules ported 1:1 from the Mac app: self-corrections („… nein warte, am Freitag“), repeats, false starts, lists („erstens … zweitens …“, shopping lists, steps, to-dos), punctuation.
- Voice commands „neue Zeile“ / „neuer Absatz“ (“new line”, “new paragraph”), filler words („ähm“, „äh“) removed.
- **Notetaker**: records meetings (microphone + system audio), transcribes them with speakers, imports audio/video files – all local.
- Hub window: **Verlauf** (history with copy), **Notetaker**, **Wörterbuch** (your words/replacements), **ClipVault** (clipboard history), **Einstellungen**.
- UI in German and English.

## Install (for friends)

1. Download `Flow-Setup-x.y.z.exe` from the [Releases page](https://github.com/leonschmidt020-bot/flow/releases) (or, for test builds, the
   `Flow-Setup-windows-x64` artifact of the latest GitHub Actions run).
2. Run it. The installer is not code-signed yet, so Windows SmartScreen may say *“Windows protected your PC”* →
   click **More info → Run anyway**. It installs per user (no admin rights) and starts Flow.
3. On first start Flow downloads the speech model once (~490 MB, from the official sherpa-onnx GitHub release). Progress is shown
   in the Flow window and in the little pill at the bottom of the screen. After that everything works offline.
4. If Windows asks for microphone access, allow it. If dictation stays silent: *Settings → Privacy & security → Microphone* →
   enable *Microphone access* **and** *Let desktop apps access your microphone* (the Flow settings page has a button for this).
5. Click into any text field, **hold Right Ctrl, speak, release**. Tap Right Ctrl twice quickly to dictate hands-free, press it again
   to finish, **Esc** cancels.

Flow lives in the system tray (pause, ClipVault, quit). Updates are checked on GitHub Releases and installed when you quit Flow
(can be switched off in the settings). Uninstall via *Settings → Apps*; your data in `%APPDATA%\Flow` is kept.

## Notetaker (meetings)

**Record:** *Aufnahme starten* in the Notetaker page, the tray menu, or **Ctrl + Alt + M** anywhere. Flow records two tracks: your
microphone (`ich.wav`) and the system audio – the other participants – via WASAPI loopback (`andere.wav`, Electron `getDisplayMedia`
with `audio: 'loopback'`; the video track that API always delivers is stopped immediately, no screen content is ever read). The pill
shows **„Meeting läuft · 12:03“** with a stop button; a live transcript appears in the hub while you talk.

**Call detection** (*Meetings erkennen*: Aus / **Nachfragen** (default) / Automatisch): like the Mac app, Flow watches which *known call
app* is using the microphone – on Windows via the privacy consent store
`HKCU\…\CapabilityAccessManager\ConsentStore\microphone` (`LastUsedTimeStop == 0` or `Start > Stop` = in use), read every 3 s with
advapi32 (koffi, no child process). Teams, Zoom, Webex, Slack, Discord, Skype, WhatsApp, Signal, Telegram, GoTo and browsers
(„Chrome (z. B. Google Meet)“) are recognised; window titles only improve the name („Teams · Wochenplanung“, „Google Meet“).
A card **„Microsoft Teams erkannt · Meeting aufnehmen?“** grows out of the pill; when the app releases the microphone Flow asks
**„Meeting vorbei?“** (and stops after 90 s without an answer; auto-started recordings stop by themselves). *Nachfragen* is the default
because it matches the Mac, only reads local registry values and never records without a click.

**After the meeting** (in the background, one job at a time): Silero VAD → ≤ 25 s chunks → **Parakeet** with token timestamps →
**speaker diarization** with sherpa-onnx (pyannote segmentation-3.0 + NVIDIA NeMo TitaNet-small embeddings, ~47 MB, downloaded on first
use from the official sherpa-onnx releases with size + sha256 check). Online calls: the system track is diarized („Sprecher 1/2…“),
your microphone is „Ich“ (echo of the others removed); in-person meetings and imported files: the single track is diarized.
Speakers can be renamed by clicking their name.

**Import:** drag an audio/video file (mp3, m4a, wav, mp4, mov, ogg, opus, flac, webm …) onto the Notetaker page or onto the pill, or use
*Audiodatei importieren*; progress shows on the pill („Audiodatei · 42 %“). The original is only referenced, never copied. Decoding:
WAV directly; otherwise **ffmpeg if installed** (setting, `PATH`, winget/scoop/choco locations – streams, any length/format), else
**Electron's built-in decoder** (mp3, AAC/m4a, mp4, ogg/opus, flac, webm; up to 400 MB). Flow does **not bundle ffmpeg**: the usual static
Windows builds (`ffmpeg-static`, BtbN "gpl") are GPL and ~80 MB – shipping one would add GPL source-offer obligations to every release
and double the installer; Electron's own LGPL ffmpeg already covers the common formats.

**Prompt für Agent:** rebuilds `<meeting>\Kontext-Paket\` (same layout as the Mac app 1.7.15): `transkript.md` – the *complete*
transcript with times and speakers, ending with „— Ende des Transkripts —“ – and `meeting.md` (overview, participants, summary, file
list, original audio path). The prompt (folder, every file with its full path, segment/word/line counts, „Lies zuerst transkript.md
KOMPLETT …“) goes to the clipboard – toast **„Prompt kopiert ✓“**.

**Summary (optional):** only if a local Claude Code CLI is installed (`claude.exe` / npm `claude.cmd`) – otherwise the button is not
shown. It runs without tools/MCP/session and sends the transcript to *your* Claude account, so *Automatisch zusammenfassen* is off by default.

**Retention:** meetings delete themselves after **3 days** (1/3/7/14/30 days or forever) unless **Behalten**. *Audio behalten* (on) keeps
the WAV tracks for *Neu auswerten*. A meeting whose `meeting.json` became unreadable falls back to `meeting.json.bak`; if both are broken
the folder is listed as damaged and never deleted automatically.

## Data

Everything is stored in `%APPDATA%\Flow` (`app.getPath('userData')`):

| file | content |
|---|---|
| `settings.json` (+ `.bak`) | settings incl. dictionary – atomic writes (temp + rename), last good copy as `.bak` |
| `history.json` (+ `.bak`) | dictation history (deleted after the retention period) |
| `models/` | speech models + Silero VAD + diarization models |
| `meetings/<id>/` | `meeting.json` (+ `.bak`, atomic), `ich.wav` / `andere.wav` (if *Audio behalten*), `Kontext-Paket/` |
| `meetings/settings.json` | notetaker settings |
| `clipvault/` | ClipVault data (see `src/clipvault/`) |
| `logs/flow.log` | local log without dictated text |

## Development

```bash
cd windows
npm ci
npm run lint          # eslint + tsc
npm test              # vitest: polish/lists parity with the Mac app, commands, dictionary, settings migration, store, hotkey, inserter, downloader …
npm run test:asr      # downloads Parakeet into .cache/models and transcribes test/fixtures/asr/*.wav, checks WER
npm run test:meeting  # + diarization models: imports test/fixtures/meeting/two_voices.wav (2 macOS voices), checks 2 speakers, turns, WER, package
npm run smoke:meeting # Electron end-to-end incl. m4a import (FLOW_NO_FFMPEG=1 forces Electron's decoder) + notetaker page screenshot
npm run fixtures:meeting  # regenerates the two-voice fixture with macOS `say` (macOS only)
FLOW_ASR_MODEL=whisper-turbo npm run test:asr
npm run build         # esbuild → dist/
npm run render        # offscreen PNGs of pill + hub states → .cache/render (no window is shown)
npm run smoke         # end-to-end: WAV → ASR → polish → (no-op paste) → history → hub screenshot, then quits
npm run dev           # starts the app with --dev --no-hotkey
npm run dist:win      # NSIS installer → release/ (on Windows / CI)
npm run dist:win:local  # cross-build on macOS (fetches the win-x64 native prebuilds first; no wine needed)
```

Flags: `--no-hotkey` (never installs the global keyboard hook), `--hidden` (autostart), `--render-check=<dir>`, `--smoke=<wav>`.
Env: `FLOW_USER_DATA` (profile dir), `FLOW_MODEL_DIR`, `FLOW_MODEL_CACHE` (ASR test), `FLOW_DEBUG=1`, `FLOW_LOG_TEXT=1`.

On macOS the app runs for development only: no clipboard access (in-memory clipboard), no key injection, hotkey only without `--no-hotkey`.

### Architecture

```
src/
  core/        pure TypeScript, unit-tested
    textCleaner.ts   fillers, dictionary, voice commands, tidy()      (port of TextCleaner.swift)
    quickPolish.ts   self-corrections, repeats, false starts, „erstens …“ lists, punctuation (QuickPolish.swift)
    smartLists.ts    automatic lists per target app                     (SmartLists.swift)
    tagger.ts        lexicon/morphology POS tagger replacing Apple's NLTagger
    pipeline.ts      applyRules → QuickPolish (same order as the Mac app)
    wer.ts           word error rate
  asr/         sherpa-onnx wrapper (Parakeet/Whisper + Silero VAD), model manifest, resumable checksummed downloader
  main/        Electron main: dictation controller, mic (hidden AudioWorklet page), pill + hub windows, tray,
               hotkey (uiohook-napi → HoldToTalk state machine), insert (clipboard + SendInput via koffi), updater, store/history
  preload/     contextBridge APIs (pill, hub, mic)
  renderer/    pill (canvas), hub (vanilla TS), mic capture page + worklet
  shared/      settings schema + migration, i18n (de/en), hub state type
  clipvault/   ClipVault module (separate agent) – contract in src/clipvault/INTERFACE.md
  meeting/     Notetaker: controller (Electron-free), recorder + capture backend, chunking, diarizer, merge, package/prompt,
               store/retention, call detection (registry), decoder, Claude CLI, i18n; main.ts = Electron glue (IPC, Ctrl+Alt+M, tray)
```

Dictation: hotkey down → mic capture starts (16 kHz mono) → key up → VAD trims/chunks → Parakeet → fillers/dictionary/commands →
polish rules (list style depends on the foreground app: Word/Outlook `•`, Obsidian/VS Code Markdown, chat apps only from 4 items) →
clipboard saved → text written → `Ctrl+V` via `SendInput` → previous clipboard restored after ~300 ms (unless „Diktat bleibt in der Zwischenablage“).

Parity with the Mac app is tested against `test/fixtures/mac-golden.json`: the Mac app's own regression sets (`PolishCases`, `ListCases`,
5 target apps each) run through the Mac rules binary (`npm run golden:mac`, macOS only) – the TypeScript port must produce the identical output.

### Releases

The update/release source is configured in **one place**: `release.config.json` (`owner`/`repo`, currently a placeholder).
CI (`.github/workflows/windows.yml`) builds the installer on every push to `windows/**`; pushing a tag `v*` publishes it to GitHub Releases,
where electron-updater picks it up.

## Licenses

Flow: MIT. Third-party: sherpa-onnx (Apache-2.0), NVIDIA Parakeet TDT 0.6B v3 (CC-BY-4.0, downloaded at runtime), pyannote segmentation-3.0
(MIT, downloaded at runtime), NVIDIA NeMo TitaNet-small (CC-BY-4.0, downloaded at runtime), OpenAI Whisper (MIT),
Silero VAD (MIT), uiohook-napi (MIT), koffi (MIT), Electron (MIT), Instrument Serif font (SIL OFL 1.1, `resources/fonts/OFL.txt`).
