// Agent-Prompt: fixed test cases (invented, no private data). Port of APTestSet.swift – the Mac bundle ids are replaced by
// the Windows process names of the same kind of app (VS Code → Code.exe, Terminal → WindowsTerminal.exe, Notes → Notepad …).

/** trigger sentences: [dictation, expected start of the rest | null = no trigger] */
export const TRIGGERS: [string, string | null][] = [
  ['Prompt: Bau mir eine Funktion, die CSV-Dateien einliest.', 'Bau mir eine Funktion'],
  ['Promt, bitte prüf die Tests im Ordner tests und mach sie grün.', 'Bitte prüf die Tests'],
  ['Brompt: fix den Bug im Login-Formular.', 'Fix den Bug'],
  ['Prompt. Recherchier, welche Vektor-Datenbanken es gibt.', 'Recherchier, welche'],
  ['Agent-Prompt: Refactor die Settings-Seite in drei Komponenten.', 'Refactor die Settings-Seite'],
  ['Agenten Prompt, schreib Tests für den Parser und lass sie laufen.', 'Schreib Tests für den Parser'],
  ['Prompt für den Agent: implementier den Export als PDF.', 'Implementier den Export'],
  ['Prompt für Claude Code: lösch nichts, aber räum den Ordner scripts auf.', 'Lösch nichts'],
  ['Prompt an den Agenten, check die Logs vom Server und fass die Fehler zusammen.', 'Check die Logs'],
  ['Ich mache jetzt einen Prompt. Es geht um die Upload-Seite, die bricht bei großen Dateien ab.', 'Es geht um die Upload-Seite'],
  ['Okay, ich mach jetzt mal einen Prompt für den Agenten: die App soll beim Start schneller laden.', 'Die App soll beim Start'],
  ['Also ich mache jetzt einen neuen Promt, bitte bau einen Dark Mode in die Einstellungen.', 'Bitte bau einen Dark Mode'],
  ['Ich diktier dir jetzt einen Prompt: prüf alle Links auf der Webseite.', 'Prüf alle Links'],
  ['Mach daraus einen Prompt: die Suche soll auch Tippfehler finden und Umlaute ignorieren.', 'Die Suche soll auch'],
  ['Die Suche soll auch Tippfehler finden und Umlaute ignorieren, mach daraus einen Prompt.', 'Die Suche soll auch'],
  ['Bau die Anmeldung mit Magic Link um und entfern das Passwortfeld. Mach mir bitte daraus einen Agent-Prompt.', 'Bau die Anmeldung'],
  ['Neuer Prompt: erstelle eine README mit Installationsanleitung.', 'Erstelle eine README'],
  ['Jetzt kommt ein Prompt: migrier die Datenbank auf Postgres 17.', 'Migrier die Datenbank'],
  ['Prompt fix den Crash beim Öffnen von leeren Dateien und schreib einen Test dazu.', 'Fix den Crash'],
  ['Prompt: Build a small CLI that renames photos by date.', 'Build a small CLI'],
  ['Agent prompt: add retry logic to the upload client with three attempts.', 'Add retry logic'],
  ["I'm going to make a prompt. Refactor the payment module and keep the public API.", 'Refactor the payment module'],
  ['Let me write a prompt for Claude: investigate why the build takes ten minutes.', 'Investigate why the build'],
  ['Please add dark mode to the settings page and make it follow the system. Turn this into a prompt.', 'Please add dark mode'],
  ["Here's a prompt: write unit tests for the date parser.", 'Write unit tests'],
  ['Prompt Mode: prüf, ob die Push-Benachrichtigungen auf dem iPhone ankommen.', 'Prüf, ob die Push'],
  // no trigger – sentences ABOUT prompts
  ['Prompt Engineering ist ein spannendes Thema für unseren Workshop.', null],
  ['Der Prompt war viel zu lang, deshalb hat es nicht geklappt.', null],
  ['Prompt ist ein englisches Wort.', null],
  ['Kannst du mir den Prompt von gestern nochmal schicken?', null],
  ['Prompt.', null],
  ['Ich finde, der Agent hat das gut gemacht.', null],
  ['Wir haben über Prompt Injection gesprochen und das war interessant.', null],
  ['Mach bitte Pizza zum Abendessen.', null],
  ['Prompt caching spart bei langen Anfragen viel Geld.', null],
  ['The prompt was too long for the model.', null],
  ['Prompts sind wie Rezepte, finde ich.', null],
];

export interface DetectCase { text: string; seconds: number; exe: string; title: string; offer: boolean; note: string }

export const VSC = 'Code.exe', TERM = 'WindowsTerminal.exe', CLAUDE = 'claude.exe', CHROME = 'chrome.exe', NOTES = 'Notepad.exe';
export const WA = 'WhatsApp.exe', MAIL = 'OUTLOOK.EXE', SLACK = 'slack.exe', WORD = 'WINWORD.EXE';

// long German tasks with English tech words (as spoken), without a trigger
export const LONG_DE1 = 'Okay also es geht um die Settings Page im Dashboard, die ist gerade echt langsam, wenn man die öffnet dauert das so drei Sekunden. Ich glaube das liegt an dem useEffect in der SettingsPanel.tsx, der lädt alle User auf einmal, das sind zwölftausend Einträge. Bau das bitte so um, dass nur die ersten fünfzig geladen werden und dann Infinite Scroll. Und prüf, ob der Endpoint slash api slash users einen limit Parameter hat, sonst ergänz den im Backend. Keine neuen Dependencies und die Tests müssen danach grün sein.';
export const LONG_DE2 = 'Also ich brauch mal was, und zwar sollen die Meeting Notizen nach dem Export als Markdown Datei gespeichert werden und nicht mehr als JSON. Schau dir die Funktion exportMeeting an, die liegt in der Datei MeetingExport.swift. Die Überschriften sollen H2 sein, die Sprecher fett, und am Ende soll das komplette Transkript stehen. Bitte achte darauf, dass alte Exporte weiter geöffnet werden können und schreib einen Test dafür.';
export const LONG_DE3 = 'Ja also, ich hab gemerkt, dass der Build auf GitHub seit gestern kaputt ist, irgendwas mit dem Swift Compiler und einer fehlenden Datei. Kannst du bitte die Logs vom letzten Run durchgehen, die Ursache finden und fixen. Wenn es an der Xcode Version liegt, dann stell die Pipeline auf die neue Version um. Committe aber nichts, ich will mir den Diff erst selbst anschauen, und lösch keine Dateien.';
export const LONG_DE4 = 'Recherchier bitte mal, welche Möglichkeiten es gibt, Sprachmodelle lokal auf dem Mac laufen zu lassen, also mit MLX oder llama.cpp oder so. Mich interessiert vor allem, wie schnell die auf einem M4 Pro sind, wie viel RAM die brauchen und ob man die per API aus Swift ansprechen kann. Mach mir am Ende eine Tabelle mit den drei besten Optionen und den Quellen dazu.';
export const LONG_DE5 = 'Die Rechnung im Portal wird falsch berechnet, wenn der Kunde Rabatt hat, dann wird der Rabatt zweimal abgezogen. Das passiert in der Funktion calculateTotal in invoice.service.ts glaube ich. Fix das bitte, und ergänz einen Unit Test mit einem Rabatt von zehn Prozent und einem Betrag von hundertneunundneunzig Euro. Die Oberfläche soll sich dabei nicht ändern und die Datenbank auch nicht.';
export const LONG_DE6 = 'So, nächster Schritt für die App: ich will, dass man in der Liste mit der Maus Einträge per Drag and Drop sortieren kann, und die Reihenfolge soll gespeichert werden. Implementier das in der SwiftUI View, nutz am besten die eingebauten Modifier und keine neue Library. Prüf auch, dass das mit der Tastatur geht, also mit Pfeiltasten, und dass Voice Over die neue Position ansagt.';
export const LONG_DE7 = 'Kannst du dir bitte das Repo anschauen und mir sagen, warum der Server nach ein paar Stunden so viel Speicher frisst. Ich vermute ein Memory Leak im Cache Modul, da wird irgendwie nie was gelöscht. Untersuch das mit einem Profiler, schreib auf was du findest, und wenn du dir sicher bist, bau einen Fix mit einer maximalen Cache Größe von fünfhundert Einträgen.';
export const LONG_DE8 = 'Die Upload Funktion soll auch Videos können, also mp4 und mov bis zwei Gigabyte. Dafür müsste man das Hochladen in Stücke teilen, Chunked Upload, und bei Abbruch weitermachen können. Schau dir an wie das Backend das gerade macht und pass beide Seiten an. Achte darauf, dass die bestehenden Bilder Uploads nicht kaputt gehen und dass es einen Fortschrittsbalken gibt.';
// English
export const LONG_EN1 = "So the onboarding flow is kind of broken right now, when a new user signs up they don't get the welcome email and the profile page shows an empty state forever. Please check the signup handler in auth controller, make sure the email job is queued, and add a loading state to the profile page. Don't touch the billing code and make sure all tests pass before you stop.";
export const LONG_EN2 = 'I need you to research how other apps handle offline sync for notes, like conflict resolution with CRDTs versus last write wins. Look at a few open source projects, summarize the trade-offs, and then propose an approach for our Swift app with Core Data. Write it up as a short design doc with a recommendation and the open risks.';

const D = (text: string, seconds: number, exe: string, title: string, offer: boolean, note: string): DetectCase => ({ text, seconds, exe, title, offer, note });

export const DETECTION: DetectCase[] = [
  // positive: long tasks
  D(LONG_DE1, 42, VSC, 'SettingsPanel.tsx - admin-dashboard - Visual Studio Code', true, 'VS Code, Refactor'),
  D(LONG_DE1, 42, CHROME, 'Jira - Google Chrome', true, 'Browser, trotzdem klarer Auftrag'),
  D(LONG_DE2, 38, TERM, 'claude', true, 'Terminal'),
  D(LONG_DE2, 38, NOTES, '', true, 'Editor-App, aber klarer Auftrag'),
  D(LONG_DE3, 35, CLAUDE, 'Claude', true, 'Claude-App'),
  D(LONG_DE3, 35, WORD, 'Dokument', true, 'Word'),
  D(LONG_DE4, 33, CHROME, 'Claude - Google Chrome', true, 'Claude im Browser'),
  D(LONG_DE4, 33, VSC, 'README.md', true, 'Recherche-Auftrag'),
  D(LONG_DE5, 36, VSC, 'invoice.service.ts', true, 'Bugfix'),
  D(LONG_DE5, 36, SLACK, '#dev', true, 'Slack, klarer Auftrag'),
  D(LONG_DE6, 34, 'Cursor.exe', 'Cursor', true, 'Cursor'),
  D(LONG_DE6, 34, NOTES, '', true, 'Feature'),
  D(LONG_DE7, 31, 'pwsh.exe', 'PowerShell', true, 'PowerShell'),
  D(LONG_DE7, 31, CHROME, 'GitHub', true, 'Browser'),
  D(LONG_DE8, 33, VSC, 'upload.ts', true, 'Feature'),
  D(LONG_DE8, 33, 'ChatGPT.exe', 'ChatGPT', true, 'ChatGPT'),
  D(LONG_EN1, 30, VSC, 'auth.controller.ts', true, 'EN Bugfix'),
  D(LONG_EN1, 30, CHROME, 'Linear', true, 'EN Browser'),
  D(LONG_EN2, 29, CLAUDE, 'Claude', true, 'EN Recherche'),
  D(LONG_EN2, 29, NOTES, '', true, 'EN Design-Doc'),
  D('Bitte fix den Fehler in der Datei Parser.swift, da wird bei leeren Zeilen ein Crash ausgelöst, und schreib einen Test dafür. Danach lass alle Tests laufen und sag mir, ob alles grün ist. Ändere dabei nichts an der öffentlichen API und benenn keine Funktionen um, weil andere Module die benutzen. Wenn du unsicher bist, frag lieber nach bevor du etwas löschst.',
    26, TERM, 'claude', true, 'Terminal, 60 Wörter'),
  D('Also im Terminal Projekt sollen die Logs rotiert werden, maximal zehn Dateien mit je fünf Megabyte, und alte sollen gezippt werden. Bau das in das Logging Modul ein und prüf, dass beim Neustart nichts verloren geht. Das Ganze bitte ohne neue Dependencies und mit einem kurzen Test, der das Rotieren mit kleinen Dateien simuliert, damit wir sehen dass es klappt.',
    28, 'wezterm-gui.exe', '~/projekt', true, 'WezTerm'),
  // negative: short
  D('Bau mir eine Funktion, die CSV einliest.', 3, VSC, 'main.swift', false, 'kurz, obwohl Auftrag'),
  D('Fix den Bug im Login.', 2, TERM, 'claude', false, 'kurz im Terminal'),
  D('Ja, mach das so, passt.', 2, TERM, 'claude', false, 'Antwort an Claude'),
  D('Kannst du die Tests nochmal laufen lassen und mir sagen was rot ist?', 5, TERM, 'claude', false, 'kurze Rückfrage'),
  D('Okay danke, das sieht gut aus. Committe das bitte noch nicht.', 4, TERM, 'claude', false, 'kurz'),
  D('Please fix the typo in the README.', 3, VSC, 'README.md', false, 'EN kurz'),
  // negative: chatting/messages/mails, also long
  D('Hey, na wie geht\'s dir? Ich wollte nur kurz sagen, dass wir am Samstag doch nicht grillen, weil das Wetter so schlecht werden soll. Vielleicht können wir stattdessen am Sonntag zum Frühstück kommen, Mama hat gefragt ob du Brötchen mitbringen kannst. Sag mir einfach Bescheid, was dir besser passt, und liebe Grüße an alle zu Hause.',
    30, WA, 'Familie', false, 'WhatsApp Plaudern'),
  D('Hallo Frau Becker, vielen Dank für Ihre schnelle Rückmeldung. Ich würde den Termin gerne auf Donnerstag um vierzehn Uhr verschieben, falls das bei Ihnen noch passt. Die Unterlagen schicke ich Ihnen bis Mittwoch per Mail, dann können wir alles in Ruhe durchgehen. Bitte geben Sie mir kurz Bescheid, ob das so klappt. Viele Grüße und einen schönen Tag noch.',
    32, MAIL, 'Termin', false, 'E-Mail'),
  D('Gestern war ich mit Jonas im Kino und danach waren wir noch essen, das war echt schön. Der Film war ein bisschen zu lang, aber die Musik war richtig gut und die Bilder auch. Am Wochenende wollen wir vielleicht nochmal los, falls du Lust hast kannst du gerne mitkommen, ich sag dir dann Bescheid wann genau. Bis später und hab einen schönen Abend.',
    31, WA, 'Jonas', false, 'Erzählung'),
  D('Liebe Oma, alles Gute zum Geburtstag! Wir denken ganz fest an dich und freuen uns schon, dich an Weihnachten wiederzusehen. Die Kinder haben dir ein Bild gemalt, das bringen wir dann mit. Pass gut auf dich auf und genieß deinen Tag mit Kuchen und Kaffee. Ganz liebe Grüße von uns allen, hab dich lieb und bis bald.',
    28, MAIL, 'Geburtstag', false, 'Glückwunsch'),
  D('Also heute im Vortrag ging es um Geduld und darum, dass man nicht alles sofort haben muss. Ich fand den Gedanken schön, dass Warten auch eine Zeit ist, in der etwas wächst. Danach wurden drei neue Lieder gespielt und eins davon hat mir besonders gefallen, das mit der ruhigen Klavier Strophe am Anfang. Ich will mir das Lied nächste Woche nochmal anhören.',
    33, NOTES, '', false, 'Notiz, Erzählung'),
  D('Einkaufsliste für morgen: Milch, Eier, Brot, Tomaten, Käse, Nudeln, Olivenöl, Bananen, Äpfel, Joghurt, Kaffee, Butter, Mehl, Zucker, Hefe, Salz, Pfeffer, Zwiebeln, Knoblauch, Paprika, Gurke, Salat, Reis, Linsen, Haferflocken, Honig, Marmelade, Orangensaft, Wasser, Toilettenpapier, Spülmittel, Müllbeutel, Zahnpasta und Duschgel.',
    27, NOTES, '', false, 'Liste'),
  D('Ich hab heute beim Joggen gemerkt, dass ich viel entspannter bin, wenn ich morgens nicht gleich aufs Handy schaue. Das will ich jetzt öfter so machen, vielleicht erst nach dem Frühstück die Nachrichten lesen. Mal schauen ob ich das durchhalte, letzte Woche hat es ja schon zwei Tage geklappt und das Gefühl war richtig gut, irgendwie freier und ruhiger.',
    30, NOTES, '', false, 'Tagebuch'),
  D('Hey Tobi, kannst du morgen bitte die Kamera mitbringen und die Akkus laden? Wir wollen um neun los, damit wir das Licht am Morgen noch mitnehmen. Ich hol dich dann ab und wir fahren zusammen zur Location, Kaffee bring ich mit. Wenn was dazwischen kommt, schreib mir einfach kurz. Freu mich schon, das wird richtig gut, bis morgen dann.',
    29, WA, 'Tobi', false, 'Chat mit Bitte'),
  D('So I was thinking about our trip next month, maybe we could stay two more days in Lisbon and skip Porto this time. The weather should be great and there are a few restaurants I really want to try. Let me know what you think and whether your boss is fine with the extra days off. Miss you and talk soon, love you.',
    27, WA, 'Anna', false, 'EN Chat'),
  D("Dear team, thanks everyone for a great quarter. We shipped the new dashboard, grew the user base and kept the support queue short. I'm really proud of how we worked together, especially during the release week. Enjoy the long weekend, get some rest, and let's meet on Tuesday for a relaxed kickoff with breakfast. Best regards and cheers to all of you.",
    30, MAIL, 'Danke', false, 'EN Rundmail'),
  D('Die Rede nächste Woche soll über Hoffnung gehen, ich möchte mit der Geschichte von Noah anfangen und dann zu der Frage kommen, wie man in schweren Zeiten dranbleibt. Am Ende vielleicht ein Dank und ein ruhiges Lied, damit die Leute Zeit haben nachzudenken. Ich schreib mir die drei Hauptpunkte auf und überleg mir noch ein persönliches Beispiel dazu.',
    34, WORD, 'Rede', false, 'lang, ohne Technik'),
  D('Also heute war ein langer Tag im Büro, wir hatten drei Meetings hintereinander und dann noch einen Anruf mit dem Kunden. Irgendwie hat der Tag nicht gereicht und ich bin mit meiner Liste nicht fertig geworden. Morgen will ich früher anfangen und mir erstmal zwei Stunden ohne Mails nehmen, das hat letzte Woche gut funktioniert und ich war danach viel entspannter.',
    31, NOTES, '', false, 'Erzählung Büro'),
  D('Hallo zusammen, kurze Info für heute Abend: das Training fällt aus, weil die Halle gesperrt ist. Wir holen es am Donnerstag nach, gleiche Uhrzeit, gleicher Ort. Bitte gebt kurz Bescheid, ob ihr dabei seid, damit ich die Mannschaften einteilen kann. Und denkt an eure Trikots für das Spiel am Samstag, das ist diesmal auswärts. Viele Grüße und bis Donnerstag.',
    30, WA, 'Team', false, 'Vereins-Chat'),
  D('Lorem ipsum wie das Wetter heute war, es hat den ganzen Morgen geregnet und erst am Nachmittag kam die Sonne raus. Wir sind dann noch kurz am See spazieren gegangen, die Enten waren alle am Ufer und haben auf Brot gewartet. Abends gab es Suppe und danach haben wir einen Film geschaut, der war ganz nett, aber etwas vorhersehbar.',
    29, '', '', false, 'unbekannte App, Erzählung'),
];

// fallback without AI: details must survive
export const FALLBACK_DE = 'Okay also ich mache jetzt mal. Es geht um die Settings Page, die lädt drei Sekunden. Bau das bitte so um, dass nur die ersten 50 User geladen werden, nein warte, lieber die ersten 100. Prüf, ob der Endpoint /api/users in users.controller.ts einen limit Parameter hat. Keine neuen Dependencies und fass das Styling von Lisa nicht an. Die Tests mit npm run test müssen danach grün sein. Ich weiß nicht genau, ob wir den Suchfilter auch serverseitig machen sollen.';
export const FALLBACK_EN = "So basically the export is broken. Please add a CSV export to ReportView.swift with the columns date, amount and category. Don't change the PDF export. Make sure the tests pass. I'm not sure if we need Excel support too.";

// sample prompts (as Claude writes them) – for tests, renders and the hub demo
export const SAMPLE_PROMPT_DE = `**Ziel:** Die Settings Page im Dashboard schneller machen, indem statt aller User nur die ersten 50 geladen und per Infinite Scroll nachgeladen werden.

## Kontext
- Fenster: SettingsPanel.tsx - admin-dashboard (Visual Studio Code)
- Die Seite braucht beim Öffnen ca. 3 Sekunden; der \`useEffect\` in \`SettingsPanel.tsx\` lädt alle ca. 12.000 User auf einmal.

## Aufgabe
1. Baue das Laden in \`SettingsPanel.tsx\` so um, dass zunächst nur die ersten 50 User geladen werden.
2. Implementiere Infinite Scroll zum Nachladen (keine klassische Pagination).
3. Prüfe, ob \`/api/users\` einen \`limit\`-Parameter unterstützt.
4. Falls nicht: ergänze ihn im Backend in \`users.controller.ts\`.
5. Führe \`npm run test\` aus.

## Akzeptanzkriterien
- Beim Öffnen werden nur 50 User geladen, weitere beim Scrollen.
- \`/api/users\` akzeptiert \`limit\`.
- \`npm run test\` ist komplett grün.

## Regeln
- Keine neuen Dependencies (kein react-query).
- Styling nicht anfassen (hat Lisa gerade gemacht).

## Offene Punkte
- Soll der Suchfilter auch serverseitig laufen?`;

export const SAMPLE_PROMPT_EN = `**Goal:** Add retry logic to the upload client.

## Task
1. Retry failed uploads up to 3 times with exponential backoff.
2. Keep the public API of \`UploadClient\` unchanged.

## Acceptance criteria
- A failing upload is retried 3 times, then reported.
- All tests pass.`;

export const SAMPLE_ORIGINAL_DE = 'Okay also es geht um die Settings Page in unserem Dashboard, die ist gerade echt langsam, wenn man die öffnet dauert das so drei Sekunden bis überhaupt was kommt. Ich glaube das liegt an dem useEffect in der SettingsPanel.tsx, der lädt irgendwie alle User auf einmal, das sind so zwölftausend Einträge. Bau das bitte so um, dass nur die ersten fünfzig geladen werden und dann Pagination, nein warte, lieber Infinite Scroll. Und prüf auch mal ob der API Endpoint slash api slash users überhaupt einen limit Parameter hat. Keine neuen Dependencies und fass das Styling nicht an, das hat Lisa gerade gemacht.';
