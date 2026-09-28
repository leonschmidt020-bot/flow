# Flow for Windows

**Flow** is a free, open-source voice dictation app. Hold a key, speak, let go – the text appears wherever your cursor is.
Speech recognition runs **100 % on your PC**: no cloud, no account, no telemetry.

> Flow is an independent project and is **not affiliated with Wispr** or Wispr Flow.

- Speech recognition: NVIDIA **Parakeet TDT 0.6B v3** (German, English + 23 more languages, detected automatically) via [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx). Optional: **Whisper large-v3-turbo**.
- Silero VAD trims silence and splits long dictations.
- Hold **Right Ctrl** (or Ctrl + Win, Right Alt, F6–F12). **Double-tap** for hands-free.
- Polish rules ported 1:1 from the Mac app: self-corrections („… nein warte, am Freitag“), repeats, false starts, lists („erstens … zweitens …“, shopping lists, steps, to-dos), punctuation.
- Voice commands „neue Zeile“ / „neuer Absatz“ (“new line”, “new paragraph”), filler words („ähm“, „äh“) removed.
- **„Text dorthin, wo die Maus ist“** (*Text goes where the mouse is*, off by default): hold the key, speak, point at any
  window – on release the text lands there without clicking into it first. A blue frame **„Text kommt hierher“** (*Text goes
  here*) follows the mouse while you speak (can be switched off). Optional **„Danach automatisch abschicken (Enter)“** (*Send
  automatically afterwards*, off by default) – only in terminals, Claude Code and chat inputs, never in documents or the code editor.
- **Word learner – „Wort gelernt?“** (*Learned a word?*, on by default): change a dictated word in the field (e.g. „Klot“ →
  „Claude“) and the pill offers **„Ins Wörterbuch“** (with choices when ambiguous) or **„Nein“**. Works in text fields, Windows
  Terminal/conhost and Claude Code's input box (also after the message was sent). Grammar fixes (case at the word start,
  endings, „zur“ → „zu“) are ignored; password fields and password managers are never read.
- Hub window: **Verlauf** (history with copy), **Wörterbuch** (your words/replacements), **ClipVault** (clipboard history), **Einstellungen**.
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

## Data

Everything is stored in `%APPDATA%\Flow` (`app.getPath('userData')`):

| file | content |
|---|---|
| `settings.json` (+ `.bak`) | settings incl. dictionary – atomic writes (temp + rename), last good copy as `.bak` |
| `history.json` (+ `.bak`) | dictation history (deleted after the retention period) |
| `models/` | speech models + Silero VAD |
| `clipvault/` | ClipVault data (see `src/clipvault/`) |
| `logs/flow.log` | local log without dictated text (mouse target: app, method, extra ms – no text, no window titles) |

## Development

```bash
cd windows
npm ci
npm run lint          # eslint + tsc
npm test              # vitest: polish/lists parity with the Mac app, commands, dictionary, settings migration, store, hotkey, inserter, downloader …
npm run test:asr      # downloads Parakeet into .cache/models and transcribes test/fixtures/asr/*.wav, checks WER
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

  core/mouseTarget.ts   mouse target rules: window filter, DPI/coordinate maths, click-allowed, auto-Enter list  (MouseTargetRules.swift)
  core/learner.ts       word learner rules: locate/anchor, Tracker, grammar vs. mishearing, suggestions          (CorrectionLearner.swift)
  core/terminalPrompt.ts  terminal rows → Claude Code input box / sent messages                                  (TerminalPrompt.swift)
  main/mouse/     MouseTarget orchestration (capture at release → foreground → a/c/b/d → paste → Enter), koffi layer, frame window
  main/learn/     CorrectionLearner service (watch ≤ 3 min, 1.5 s readings, finish on the next dictation)
  main/uia/       UI Automation client + flow-uia.ps1 helper (one long-lived powershell.exe, JSON lines)
```

### „Text dorthin, wo die Maus ist“ and the word learner (Windows)

*Mouse target.* Hotkey pressed → the frame follows the window under the mouse (~8 Hz). Hotkey **released** → that window
counts (`WindowFromPoint` → `GetAncestor(GA_ROOT)`; own, tool, click-through and cloaked windows are looked through, desktop/
taskbar/start menu mean „no target“). While speech recognition runs, UI Automation is asked what lies under the mouse. Before
pasting: already the foreground window → nothing to do (method 0). Otherwise `SetForegroundWindow` (right after our own hook saw
the key release) → `AttachThreadInput` to the foreground thread → ALT tap, each verified with `GetForegroundWindow`, ≤ 400 ms in
total. Then: a) text field under the mouse → UI Automation `SetFocus`; c) terminal/chat input → one click at the release point,
only if `WM_NCHITTEST` says `HTCLIENT` and UI Automation sees no button/link/tab there; b) otherwise the window's remembered
focus; d) failed → paste normally with a toast. Auto-Enter only after a confirmed paste and only in terminals, VS Code's terminal/
chat inputs, chat apps and browser tabs whose title is a web chat (ChatGPT, Claude, Gemini, WhatsApp Web …).

*Word learner.* After each paste Flow reads the focused element via UI Automation (value / text around the caret; Windows
Terminal and conhost: visible rows; VS Code & co.: xterm.js's accessibility rows) every 1.5 s for up to 3 minutes, and asks when the
same change stood for three readings or editing is over (sent, new dictation, text gone). Accepted pairs are stored as normal
dictionary replacements (Windows' recognisers take no vocabulary hints, so there is no „hint only“ entry as on the Mac).

*UI Automation helper.* `flow-uia.ps1` runs in one `powershell.exe` (hidden, started on first use, stopped after 5 idle
minutes) using .NET's `System.Windows.Automation` – no compiled binary, and a slow or hung app can never freeze Flow's main process
(requests time out and the helper is restarted). If PowerShell is blocked (Constrained Language Mode/AppLocker) both features fall
back to what works without it (no field focus, no learning).

*What only a real Windows PC can verify* (everything above is unit-tested with mocks; the native parts were written without
running on Windows): the koffi calls (`WindowFromPoint`, DWM cloaking/frame bounds, `SendMessageTimeout(WM_NCHITTEST)`,
`AttachThreadInput`, the ALT tap, `SendInput` mouse click); whether the foreground switch succeeds within 400 ms on Windows 10/11;
the helper start-up (execution policy, Add-Type, per-monitor DPI) and what Windows Terminal, conhost, VS Code (xterm rows only with
screen-reader support on), Chromium chat apps and Word expose through UI Automation; the frame position on mixed-DPI
multi-monitor setups.

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

Flow: MIT. Third-party: sherpa-onnx (Apache-2.0), NVIDIA Parakeet TDT 0.6B v3 (CC-BY-4.0, downloaded at runtime), OpenAI Whisper (MIT),
Silero VAD (MIT), uiohook-napi (MIT), koffi (MIT), Electron (MIT), Instrument Serif font (SIL OFL 1.1, `resources/fonts/OFL.txt`).
