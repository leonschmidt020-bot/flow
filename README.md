# Flow – lokales Diktat + ClipVault

> Unabhängiges Open-Source-Projekt – **nicht verbunden mit Wispr AI / Wispr Flow**.

**Deutsch** · [English](#english)

**Flow** ist eine kostenlose Diktier-App: **Taste halten, sprechen, loslassen** – der Text steht dort, wo dein Cursor ist.
Die Spracherkennung läuft **komplett auf deinem Rechner** (kein Konto, keine Cloud, keine Telemetrie).
Dazu gehört **ClipVault**, ein Verlauf für die Zwischenablage mit Suche, Bildern, Anheften und Bereichen.

| | Mac | Windows |
|---|---|---|
| Diktat-Taste | **fn** halten (doppelt tippen = freihändig) | **rechte Strg** halten (doppelt tippen = freihändig) |
| Spracherkennung | Parakeet (CoreML), optional Whisper | Parakeet v3 (sherpa-onnx), optional Whisper |
| ClipVault | ⌘⇧V | Strg+Umschalt+V |
| Voraussetzung | macOS 26+, Apple Silicon | Windows 10/11, 64-Bit |
| Code | [`mac/`](mac/README.md) (Swift) | [`windows/`](windows/README.md) (Electron + TypeScript) |

## Installieren

**Windows:** Auf der [Releases-Seite](https://github.com/leonschmidt020-bot/flow/releases) `Flow-Setup-….exe` laden und starten.
Der Installer ist (noch) nicht signiert – wenn SmartScreen warnt: **Weitere Informationen → Trotzdem ausführen**.
Beim ersten Start lädt Flow das Sprachmodell einmalig (~490 MB), danach geht alles offline.
Details: [windows/README.md](windows/README.md).

**Mac:** Im Terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/leonschmidt020-bot/flow/main/mac/install-mac.sh | bash
```

Das Skript prüft macOS-Version und Xcode-Werkzeuge, baut beide Apps und startet die Einrichtung (Mikrofon, Bedienungshilfen).
Details, Voraussetzungen und Deinstallation: [mac/README.md](mac/README.md).

## Datenschutz

- Alles bleibt auf deinem Rechner: Audio, Texte, Verlauf, Wörterbuch.
- Netz nur für den einmaligen Modell-Download und die Update-Prüfung (GitHub).
- ClipVault-**Teilen** mit einem Freund ist optional und standardmäßig **aus**. Es läuft Ende-zu-Ende verschlüsselt über einen
  **eigenen** kostenlosen Cloudflare Worker ([Anleitung](mac/clipvault/sync-worker/README.md)). Mac und Windows können
  denselben Tresor teilen.

## Lizenz

MIT – siehe [LICENSE](LICENSE).

---

## English

**Flow** is a free dictation app: **hold a key, speak, release** – the text appears wherever your cursor is. Speech recognition
runs **entirely on your computer** (no account, no cloud, no telemetry). It comes with **ClipVault**, a clipboard history with
search, images, pins and collections.

- **Windows:** download `Flow-Setup-….exe` from [Releases](https://github.com/leonschmidt020-bot/flow/releases) and run it
  (unsigned for now – SmartScreen: *More info → Run anyway*). Hold **Right Ctrl** to dictate. See [windows/README.md](windows/README.md).
- **Mac (macOS 26+, Apple Silicon):**
  `curl -fsSL https://raw.githubusercontent.com/leonschmidt020-bot/flow/main/mac/install-mac.sh | bash` – hold **fn** to dictate.
  See [mac/README.md](mac/README.md).
- Optional end-to-end encrypted ClipVault sharing via your own free Cloudflare Worker (off by default).

Flow is an independent project and is **not affiliated with Wispr**. License: MIT.
