# Flow auf Windows installieren – Schritt für Schritt

Flow schreibt auf, was du sagst: Taste halten, sprechen, loslassen – der Text steht dort, wo dein Cursor ist.
Kostenlos, ohne Konto, die Spracherkennung läuft nur auf deinem PC. Du brauchst Windows 10 oder 11 und einmalig
Internet (etwa 600 MB Download). Dauer: rund 5 Minuten.

## 1. Herunterladen

1. Öffne **https://github.com/leonschmidt020-bot/flow/releases/latest**
2. Klicke unten bei „Assets“ auf **`Flow-Setup-….exe`** (die Datei mit etwa 114 MB).

**Der Browser warnt?** Das ist normal: Flow ist noch neu und nicht bei Microsoft registriert.

- **Edge** („… wird häufig nicht heruntergeladen“): oben rechts auf die Downloads klicken (oder **Strg + J**) → bei der
  Datei auf **…** → **Beibehalten** → **Mehr anzeigen** → **Trotzdem beibehalten**.
- **Chrome**: bei der Warnung auf **Beibehalten** klicken.

## 2. Installieren

1. Doppelklick auf die heruntergeladene Datei.
2. Kommt das blaue Fenster **„Der Computer wurde durch Windows geschützt“**: auf **Weitere Informationen** klicken, dann
   auf **Trotzdem ausführen**.
3. Flow installiert sich selbst und startet. Administrator-Rechte sind nicht nötig.

## 3. Einmal warten: das Sprachmodell

Beim ersten Start lädt Flow das Sprachmodell (etwa 490 MB). Den Fortschritt siehst du im Flow-Fenster. Warte, bis
**„Sprachmodell bereit“** erscheint – vorher geht das Diktieren noch nicht. Danach funktioniert alles ohne Internet.

## 4. Mikrofon erlauben

Fragt Windows nach dem Mikrofon, klicke auf **Ja / Zulassen**.

## 5. Diktieren

1. Klicke in ein Textfeld, zum Beispiel im Editor, in WhatsApp oder im Browser.
2. **Rechte Strg-Taste gedrückt halten**, sprechen, loslassen. Der Text erscheint.

**Dein Laptop hat rechts keine Strg-Taste** (dort sitzt oft die Copilot-Taste)? Dann öffne Flow → **Einstellungen** und
wähle als Taste **Strg + Win** oder **Alt Gr**. Drückst du die Copilot-Taste, bietet Flow die Umstellung auch selbst an.

Zweimal kurz auf die Taste tippen startet freihändiges Diktieren, noch einmal drücken beendet es. **Esc** bricht ab.

## Wo ist Flow?

- Unten rechts in der Taskleiste beim kleinen Pfeil **^**: das Flow-Symbol. Klick darauf öffnet das Fenster.
- Unten in der Bildschirmmitte: ein kleiner dunkler Strich, die „Pille“. Sie zeigt, wann Flow zuhört. Du kannst sie
  anklicken und an eine andere Stelle ziehen.
- **Strg + Umschalt + V** öffnet ClipVault, den Verlauf deiner Zwischenablage.

## Wenn etwas nicht geht

| Problem | Lösung |
|---|---|
| Es kommt kein Text | Steht im Flow-Fenster „Sprachmodell bereit“? Wenn nicht: warten, bis der Download fertig ist. |
| Immer noch kein Text | Windows-Einstellungen → Datenschutz und Sicherheit → Mikrofon → **Mikrofonzugriff** und **Desktop-Apps den Zugriff erlauben** einschalten. |
| Die Taste macht nichts | Flow → Einstellungen → andere Taste wählen (Strg + Win, Alt Gr oder F8). |
| Falsches Mikrofon (Headset) | Flow → Einstellungen → Mikrofon auswählen. |
| Text wird schlecht erkannt | Näher ans Mikrofon, Mikrofon-Lautstärke in Windows auf 80–100 %. |
| In einem Programm kommt nichts an | Programme, die „als Administrator“ laufen, nehmen den Text nicht an. Normal starten. |

Updates holt Flow selbst und installiert sie, wenn du Flow beendest. Entfernen: Windows-Einstellungen → Apps → Flow.
