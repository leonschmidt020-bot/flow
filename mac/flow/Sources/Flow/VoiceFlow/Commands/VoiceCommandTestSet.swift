import Foundation

// MARK: - Sprachbefehle: Testsatz (Genauigkeit/Trefferquote) – läuft mit `Flow --vcmd-test`
//
// Feste Uhr: Mittwoch, 30.09.2026, 10:00 (Europe/Berlin). Eigener Name „Lena“, Partner „Nico“
// (Fälle mit partner: "Lena" spielen Nicos Mac nach). Schreibweisen wie aus Parakeet/Whisper:
// klein, ohne Satzzeichen, Varianten („Niko“, „Erinnermich“, „Nicco“).

struct VCCase {
    let text: String
    /// nil = normaler Satz (darf NIE ein Befehl werden)
    var kind: VCKind? = nil
    var body: String? = nil
    /// „yyyy-MM-dd HH:mm“ oder „yyyy-MM-dd“ (ganztägig) oder „-“ (ohne Datum)
    var when: String? = nil
    /// Termin-Ende „HH:mm“
    var end: String? = nil
    /// Partner in diesem Fall (Standard „Nico“, eigener Name dann „Lena“)
    var partner = "Nico"
}

enum VCTestSet {
    static let now: Date = {
        var c = DateComponents(); c.year = 2026; c.month = 9; c.day = 30; c.hour = 10; c.minute = 0
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return cal.date(from: c)!
    }()
    static var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Europe/Berlin")!; cal.locale = Locale(identifier: "de_DE")
        return cal
    }

    private static func n(_ t: String) -> VCCase { VCCase(text: t) }
    private static func send(_ t: String, _ body: String, partner: String = "Nico") -> VCCase { VCCase(text: t, kind: .send, body: body, partner: partner) }
    private static func rem(_ t: String, _ body: String, _ when: String) -> VCCase { VCCase(text: t, kind: .reminder, body: body, when: when) }
    private static func ev(_ t: String, _ body: String, _ when: String, _ end: String? = nil) -> VCCase { VCCase(text: t, kind: .event, body: body, when: when, end: end) }
    private static func note(_ t: String, _ body: String) -> VCCase { VCCase(text: t, kind: .note, body: body) }
    private static func find(_ t: String, _ body: String) -> VCCase { VCCase(text: t, kind: .search, body: body) }

    // MARK: Normale Sätze – müssen normal eingefügt werden

    static let normal: [VCCase] = [
        // Anfang sieht aus wie „Schick …“
        n("Schick mir bitte die Unterlagen bis morgen."), n("Schickst du Nico noch die Präsentation?"), n("Schick Nico doch einfach eine Mail."),
        n("Schick Nico die Datei, wenn du Zeit hast."), n("Schickt ihr uns die Rechnung per Post?"), n("Schicksal ist, was man daraus macht."),
        n("Sende mir den Link später."), n("Sendung verpasst, kannst du sie aufnehmen?"), n("Sender und Empfänger müssen gleich eingestellt sein."),
        n("Kannst du Nico schicken, was wir besprochen haben?"), n("Ich schick Nico gleich die Datei."), n("Nico, schick mir bitte die Zahlen."),
        n("Bitte schick Nico nicht die alte Version."), n("Schicke Grüße aus Wolfenbüttel!"), n("Schreib Nico doch mal, ob er Zeit hat."),
        n("Schreib mir, wenn du angekommen bist."), n("Schreibe einen kurzen Bericht über das Projekt."), n("schick nico mal die neue version"),
        n("Schick Nico lieber morgen die Zahlen."), n("Schick Maria: ich komme später"), n("Schick Mason die Rechnung."),
        n("Schick den Brief an Nico."), n("Schreib Nico eine kurze Mail wegen morgen."), n("Sende Nico auch die Fotos vom Ausflug."),
        // Anfang sieht aus wie „Erinner mich …“
        n("Erinnerst du dich an den Sommer in Bulgarien?"), n("Erinnerung an meine Oma: sie hat immer gesungen."), n("Erinnerungen sind das Einzige, was bleibt."),
        n("Erinnere mich nicht an diesen Abend."), n("Erinnere mich daran, dass du mir noch zehn Euro schuldest."),
        n("Erinner mich, wie das nochmal ging mit dem Router."), n("Erinnert mich an früher, als wir klein waren."), n("Ich erinnere dich morgen um neun daran."),
        n("Erinnerungsfotos vom Camp sind online."), n("Erinnere mich morgen an deine Adresse, okay?"), n("Erinner mich bloß nicht an die Klausur."),
        n("Erinnere mich, warum wir das so gebaut haben."), n("Erinner mich morgen um 9 daran?"), n("Erinnerung: morgen ist Teammeeting."),
        // Anfang sieht aus wie „Termin …“ / „Kalender …“
        n("Termin am Freitag passt mir leider nicht."), n("Termin am Freitag um 14 Uhr ist abgesagt."), n("Termine sind diese Woche echt viele."),
        n("Terminplanung ist nicht meine Stärke."), n("Termin mit Pierre wurde auf Montag verschoben."), n("Kalenderwoche 40 wird stressig."),
        n("Kalender ist voll bis Oktober."), n("Termin bestätigt, bis Freitag!"), n("Termin Freitag 14 Uhr?"), n("Termin morgen um 10 passt dir?"),
        n("Termin am Montag habe ich schon eingetragen."), n("Termin um 15 Uhr klappt bei mir."), n("Termin steht, Freitag um zwei."),
        n("Kalender morgen checken wir zusammen."), n("Termin morgen ist leider geplatzt, sorry."), n("Terminator ist ein Klassiker."),
        // Anfang sieht aus wie „Notiz …“
        n("Notizen habe ich mir leider keine gemacht."), n("Notiz am Rande: die Kaffeemaschine ist kaputt."), n("Notizbuch liegt auf dem Tisch."),
        n("Notiz an alle: Das Büro bleibt morgen zu."), n("Notiz für Nico: der Schlüssel liegt unter der Matte."), n("Notiz ist schon im Ordner."),
        n("Bitte Notiz machen für das Protokoll."),
        // Anfang sieht aus wie „Such …“ / „Google …“
        n("Such dir einfach was Schönes aus."), n("Suchst du noch eine Wohnung in Hamburg?"), n("Suche nach einer Wohnung läuft leider schlecht."),
        n("Such nicht so lange, nimm einfach das erste."), n("Google hat ein neues Modell vorgestellt."), n("Google Maps zeigt den Weg falsch an."),
        n("Suche nach Mitbewohnern gestaltet sich schwierig."), n("Suchen macht keinen Spaß."), n("Such nach deinem Schlüssel im Auto."),
        // Englisch
        n("Note that the deadline moved to Friday."), n("Note the difference between both versions."), n("Notes from today's meeting are in the doc."),
        n("Please note: the office is closed on Monday."), n("Remind me why we chose this option?"), n("Remind me what the password was."),
        n("You remind me of my brother."), n("Reminder: team meeting tomorrow at 10."), n("Remind me of your name again?"),
        n("Send me the file when you get a chance."), n("Send Nico the updated slides please."), n("Sending you the draft now."),
        n("Sent Nico the invoice yesterday."), n("Text me when you land."), n("Message received, thanks!"), n("Send Nico a gift card for his birthday."),
        n("Schedule looks full this week."), n("Scheduled for Friday at 2pm."), n("Calendar invites went out this morning."),
        n("Appointment was moved to Monday at 3."), n("Search results are not great today."), n("Searching for a new apartment is exhausting."),
        n("Look up at the stars tonight."), n("Looking up the answer now."), n("Google is down again."), n("New event venue confirmed for Friday."),
        n("Add an event planner to the team."), n("Take a note of that, it's important."), n("Remind me not to do that again."),
        n("Schedule a call?"), n("Note to everyone: the meeting starts late."), n("Search for the truth is endless."),
        // Befehlswörter mitten im Satz
        n("Kannst du mir morgen um 9 eine Erinnerung schicken?"), n("Ich wollte dich nur erinnern, dass wir morgen einen Termin haben."),
        n("Bitte trag den Termin am Freitag in deinen Kalender ein."), n("Hast du eine Notiz gemacht?"), n("Ich muss nach dem Schlüssel suchen."),
        n("Kannst du mal nach Flügen suchen?"), n("We should schedule a meeting with Pierre on Friday."), n("Could you remind me tomorrow at 9?"),
        n("I'll send Nico the notes later."), n("Ich habe morgen um 9 einen Termin beim Zahnarzt."), n("Morgen um 9 treffen wir uns am Bahnhof."),
        n("Kannst du mich morgen an den Zahnarzt erinnern?"), n("Wir sollten Nico schicken, dass es später wird."), n("Das Meeting mit Pierre ist am Freitag um 14 Uhr."),
        n("Hey Flow, schick Nico: das ist nur ein Test im Satz."), n("Also erinnere mich morgen an den Zahnarzt."), n("Okay, Termin am Freitag um 14 Uhr mit Pierre."),
        n("Und Notiz: das hier ist normaler Text."), n("Ja, such nach dem Fehler im Log."),
        // Ganz normale Diktate
        n("Hallo Nico, ich komme etwa zehn Minuten später."), n("Liebe Grüße an Nico und die Familie."), n("Danke für die schnelle Antwort, das hilft mir sehr."),
        n("Neue Zeile ist ein Sprachbefehl, das weiß ich."), n("Ich bin heute im Homeoffice und ab 14 Uhr erreichbar."), n("Die Klausur für die elfte Klasse ist fertig."),
        n("Kannst du mir die Folien bis Freitag schicken?"), n("Wir treffen uns morgen um halb zehn vor der Kirche."), n("Das Update auf Version 1.5.6 ist raus."),
        n("Bitte prüf noch einmal die Rechnung von KiTaNet."), n("Die Wohnung in der Lindenstraße hat drei Zimmer."), n("Ich habe die Tickets für Sofia gebucht."),
        n("Morgen früh fahre ich nach Hannover."), n("Heute Abend gibt es Pizza bei uns."), n("Der Worship-Abend war richtig stark."),
        n("Guten Morgen zusammen, kurzer Stand vom Projekt."), n("Sehr geehrter Herr Dr. Hallbauer, vielen Dank für Ihre Rückmeldung."),
        n("Wir müssen noch das Budget für Oktober besprechen."), n("Kurze Frage: passt dir Freitag um 14 Uhr?"), n("Ich schicke dir gleich den Link."),
        n("Das Camp startet am 3. Juli und endet am 28. August."), n("Mein Handy ist gleich leer, ich melde mich später."),
        n("Die Pille zeigt jetzt einen grünen Punkt."), n("Ich finde das neue Design richtig schön."), n("Lass uns das am Wochenende in Ruhe anschauen."),
        n("Oma fragt, ob das Ferienhaus im Oktober frei ist."), n("Die Gäste reisen am Samstag um 11 Uhr ab."), n("Ich brauche noch zwei Stunden für den Bericht."),
        n("In zwei Stunden bin ich zu Hause."), n("Um 9 Uhr fängt der Unterricht an."), n("Am Freitag habe ich frei."), n("Übermorgen ist Omas Geburtstag."),
        n("Nächste Woche bin ich in Hamburg."), n("Nico und ich sind Geschwister."), n("Wie spät ist es eigentlich in Lissabon?"),
        n("Kannst du bitte die Heizung runterdrehen?"), n("Ich hab die Datei im geteilten Ordner abgelegt."), n("Bis später, ich muss los."),
        n("Hey, are we still on for dinner tonight?"), n("Thanks for the update, looks great."), n("The build failed again on CI."),
        n("Let's meet tomorrow at 5 at the coffee shop."), n("I'm running ten minutes late, sorry."), n("Can you send me the invoice by Friday?"),
        n("We need to finalize the budget before Monday."), n("The new portal is live now."), n("Please review the timesheet before Friday."),
        n("Pierre asked about the budget versus actual report."), n("Good morning everyone, quick update on the project."),
        n("I think the second option is better."), n("Tomorrow at 9 I have a call with Rafael."), n("In two hours the store closes."),
        n("On Friday we go to Bulgaria."), n("Next week is going to be busy."), n("Could you check the logs for errors?"),
        n("Meeting notes are attached."), n("Happy birthday, have a great day!"), n("The dentist appointment is on Tuesday."),
        // Zusatz-Formen: Gegenstücke, die normal bleiben müssen
        n("Schreib Nico doch, dass wir später kommen."), n("Schreibt Nico noch zurück?"), n("Schreib Nico bitte nicht so spät."),
        n("Nachricht an Nico ist raus."), n("Nachricht an Nico hab ich schon geschickt."), n("Nachricht an alle: Probe fällt aus."),
        n("Trag in den Kalender ein, was du schon weißt."), n("Trag das bitte in deinen Kalender ein."), n("Trag dich in die Liste ein."),
        n("Google mal selbst, ich hab keine Zeit."), n("Google Maps ist heute langsam."), n("Look up at the sky tonight."), n("Looking up flights now."),
        n("Notiere dir das bitte, Tobi."), n("Notiere alles, was dir auffällt."), n("Notieren ist wichtig im Unterricht."),
        n("Suche nach einem neuen Proberaum."), n("Suche nach Sponsoren starten"), n("Suche nach dem verlorenen Sohn – Predigtreihe Teil 3"),
        n("Schick Nico, hat er gesagt, alles was du hast."), n("Erinner mich morgen, hat sie gesagt, und dann hat sie es vergessen."),
        n("Schick Nico, Micha und Tobi die Einladung."), n("Such nach mir, Herr, wenn ich mich verliere."), n("Remind me, remind me, you're the God who never leaves."),
        n("Notiz vom Arzt brauche ich noch für die Uni."), n("Notiz? Die hab ich weggeworfen."), n("Note: attachments are too large, I'll send the rest later."),
        n("“Remind me tomorrow” is what she always says."), n("schick nico nichts bevor ich drübergeschaut hab"),
    ]

    // MARK: Befehle

    static let commands: [VCCase] = [
        // Schicken
        send("Schick Nico: Ich komme zehn Minuten später.", "Ich komme zehn Minuten später."),
        send("schick nico ich komme zehn minuten später", "Ich komme zehn minuten später"),
        send("Sende an Nico, dass das Meeting verschoben ist.", "Dass das Meeting verschoben ist."),
        send("Sende an Nico den Link zum Dokument.", "Den Link zum Dokument."),
        send("Schick Niko: bin gleich da", "Bin gleich da"),
        send("Schicke Nico, der Code ist fertig.", "Der Code ist fertig."),
        send("Send Nico: running late, start without me.", "Running late, start without me."),
        send("send nico running late", "Running late"),
        send("Send to Nico: the slides are in the shared folder.", "The slides are in the shared folder."),
        send("Text Nico: call me when you're free.", "Call me when you're free."),
        send("Schick Nico eine Nachricht: Wir treffen uns um acht.", "Wir treffen uns um acht."),
        send("Nachricht an Nico: Denk an die Tickets.", "Denk an die Tickets."),
        send("Bitte schick Nico: Danke für heute!", "Danke für heute!"),
        send("Schick Nicco: alles klar", "Alles klar"),
        send("Schreib Nico: Ich bin in fünf Minuten da.", "Ich bin in fünf Minuten da."),
        send("Send Nico a message saying the build is green.", "The build is green."),
        send("Send Lena: dinner at seven?", "Dinner at seven?", partner: "Lena"),
        send("Schick Léna: Bin unterwegs.", "Bin unterwegs.", partner: "Lena"),
        send("schick lena bin gleich zuhause", "Bin gleich zuhause", partner: "Lena"),
        send("Schick Nico – Kopplungscode kommt per iMessage.", "Kopplungscode kommt per iMessage."),
        send("Schick Nico:\nPunkt eins\nPunkt zwei", "Punkt eins\nPunkt zwei"),
        // Erinnerungen
        rem("Erinner mich morgen um 9 an den Zahnarzt.", "Zahnarzt", "2026-10-01 09:00"),
        rem("Erinnere mich in 2 Stunden daran, die Wäsche aufzuhängen.", "Die Wäsche aufhängen", "2026-09-30 12:00"),
        rem("Erinner mich am Freitag, Pierre anzurufen.", "Pierre anrufen", "2026-10-02"),
        rem("erinnere mich morgen früh an die Tickets", "Tickets", "2026-10-01 09:00"),
        rem("Erinner mich heute Abend an den Müll.", "Müll", "2026-09-30 19:00"),
        rem("Erinnermich in 30 Minuten an den Ofen", "Ofen", "2026-09-30 10:30"),
        rem("Erinnere mich um halb zehn an das Meeting.", "Meeting", "2026-10-01 09:30"),
        rem("Erinner mich übermorgen um 15 Uhr an die Präsentation", "Präsentation", "2026-10-02 15:00"),
        rem("Erinner mich am 3. Oktober an Omas Geburtstag.", "Omas Geburtstag", "2026-10-03"),
        rem("Erinner mich nächsten Montag um 8 an die Steuer", "Steuer", "2026-10-05 08:00"),
        rem("Erinnere mich in einer halben Stunde, den Tee rauszuholen.", "Den Tee rausholen", "2026-09-30 10:30"),
        rem("Erinner mich daran, dass ich Milch kaufen muss.", "Milch kaufen", "-"),
        rem("Bitte erinner mich morgen um 7 ans Joggen.", "Joggen", "2026-10-01 07:00"),
        rem("Erinner mich um 3 an den Anruf mit Pierre", "Anruf mit Pierre", "2026-09-30 15:00"),
        rem("Erinnere mich am 12.10. an die Rechnung", "Rechnung", "2026-10-12"),
        rem("Erinner mich in drei Tagen um 9 Uhr an das Paket", "Paket", "2026-10-03 09:00"),
        rem("Erinner mich morgen um 9:30 an den Call.", "Call", "2026-10-01 09:30"),
        rem("Erinner mich Freitag um viertel nach 4 an den Friseur", "Friseur", "2026-10-02 16:15"),
        rem("Erinnere mich heute um 17 Uhr an das Training", "Training", "2026-09-30 17:00"),
        rem("Erinner mich morgen an das Paket", "Paket", "2026-10-01"),
        rem("Erinnere mich um 14 Uhr an die Tabletten.", "Tabletten", "2026-09-30 14:00"),
        rem("erinner mich morgen um acht an den müll", "Müll", "2026-10-01 08:00"),
        rem("Erinner mich am dritten Oktober an das Konzert", "Konzert", "2026-10-03"),
        rem("Remind me tomorrow at 5pm to call mom.", "Call mom", "2026-10-01 17:00"),
        rem("Remind me in 2 hours to check the oven.", "Check the oven", "2026-09-30 12:00"),
        rem("remind me to send the invoice on Friday", "Send the invoice", "2026-10-02"),
        rem("Remind me next Monday at 9 about the report.", "Report", "2026-10-05 09:00"),
        rem("Please remind me tonight to water the plants.", "Water the plants", "2026-09-30 19:00"),
        rem("Remind me at 3 to pick up the kids", "Pick up the kids", "2026-09-30 15:00"),
        rem("Remind me in 30 minutes to stretch", "Stretch", "2026-09-30 10:30"),
        // Termine
        ev("Termin am Freitag 14 Uhr mit Pierre", "Termin mit Pierre", "2026-10-02 14:00", "14:30"),
        ev("Termin morgen um 10 Uhr Zahnarzt", "Zahnarzt", "2026-10-01 10:00", "10:30"),
        ev("Kalender: Mittagessen mit Rafael am Montag um 12", "Mittagessen mit Rafael", "2026-10-05 12:00", "12:30"),
        ev("Neuer Termin: Budget-Meeting nächsten Mittwoch um 15 Uhr für eine Stunde", "Budget-Meeting", "2026-10-07 15:00", "16:00"),
        ev("Termin übermorgen 9 bis 11 Uhr Workshop", "Workshop", "2026-10-02 09:00", "11:00"),
        ev("Termin am 12.10. um 16 Uhr mit dem Vermieter", "Termin mit dem Vermieter", "2026-10-12 16:00", "16:30"),
        ev("termin freitag 14 uhr mit pierre", "Termin mit pierre", "2026-10-02 14:00", "14:30"),
        ev("Trag einen Termin ein: Friseur Samstag um 11", "Friseur", "2026-10-03 11:00", "11:30"),
        ev("Termin heute um 16 Uhr Telefonat mit Milan", "Telefonat mit Milan", "2026-09-30 16:00", "16:30"),
        ev("Termin Montag von 14 bis 15 Uhr Teammeeting", "Teammeeting", "2026-10-05 14:00", "15:00"),
        ev("Kalender: Geburtstag Mama am 3. Oktober", "Geburtstag Mama", "2026-10-03"),
        ev("Termin in drei Tagen um 10 Uhr Werkstatt", "Werkstatt", "2026-10-03 10:00", "10:30"),
        ev("Termin Freitag 14 Uhr mit Pierre für zwei Stunden", "Termin mit Pierre", "2026-10-02 14:00", "16:00"),
        ev("Termin morgen halb drei Physio", "Physio", "2026-10-01 14:30", "15:00"),
        ev("Calendar: lunch with Mike tomorrow at noon", "Lunch with Mike", "2026-10-01 12:00", "12:30"),
        ev("New event Friday at 2 pm with Pierre", "Meeting with Pierre", "2026-10-02 14:00", "14:30"),
        ev("Schedule a meeting with Pierre on Monday at 10", "Meeting with Pierre", "2026-10-05 10:00", "10:30"),
        ev("Add an event tomorrow at 9 dentist", "Dentist", "2026-10-01 09:00", "09:30"),
        // Notizen
        note("Notiz: Milch, Eier und Brot kaufen.", "Milch, Eier und Brot kaufen."),
        note("notiz idee für das camp logo mit sonne", "Idee für das camp logo mit sonne"),
        note("Neue Notiz: Wohnung Lindenstraße anrufen", "Wohnung Lindenstraße anrufen"),
        note("Notiz an mich: Reifen wechseln", "Reifen wechseln"),
        note("Note: buy a new charger", "Buy a new charger"),
        note("Note to self: renew the visa documents", "Renew the visa documents"),
        note("Notiz, Hallbauer fragen wegen Clair de Lune", "Hallbauer fragen wegen Clair de Lune"),
        note("New note: song idea about morning light", "Song idea about morning light"),
        // Suche
        find("Such nach Pizzerien in Hamburg", "Pizzerien in Hamburg"),
        find("Suche im Internet nach Flügen nach Sofia", "Flügen nach Sofia"),
        find("Google mal Wetter Wolfenbüttel", "Wetter Wolfenbüttel"),
        find("Search for NH35 dial 28.5mm", "NH35 dial 28.5mm"),
        find("Look up the weather in Berlin", "The weather in Berlin"),
        find("such mal nach günstigen Monitoren", "Günstigen Monitoren"),
        // Zusatz-Formen
        send("Schreib Nico: Probe heute fällt aus.", "Probe heute fällt aus."),
        send("schreib nico ich bin in fünf minuten da", "Ich bin in fünf minuten da"),
        send("Nachricht an Nico: Papa ruft gleich an.", "Papa ruft gleich an."),
        send("Nachricht an Niko, bring die Kamera mit.", "Bring die Kamera mit."),
        send("An Nico senden: Der Server läuft wieder.", "Der Server läuft wieder."),
        send("schick nico bitte ich komm heute nicht zum training", "Ich komm heute nicht zum training"),
        ev("Trag in den Kalender ein: Samstag 15 Uhr Geburtstag bei Rudi", "Geburtstag bei Rudi", "2026-10-03 15:00", "15:30"),
        ev("Trag in meinen Kalender ein: Montag um 9 Zahnarzt", "Zahnarzt", "2026-10-05 09:00", "09:30"),
        ev("Neuer Kalendereintrag Mittwoch acht Uhr früh Zug nach Hamburg", "Zug nach Hamburg", "2026-10-07 08:00", "08:30"),
        ev("Event Saturday 7pm worship night at the church hall", "Worship night at the church hall", "2026-10-03 19:00", "19:30"),
        find("Google mal Öffnungszeiten Bürgeramt Wolfenbüttel", "Öffnungszeiten Bürgeramt Wolfenbüttel"),
        find("google mal nach flügen nach sofia", "Flügen nach sofia"),
        find("Look up the Brenninkmeyer quote about hell", "The Brenninkmeyer quote about hell"),
        find("look up bafög höchstsatz 2026", "Bafög höchstsatz 2026"),
        find("Websuche: BAföG Höchstsatz 2026", "BAföG Höchstsatz 2026"),
        find("such nach wie lange muss hefeteig gehen", "Wie lange muss hefeteig gehen"),
        note("Notiere: Milan braucht die Passnummern bis Ende Oktober.", "Milan braucht die Passnummern bis Ende Oktober."),
        note("Notier dir: Reifenwechsel im Oktober", "Reifenwechsel im Oktober"),
        note("Notiz zum Uhrenprojekt: Händler drei hat geantwortet.", "Zum Uhrenprojekt: Händler drei hat geantwortet."),
    ]

    // MARK: Auswertung

    struct Report { var tp = 0, fp = 0, fn = 0, tn = 0, exact = 0, wrongKind = 0; var lines: [String] = [] }

    static func options(for c: VCCase) -> VoiceCommandParser.Options {
        var o = VoiceCommandParser.Options()
        o.partners = [c.partner]
        o.me = c.partner == "Nico" ? "Lena" : "Nico"
        o.calendar = calendar
        return o
    }

    static func describe(_ c: VoiceCommand?) -> String {
        guard let c else { return "– kein Befehl" }
        let f = DateFormatter(); f.timeZone = calendar.timeZone; f.dateFormat = c.allDay ? "yyyy-MM-dd" : "yyyy-MM-dd HH:mm"
        let e = DateFormatter(); e.timeZone = calendar.timeZone; e.dateFormat = "HH:mm"
        var s = "\(c.kind.rawValue) „\(c.text.replacingOccurrences(of: "\n", with: "⏎"))“"
        if let p = c.partner { s += " an \(p)" }
        if let d = c.date { s += " @ \(f.string(from: d))" } else if c.kind == .reminder { s += " @ -" }
        if c.kind == .event, !c.allDay, let en = c.end { s += "–\(e.string(from: en))" }
        return s
    }

    static func matches(_ got: VoiceCommand, _ want: VCCase) -> Bool {
        guard got.kind == want.kind else { return false }
        if let b = want.body, got.text != b { return false }
        if want.kind == .send, got.partner != want.partner { return false }
        if let w = want.when {
            let f = DateFormatter(); f.timeZone = calendar.timeZone
            if w == "-" { if got.date != nil { return false } }
            else {
                guard let d = got.date else { return false }
                f.dateFormat = w.count > 10 ? "yyyy-MM-dd HH:mm" : "yyyy-MM-dd"
                if f.string(from: d) != w || got.allDay != (w.count <= 10) { return false }
            }
        }
        if let e = want.end {
            guard let en = got.end else { return false }
            let f = DateFormatter(); f.timeZone = calendar.timeZone; f.dateFormat = "HH:mm"
            if f.string(from: en) != e { return false }
        }
        return true
    }

    static func run(verbose: Bool) -> Report {
        var r = Report()
        for c in normal {
            let got = VoiceCommandParser.parse(c.text, now: now, options: options(for: c))
            if let got { r.fp += 1; r.lines.append("FALSCH AUSGELÖST  „\(c.text)“ → \(describe(got))") }
            else { r.tn += 1; if verbose { r.lines.append("ok normal        „\(c.text)“") } }
        }
        for c in commands {
            let got = VoiceCommandParser.parse(c.text, now: now, options: options(for: c))
            guard let got else { r.fn += 1; r.lines.append("NICHT ERKANNT    „\(c.text)“ (erwartet \(c.kind!.rawValue))"); continue }
            if got.kind != c.kind { r.wrongKind += 1; r.fn += 1; r.lines.append("FALSCHE ART      „\(c.text)“ → \(describe(got))"); continue }
            r.tp += 1
            if matches(got, c) { r.exact += 1; if verbose { r.lines.append("ok befehl        „\(c.text)“ → \(describe(got))") } }
            else { r.lines.append("UNGENAU          „\(c.text)“ → \(describe(got)) · erwartet „\(c.body ?? "")“ @ \(c.when ?? "")\(c.end.map { "–" + $0 } ?? "")") }
        }
        return r
    }
}
