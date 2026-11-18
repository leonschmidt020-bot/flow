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

## Mit Freunden teilen und Fehlerberichte

Mit ClipVault könnt ihr einen **geteilten Tresor** haben: Was einer teilt, haben alle anderen sofort – verschlüsselt,
egal ob Windows oder Mac.

1. Jemand, der schon im Tresor ist, erzeugt in seinem ClipVault einen **Kopplungscode** (beginnt mit `cvpair1.`) und
   schickt ihn dir privat. Der Code gilt 15 Minuten.
2. Bei dir das **Flow-Fenster** öffnen (Flow-Symbol unten rechts → **Flow öffnen**) und oben links neben „Flow“ auf das
   **ClipVault-Symbol** klicken (oder links **ClipVault**). Dann links **Geteilt**.
3. Dort steht **Mit dem Team verbinden**: Code ins Feld einfügen (Strg + V) → **Koppeln**. Sync schaltet sich dabei
   selbst ein. Nach ein paar Sekunden steht oben **verbunden (live)**. Eine Adresse musst du nicht eintragen – sie
   steckt im Code.
4. Unter ClipVault → **Einstellungen** → **Teilen & Sync** bei **Mein Name** deinen Vornamen eintragen – so sehen die
   anderen, wer etwas geteilt hat. Dort kannst du auch selbst **weitere Personen einladen** (Code erzeugen) oder dich
   **vom Tresor trennen**.

Unter **Geteilt** kannst du oben nach Person filtern (Alle · die einzelnen Namen · Von mir).

**Fehlerberichte:** Wenn du willst, dass dir jemand aus dem Tresor helfen kann, wenn Flow hakt: Flow-Fenster →
Einstellungen → **Fehlerberichte** → **Fehlerberichte automatisch an den geteilten Tresor senden** einschalten.
Geschickt werden nur Version, Windows-Version, Prozessor, Taste, Mikrofonname, eine Prüfliste und Zeilen aus dem
Flow-Protokoll (dein Benutzername wird dabei durch `<user>` ersetzt) – **nie** was du diktierst, **nie** deine
Zwischenablage. Mit **Jetzt senden** (auch im Menü am Flow-Symbol unten rechts: **Fehlerbericht jetzt senden**)
schickst du sofort einen.

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

## Etwas automatisch ins Team schicken (Ausgang-Ordner)
Alles, was in den Ordner `%APPDATA%\Flow\clipvault\outbox\` gelegt wird, teilt Flow nach 1–3 Sekunden automatisch in den geteilten Tresor:
- `.txt` und `.md` werden als Text geteilt.
- Alle anderen Dateien werden als Datei geteilt.

Danach wandert die Datei nach `outbox\sent\`. So kann z. B. ein Coding-Agent auf diesem PC Nachrichten, Berichte oder Dateien an das Team schicken, ohne dass jemand klickt. Voraussetzung: ClipVault ist mit einem Tresor gekoppelt („verbunden (live)“).
