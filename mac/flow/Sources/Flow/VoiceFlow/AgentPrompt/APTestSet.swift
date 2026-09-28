import Foundation

// MARK: - Agent-Prompt: feste Testfälle (erfunden, keine privaten Daten)

enum APTestSet {
    // Auslöser: (Diktat, erwarteter Rest-Anfang oder nil = kein Auslöser)
    static let triggers: [(String, String?)] = [
        ("Prompt: Bau mir eine Funktion, die CSV-Dateien einliest.", "Bau mir eine Funktion"),
        ("Promt, bitte prüf die Tests im Ordner tests und mach sie grün.", "Bitte prüf die Tests"),
        ("Brompt: fix den Bug im Login-Formular.", "Fix den Bug"),
        ("Prompt. Recherchier, welche Vektor-Datenbanken es gibt.", "Recherchier, welche"),
        ("Agent-Prompt: Refactor die Settings-Seite in drei Komponenten.", "Refactor die Settings-Seite"),
        ("Agenten Prompt, schreib Tests für den Parser und lass sie laufen.", "Schreib Tests für den Parser"),
        ("Prompt für den Agent: implementier den Export als PDF.", "Implementier den Export"),
        ("Prompt für Claude Code: lösch nichts, aber räum den Ordner scripts auf.", "Lösch nichts"),
        ("Prompt an den Agenten, check die Logs vom Server und fass die Fehler zusammen.", "Check die Logs"),
        ("Ich mache jetzt einen Prompt. Es geht um die Upload-Seite, die bricht bei großen Dateien ab.", "Es geht um die Upload-Seite"),
        ("Okay, ich mach jetzt mal einen Prompt für den Agenten: die App soll beim Start schneller laden.", "Die App soll beim Start"),
        ("Also ich mache jetzt einen neuen Promt, bitte bau einen Dark Mode in die Einstellungen.", "Bitte bau einen Dark Mode"),
        ("Ich diktier dir jetzt einen Prompt: prüf alle Links auf der Webseite.", "Prüf alle Links"),
        ("Mach daraus einen Prompt: die Suche soll auch Tippfehler finden und Umlaute ignorieren.", "Die Suche soll auch"),
        ("Die Suche soll auch Tippfehler finden und Umlaute ignorieren, mach daraus einen Prompt.", "Die Suche soll auch"),
        ("Bau die Anmeldung mit Magic Link um und entfern das Passwortfeld. Mach mir bitte daraus einen Agent-Prompt.", "Bau die Anmeldung"),
        ("Neuer Prompt: erstelle eine README mit Installationsanleitung.", "Erstelle eine README"),
        ("Jetzt kommt ein Prompt: migrier die Datenbank auf Postgres 17.", "Migrier die Datenbank"),
        ("Prompt fix den Crash beim Öffnen von leeren Dateien und schreib einen Test dazu.", "Fix den Crash"),
        ("Prompt: Build a small CLI that renames photos by date.", "Build a small CLI"),
        ("Agent prompt: add retry logic to the upload client with three attempts.", "Add retry logic"),
        ("I'm going to make a prompt. Refactor the payment module and keep the public API.", "Refactor the payment module"),
        ("Let me write a prompt for Claude: investigate why the build takes ten minutes.", "Investigate why the build"),
        ("Please add dark mode to the settings page and make it follow the system. Turn this into a prompt.", "Please add dark mode"),
        ("Here's a prompt: write unit tests for the date parser.", "Write unit tests"),
        ("Prompt Mode: prüf, ob die Push-Benachrichtigungen auf dem iPhone ankommen.", "Prüf, ob die Push"),
        // Keine Auslöser
        ("Prompt Engineering ist ein spannendes Thema für unseren Workshop.", nil),
        ("Der Prompt war viel zu lang, deshalb hat es nicht geklappt.", nil),
        ("Prompt ist ein englisches Wort.", nil),
        ("Kannst du mir den Prompt von gestern nochmal schicken?", nil),
        ("Prompt.", nil),
        ("Ich finde, der Agent hat das gut gemacht.", nil),
        ("Wir haben über Prompt Injection gesprochen und das war interessant.", nil),
        ("Mach bitte Pizza zum Abendessen.", nil),
        ("Prompt caching spart bei langen Anfragen viel Geld.", nil),
        ("The prompt was too long for the model.", nil),
        ("Prompts sind wie Rezepte, finde ich.", nil),
    ]

    struct D { let text: String; let seconds: Double; let bundle: String; let title: String; let offer: Bool; let note: String }

    static let vsc = "com.microsoft.VSCode", term = "com.apple.Terminal", claude = "com.anthropic.claudefordesktop"
    static let chrome = "com.google.Chrome", notes = "com.apple.Notes", wa = "net.whatsapp.WhatsApp", mail = "com.apple.mail"
    static let slack = "com.tinyspeck.slackmacgap", pages = "com.apple.iWork.Pages"

    // Lange deutsche Aufträge mit englischen Fachwörtern (wie gesprochen), ohne Auslöser
    static let longDE1 = "Okay also es geht um die Settings Page im Dashboard, die ist gerade echt langsam, wenn man die öffnet dauert das so drei Sekunden. Ich glaube das liegt an dem useEffect in der SettingsPanel.tsx, der lädt alle User auf einmal, das sind zwölftausend Einträge. Bau das bitte so um, dass nur die ersten fünfzig geladen werden und dann Infinite Scroll. Und prüf, ob der Endpoint slash api slash users einen limit Parameter hat, sonst ergänz den im Backend. Keine neuen Dependencies und die Tests müssen danach grün sein."
    static let longDE2 = "Also ich brauch mal was, und zwar sollen die Meeting Notizen nach dem Export als Markdown Datei gespeichert werden und nicht mehr als JSON. Schau dir die Funktion exportMeeting an, die liegt in der Datei MeetingExport.swift. Die Überschriften sollen H2 sein, die Sprecher fett, und am Ende soll das komplette Transkript stehen. Bitte achte darauf, dass alte Exporte weiter geöffnet werden können und schreib einen Test dafür."
    static let longDE3 = "Ja also, ich hab gemerkt, dass der Build auf GitHub seit gestern kaputt ist, irgendwas mit dem Swift Compiler und einer fehlenden Datei. Kannst du bitte die Logs vom letzten Run durchgehen, die Ursache finden und fixen. Wenn es an der Xcode Version liegt, dann stell die Pipeline auf die neue Version um. Committe aber nichts, ich will mir den Diff erst selbst anschauen, und lösch keine Dateien."
    static let longDE4 = "Recherchier bitte mal, welche Möglichkeiten es gibt, Sprachmodelle lokal auf dem Mac laufen zu lassen, also mit MLX oder llama.cpp oder so. Mich interessiert vor allem, wie schnell die auf einem M4 Pro sind, wie viel RAM die brauchen und ob man die per API aus Swift ansprechen kann. Mach mir am Ende eine Tabelle mit den drei besten Optionen und den Quellen dazu."
    static let longDE5 = "Die Rechnung im Portal wird falsch berechnet, wenn der Kunde Rabatt hat, dann wird der Rabatt zweimal abgezogen. Das passiert in der Funktion calculateTotal in invoice.service.ts glaube ich. Fix das bitte, und ergänz einen Unit Test mit einem Rabatt von zehn Prozent und einem Betrag von hundertneunundneunzig Euro. Die Oberfläche soll sich dabei nicht ändern und die Datenbank auch nicht."
    static let longDE6 = "So, nächster Schritt für die App: ich will, dass man in der Liste mit der Maus Einträge per Drag and Drop sortieren kann, und die Reihenfolge soll gespeichert werden. Implementier das in der SwiftUI View, nutz am besten die eingebauten Modifier und keine neue Library. Prüf auch, dass das mit der Tastatur geht, also mit Pfeiltasten, und dass Voice Over die neue Position ansagt."
    static let longDE7 = "Kannst du dir bitte das Repo anschauen und mir sagen, warum der Server nach ein paar Stunden so viel Speicher frisst. Ich vermute ein Memory Leak im Cache Modul, da wird irgendwie nie was gelöscht. Untersuch das mit einem Profiler, schreib auf was du findest, und wenn du dir sicher bist, bau einen Fix mit einer maximalen Cache Größe von fünfhundert Einträgen."
    static let longDE8 = "Die Upload Funktion soll auch Videos können, also mp4 und mov bis zwei Gigabyte. Dafür müsste man das Hochladen in Stücke teilen, Chunked Upload, und bei Abbruch weitermachen können. Schau dir an wie das Backend das gerade macht und pass beide Seiten an. Achte darauf, dass die bestehenden Bilder Uploads nicht kaputt gehen und dass es einen Fortschrittsbalken gibt."
    // Englisch
    static let longEN1 = "So the onboarding flow is kind of broken right now, when a new user signs up they don't get the welcome email and the profile page shows an empty state forever. Please check the signup handler in auth controller, make sure the email job is queued, and add a loading state to the profile page. Don't touch the billing code and make sure all tests pass before you stop."
    static let longEN2 = "I need you to research how other apps handle offline sync for notes, like conflict resolution with CRDTs versus last write wins. Look at a few open source projects, summarize the trade-offs, and then propose an approach for our Swift app with Core Data. Write it up as a short design doc with a recommendation and the open risks."

    static let detection: [D] = [
        // Positiv: lange Aufträge
        D(text: longDE1, seconds: 42, bundle: vsc, title: "SettingsPanel.tsx — admin-dashboard", offer: true, note: "VS Code, Refactor"),
        D(text: longDE1, seconds: 42, bundle: chrome, title: "Jira", offer: true, note: "Browser, trotzdem klarer Auftrag"),
        D(text: longDE2, seconds: 38, bundle: term, title: "claude", offer: true, note: "Terminal"),
        D(text: longDE2, seconds: 38, bundle: notes, title: "", offer: true, note: "Notizen-App, aber klarer Auftrag"),
        D(text: longDE3, seconds: 35, bundle: claude, title: "Claude", offer: true, note: "Claude-App"),
        D(text: longDE3, seconds: 35, bundle: pages, title: "Dokument", offer: true, note: "Pages"),
        D(text: longDE4, seconds: 33, bundle: chrome, title: "Claude - Google Chrome", offer: true, note: "Claude im Browser"),
        D(text: longDE4, seconds: 33, bundle: vsc, title: "README.md", offer: true, note: "Recherche-Auftrag"),
        D(text: longDE5, seconds: 36, bundle: vsc, title: "invoice.service.ts", offer: true, note: "Bugfix"),
        D(text: longDE5, seconds: 36, bundle: slack, title: "#dev", offer: true, note: "Slack, klarer Auftrag"),
        D(text: longDE6, seconds: 34, bundle: "com.todesktop.230313mzl4w4u92", title: "Cursor", offer: true, note: "Cursor"),
        D(text: longDE6, seconds: 34, bundle: notes, title: "", offer: true, note: "Feature"),
        D(text: longDE7, seconds: 31, bundle: "com.googlecode.iterm2", title: "zsh", offer: true, note: "iTerm"),
        D(text: longDE7, seconds: 31, bundle: chrome, title: "GitHub", offer: true, note: "Browser"),
        D(text: longDE8, seconds: 33, bundle: vsc, title: "upload.ts", offer: true, note: "Feature"),
        D(text: longDE8, seconds: 33, bundle: "com.openai.chat", title: "ChatGPT", offer: true, note: "ChatGPT"),
        D(text: longEN1, seconds: 30, bundle: vsc, title: "auth.controller.ts", offer: true, note: "EN Bugfix"),
        D(text: longEN1, seconds: 30, bundle: chrome, title: "Linear", offer: true, note: "EN Browser"),
        D(text: longEN2, seconds: 29, bundle: claude, title: "Claude", offer: true, note: "EN Recherche"),
        D(text: longEN2, seconds: 29, bundle: notes, title: "", offer: true, note: "EN Design-Doc"),
        D(text: "Bitte fix den Fehler in der Datei Parser.swift, da wird bei leeren Zeilen ein Crash ausgelöst, und schreib einen Test dafür. Danach lass alle Tests laufen und sag mir, ob alles grün ist. Ändere dabei nichts an der öffentlichen API und benenn keine Funktionen um, weil andere Module die benutzen. Wenn du unsicher bist, frag lieber nach bevor du etwas löschst.",
          seconds: 26, bundle: term, title: "claude", offer: true, note: "Terminal, 60 Wörter"),
        D(text: "Also im Terminal Projekt sollen die Logs rotiert werden, maximal zehn Dateien mit je fünf Megabyte, und alte sollen gezippt werden. Bau das in das Logging Modul ein und prüf, dass beim Neustart nichts verloren geht. Das Ganze bitte ohne neue Dependencies und mit einem kurzen Test, der das Rotieren mit kleinen Dateien simuliert, damit wir sehen dass es klappt.",
          seconds: 28, bundle: "com.mitchellh.ghostty", title: "~/projekt", offer: true, note: "Ghostty"),
        // Negativ: kurz
        D(text: "Bau mir eine Funktion, die CSV einliest.", seconds: 3, bundle: vsc, title: "main.swift", offer: false, note: "kurz, obwohl Auftrag"),
        D(text: "Fix den Bug im Login.", seconds: 2, bundle: term, title: "claude", offer: false, note: "kurz im Terminal"),
        D(text: "Ja, mach das so, passt.", seconds: 2, bundle: term, title: "claude", offer: false, note: "Antwort an Claude"),
        D(text: "Kannst du die Tests nochmal laufen lassen und mir sagen was rot ist?", seconds: 5, bundle: term, title: "claude", offer: false, note: "kurze Rückfrage"),
        D(text: "Okay danke, das sieht gut aus. Committe das bitte noch nicht.", seconds: 4, bundle: term, title: "claude", offer: false, note: "kurz"),
        D(text: "Please fix the typo in the README.", seconds: 3, bundle: vsc, title: "README.md", offer: false, note: "EN kurz"),
        // Negativ: Plaudern/Nachrichten/Mails, auch lang
        D(text: "Hey, na wie geht's dir? Ich wollte nur kurz sagen, dass wir am Samstag doch nicht grillen, weil das Wetter so schlecht werden soll. Vielleicht können wir stattdessen am Sonntag zum Frühstück kommen, Mama hat gefragt ob du Brötchen mitbringen kannst. Sag mir einfach Bescheid, was dir besser passt, und liebe Grüße an alle zu Hause.",
          seconds: 30, bundle: wa, title: "Familie", offer: false, note: "WhatsApp Plaudern"),
        D(text: "Hallo Frau Becker, vielen Dank für Ihre schnelle Rückmeldung. Ich würde den Termin gerne auf Donnerstag um vierzehn Uhr verschieben, falls das bei Ihnen noch passt. Die Unterlagen schicke ich Ihnen bis Mittwoch per Mail, dann können wir alles in Ruhe durchgehen. Bitte geben Sie mir kurz Bescheid, ob das so klappt. Viele Grüße und einen schönen Tag noch.",
          seconds: 32, bundle: mail, title: "Termin", offer: false, note: "E-Mail"),
        D(text: "Gestern war ich mit Jonas im Kino und danach waren wir noch essen, das war echt schön. Der Film war ein bisschen zu lang, aber die Musik war richtig gut und die Bilder auch. Am Wochenende wollen wir vielleicht nochmal los, falls du Lust hast kannst du gerne mitkommen, ich sag dir dann Bescheid wann genau. Bis später und hab einen schönen Abend.",
          seconds: 31, bundle: wa, title: "Jonas", offer: false, note: "Erzählung"),
        D(text: "Liebe Oma, alles Gute zum Geburtstag! Wir denken ganz fest an dich und freuen uns schon, dich an Weihnachten wiederzusehen. Die Kinder haben dir ein Bild gemalt, das bringen wir dann mit. Pass gut auf dich auf und genieß deinen Tag mit Kuchen und Kaffee. Ganz liebe Grüße von uns allen, hab dich lieb und bis bald.",
          seconds: 28, bundle: mail, title: "Geburtstag", offer: false, note: "Glückwunsch"),
        D(text: "Also heute im Vortrag ging es um Geduld und darum, dass man nicht alles sofort haben muss. Ich fand den Gedanken schön, dass Warten auch eine Zeit ist, in der etwas wächst. Danach wurden drei neue Lieder gespielt und eins davon hat mir besonders gefallen, das mit der ruhigen Klavier Strophe am Anfang. Ich will mir das Lied nächste Woche nochmal anhören.",
          seconds: 33, bundle: notes, title: "", offer: false, note: "Notiz, Erzählung"),
        D(text: "Einkaufsliste für morgen: Milch, Eier, Brot, Tomaten, Käse, Nudeln, Olivenöl, Bananen, Äpfel, Joghurt, Kaffee, Butter, Mehl, Zucker, Hefe, Salz, Pfeffer, Zwiebeln, Knoblauch, Paprika, Gurke, Salat, Reis, Linsen, Haferflocken, Honig, Marmelade, Orangensaft, Wasser, Toilettenpapier, Spülmittel, Müllbeutel, Zahnpasta und Duschgel.",
          seconds: 27, bundle: notes, title: "", offer: false, note: "Liste"),
        D(text: "Ich hab heute beim Joggen gemerkt, dass ich viel entspannter bin, wenn ich morgens nicht gleich aufs Handy schaue. Das will ich jetzt öfter so machen, vielleicht erst nach dem Frühstück die Nachrichten lesen. Mal schauen ob ich das durchhalte, letzte Woche hat es ja schon zwei Tage geklappt und das Gefühl war richtig gut, irgendwie freier und ruhiger.",
          seconds: 30, bundle: notes, title: "", offer: false, note: "Tagebuch"),
        D(text: "Hey Tobi, kannst du morgen bitte die Kamera mitbringen und die Akkus laden? Wir wollen um neun los, damit wir das Licht am Morgen noch mitnehmen. Ich hol dich dann ab und wir fahren zusammen zur Location, Kaffee bring ich mit. Wenn was dazwischen kommt, schreib mir einfach kurz. Freu mich schon, das wird richtig gut, bis morgen dann.",
          seconds: 29, bundle: wa, title: "Tobi", offer: false, note: "Chat mit Bitte"),
        D(text: "So I was thinking about our trip next month, maybe we could stay two more days in Lisbon and skip Porto this time. The weather should be great and there are a few restaurants I really want to try. Let me know what you think and whether your boss is fine with the extra days off. Miss you and talk soon, love you.",
          seconds: 27, bundle: wa, title: "Anna", offer: false, note: "EN Chat"),
        D(text: "Dear team, thanks everyone for a great quarter. We shipped the new dashboard, grew the user base and kept the support queue short. I'm really proud of how we worked together, especially during the release week. Enjoy the long weekend, get some rest, and let's meet on Tuesday for a relaxed kickoff with breakfast. Best regards and cheers to all of you.",
          seconds: 30, bundle: mail, title: "Danke", offer: false, note: "EN Rundmail"),
        D(text: "Die Rede nächste Woche soll über Hoffnung gehen, ich möchte mit der Geschichte von Noah anfangen und dann zu der Frage kommen, wie man in schweren Zeiten dranbleibt. Am Ende vielleicht ein Dank und ein ruhiges Lied, damit die Leute Zeit haben nachzudenken. Ich schreib mir die drei Hauptpunkte auf und überleg mir noch ein persönliches Beispiel dazu.",
          seconds: 34, bundle: pages, title: "Rede", offer: false, note: "lang, ohne Technik"),
        D(text: "Also heute war ein langer Tag im Büro, wir hatten drei Meetings hintereinander und dann noch einen Anruf mit dem Kunden. Irgendwie hat der Tag nicht gereicht und ich bin mit meiner Liste nicht fertig geworden. Morgen will ich früher anfangen und mir erstmal zwei Stunden ohne Mails nehmen, das hat letzte Woche gut funktioniert und ich war danach viel entspannter.",
          seconds: 31, bundle: notes, title: "", offer: false, note: "Erzählung Büro"),
        D(text: "Hallo zusammen, kurze Info für heute Abend: das Training fällt aus, weil die Halle gesperrt ist. Wir holen es am Donnerstag nach, gleiche Uhrzeit, gleicher Ort. Bitte gebt kurz Bescheid, ob ihr dabei seid, damit ich die Mannschaften einteilen kann. Und denkt an eure Trikots für das Spiel am Samstag, das ist diesmal auswärts. Viele Grüße und bis Donnerstag.",
          seconds: 30, bundle: wa, title: "Team", offer: false, note: "Vereins-Chat"),
        D(text: "Lorem ipsum wie das Wetter heute war, es hat den ganzen Morgen geregnet und erst am Nachmittag kam die Sonne raus. Wir sind dann noch kurz am See spazieren gegangen, die Enten waren alle am Ufer und haben auf Brot gewartet. Abends gab es Suppe und danach haben wir einen Film geschaut, der war ganz nett, aber etwas vorhersehbar.",
          seconds: 29, bundle: "", title: "", offer: false, note: "unbekannte App, Erzählung"),
    ]

    // Rückfall ohne KI: Details müssen erhalten bleiben
    static let fallbackDE = "Okay also ich mache jetzt mal. Es geht um die Settings Page, die lädt drei Sekunden. Bau das bitte so um, dass nur die ersten 50 User geladen werden, nein warte, lieber die ersten 100. Prüf, ob der Endpoint /api/users in users.controller.ts einen limit Parameter hat. Keine neuen Dependencies und fass das Styling von Lisa nicht an. Die Tests mit npm run test müssen danach grün sein. Ich weiß nicht genau, ob wir den Suchfilter auch serverseitig machen sollen."
    static let fallbackEN = "So basically the export is broken. Please add a CSV export to ReportView.swift with the columns date, amount and category. Don't change the PDF export. Make sure the tests pass. I'm not sure if we need Excel support too."
}
