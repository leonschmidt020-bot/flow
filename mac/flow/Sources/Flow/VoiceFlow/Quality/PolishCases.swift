import Foundation

/// Regressions-Satz für den Feinschliff: erkannte Diktate (so wie sie nach `TextCleaner.applyRules` aussehen)
/// mit erwarteter Ausgabe. Tags: korrektur, fehlstart, liste, namen, code, chat, ohne (= nichts ändern), satzzeichen.
/// `screen` = sichtbarer Fenstertext (Kontext-Diktat), `app` = Bundle-ID der App im Vordergrund.
struct PolishCase: Sendable {
    let id: String
    let tag: String
    let input: String
    let expected: String
    var app: String = "com.apple.Notes"
    var screen: String = ""

    var needsFix: Bool { input != expected }
}

enum PolishCases {
    static let vscode = "com.microsoft.VSCode", mail = "com.apple.mail", slack = "com.tinyspeck.slackmacgap"
    static let terminal = "com.apple.Terminal", whatsapp = "net.whatsapp.WhatsApp"

    static let all: [PolishCase] = [
        // ── Selbstkorrekturen DE ──
        .init(id: "k01", tag: "korrektur", input: "Wir treffen uns am Donnerstag, nein warte, am Freitag um zehn.", expected: "Wir treffen uns am Freitag um zehn."),
        .init(id: "k02", tag: "korrektur", input: "Ich nehme den Käsetoast, nein warte, die Dino Nuggets.", expected: "Ich nehme die Dino Nuggets."),
        .init(id: "k03", tag: "korrektur", input: "Das Meeting ist um drei, ich meine um vier Uhr.", expected: "Das Meeting ist um vier Uhr."),
        .init(id: "k04", tag: "korrektur", input: "Schick das bitte an Peter, nein warte, an Paul.", expected: "Schick das bitte an Paul."),
        .init(id: "k05", tag: "korrektur", input: "Wir brauchen fünf Stühle, nein sorry, sechs Stühle.", expected: "Wir brauchen sechs Stühle."),
        .init(id: "k06", tag: "korrektur", input: "Der Flug geht morgen, nein warte, übermorgen.", expected: "Der Flug geht übermorgen."),
        .init(id: "k07", tag: "korrektur", input: "Ruf bitte Anna an. Nein warte, schreib ihr lieber eine Nachricht.", expected: "Schreib ihr lieber eine Nachricht."),
        .init(id: "k08", tag: "korrektur", input: "Das kostet 30 Euro, äh nein, 40 Euro.", expected: "Das kostet 40 Euro."),
        .init(id: "k09", tag: "korrektur", input: "Ich komme um acht. Streich das. Ich komme um neun.", expected: "Ich komme um neun."),
        .init(id: "k10", tag: "korrektur", input: "Die Datei heißt Bericht final, oder besser gesagt Bericht Version zwei.", expected: "Die Datei heißt Bericht Version zwei."),
        .init(id: "k11", tag: "korrektur", input: "Kannst du mir bis Montag, nein warte, bis Dienstag die Folien schicken?", expected: "Kannst du mir bis Dienstag die Folien schicken?"),
        .init(id: "k12", tag: "korrektur", input: "Treffpunkt ist der Bahnhof, Korrektur, der Marktplatz.", expected: "Treffpunkt ist der Marktplatz."),
        .init(id: "k13", tag: "korrektur", input: "Wir launchen das Feature next week, nein warte, this week.", expected: "Wir launchen das Feature this week."),
        .init(id: "k14", tag: "korrektur", input: "Wir treffen uns am Donnerstag. Nein, warte. Am Freitag.", expected: "Wir treffen uns am Freitag."),
        // ── Selbstkorrekturen EN ──
        .init(id: "k15", tag: "korrektur", input: "Let's meet on Monday, no wait, on Tuesday.", expected: "Let's meet on Tuesday."),
        .init(id: "k16", tag: "korrektur", input: "Send the invoice to Mark, actually make that Sarah.", expected: "Send the invoice to Sarah."),
        .init(id: "k17", tag: "korrektur", input: "I need three copies, sorry, I mean four copies.", expected: "I need four copies."),
        .init(id: "k18", tag: "korrektur", input: "The deadline is Friday, I mean Thursday.", expected: "The deadline is Thursday."),
        .init(id: "k19", tag: "korrektur", input: "We should take the train, or rather the bus.", expected: "We should take the bus."),
        .init(id: "k20", tag: "korrektur", input: "Book a table for six, no sorry, for eight people.", expected: "Book a table for eight people."),
        .init(id: "k21", tag: "korrektur", input: "Call me at five. Scratch that. Call me at six.", expected: "Call me at six."),
        .init(id: "k22", tag: "korrektur", input: "It costs 20 dollars, wait no, 25 dollars.", expected: "It costs 25 dollars."),

        // ── Fehlstarts & Wiederholungen ──
        .init(id: "f01", tag: "fehlstart", input: "Ich wollte, ich wollte dir sagen, dass es klappt.", expected: "Ich wollte dir sagen, dass es klappt."),
        .init(id: "f02", tag: "fehlstart", input: "Wir sollten wir sollten das morgen besprechen.", expected: "Wir sollten das morgen besprechen."),
        .init(id: "f03", tag: "fehlstart", input: "Das ist, das ist wirklich eine gute Idee.", expected: "Das ist wirklich eine gute Idee."),
        .init(id: "f04", tag: "fehlstart", input: "Ich hab, ich habe gestern mit ihm gesprochen.", expected: "Ich habe gestern mit ihm gesprochen."),
        .init(id: "f05", tag: "fehlstart", input: "Kannst du, kannst du mir kurz helfen?", expected: "Kannst du mir kurz helfen?"),
        .init(id: "f06", tag: "fehlstart", input: "Der, der Termin ist verschoben.", expected: "Der Termin ist verschoben."),
        .init(id: "f07", tag: "fehlstart", input: "I think, I think we should wait.", expected: "I think we should wait."),
        .init(id: "f08", tag: "fehlstart", input: "Can you, can you send me the file?", expected: "Can you send me the file?"),
        .init(id: "f09", tag: "fehlstart", input: "We need to, we need to talk about the budget.", expected: "We need to talk about the budget."),
        .init(id: "f10", tag: "fehlstart", input: "It was, it was a great day.", expected: "It was a great day."),
        .init(id: "f11", tag: "fehlstart", input: "Wir müssen die, wir müssen die Halle bis Freitag buchen.", expected: "Wir müssen die Halle bis Freitag buchen."),

        // ── Aufzählungen ──
        .init(id: "l01", tag: "liste", input: "Ich brauche noch erstens Milch, zweitens Brot und drittens Eier.", expected: "Ich brauche noch:\n1. Milch\n2. Brot\n3. Eier"),
        .init(id: "l02", tag: "liste", input: "Für das Camp: erstens Halle buchen, zweitens Einladungen verschicken, drittens Essen bestellen.", expected: "Für das Camp:\n1. Halle buchen\n2. Einladungen verschicken\n3. Essen bestellen"),
        .init(id: "l03", tag: "liste", input: "Punkt eins Budget, Punkt zwei Zeitplan, Punkt drei Sonstiges.", expected: "1. Budget\n2. Zeitplan\n3. Sonstiges"),
        .init(id: "l04", tag: "liste", input: "Die Agenda für morgen. Erstens Begrüßung, zweitens Rückblick, drittens Planung. Danach essen wir zusammen.", expected: "Die Agenda für morgen:\n1. Begrüßung\n2. Rückblick\n3. Planung\n\nDanach essen wir zusammen."),
        .init(id: "l05", tag: "liste", input: "Als erstes rufst du Pierre an, als zweites schickst du die Rechnung.", expected: "1. Rufst du Pierre an\n2. Schickst du die Rechnung"),
        .init(id: "l06", tag: "liste", input: "Wir haben zwei Optionen: erstens mieten, zweitens kaufen.", expected: "Wir haben zwei Optionen:\n1. Mieten\n2. Kaufen"),
        .init(id: "l07", tag: "liste", input: "My priorities are firstly the website, secondly the app, and thirdly the newsletter.", expected: "My priorities are:\n1. The website\n2. The app\n3. The newsletter"),
        .init(id: "l08", tag: "liste", input: "Number one, bring water. Number two, bring snacks. Number three, bring a jacket.", expected: "1. Bring water\n2. Bring snacks\n3. Bring a jacket"),
        .init(id: "l09", tag: "liste", input: "First, check the logs, second, restart the server, third, notify the team.", expected: "1. Check the logs\n2. Restart the server\n3. Notify the team"),
        .init(id: "l10", tag: "liste", input: "Shopping list: point one apples, point two bananas.", expected: "Shopping list:\n1. Apples\n2. Bananas"),

        // ── Namen & Kontext ──
        .init(id: "n01", tag: "namen", input: "Hallo Frau okonkwo, danke für die schnelle Antwort.", expected: "Hallo Frau Okonkwo, danke für die schnelle Antwort.",
              app: mail, screen: "Von: Anneliese Okonkwo <a.okonkwo@example.org>\nBetreff: Sommerfest Planung\nHallo Lena, anbei die Liste."),
        .init(id: "n02", tag: "namen", input: "Schick das an Brenninkmeyer, nein warte, an Okonkwo.", expected: "Schick das an Okonkwo.",
              app: mail, screen: "An: Daniel Brenninkmeyer; Anneliese Okonkwo\nBetreff: Bericht"),
        .init(id: "n03", tag: "namen", input: "Anneliese, kannst du das bis morgen prüfen?", expected: "Anneliese, kannst du das bis morgen prüfen?",
              app: slack, screen: "Anneliese Okonkwo 10:42 Ich schaue es mir an\nJonas Weber 10:45 Danke!"),
        .init(id: "n04", tag: "namen", input: "Ich arbeite mit KiTaNet an Flow.", expected: "Ich arbeite mit KiTaNet an Flow."),
        .init(id: "n05", tag: "namen", input: "Hi siobhan, the draft looks good.", expected: "Hi Siobhan, the draft looks good.",
              app: mail, screen: "From: Siobhan Nwachukwu\nSubject: Draft v2\nHi Lena, here is the new draft."),
        .init(id: "n06", tag: "namen", input: "Bitte leite die Mail an nwachukwu weiter.", expected: "Bitte leite die Mail an Nwachukwu weiter.",
              app: mail, screen: "From: Siobhan Nwachukwu\nSubject: Draft v2"),
        .init(id: "n07", tag: "namen", input: "Rafael hat das Angebot gestern geschickt.", expected: "Rafael hat das Angebot gestern geschickt.",
              app: mail, screen: "Von: Rafael Duarte\nBetreff: Proposal"),
        .init(id: "n08", tag: "namen", input: "Sag Hallbauer, dass die Arbeit fertig ist.", expected: "Sag Hallbauer, dass die Arbeit fertig ist.",
              app: mail, screen: "Von: Dr. Hallbauer\nBetreff: Hausarbeit"),

        // ── Code ──
        .init(id: "c01", tag: "code", input: "Ruf fetch user profile auf, bevor die Seite lädt.", expected: "Ruf fetchUserProfile auf, bevor die Seite lädt.",
              app: vscode, screen: "async function fetchUserProfile(id) {\n  const res = await api.get(`/users/${id}`)\n}"),
        .init(id: "c02", tag: "code", input: "Die Funktion get user by id gibt null zurück.", expected: "Die Funktion get_user_by_id gibt null zurück.",
              app: vscode, screen: "def get_user_by_id(user_id):\n    return db.query(User).get(user_id)"),
        .init(id: "c03", tag: "code", input: "Der use effect Hook läuft zweimal.", expected: "Der useEffect Hook läuft zweimal.",
              app: vscode, screen: "useEffect(() => { loadData() }, [])"),
        .init(id: "c04", tag: "code", input: "Die Datei main.swift hat einen Fehler in Zeile 42.", expected: "Die Datei main.swift hat einen Fehler in Zeile 42.", app: vscode),
        .init(id: "c05", tag: "code", input: "Setz die Variable isEnabled auf true.", expected: "Setz die Variable isEnabled auf true.", app: vscode),
        .init(id: "c06", tag: "code", input: "Run npm install and then npm run build.", expected: "Run npm install and then npm run build.", app: terminal),
        .init(id: "c07", tag: "code", input: "Führ kubectl get pods aus.", expected: "Führ kubectl get pods aus.", app: terminal, screen: "$ kubectl get pods\nNAME READY STATUS"),
        .init(id: "c08", tag: "code", input: "The user store class needs a reset method.", expected: "The UserStore class needs a reset method.",
              app: vscode, screen: "final class UserStore: ObservableObject {\n  func reset() {}\n}"),

        // ── Chat (nichts zu tun) ──
        .init(id: "h01", tag: "chat", input: "Hey, hast du morgen Zeit?", expected: "Hey, hast du morgen Zeit?", app: whatsapp),
        .init(id: "h02", tag: "chat", input: "Haha, ja, voll.", expected: "Haha, ja, voll.", app: whatsapp),
        .init(id: "h03", tag: "chat", input: "Bin in 10 Minuten da.", expected: "Bin in 10 Minuten da.", app: whatsapp),
        .init(id: "h04", tag: "chat", input: "Danke dir, das war echt lieb.", expected: "Danke dir, das war echt lieb.", app: whatsapp),
        .init(id: "h05", tag: "chat", input: "Sounds good, see you tomorrow.", expected: "Sounds good, see you tomorrow.", app: slack),
        .init(id: "h06", tag: "chat", input: "No worries, I'll handle it.", expected: "No worries, I'll handle it.", app: slack),
        .init(id: "h07", tag: "chat", input: "Kannst du mir das Rezept schicken?", expected: "Kannst du mir das Rezept schicken?", app: whatsapp),
        .init(id: "h08", tag: "chat", input: "Alles klar, bis später!", expected: "Alles klar, bis später!", app: whatsapp),

        // ── Fallen: nichts ändern ──
        .init(id: "o01", tag: "ohne", input: "Ich meine, das sollten wir wirklich machen.", expected: "Ich meine, das sollten wir wirklich machen."),
        .init(id: "o02", tag: "ohne", input: "Ich meine nicht dich, sondern ihn.", expected: "Ich meine nicht dich, sondern ihn."),
        .init(id: "o03", tag: "ohne", input: "Nein, warte kurz, ich komme gleich.", expected: "Nein, warte kurz, ich komme gleich."),
        .init(id: "o04", tag: "ohne", input: "I actually like the new design.", expected: "I actually like the new design."),
        .init(id: "o05", tag: "ohne", input: "Wait a second, I need to check something.", expected: "Wait a second, I need to check something."),
        .init(id: "o06", tag: "ohne", input: "Erstens bin ich müde und außerdem ist es spät.", expected: "Erstens bin ich müde und außerdem ist es spät."),
        .init(id: "o07", tag: "ohne", input: "Bitte vergiss das nicht, morgen ist der Termin.", expected: "Bitte vergiss das nicht, morgen ist der Termin."),
        .init(id: "o08", tag: "ohne", input: "Der erste Punkt ist das Budget.", expected: "Der erste Punkt ist das Budget."),
        .init(id: "o09", tag: "ohne", input: "Er hat nein gesagt, warte also nicht auf ihn.", expected: "Er hat nein gesagt, warte also nicht auf ihn."),
        .init(id: "o10", tag: "ohne", input: "Das Konzert war laut, sehr laut.", expected: "Das Konzert war laut, sehr laut."),
        .init(id: "o11", tag: "ohne", input: "Wir kamen, wir sahen, wir siegten.", expected: "Wir kamen, wir sahen, wir siegten."),
        .init(id: "o12", tag: "ohne", input: "Die Zahlen sind eins, zwei, drei.", expected: "Die Zahlen sind eins, zwei, drei."),
        .init(id: "o13", tag: "ohne", input: "First of all, thank you for coming.", expected: "First of all, thank you for coming."),
        .init(id: "o14", tag: "ohne", input: "I mean it, this is important.", expected: "I mean it, this is important."),
        .init(id: "o15", tag: "ohne", input: "Sorry, ich bin zu spät.", expected: "Sorry, ich bin zu spät."),
        .init(id: "o16", tag: "ohne", input: "The second option is better than the first.", expected: "The second option is better than the first."),
        .init(id: "o17", tag: "ohne", input: "Ich habe dem Kunden abgesagt, sorry, es ging nicht anders.", expected: "Ich habe dem Kunden abgesagt, sorry, es ging nicht anders."),
        .init(id: "o18", tag: "ohne", input: "Make that call before noon, please.", expected: "Make that call before noon, please."),
        .init(id: "o19", tag: "ohne", input: "Er sagte: Ich meine es ernst.", expected: "Er sagte: Ich meine es ernst."),
        .init(id: "o20", tag: "ohne", input: "Honestly, I think it's fine.", expected: "Honestly, I think it's fine."),
        .init(id: "o21", tag: "ohne", input: "Das Wetter ist schön, die Sonne scheint, wir gehen raus.", expected: "Das Wetter ist schön, die Sonne scheint, wir gehen raus."),
        .init(id: "o22", tag: "ohne", input: "Anneliese Okonkwo kommt morgen um neun.", expected: "Anneliese Okonkwo kommt morgen um neun.",
              app: mail, screen: "Von: Anneliese Okonkwo\nBetreff: Termin"),

        // ── Satzzeichen ──
        .init(id: "p01", tag: "satzzeichen", input: "Ich bin gleich da", expected: "Ich bin gleich da."),
        .init(id: "p02", tag: "satzzeichen", input: "Wann kommst du morgen", expected: "Wann kommst du morgen?"),
        .init(id: "p03", tag: "satzzeichen", input: "Das Meeting wurde auf nächste Woche verschoben weil der Raum belegt ist und Pierre krank ist",
              expected: "Das Meeting wurde auf nächste Woche verschoben, weil der Raum belegt ist und Pierre krank ist."),
        .init(id: "p04", tag: "satzzeichen", input: "Can you send me the slides", expected: "Can you send me the slides?"),
        .init(id: "p05", tag: "satzzeichen", input: "Ich weiß nicht ob das morgen klappt aber ich versuche es", expected: "Ich weiß nicht, ob das morgen klappt, aber ich versuche es."),
    ]

    /// Nachträglich geschrieben, OHNE die Regeln danach anzupassen – misst, wie gut sie verallgemeinern.
    static let holdout: [PolishCase] = [
        .init(id: "x01", tag: "korrektur", input: "Ich bin um sieben da, nein warte, um halb acht.", expected: "Ich bin um halb acht da."),
        .init(id: "x02", tag: "korrektur", input: "Bring bitte Cola mit, nein sorry, Wasser.", expected: "Bring bitte Wasser mit."),
        .init(id: "x03", tag: "korrektur", input: "Der Workshop ist in Raum 12, ich meine Raum 14.", expected: "Der Workshop ist in Raum 14."),
        .init(id: "x04", tag: "korrektur", input: "Wir fahren mit dem Auto, oder besser mit dem Zug.", expected: "Wir fahren mit dem Zug."),
        .init(id: "x05", tag: "korrektur", input: "Please invite Tom, no wait, invite Jerry instead.", expected: "Please invite Jerry instead."),
        .init(id: "x06", tag: "korrektur", input: "The meeting is at 3 pm, actually make that 4 pm.", expected: "The meeting is at 4 pm."),
        .init(id: "x07", tag: "korrektur", input: "Ich schreibe dir heute Abend. Vergiss das. Ich rufe dich morgen an.", expected: "Ich rufe dich morgen an."),
        .init(id: "x08", tag: "korrektur", input: "Das Budget liegt bei 5000 Euro, nein warte, bei 5500 Euro.", expected: "Das Budget liegt bei 5500 Euro."),
        .init(id: "x09", tag: "korrektur", input: "We need two volunteers, I mean three volunteers, for Saturday.", expected: "We need three volunteers for Saturday."),
        .init(id: "x10", tag: "korrektur", input: "Leg die Datei in den Ordner Rechnungen, nein warte, in den Ordner Belege.", expected: "Leg die Datei in den Ordner Belege."),
        .init(id: "x11", tag: "fehlstart", input: "Also ich, also ich finde das gut.", expected: "Also ich finde das gut."),
        .init(id: "x12", tag: "fehlstart", input: "Könntest du, könntest du das kurz prüfen?", expected: "Könntest du das kurz prüfen?"),
        .init(id: "x13", tag: "fehlstart", input: "I was, I was going to call you.", expected: "I was going to call you."),
        .init(id: "x14", tag: "fehlstart", input: "Wir haben, wir haben morgen frei.", expected: "Wir haben morgen frei."),
        .init(id: "x15", tag: "liste", input: "Für die Reise brauchen wir erstens Pässe, zweitens Tickets und drittens Geld.", expected: "Für die Reise brauchen wir:\n1. Pässe\n2. Tickets\n3. Geld"),
        .init(id: "x16", tag: "liste", input: "Punkt eins Begrüßung. Punkt zwei Lobpreis. Punkt drei Predigt.", expected: "1. Begrüßung\n2. Lobpreis\n3. Predigt"),
        .init(id: "x17", tag: "liste", input: "The plan: firstly research, secondly design, thirdly build.", expected: "The plan:\n1. Research\n2. Design\n3. Build"),
        .init(id: "x18", tag: "liste", input: "Zweitens ist das zu teuer.", expected: "Zweitens ist das zu teuer."),
        .init(id: "x19", tag: "ohne", input: "Ich meine, wir sollten früher anfangen.", expected: "Ich meine, wir sollten früher anfangen."),
        .init(id: "x20", tag: "ohne", input: "Sie sagte nein, warte bis morgen.", expected: "Sie sagte nein, warte bis morgen."),
        .init(id: "x21", tag: "ohne", input: "At first I didn't like it, but now I do.", expected: "At first I didn't like it, but now I do."),
        .init(id: "x22", tag: "ohne", input: "Das ist die zweite Version, die erste war schlechter.", expected: "Das ist die zweite Version, die erste war schlechter."),
        .init(id: "x23", tag: "ohne", input: "Sorry for the late reply, I was traveling.", expected: "Sorry for the late reply, I was traveling."),
        .init(id: "x24", tag: "ohne", input: "Ich komme, wenn ich kann, aber versprechen kann ich nichts.", expected: "Ich komme, wenn ich kann, aber versprechen kann ich nichts."),
        .init(id: "x25", tag: "ohne", input: "Wir sehen uns, wir hören uns, bis bald!", expected: "Wir sehen uns, wir hören uns, bis bald!"),
        .init(id: "x26", tag: "ohne", input: "He said, I mean what I say.", expected: "He said, I mean what I say."),
        .init(id: "x27", tag: "ohne", input: "Moment, ich schaue kurz nach.", expected: "Moment, ich schaue kurz nach."),
        .init(id: "x28", tag: "chat", input: "Ok cool, dann bis gleich.", expected: "Ok cool, dann bis gleich."),
        .init(id: "x29", tag: "namen", input: "Frag mal nwachukwu, ob das passt.", expected: "Frag mal Nwachukwu, ob das passt.",
              app: slack, screen: "Siobhan Nwachukwu 09:12 Bin heute im Büro"),
        .init(id: "x30", tag: "code", input: "Der Fehler kommt aus handle payment intent.", expected: "Der Fehler kommt aus handlePaymentIntent.",
              app: vscode, screen: "export async function handlePaymentIntent(evt) {"),
        .init(id: "x31", tag: "satzzeichen", input: "Hast du die Unterlagen schon bekommen", expected: "Hast du die Unterlagen schon bekommen?"),
        .init(id: "x32", tag: "satzzeichen", input: "Ich glaube dass wir das schaffen", expected: "Ich glaube, dass wir das schaffen."),
    ]
}
