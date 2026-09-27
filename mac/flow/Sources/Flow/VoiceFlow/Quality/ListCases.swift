import Foundation

/// Regressions-Satz „intelligente Listen“ (SmartLists). Eingaben so, wie sie nach `TextCleaner.applyRules` aussehen.
/// `expected` in neutraler Schreibweise: „- “ = Stichpunkt, „[ ] “ = Checkliste, „1. “ = nummeriert; wird je Ziel-App umgesetzt
/// (Markdown: „- “/„- [ ] “, Notizen/Terminal: „- “, Mail/Chat: „• “). Chat: Liste erst ab 4 Punkten oder auf Wunsch, sonst bleibt der Satz
/// (eigene Erwartung mit `chat:`). Tag „prosa“ = darf NIE zur Liste werden (erwartet = Eingabe).
struct ListCase: Sendable {
    let id: String
    let tag: String
    let input: String
    let expected: String
    var chat: String?
}

enum ListCases {
    static let bundles: [(SmartLists.Target, String)] = [
        (.markdown, "md.obsidian"), (.plain, "com.apple.Notes"), (.mail, "com.apple.mail"), (.chat, "net.whatsapp.WhatsApp"), (.terminal, "com.apple.Terminal"),
    ]

    static func isListLine(_ l: String) -> Bool {
        l.hasPrefix("- ") || l.hasPrefix("• ") || l.hasPrefix("[ ] ") || l.range(of: "^\\d+\\. ", options: .regularExpression) != nil
    }

    /// Neutrale Schreibweise → Ziel-App
    static func render(_ neutral: String, _ t: SmartLists.Target) -> String {
        neutral.components(separatedBy: "\n").map { l -> String in
            if l.hasPrefix("[ ] ") { return SmartLists.marker(.checklist, 0, t) + l.dropFirst(4) }
            if l.hasPrefix("- ") { return SmartLists.marker(.bullets, 0, t) + l.dropFirst(2) }
            return l
        }.joined(separator: "\n")
    }

    static func expected(_ c: ListCase, _ t: SmartLists.Target) -> String {
        if t == .chat {
            if let x = c.chat { return render(x, t) }
            let items = c.expected.components(separatedBy: "\n").filter(isListLine).count
            if c.tag != "hinweis", items < 4 { return c.input }
        }
        return render(c.expected, t)
    }

    static let all: [ListCase] = [
        // ── Einkauf ──
        .init(id: "e01", tag: "einkauf", input: "Ich gehe einkaufen und will mitnehmen eine Banane, einen Apfel, Milch und Brot.", expected: "Einkaufen:\n- Banane\n- Apfel\n- Milch\n- Brot"),
        .init(id: "e02", tag: "einkauf", input: "Ich muss noch Milch, Brot, Eier und Butter kaufen.", expected: "Einkaufen:\n- Milch\n- Brot\n- Eier\n- Butter"),
        .init(id: "e03", tag: "einkauf", input: "Kauf bitte Tomaten, Gurken und Paprika.", expected: "Einkaufen:\n- Tomaten\n- Gurken\n- Paprika"),
        .init(id: "e04", tag: "einkauf", input: "Für den Grillabend müssen wir noch Würstchen, Kohle, Brötchen und Ketchup besorgen.",
              expected: "Für den Grillabend müssen wir noch besorgen:\n- Würstchen\n- Kohle\n- Brötchen\n- Ketchup"),
        .init(id: "e05", tag: "einkauf", input: "Wir brauchen noch zwei Liter Milch, 500 Gramm Mehl, sechs Eier und eine Packung Zucker.",
              expected: "Wir brauchen noch:\n- Zwei Liter Milch\n- 500 Gramm Mehl\n- Sechs Eier\n- Eine Packung Zucker"),
        .init(id: "e06", tag: "einkauf", input: "I need to buy eggs, milk, bread and butter.", expected: "Shopping:\n- Eggs\n- Milk\n- Bread\n- Butter"),
        .init(id: "e07", tag: "einkauf", input: "Einkaufsliste: Hafermilch, Bananen, Haferflocken, Honig und Nüsse.",
              expected: "Einkaufsliste:\n- Hafermilch\n- Bananen\n- Haferflocken\n- Honig\n- Nüsse"),
        .init(id: "e08", tag: "einkauf", input: "Shopping list: apples, pears, a loaf of bread and cheese.", expected: "Shopping list:\n- Apples\n- Pears\n- A loaf of bread\n- Cheese"),
        .init(id: "e09", tag: "einkauf", input: "Ich geh schnell zum Rewe und hole Brot, Käse, Tomaten und Wein.",
              expected: "Ich geh schnell zum Rewe und hole:\n- Brot\n- Käse\n- Tomaten\n- Wein"),
        .init(id: "e10", tag: "einkauf", input: "Wir müssen für die Party Chips, Cola, Bier und Eis holen.", expected: "Wir müssen für die Party holen:\n- Chips\n- Cola\n- Bier\n- Eis"),
        .init(id: "e11", tag: "einkauf", input: "We need to get paper towels, dish soap and trash bags.", expected: "We need to get:\n- Paper towels\n- Dish soap\n- Trash bags"),
        .init(id: "e12", tag: "einkauf", input: "Bitte bring vom Bäcker drei Brötchen, zwei Croissants und ein Baguette mit.",
              expected: "Bitte bring vom Bäcker mit:\n- Drei Brötchen\n- Zwei Croissants\n- Ein Baguette"),
        .init(id: "e13", tag: "einkauf", input: "Buy milk, eggs and bread.", expected: "Shopping:\n- Milk\n- Eggs\n- Bread"),
        .init(id: "e14", tag: "einkauf", input: "Ich gehe morgen einkaufen und brauche Reis, Linsen, Kokosmilch und Curry.",
              expected: "Einkaufen (morgen):\n- Reis\n- Linsen\n- Kokosmilch\n- Curry"),
        .init(id: "e15", tag: "einkauf", input: "Ich muss noch eine Zahnbürste, ein Duschgel und eine Zahnpasta besorgen.",
              expected: "Einkaufen:\n- Zahnbürste\n- Duschgel\n- Zahnpasta"),
        .init(id: "e16", tag: "einkauf", input: "I'm going to the store to buy apples, oat milk, peanut butter and granola.",
              expected: "I'm going to the store to buy:\n- Apples\n- Oat milk\n- Peanut butter\n- Granola"),

        // ── Packen ──
        .init(id: "p01", tag: "packen", input: "Für den Urlaub muss ich noch Sonnencreme, Badehose, Handtuch und Ladekabel einpacken.",
              expected: "Für den Urlaub muss ich noch einpacken:\n- Sonnencreme\n- Badehose\n- Handtuch\n- Ladekabel"),
        .init(id: "p02", tag: "packen", input: "Pack bitte den Pass, die Zahnbürste und das Ladekabel ein.", expected: "Packliste:\n- Pass\n- Zahnbürste\n- Ladekabel"),
        .init(id: "p03", tag: "packen", input: "Ins Camp nehme ich mit: Schlafsack, Isomatte, Taschenlampe und Regenjacke.",
              expected: "Ins Camp nehme ich mit:\n- Schlafsack\n- Isomatte\n- Taschenlampe\n- Regenjacke"),
        .init(id: "p04", tag: "packen", input: "Pack sunscreen, a towel, flip flops and your charger.", expected: "Packing list:\n- Sunscreen\n- Towel\n- Flip flops\n- Your charger"),
        .init(id: "p05", tag: "packen", input: "For the trip we need passports, tickets, cash and a phone charger.",
              expected: "For the trip we need:\n- Passports\n- Tickets\n- Cash\n- A phone charger"),
        .init(id: "p06", tag: "packen", input: "Ich will mitnehmen: Laptop, Kamera, Stativ und Mikrofon.", expected: "Ich will mitnehmen:\n- Laptop\n- Kamera\n- Stativ\n- Mikrofon"),
        .init(id: "p07", tag: "packen", input: "Nimm Wasser, Snacks und eine Jacke mit.", expected: "Nimm mit:\n- Wasser\n- Snacks\n- Eine Jacke"),
        .init(id: "p08", tag: "packen", input: "Für Bulgarien packe ich den Laptop, die Kamera, das Mikro und zwei Adapter ein.",
              expected: "Für Bulgarien packe ich ein:\n- Laptop\n- Kamera\n- Mikro\n- Zwei Adapter"),
        .init(id: "p09", tag: "packen", input: "Don't forget to pack your passport, the tickets and some cash.", expected: "Don't forget to pack:\n- Your passport\n- Tickets\n- Cash"),

        // ── Agenda / Themen ──
        .init(id: "a01", tag: "agenda", input: "Die Themen für morgen sind Budget, Zeitplan, Personal und Sonstiges.",
              expected: "Die Themen für morgen:\n- Budget\n- Zeitplan\n- Personal\n- Sonstiges"),
        .init(id: "a02", tag: "agenda", input: "Agenda für Montag: Begrüßung, Rückblick auf das Camp, Finanzen und Gebet.",
              expected: "Agenda für Montag:\n- Begrüßung\n- Rückblick auf das Camp\n- Finanzen\n- Gebet"),
        .init(id: "a03", tag: "agenda", input: "The agenda for Friday is welcome, project updates, budget review and next steps.",
              expected: "The agenda for Friday:\n- Welcome\n- Project updates\n- Budget review\n- Next steps"),
        .init(id: "a04", tag: "agenda", input: "Topics: hiring, the new website, and the retreat.", expected: "Topics:\n- Hiring\n- The new website\n- The retreat"),
        .init(id: "a05", tag: "agenda", input: "Punkte für das Meeting mit Pierre: Timesheet, Budget und Rechnungen.",
              expected: "Punkte für das Meeting mit Pierre:\n- Timesheet\n- Budget\n- Rechnungen"),
        .init(id: "a06", tag: "agenda", input: "Folgende Punkte sind offen: Vertrag, Rechnung und Logo.", expected: "Folgende Punkte sind offen:\n- Vertrag\n- Rechnung\n- Logo"),
        .init(id: "a07", tag: "agenda", input: "Ideen für das Wochenende: Kino, Wandern oder Grillen.", expected: "Ideen für das Wochenende:\n- Kino\n- Wandern\n- Grillen"),
        .init(id: "a08", tag: "agenda", input: "Questions for the call: pricing, timeline, and who owns the migration.",
              expected: "Questions for the call:\n- Pricing\n- Timeline\n- Who owns the migration"),
        .init(id: "a09", tag: "agenda", input: "Tagesordnung: Andacht, Berichte der Teams, Planung Sommerfest, Verschiedenes.",
              expected: "Tagesordnung:\n- Andacht\n- Berichte der Teams\n- Planung Sommerfest\n- Verschiedenes"),
        .init(id: "a10", tag: "agenda", input: "Unsere Ziele für das Quartal sind mehr Kunden, bessere Prozesse und ein neues Portal.",
              expected: "Unsere Ziele für das Quartal:\n- Mehr Kunden\n- Bessere Prozesse\n- Ein neues Portal"),
        .init(id: "a11", tag: "agenda", input: "The options are Stripe, Paddle or Lemon Squeezy.", expected: "The options:\n- Stripe\n- Paddle\n- Lemon Squeezy"),

        // ── Schritte / Reihenfolge ──
        .init(id: "s01", tag: "schritte", input: "Zuerst schneidest du die Zwiebeln, dann brätst du sie an, danach gibst du die Tomaten dazu und zum Schluss würzt du alles.",
              expected: "1. Zuerst schneidest du die Zwiebeln\n2. Dann brätst du sie an\n3. Danach gibst du die Tomaten dazu\n4. Zum Schluss würzt du alles"),
        .init(id: "s02", tag: "schritte", input: "Zuerst die Butter schmelzen, dann den Zucker einrühren, danach die Eier dazugeben und zum Schluss das Mehl unterheben.",
              expected: "1. Die Butter schmelzen\n2. Den Zucker einrühren\n3. Die Eier dazugeben\n4. Das Mehl unterheben"),
        .init(id: "s03", tag: "schritte", input: "First, open the settings, then click on privacy, after that turn on the microphone, and finally restart the app.",
              expected: "1. Open the settings\n2. Click on privacy\n3. Turn on the microphone\n4. Restart the app"),
        .init(id: "s04", tag: "schritte", input: "So installierst du die App. Zuerst lädst du das Paket herunter. Dann öffnest du es. Danach ziehst du die App in den Programme-Ordner. Zum Schluss startest du sie.",
              expected: "So installierst du die App:\n1. Zuerst lädst du das Paket herunter\n2. Dann öffnest du es\n3. Danach ziehst du die App in den Programme-Ordner\n4. Zum Schluss startest du sie"),
        .init(id: "s05", tag: "schritte", input: "To start, clone the repo. Then run npm install. Next, copy the env file. Finally, run npm run dev.",
              expected: "1. Clone the repo\n2. Run npm install\n3. Copy the env file\n4. Run npm run dev"),
        .init(id: "s06", tag: "schritte", input: "Morgen läuft es so ab: zuerst Frühstück, dann Andacht, danach Workshops und zum Schluss Lagerfeuer.",
              expected: "Morgen läuft es so ab:\n1. Frühstück\n2. Andacht\n3. Workshops\n4. Lagerfeuer"),
        .init(id: "s07", tag: "schritte", input: "Als erstes meldest du dich an, dann füllst du das Formular aus, danach lädst du den Pass hoch und zum Schluss bezahlst du.",
              expected: "1. Als erstes meldest du dich an\n2. Dann füllst du das Formular aus\n3. Danach lädst du den Pass hoch\n4. Zum Schluss bezahlst du"),
        .init(id: "s08", tag: "schritte", input: "First, preheat the oven to 180 degrees. Then mix the flour and sugar. Next, add the eggs. Finally, bake for 25 minutes.",
              expected: "1. Preheat the oven to 180 degrees\n2. Mix the flour and sugar\n3. Add the eggs\n4. Bake for 25 minutes"),
        .init(id: "s09", tag: "schritte", input: "Erstmal Backup machen, dann das Update installieren und zum Schluss neu starten.",
              expected: "1. Backup machen\n2. Das Update installieren\n3. Neu starten"),
        .init(id: "s10", tag: "schritte", input: "Zuerst Kaffee, dann Mails, danach das Meeting mit Rafael, anschließend Mittagessen und zum Schluss Sport.",
              expected: "1. Kaffee\n2. Mails\n3. Das Meeting mit Rafael\n4. Mittagessen\n5. Sport"),
        .init(id: "s11", tag: "schritte", input: "First we pray, then we worship, then we hear the word, and finally we send people out.",
              expected: "1. We pray\n2. We worship\n3. We hear the word\n4. We send people out"),

        // ── Rangliste ──
        .init(id: "r01", tag: "rangliste", input: "Meine Top drei Filme sind Inception, Interstellar und Tenet.", expected: "Meine Top drei Filme:\n1. Inception\n2. Interstellar\n3. Tenet"),
        .init(id: "r02", tag: "rangliste", input: "Platz eins Hillsong, Platz zwei Bethel und Platz drei Elevation.", expected: "1. Hillsong\n2. Bethel\n3. Elevation", chat: "1. Hillsong\n2. Bethel\n3. Elevation"),
        .init(id: "r03", tag: "rangliste", input: "My top 5 worship songs are Goodness of God, Holy Forever, Firm Foundation, Gratitude and Way Maker.",
              expected: "My top 5 worship songs:\n1. Goodness of God\n2. Holy Forever\n3. Firm Foundation\n4. Gratitude\n5. Way Maker"),
        .init(id: "r04", tag: "rangliste", input: "Auf Platz eins ist Pizza, auf Platz zwei Pasta und auf Platz drei Sushi.", expected: "1. Pizza\n2. Pasta\n3. Sushi", chat: "1. Pizza\n2. Pasta\n3. Sushi"),
        .init(id: "r05", tag: "rangliste", input: "Ranking from best to worst: Paris, Rome, London.", expected: "Ranking from best to worst:\n1. Paris\n2. Rome\n3. London"),
        .init(id: "r06", tag: "rangliste", input: "Meine Prioritäten sind Familie, Gemeinde, Arbeit und Sport.", expected: "Meine Prioritäten:\n1. Familie\n2. Gemeinde\n3. Arbeit\n4. Sport"),

        // ── Aufgaben / To-dos ──
        .init(id: "t01", tag: "todo", input: "Ich muss heute noch die Wäsche machen, Mama anrufen und die Rechnung an Pierre schreiben.",
              expected: "To-dos (heute):\n[ ] Die Wäsche machen\n[ ] Mama anrufen\n[ ] Die Rechnung an Pierre schreiben"),
        .init(id: "t02", tag: "todo", input: "To-dos: Steuererklärung abgeben, Auto zum TÜV bringen, Geschenk für Mia kaufen.",
              expected: "To-dos:\n[ ] Steuererklärung abgeben\n[ ] Auto zum TÜV bringen\n[ ] Geschenk für Mia kaufen"),
        .init(id: "t03", tag: "todo", input: "I still need to call the bank, renew my passport and book the flights.",
              expected: "To-dos:\n[ ] Call the bank\n[ ] Renew my passport\n[ ] Book the flights"),
        .init(id: "t04", tag: "todo", input: "Heute muss ich noch einkaufen, putzen und die Präsentation fertig machen.",
              expected: "To-dos (heute):\n[ ] Einkaufen\n[ ] Putzen\n[ ] Die Präsentation fertig machen"),
        .init(id: "t05", tag: "todo", input: "Meine Aufgaben für diese Woche sind Website fertig machen, Rechnungen schreiben und Camp planen.",
              expected: "Meine Aufgaben für diese Woche:\n[ ] Website fertig machen\n[ ] Rechnungen schreiben\n[ ] Camp planen"),
        .init(id: "t06", tag: "todo", input: "My to-dos for today are answer emails, fix the login bug, and prepare the demo.",
              expected: "My to-dos for today:\n[ ] Answer emails\n[ ] Fix the login bug\n[ ] Prepare the demo"),
        .init(id: "t07", tag: "todo", input: "Wir müssen die Halle buchen, Flyer drucken, Essen bestellen und Helfer einteilen.",
              expected: "To-dos:\n[ ] Die Halle buchen\n[ ] Flyer drucken\n[ ] Essen bestellen\n[ ] Helfer einteilen"),
        .init(id: "t08", tag: "todo", input: "Don't forget to water the plants, feed the cat and lock the door.",
              expected: "Don't forget to:\n[ ] Water the plants\n[ ] Feed the cat\n[ ] Lock the door"),
        .init(id: "t09", tag: "todo", input: "Nicht vergessen: Müll rausbringen, Blumen gießen und Katze füttern.",
              expected: "Nicht vergessen:\n[ ] Müll rausbringen\n[ ] Blumen gießen\n[ ] Katze füttern"),
        .init(id: "t10", tag: "todo", input: "Vergiss nicht, die Tür abzuschließen, das Licht auszumachen und den Hund zu füttern.",
              expected: "Vergiss nicht:\n[ ] Die Tür abzuschließen\n[ ] Das Licht auszumachen\n[ ] Den Hund zu füttern"),
        .init(id: "t11", tag: "todo", input: "I have to finish the report, send it to Pierre, and update the invoice.",
              expected: "To-dos:\n[ ] Finish the report\n[ ] Send it to Pierre\n[ ] Update the invoice"),

        // ── Aufforderungen hintereinander ──
        .init(id: "i01", tag: "imperativ", input: "Kauf Brot beim Bäcker. Ruf Oma wegen Sonntag an. Schick Nico die Rechnung.",
              expected: "- Kauf Brot beim Bäcker\n- Ruf Oma wegen Sonntag an\n- Schick Nico die Rechnung"),
        .init(id: "i02", tag: "imperativ", input: "Check the server logs. Restart the database. Notify the team in Slack.",
              expected: "- Check the server logs\n- Restart the database\n- Notify the team in Slack"),
        .init(id: "i03", tag: "imperativ", input: "Bitte schick mir die Unterlagen. Ruf mich morgen früh an. Denk an den Termin am Freitag.",
              expected: "- Bitte schick mir die Unterlagen\n- Ruf mich morgen früh an\n- Denk an den Termin am Freitag"),
        .init(id: "i04", tag: "imperativ", input: "Open the file. Find the config section. Change the port to 8080. Save and restart.",
              expected: "- Open the file\n- Find the config section\n- Change the port to 8080\n- Save and restart"),
        .init(id: "i05", tag: "imperativ", input: "Schreib Rafael wegen dem Angebot. Buch den Flug nach Sofia. Prüf die Rechnung von Nordlicht GmbH. Meld dich bei Milan.",
              expected: "- Schreib Rafael wegen dem Angebot\n- Buch den Flug nach Sofia\n- Prüf die Rechnung von Nordlicht GmbH\n- Meld dich bei Milan"),

        // ── Sprach-Hinweis ──
        .init(id: "h01", tag: "hinweis", input: "Milch, Brot und Eier, als Liste.", expected: "- Milch\n- Brot\n- Eier"),
        .init(id: "h02", tag: "hinweis", input: "Wir brauchen Stühle, Tische, Beamer und Mikrofone, nummeriert.", expected: "Wir brauchen:\n1. Stühle\n2. Tische\n3. Beamer\n4. Mikrofone"),
        .init(id: "h03", tag: "hinweis", input: "Ich muss noch Milch, Brot, Eier und Butter kaufen. Keine Liste.", expected: "Ich muss noch Milch, Brot, Eier und Butter kaufen."),
        .init(id: "h04", tag: "hinweis", input: "Heute Abend Bibelkreis, morgen Training, am Samstag Camp-Treffen. Als Liste bitte.",
              expected: "- Heute Abend Bibelkreis\n- Morgen Training\n- Am Samstag Camp-Treffen"),
        .init(id: "h05", tag: "hinweis", input: "Apples, bananas, and grapes, as a list.", expected: "- Apples\n- Bananas\n- Grapes"),
        .init(id: "h06", tag: "hinweis", input: "I need to call Sarah, email Tom and book the room. No list.", expected: "I need to call Sarah, email Tom and book the room."),
        .init(id: "h07", tag: "hinweis", input: "Die Gäste sind Anna, Tom und Lisa als Checkliste.", expected: "Die Gäste sind:\n[ ] Anna\n[ ] Tom\n[ ] Lisa"),
        .init(id: "h08", tag: "hinweis", input: "Schick mir die Namen als Liste.", expected: "Schick mir die Namen als Liste."),
        .init(id: "h09", tag: "hinweis", input: "Wie willst du es haben? Als Liste.", expected: "Wie willst du es haben? Als Liste."),
        .init(id: "h10", tag: "hinweis", input: "Zuerst Kaffee, dann Mails, dann Meeting. Nummeriert.", expected: "1. Kaffee\n2. Mails\n3. Meeting"),
        .init(id: "h11", tag: "hinweis", input: "Einkaufen, Wäsche, Steuer. Als Checkliste.", expected: "[ ] Einkaufen\n[ ] Wäsche\n[ ] Steuer"),
        .init(id: "h12", tag: "hinweis", input: "Die Themen sind Budget, Zeitplan und Team, keine Liste bitte.", expected: "Die Themen sind Budget, Zeitplan und Team."),
        .init(id: "h13", tag: "hinweis", input: "Call Sarah. Email Tom. Book the room. As a numbered list.", expected: "1. Call Sarah\n2. Email Tom\n3. Book the room"),

        // ── Namen ──
        .init(id: "n01", tag: "namen", input: "Einladen: Pierre Mau, Rafael Duarte, Anneliese Okonkwo und Daniel Brenninkmeyer.",
              expected: "Einladen:\n- Pierre Mau\n- Rafael Duarte\n- Anneliese Okonkwo\n- Daniel Brenninkmeyer"),
        .init(id: "n02", tag: "namen", input: "Invite list: Siobhan Nwachukwu, Tom O'Brien, and Anna-Lena Muster.",
              expected: "Invite list:\n- Siobhan Nwachukwu\n- Tom O'Brien\n- Anna-Lena Muster"),
        .init(id: "n03", tag: "namen", input: "Teilnehmer: Lena, Nico, Mia und Papa.", expected: "Teilnehmer:\n- Lena\n- Nico\n- Mia\n- Papa"),
        .init(id: "n04", tag: "namen", input: "Bestell bei Amazon das iPhone-Ladekabel, die AirPods Hülle und den USB-C Hub.",
              expected: "Bestell bei Amazon:\n- Das iPhone-Ladekabel\n- Die AirPods Hülle\n- Den USB-C Hub"),
        .init(id: "n05", tag: "namen", input: "Setlist für Sonntag: Komm und staune, Ich bin gemeint, Deeper und Holy Presence.",
              expected: "Setlist für Sonntag:\n- Komm und staune\n- Ich bin gemeint\n- Deeper\n- Holy Presence"),
        .init(id: "n06", tag: "namen", input: "Worship set for Sunday: Goodness of God, Holy Forever, Firm Foundation and Gratitude.",
              expected: "Worship set for Sunday:\n- Goodness of God\n- Holy Forever\n- Firm Foundation\n- Gratitude"),

        // ── Zahlen ──
        .init(id: "z01", tag: "zahlen", input: "Wir brauchen 20 Stühle, 5 Tische, 2 Beamer und 100 Becher.", expected: "Wir brauchen:\n- 20 Stühle\n- 5 Tische\n- 2 Beamer\n- 100 Becher"),
        .init(id: "z02", tag: "zahlen", input: "Order 50 flyers, 10 posters and 200 stickers.", expected: "Order:\n- 50 flyers\n- 10 posters\n- 200 stickers"),
        .init(id: "z03", tag: "zahlen", input: "Für das Camp brauchen wir 120 Bibeln, 60 Stifte, 30 Namensschilder und 4 Kisten Wasser.",
              expected: "Für das Camp brauchen wir:\n- 120 Bibeln\n- 60 Stifte\n- 30 Namensschilder\n- 4 Kisten Wasser"),

        // ── Gemischt (Text davor/danach) ──
        .init(id: "g01", tag: "gemischt", input: "Hey Nico. Ich gehe gleich einkaufen und hole Milch, Eier, Käse und Brot. Brauchst du noch was?",
              expected: "Hey Nico.\n\nEinkaufen:\n- Milch\n- Eier\n- Käse\n- Brot\n\nBrauchst du noch was?"),
        .init(id: "g02", tag: "gemischt", input: "Kurzes Update zum Camp. Die Themen für Montag sind Andacht, Spiele, Essen und Gebet. Meldet euch bis Freitag.",
              expected: "Kurzes Update zum Camp.\n\nDie Themen für Montag:\n- Andacht\n- Spiele\n- Essen\n- Gebet\n\nMeldet euch bis Freitag."),
        .init(id: "g03", tag: "gemischt", input: "Quick update. For the launch we need a landing page, a demo video, a press kit and an email sequence. Let me know what you think.",
              expected: "Quick update.\n\nFor the launch we need:\n- A landing page\n- A demo video\n- A press kit\n- An email sequence\n\nLet me know what you think."),
        .init(id: "g04", tag: "gemischt", input: "Ich muss heute noch drei Sachen erledigen: Steuer abgeben, Auto waschen und Oma besuchen.",
              expected: "Ich muss heute noch drei Sachen erledigen:\n[ ] Steuer abgeben\n[ ] Auto waschen\n[ ] Oma besuchen"),
        .init(id: "g05", tag: "gemischt", input: "Einkaufen: Milch, Brot, Eier. Packen: Pass, Tickets, Ladekabel.",
              expected: "Einkaufen:\n- Milch\n- Brot\n- Eier\n\nPacken:\n- Pass\n- Tickets\n- Ladekabel", chat: "Einkaufen: Milch, Brot, Eier. Packen: Pass, Tickets, Ladekabel."),
        .init(id: "g06", tag: "gemischt", input: "Für das Portal muss ich noch das Login fixen, die Preise anpassen und die Landingpage deployen.",
              expected: "Für das Portal muss ich noch:\n[ ] Das Login fixen\n[ ] Die Preise anpassen\n[ ] Die Landingpage deployen"),
        .init(id: "g07", tag: "gemischt", input: "Für das Camp brauchen wir Bibeln, Stifte, Namensschilder und Snacks.",
              expected: "Für das Camp brauchen wir:\n- Bibeln\n- Stifte\n- Namensschilder\n- Snacks"),
        .init(id: "g08", tag: "gemischt", input: "Schick Nico die Rechnung. Ruf Pierre wegen dem Budget an. Buch den Flug nach Bulgarien.",
              expected: "- Schick Nico die Rechnung\n- Ruf Pierre wegen dem Budget an\n- Buch den Flug nach Bulgarien"),
        .init(id: "g09", tag: "gemischt", input: "Also für die Villa brauche ich noch Sofa, Couchtisch, Stehlampe und Teppich.",
              expected: "Also für die Villa brauche ich noch:\n- Sofa\n- Couchtisch\n- Stehlampe\n- Teppich"),

        // ── Prosa: darf nie Liste werden ──
        .init(id: "o01", tag: "prosa", input: "Ich war müde, hungrig und genervt.", expected: "Ich war müde, hungrig und genervt."),
        .init(id: "o02", tag: "prosa", input: "Wir haben gegessen, getrunken und gelacht.", expected: "Wir haben gegessen, getrunken und gelacht."),
        .init(id: "o03", tag: "prosa", input: "Ich habe heute Äpfel, Birnen und Bananen gekauft.", expected: "Ich habe heute Äpfel, Birnen und Bananen gekauft."),
        .init(id: "o04", tag: "prosa", input: "Gestern habe ich Milch, Brot und Eier geholt.", expected: "Gestern habe ich Milch, Brot und Eier geholt."),
        .init(id: "o05", tag: "prosa", input: "Ich brauche Zeit, Ruhe und Geduld.", expected: "Ich brauche Zeit, Ruhe und Geduld."),
        .init(id: "o06", tag: "prosa", input: "Ich brauche dich, deine Liebe und deine Zeit.", expected: "Ich brauche dich, deine Liebe und deine Zeit."),
        .init(id: "o07", tag: "prosa", input: "Ich habe Anna, Tom und Lisa getroffen.", expected: "Ich habe Anna, Tom und Lisa getroffen."),
        .init(id: "o08", tag: "prosa", input: "Wir waren in Paris, Rom und London.", expected: "Wir waren in Paris, Rom und London."),
        .init(id: "o09", tag: "prosa", input: "Sie ist klug, witzig und ehrlich.", expected: "Sie ist klug, witzig und ehrlich."),
        .init(id: "o10", tag: "prosa", input: "The food was cheap, tasty and fast.", expected: "The food was cheap, tasty and fast."),
        .init(id: "o11", tag: "prosa", input: "I met Sarah, John and Mike at the conference.", expected: "I met Sarah, John and Mike at the conference."),
        .init(id: "o12", tag: "prosa", input: "We visited Berlin, Munich and Hamburg last summer.", expected: "We visited Berlin, Munich and Hamburg last summer."),
        .init(id: "o13", tag: "prosa", input: "I bought eggs, milk and bread yesterday.", expected: "I bought eggs, milk and bread yesterday."),
        .init(id: "o14", tag: "prosa", input: "I need time, patience and support right now.", expected: "I need time, patience and support right now."),
        .init(id: "o15", tag: "prosa", input: "Brauchst du Milch, Brot oder Eier?", expected: "Brauchst du Milch, Brot oder Eier?"),
        .init(id: "o16", tag: "prosa", input: "Wenn du Zeit hast, Lust hast und nicht müde bist, komm vorbei.", expected: "Wenn du Zeit hast, Lust hast und nicht müde bist, komm vorbei."),
        .init(id: "o17", tag: "prosa", input: "Kommst du morgen, übermorgen oder am Wochenende?", expected: "Kommst du morgen, übermorgen oder am Wochenende?"),
        .init(id: "o18", tag: "prosa", input: "Wir können Pizza, Pasta oder Salat essen.", expected: "Wir können Pizza, Pasta oder Salat essen."),
        .init(id: "o19", tag: "prosa", input: "Ich mag Äpfel, Birnen und Kirschen.", expected: "Ich mag Äpfel, Birnen und Kirschen."),
        .init(id: "o20", tag: "prosa", input: "Wir müssen reden, zuhören und verstehen.", expected: "Wir müssen reden, zuhören und verstehen."),
        .init(id: "o21", tag: "prosa", input: "I have to admit, I was wrong, and I'm sorry.", expected: "I have to admit, I was wrong, and I'm sorry."),
        .init(id: "o22", tag: "prosa", input: "Ich muss sagen, das Essen war gut, der Service schnell und die Preise fair.",
              expected: "Ich muss sagen, das Essen war gut, der Service schnell und die Preise fair."),
        .init(id: "o23", tag: "prosa", input: "Zuerst dachte ich, das wird nichts, aber dann hat es doch geklappt.", expected: "Zuerst dachte ich, das wird nichts, aber dann hat es doch geklappt."),
        .init(id: "o24", tag: "prosa", input: "Dann gehen wir essen, danach ins Kino.", expected: "Dann gehen wir essen, danach ins Kino."),
        .init(id: "o25", tag: "prosa", input: "Kannst du mir Milch, Brot und Eier mitbringen?", expected: "Kannst du mir Milch, Brot und Eier mitbringen?"),
        .init(id: "o26", tag: "prosa", input: "Hast du an Pass, Tickets und Geld gedacht?", expected: "Hast du an Pass, Tickets und Geld gedacht?"),
        .init(id: "o27", tag: "prosa", input: "Ich habe Milch, Brot und Eier eingepackt.", expected: "Ich habe Milch, Brot und Eier eingepackt."),
        .init(id: "o28", tag: "prosa", input: "Er hat gesagt, dass wir Stühle, Tische und Beamer brauchen.", expected: "Er hat gesagt, dass wir Stühle, Tische und Beamer brauchen."),
        .init(id: "o29", tag: "prosa", input: "Die Kinder spielen, lachen und rennen im Garten.", expected: "Die Kinder spielen, lachen und rennen im Garten."),
        .init(id: "o30", tag: "prosa", input: "Hallo Anna, hallo Tom, hallo Lisa.", expected: "Hallo Anna, hallo Tom, hallo Lisa."),
        .init(id: "o31", tag: "prosa", input: "Danke für die Blumen, den Kuchen und die Karte.", expected: "Danke für die Blumen, den Kuchen und die Karte."),
        .init(id: "o32", tag: "prosa", input: "We need to talk about the budget, the timeline and the team.", expected: "We need to talk about the budget, the timeline and the team."),
        .init(id: "o33", tag: "prosa", input: "I need you, your help and your time.", expected: "I need you, your help and your time."),
        .init(id: "o34", tag: "prosa", input: "Wir brauchen mehr Mut, mehr Glauben und mehr Liebe.", expected: "Wir brauchen mehr Mut, mehr Glauben und mehr Liebe."),
        .init(id: "o35", tag: "prosa", input: "Ich gehe heute einkaufen, kochen und putzen.", expected: "Ich gehe heute einkaufen, kochen und putzen."),
        .init(id: "o36", tag: "prosa", input: "Die Farben sind Rot, Blau und Grün.", expected: "Die Farben sind Rot, Blau und Grün."),
        .init(id: "o37", tag: "prosa", input: "Mein Lieblingsessen sind Pizza, Pasta und Sushi.", expected: "Mein Lieblingsessen sind Pizza, Pasta und Sushi."),
        .init(id: "o38", tag: "prosa", input: "Das Camp war laut, chaotisch und wunderschön.", expected: "Das Camp war laut, chaotisch und wunderschön."),
        .init(id: "o39", tag: "prosa", input: "Ich hole Anna, Tom und Lisa vom Bahnhof ab.", expected: "Ich hole Anna, Tom und Lisa vom Bahnhof ab."),
        .init(id: "o40", tag: "prosa", input: "Wir fahren morgen nach Berlin, Leipzig und Dresden.", expected: "Wir fahren morgen nach Berlin, Leipzig und Dresden."),
        .init(id: "o41", tag: "prosa", input: "Ich pack das schon, keine Sorge, das wird gut.", expected: "Ich pack das schon, keine Sorge, das wird gut."),
        .init(id: "o42", tag: "prosa", input: "Get well soon, rest a lot and drink water.", expected: "Get well soon, rest a lot and drink water."),
        .init(id: "o43", tag: "prosa", input: "Brot, Butter und Marmelade stehen auf dem Tisch.", expected: "Brot, Butter und Marmelade stehen auf dem Tisch."),
        .init(id: "o44", tag: "prosa", input: "Ich muss noch schnell was essen, duschen und los.", expected: "Ich muss noch schnell was essen, duschen und los."),
        .init(id: "o45", tag: "prosa", input: "Zuerst gehen wir essen, dann ins Kino, danach nach Hause.", expected: "Zuerst gehen wir essen, dann ins Kino, danach nach Hause."),
        .init(id: "o46", tag: "prosa", input: "Zuerst waren wir im Museum, dann im Park, danach beim Italiener und zum Schluss noch im Kino.",
              expected: "Zuerst waren wir im Museum, dann im Park, danach beim Italiener und zum Schluss noch im Kino."),
        .init(id: "o47", tag: "prosa", input: "First we went to the museum, then to the park, after that to a café, and finally to the cinema.",
              expected: "First we went to the museum, then to the park, after that to a café, and finally to the cinema."),
        .init(id: "o48", tag: "prosa", input: "Komm rein. Setz dich. Fühl dich wie zu Hause.", expected: "Komm rein. Setz dich. Fühl dich wie zu Hause."),
        .init(id: "o49", tag: "prosa", input: "Für das Meeting brauche ich Rafael, Nico und Pierre.", expected: "Für das Meeting brauche ich Rafael, Nico und Pierre."),
        .init(id: "o50", tag: "prosa", input: "Grab milk, eggs, and coffee on your way home.", expected: "Grab milk, eggs, and coffee on your way home."),
        .init(id: "o51", tag: "prosa", input: "Can you pick up some apples, bananas and oranges?", expected: "Can you pick up some apples, bananas and oranges?"),
        .init(id: "o52", tag: "prosa", input: "Ich habe 3 Kinder, 2 Hunde und eine Katze.", expected: "Ich habe 3 Kinder, 2 Hunde und eine Katze."),
        .init(id: "o53", tag: "prosa", input: "Das kostet 12,50 €, 8 € und 3,20 €.", expected: "Das kostet 12,50 €, 8 € und 3,20 €."),
        .init(id: "o54", tag: "prosa", input: "Liebe Grüße, Lena.", expected: "Liebe Grüße, Lena."),
        .init(id: "o55", tag: "prosa", input: "Das Wetter ist schön, die Sonne scheint, wir gehen raus.", expected: "Das Wetter ist schön, die Sonne scheint, wir gehen raus."),
        .init(id: "o56", tag: "prosa", input: "I love you, I miss you and I can't wait to see you.", expected: "I love you, I miss you and I can't wait to see you."),
        .init(id: "o57", tag: "prosa", input: "Thanks for the flowers, the cake and the card.", expected: "Thanks for the flowers, the cake and the card."),
        .init(id: "o58", tag: "prosa", input: "Er kauft Aktien, Anleihen und Gold, weil er Angst vor Inflation hat.",
              expected: "Er kauft Aktien, Anleihen und Gold, weil er Angst vor Inflation hat."),
        .init(id: "o59", tag: "prosa", input: "Ich brauche noch ein bisschen Zeit, dann melde ich mich.", expected: "Ich brauche noch ein bisschen Zeit, dann melde ich mich."),
        .init(id: "o60", tag: "prosa", input: "Wir sollten über das Budget, den Zeitplan und das Team sprechen.", expected: "Wir sollten über das Budget, den Zeitplan und das Team sprechen."),
        .init(id: "o61", tag: "prosa", input: "At first I didn't like it, then I got used to it, and finally I loved it.",
              expected: "At first I didn't like it, then I got used to it, and finally I loved it."),
        .init(id: "o62", tag: "prosa", input: "Dad needs rest, water and some quiet.", expected: "Dad needs rest, water and some quiet."),
        .init(id: "o63", tag: "prosa", input: "Wir bringen Freude, Hoffnung und Liebe mit.", expected: "Wir bringen Freude, Hoffnung und Liebe mit."),
        .init(id: "o64", tag: "prosa", input: "Ruf mich an, wenn du Zeit hast.", expected: "Ruf mich an, wenn du Zeit hast."),
        .init(id: "o65", tag: "prosa", input: "Jesus ist der Weg, die Wahrheit und das Leben.", expected: "Jesus ist der Weg, die Wahrheit und das Leben."),
        .init(id: "o66", tag: "prosa", input: "Ich habe mit Nico, Mia und Papa telefoniert.", expected: "Ich habe mit Nico, Mia und Papa telefoniert."),
    ]

    /// Nachträglich geschrieben, OHNE die Regeln danach anzupassen – misst, wie gut sie verallgemeinern (`--holdout`).
    static let holdout: [ListCase] = [
        .init(id: "x01", tag: "einkauf", input: "Ich fahre gleich zu Aldi und brauche Toast, Käse, Gurken und Joghurt.",
              expected: "Ich fahre gleich zu Aldi und brauche:\n- Toast\n- Käse\n- Gurken\n- Joghurt"),
        .init(id: "x02", tag: "einkauf", input: "Für die Freizeit müssen wir noch Bälle, Seile, Hütchen und Pfeifen besorgen.",
              expected: "Für die Freizeit müssen wir noch besorgen:\n- Bälle\n- Seile\n- Hütchen\n- Pfeifen"),
        .init(id: "x03", tag: "agenda", input: "Die Punkte für heute sind Rückblick, Finanzen und Ausblick.", expected: "Die Punkte für heute:\n- Rückblick\n- Finanzen\n- Ausblick"),
        .init(id: "x04", tag: "schritte", input: "Zuerst Wasser kochen, dann den Tee reinhängen, danach drei Minuten warten und zum Schluss Honig dazugeben.",
              expected: "1. Wasser kochen\n2. Den Tee reinhängen\n3. Drei Minuten warten\n4. Honig dazugeben"),
        .init(id: "x05", tag: "todo", input: "Ich muss morgen noch das Auto tanken, die Pakete abholen und Oma anrufen.",
              expected: "To-dos (morgen):\n[ ] Das Auto tanken\n[ ] Die Pakete abholen\n[ ] Oma anrufen"),
        .init(id: "x06", tag: "packen", input: "Pack bitte die Badehose, das Handtuch, die Sonnenbrille und die Flip-Flops ein.",
              expected: "Packliste:\n- Badehose\n- Handtuch\n- Sonnenbrille\n- Flip-Flops"),
        .init(id: "x07", tag: "rangliste", input: "Meine Top fünf Lieder sind Deeper, Holy Presence, Masters, Symphony und Ghost.",
              expected: "Meine Top fünf Lieder:\n1. Deeper\n2. Holy Presence\n3. Masters\n4. Symphony\n5. Ghost"),
        .init(id: "x08", tag: "imperativ", input: "Ruf den Vermieter an. Schreib der Versicherung. Bezahl die Stromrechnung.",
              expected: "- Ruf den Vermieter an\n- Schreib der Versicherung\n- Bezahl die Stromrechnung"),
        .init(id: "x09", tag: "einkauf", input: "I need to pick up bread, cheese, tomatoes and wine.", expected: "Shopping:\n- Bread\n- Cheese\n- Tomatoes\n- Wine"),
        .init(id: "x10", tag: "packen", input: "Things to bring: sleeping bag, flashlight, rain jacket and snacks.",
              expected: "Things to bring:\n- Sleeping bag\n- Flashlight\n- Rain jacket\n- Snacks"),
        .init(id: "x11", tag: "schritte", input: "First, log in to the dashboard, then open billing, next download the invoice, and finally send it to Pierre.",
              expected: "1. Log in to the dashboard\n2. Open billing\n3. Download the invoice\n4. Send it to Pierre"),
        .init(id: "x12", tag: "todo", input: "I have to clean the kitchen, do the laundry and call my dad.", expected: "To-dos:\n[ ] Clean the kitchen\n[ ] Do the laundry\n[ ] Call my dad"),
        .init(id: "x13", tag: "rangliste", input: "The priorities are hiring, fundraising and the product launch.", expected: "The priorities:\n1. Hiring\n2. Fundraising\n3. The product launch"),
        .init(id: "x14", tag: "einkauf", input: "Buy coffee, oat milk, bananas, and eggs.", expected: "Shopping:\n- Coffee\n- Oat milk\n- Bananas\n- Eggs"),
        .init(id: "x15", tag: "hinweis", input: "Bibel, Stift, Notizbuch, als Liste bitte.", expected: "- Bibel\n- Stift\n- Notizbuch"),
        .init(id: "x16", tag: "hinweis", input: "Wir brauchen Brot, Käse und Wein, keine Liste.", expected: "Wir brauchen Brot, Käse und Wein."),
        .init(id: "x17", tag: "hinweis", input: "Send the draft to Tom. Book the room. Order lunch. Numbered.", expected: "1. Send the draft to Tom\n2. Book the room\n3. Order lunch"),
        .init(id: "x18", tag: "gemischt", input: "Hi Anna. Für Samstag brauchen wir noch Kuchen, Kaffee, Teller und Servietten. Kannst du was davon mitbringen?",
              expected: "Hi Anna.\n\nFür Samstag brauchen wir noch:\n- Kuchen\n- Kaffee\n- Teller\n- Servietten\n\nKannst du was davon mitbringen?"),
        .init(id: "y01", tag: "prosa", input: "Ich war gestern bei Mama, bei Oma und bei Tante Gabi.", expected: "Ich war gestern bei Mama, bei Oma und bei Tante Gabi."),
        .init(id: "y02", tag: "prosa", input: "Wir haben Pizza, Salat und Eis gegessen.", expected: "Wir haben Pizza, Salat und Eis gegessen."),
        .init(id: "y03", tag: "prosa", input: "Er ist groß, stark und schnell.", expected: "Er ist groß, stark und schnell."),
        .init(id: "y04", tag: "prosa", input: "I called Tom, Anna and Lisa this morning.", expected: "I called Tom, Anna and Lisa this morning."),
        .init(id: "y05", tag: "prosa", input: "We talked about money, time and priorities.", expected: "We talked about money, time and priorities."),
        .init(id: "y06", tag: "prosa", input: "Ich muss zugeben, du hattest recht, und es tut mir leid.", expected: "Ich muss zugeben, du hattest recht, und es tut mir leid."),
        .init(id: "y07", tag: "prosa", input: "Kauf dir was Schönes, du hast es dir verdient.", expected: "Kauf dir was Schönes, du hast es dir verdient."),
        .init(id: "y08", tag: "prosa", input: "Zuerst war ich skeptisch, dann neugierig und am Ende begeistert.", expected: "Zuerst war ich skeptisch, dann neugierig und am Ende begeistert."),
        .init(id: "y09", tag: "prosa", input: "First I was nervous, then excited, and finally relieved.", expected: "First I was nervous, then excited, and finally relieved."),
        .init(id: "y10", tag: "prosa", input: "Ich brauche dringend Urlaub, Schlaf und Ruhe.", expected: "Ich brauche dringend Urlaub, Schlaf und Ruhe."),
        .init(id: "y11", tag: "prosa", input: "Brauchen wir Milch, Eier oder Butter?", expected: "Brauchen wir Milch, Eier oder Butter?"),
        .init(id: "y12", tag: "prosa", input: "Nimm dir Zeit, trink was und entspann dich.", expected: "Nimm dir Zeit, trink was und entspann dich."),
        .init(id: "y13", tag: "prosa", input: "Sie hat Äpfel, Birnen und Pflaumen im Garten.", expected: "Sie hat Äpfel, Birnen und Pflaumen im Garten."),
        .init(id: "y14", tag: "prosa", input: "Bring deine Freunde, deine Familie und deine Nachbarn mit.", expected: "Bring deine Freunde, deine Familie und deine Nachbarn mit."),
        .init(id: "y15", tag: "prosa", input: "Das Team besteht aus Anna, Tom, Lisa und Ben.", expected: "Das Team besteht aus Anna, Tom, Lisa und Ben."),
        .init(id: "y16", tag: "prosa", input: "I love pizza, pasta and ice cream.", expected: "I love pizza, pasta and ice cream."),
        .init(id: "y17", tag: "prosa", input: "Wir müssen lernen, wachsen und vertrauen.", expected: "Wir müssen lernen, wachsen und vertrauen."),
        .init(id: "y18", tag: "prosa", input: "Heute Morgen habe ich gebetet, gelesen und Kaffee getrunken.", expected: "Heute Morgen habe ich gebetet, gelesen und Kaffee getrunken."),
        .init(id: "y19", tag: "prosa", input: "Pack's an, du schaffst das, ich glaub an dich.", expected: "Pack's an, du schaffst das, ich glaub an dich."),
        .init(id: "y20", tag: "prosa", input: "Can you buy milk, eggs and bread on the way?", expected: "Can you buy milk, eggs and bread on the way?"),
        .init(id: "y21", tag: "prosa", input: "Ich hätte gern einen Kaffee, ein Croissant und ein Wasser.", expected: "Ich hätte gern einen Kaffee, ein Croissant und ein Wasser."),
        .init(id: "y22", tag: "prosa", input: "Get some rest, drink some water and call me tomorrow.", expected: "Get some rest, drink some water and call me tomorrow."),
    ]

    /// Zweiter frischer Satz – einmal gemessen, danach nicht nachgestellt (`--holdout2`)
    static let holdout2: [ListCase] = [
        .init(id: "w01", tag: "einkauf", input: "Ich muss noch Nudeln, Tomatensoße, Parmesan und Basilikum holen.", expected: "Einkaufen:\n- Nudeln\n- Tomatensoße\n- Parmesan\n- Basilikum"),
        .init(id: "w02", tag: "einkauf", input: "Wir brauchen für das Frühstück Brötchen, Butter, Marmelade und Kaffee.",
              expected: "Wir brauchen für das Frühstück:\n- Brötchen\n- Butter\n- Marmelade\n- Kaffee"),
        .init(id: "w03", tag: "einkauf", input: "Please buy toilet paper, dish soap and garbage bags.", expected: "Shopping:\n- Toilet paper\n- Dish soap\n- Garbage bags"),
        .init(id: "w04", tag: "packen", input: "Für das Wochenende packe ich zwei T-Shirts, eine Jeans, die Jacke und das Ladekabel ein.",
              expected: "Für das Wochenende packe ich ein:\n- Zwei T-Shirts\n- Eine Jeans\n- Jacke\n- Ladekabel"),
        .init(id: "w05", tag: "agenda", input: "Themen für das Teammeeting: Urlaubsplanung, neue Kunden und Serverkosten.",
              expected: "Themen für das Teammeeting:\n- Urlaubsplanung\n- Neue Kunden\n- Serverkosten"),
        .init(id: "w06", tag: "agenda", input: "The topics for tomorrow are onboarding, pricing and the roadmap.", expected: "The topics for tomorrow:\n- Onboarding\n- Pricing\n- The roadmap"),
        .init(id: "w07", tag: "schritte", input: "Zuerst den Rechner neu starten, dann das Kabel prüfen, danach den Router resetten und zum Schluss den Support anrufen.",
              expected: "1. Den Rechner neu starten\n2. Das Kabel prüfen\n3. Den Router resetten\n4. Den Support anrufen"),
        .init(id: "w08", tag: "schritte", input: "First, sign up, then verify your email, and finally choose a plan.", expected: "1. Sign up\n2. Verify your email\n3. Choose a plan"),
        .init(id: "w09", tag: "todo", input: "Ich muss heute noch die Steuer machen, den Keller aufräumen und Nico zurückrufen.",
              expected: "To-dos (heute):\n[ ] Die Steuer machen\n[ ] Den Keller aufräumen\n[ ] Nico zurückrufen"),
        .init(id: "w10", tag: "todo", input: "We need to update the docs, fix the tests and ship the release.", expected: "To-dos:\n[ ] Update the docs\n[ ] Fix the tests\n[ ] Ship the release"),
        .init(id: "w11", tag: "imperativ", input: "Mach die Heizung aus. Schließ die Fenster. Stell den Müll raus.",
              expected: "- Mach die Heizung aus\n- Schließ die Fenster\n- Stell den Müll raus"),
        .init(id: "w12", tag: "rangliste", input: "Meine Top drei Städte sind Lissabon, Rom und Kapstadt.", expected: "Meine Top drei Städte:\n1. Lissabon\n2. Rom\n3. Kapstadt"),
        .init(id: "w13", tag: "hinweis", input: "Anna, Tom, Lisa und Ben, als Checkliste.", expected: "[ ] Anna\n[ ] Tom\n[ ] Lisa\n[ ] Ben"),
        .init(id: "w14", tag: "hinweis", input: "Ich muss noch Mehl, Zucker, Eier und Milch kaufen, nicht als Liste.", expected: "Ich muss noch Mehl, Zucker, Eier und Milch kaufen."),
        .init(id: "v01", tag: "prosa", input: "Ich bin heute müde, aber glücklich und dankbar.", expected: "Ich bin heute müde, aber glücklich und dankbar."),
        .init(id: "v02", tag: "prosa", input: "Wir haben Rafael, Pierre und Milan eingeladen.", expected: "Wir haben Rafael, Pierre und Milan eingeladen."),
        .init(id: "v03", tag: "prosa", input: "Sie kauft immer Bio-Eier, Hafermilch und Vollkornbrot.", expected: "Sie kauft immer Bio-Eier, Hafermilch und Vollkornbrot."),
        .init(id: "v04", tag: "prosa", input: "I need a break, a coffee and a nap.", expected: "I need a break, a coffee and a nap."),
        .init(id: "v05", tag: "prosa", input: "Er hat Hunger, Durst und Kopfweh.", expected: "Er hat Hunger, Durst und Kopfweh."),
        .init(id: "v06", tag: "prosa", input: "Zuerst Gott, dann die Familie, dann die Arbeit.", expected: "Zuerst Gott, dann die Familie, dann die Arbeit."),
        .init(id: "v07", tag: "prosa", input: "We went hiking, swimming and camping.", expected: "We went hiking, swimming and camping."),
        .init(id: "v08", tag: "prosa", input: "Ich brauche nur dich, Musik und einen guten Kaffee.", expected: "Ich brauche nur dich, Musik und einen guten Kaffee."),
        .init(id: "v09", tag: "prosa", input: "Kauf nicht zu viel, wir haben noch Brot, Käse und Obst.", expected: "Kauf nicht zu viel, wir haben noch Brot, Käse und Obst."),
        .init(id: "v10", tag: "prosa", input: "Das Konzert, die Predigt und der Lobpreis waren stark.", expected: "Das Konzert, die Predigt und der Lobpreis waren stark."),
        .init(id: "v11", tag: "prosa", input: "Bring Geduld, gute Laune und Humor mit.", expected: "Bring Geduld, gute Laune und Humor mit."),
        .init(id: "v12", tag: "prosa", input: "Pack your bags, we're leaving in ten minutes.", expected: "Pack your bags, we're leaving in ten minutes."),
        .init(id: "v13", tag: "prosa", input: "Holt ihr uns ab, oder sollen wir laufen?", expected: "Holt ihr uns ab, oder sollen wir laufen?"),
        .init(id: "v14", tag: "prosa", input: "Ich habe Rom, Paris, London und Madrid besucht.", expected: "Ich habe Rom, Paris, London und Madrid besucht."),
        .init(id: "v15", tag: "prosa", input: "Kommt rein. Macht es euch gemütlich. Nehmt euch was zu trinken.", expected: "Kommt rein. Macht es euch gemütlich. Nehmt euch was zu trinken."),
        .init(id: "v16", tag: "prosa", input: "Order matters, timing matters and people matter.", expected: "Order matters, timing matters and people matter."),
    ]

    /// Dritter frischer Satz (Endmessung, nicht nachgestellt) – `--holdout3`
    static let holdout3: [ListCase] = [
        .init(id: "u01", tag: "einkauf", input: "Ich gehe nachher einkaufen und brauche Äpfel, Karotten, Hummus und Wraps.", expected: "Einkaufen (nachher):\n- Äpfel\n- Karotten\n- Hummus\n- Wraps"),
        .init(id: "u02", tag: "einkauf", input: "Can you grab batteries, tape, zip ties and a flashlight?", expected: "Can you grab batteries, tape, zip ties and a flashlight?"),
        .init(id: "u03", tag: "packen", input: "Für die Freizeit packen wir Zelte, Planen, Seile und Heringe ein.", expected: "Für die Freizeit packen wir ein:\n- Zelte\n- Planen\n- Seile\n- Heringe"),
        .init(id: "u04", tag: "agenda", input: "Agenda: Begrüßung, Lobpreis, Predigt, Abkündigungen und Segen.", expected: "Agenda:\n- Begrüßung\n- Lobpreis\n- Predigt\n- Abkündigungen\n- Segen"),
        .init(id: "u05", tag: "schritte", input: "Zuerst öffnest du Einstellungen, dann gehst du auf Datenschutz, danach auf Mikrofon und zum Schluss setzt du den Haken bei Flow.",
              expected: "1. Zuerst öffnest du Einstellungen\n2. Dann gehst du auf Datenschutz\n3. Danach auf Mikrofon\n4. Zum Schluss setzt du den Haken bei Flow"),
        .init(id: "u06", tag: "todo", input: "Ich muss diese Woche noch die Rechnung an KiTaNet schicken, das Portal updaten und mit Pierre telefonieren.",
              expected: "To-dos:\n[ ] Die Rechnung an KiTaNet schicken\n[ ] Das Portal updaten\n[ ] Mit Pierre telefonieren"),
        .init(id: "u07", tag: "todo", input: "I need to renew the domain, cancel the old plan and back up the database.",
              expected: "To-dos:\n[ ] Renew the domain\n[ ] Cancel the old plan\n[ ] Back up the database"),
        .init(id: "u08", tag: "rangliste", input: "My top three apps are Obsidian, Linear and Raycast.", expected: "My top three apps:\n1. Obsidian\n2. Linear\n3. Raycast"),
        .init(id: "u09", tag: "hinweis", input: "Zelte, Planen, Seile, als nummerierte Liste.", expected: "1. Zelte\n2. Planen\n3. Seile"),
        .init(id: "u10", tag: "imperativ", input: "Lösch die alten Backups. Starte den Server neu. Prüf die Logs.", expected: "- Lösch die alten Backups\n- Starte den Server neu\n- Prüf die Logs"),
        .init(id: "q01", tag: "prosa", input: "Gott ist treu, gut und gnädig.", expected: "Gott ist treu, gut und gnädig."),
        .init(id: "q02", tag: "prosa", input: "Ich habe heute gearbeitet, gekocht und aufgeräumt.", expected: "Ich habe heute gearbeitet, gekocht und aufgeräumt."),
        .init(id: "q03", tag: "prosa", input: "Wir brauchen dich, wir lieben dich und wir vermissen dich.", expected: "Wir brauchen dich, wir lieben dich und wir vermissen dich."),
        .init(id: "q04", tag: "prosa", input: "Nico, Mia und ich fahren morgen nach Hamburg.", expected: "Nico, Mia und ich fahren morgen nach Hamburg."),
        .init(id: "q05", tag: "prosa", input: "I need to think about it, talk to Nico and then decide.", expected: "I need to think about it, talk to Nico and then decide."),
        .init(id: "q06", tag: "prosa", input: "Ich kaufe lieber Qualität statt Quantität, das lohnt sich.", expected: "Ich kaufe lieber Qualität statt Quantität, das lohnt sich."),
        .init(id: "q07", tag: "prosa", input: "Die Wohnung ist hell, groß, ruhig und zentral.", expected: "Die Wohnung ist hell, groß, ruhig und zentral."),
        .init(id: "q08", tag: "prosa", input: "We bought a house, a car and a dog last year.", expected: "We bought a house, a car and a dog last year."),
        .init(id: "q09", tag: "prosa", input: "Hol mich ab, wenn du fertig bist, und bring gute Laune mit.", expected: "Hol mich ab, wenn du fertig bist, und bring gute Laune mit."),
        .init(id: "q10", tag: "prosa", input: "Zuerst lachen, dann weinen, dann wieder lachen, so ist das Leben.", expected: "Zuerst lachen, dann weinen, dann wieder lachen, so ist das Leben."),
        .init(id: "q11", tag: "prosa", input: "First impressions matter, but consistency matters more.", expected: "First impressions matter, but consistency matters more."),
        .init(id: "q12", tag: "prosa", input: "Er braucht keine Hilfe, kein Geld und keine Ratschläge.", expected: "Er braucht keine Hilfe, kein Geld und keine Ratschläge."),
        .init(id: "q13", tag: "prosa", input: "Ich brauche einen Laptop, der schnell, leise und leicht ist.", expected: "Ich brauche einen Laptop, der schnell, leise und leicht ist."),
        .init(id: "q14", tag: "prosa", input: "Packen wir's an, Leute, das wird ein guter Tag.", expected: "Packen wir's an, Leute, das wird ein guter Tag."),
        .init(id: "q15", tag: "prosa", input: "Bring it on, we are ready, let's go.", expected: "Bring it on, we are ready, let's go."),
        .init(id: "q16", tag: "prosa", input: "Wir haben Kaffee, Kuchen und gute Gespräche genossen.", expected: "Wir haben Kaffee, Kuchen und gute Gespräche genossen."),
        .init(id: "q17", tag: "prosa", input: "Ich hole mir einen Kaffee, dann geht's weiter.", expected: "Ich hole mir einen Kaffee, dann geht's weiter."),
        .init(id: "q18", tag: "prosa", input: "Der Plan: erst essen, dann reden.", expected: "Der Plan: erst essen, dann reden."),
        .init(id: "q19", tag: "prosa", input: "Order the pizza, I'll get the drinks and you bring dessert.", expected: "Order the pizza, I'll get the drinks and you bring dessert."),
        .init(id: "q20", tag: "prosa", input: "Wir müssen mutig, ehrlich und demütig bleiben.", expected: "Wir müssen mutig, ehrlich und demütig bleiben."),
    ]
}

/// `--quality-lists-eval [--show] [--only id,id]` – Präzision, Genauigkeit, Zeit je Ziel-App
enum ListEval {
    /// `--quality-lists-eval --tags "text"`: Wortarten wie SmartLists sie sieht
    static func tags(_ text: String) {
        let lang = SmartLists.language(text)
        print("Sprache: \(lang.rawValue)")
        print(SmartLists.tag(text, lang: lang).map { "\($0.text)/\($0.tag?.rawValue ?? "?")/\($0.lemma)" }.joined(separator: " "))
    }

    static func run(_ args: [String]) async -> Int32 {
        if let i = args.firstIndex(of: "--tags"), i + 1 < args.count { tags(args[i + 1]); return 0 }
        let show = args.contains("--show")
        let only = args.firstIndex(of: "--only").flatMap { $0 + 1 < args.count ? Set(args[$0 + 1].split(separator: ",").map(String.init)) : nil }
        let pool = args.contains("--holdout3") ? ListCases.holdout3 : args.contains("--holdout2") ? ListCases.holdout2 : args.contains("--holdout") ? ListCases.holdout : args.contains("--beide") ? ListCases.all + ListCases.holdout : ListCases.all
        let cases = pool.filter { only == nil || only!.contains($0.id) }
        Polisher.fmAvailable = { false }        // Lenas Mac: Apple Intelligence aus → die Regeln tragen allein
        SmartLists.prewarm()
        _ = QuickPolish.lexicalClasses("warm up"); _ = SpellBatch.unknown(["warmup"])
        print("\(cases.count) Fälle × \(ListCases.bundles.count) Ziel-Apps · Tags: " + Dictionary(grouping: cases, by: \.tag).map { "\($0.key) \($0.value.count)" }.sorted().joined(separator: ", "))
        var failed = 0
        var times: [Double] = []
        var listTimes: [Double] = [], oldTimes: [Double] = [], detTimes: [Double] = []
        print("\nZiel       genau   Listen-Fälle  Prosa unberührt  falsche Listen  verpasst  Punkte exakt")
        var perTag: [String: (Int, Int)] = [:]
        for (target, bundle) in ListCases.bundles {
            var exact = 0, prose = 0, proseOK = 0, falseLists = 0, missed = 0, listCases = 0, itemsOK = 0
            for c in cases {
                let exp = QualityCLI.norm(ListCases.expected(c, target))
                let t0 = DispatchTime.now().uptimeNanoseconds
                let rules = QuickPolish.apply(c.input, snapshot: nil, app: bundle)
                times.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000)
                let t1 = DispatchTime.now().uptimeNanoseconds
                _ = SmartLists.pass(c.input, target: target)
                listTimes.append(Double(DispatchTime.now().uptimeNanoseconds - t1) / 1_000_000)
                let t2 = DispatchTime.now().uptimeNanoseconds
                _ = QuickPolish.formatLists(c.input)
                oldTimes.append(Double(DispatchTime.now().uptimeNanoseconds - t2) / 1_000_000)
                let t3 = DispatchTime.now().uptimeNanoseconds
                _ = SmartLists.format(c.input, target: target)
                detTimes.append(Double(DispatchTime.now().uptimeNanoseconds - t3) / 1_000_000)
                let o = await Polisher.run(c.input, snapshot: nil, mode: .fast, app: bundle)
                let out = QualityCLI.norm(o.text)
                _ = rules
                let outLines = out.components(separatedBy: "\n").filter(ListCases.isListLine)
                let expLines = exp.components(separatedBy: "\n").filter(ListCases.isListLine)
                let ok = out == exp
                if ok { exact += 1 }
                var pt = perTag[c.tag] ?? (0, 0); pt.1 += 1; if ok { pt.0 += 1 }; perTag[c.tag] = pt
                if expLines.isEmpty {
                    prose += 1
                    if outLines.isEmpty { proseOK += 1 } else { falseLists += 1 }
                } else {
                    listCases += 1
                    if outLines.isEmpty { missed += 1 }
                    if outLines == expLines { itemsOK += 1 }
                }
                if !ok { failed += 1 }
                if show || !ok {
                    print("  \(ok ? "✓" : "✗") \(target.rawValue) \(c.id) [\(o.engine)]: \(out.replacingOccurrences(of: "\n", with: "⏎"))"
                          + (ok ? "" : "\n      erwartet: \(exp.replacingOccurrences(of: "\n", with: "⏎"))"))
                }
            }
            print(String(format: "%-9@ %3d/%3d   %3d           %3d/%3d          %3d            %3d       %3d/%3d", target.rawValue as NSString, exact, cases.count,
                         listCases, proseOK, prose, falseLists, missed, itemsOK, listCases))
        }
        times.sort(); listTimes.sort(); oldTimes.sort(); detTimes.sort()
        func q(_ a: [Double], _ p: Double) -> Double { a.isEmpty ? 0 : a[min(a.count - 1, Int(Double(a.count) * p))] }
        print(String(format: "\nRegel-Stufe gesamt (QuickPolish.apply): p50 %.2f ms · p95 %.2f ms · max %.2f ms (%d Läufe)", q(times, 0.5), q(times, 0.95), times.last ?? 0, times.count))
        print(String(format: "davon Listen (SmartLists.pass):       p50 %.2f ms · p95 %.2f ms · max %.2f ms", q(listTimes, 0.5), q(listTimes, 0.95), listTimes.last ?? 0))
        print(String(format: "  „erstens …“ (formatLists, alt):       p50 %.2f ms · p95 %.2f ms", q(oldTimes, 0.5), q(oldTimes, 0.95)))
        print(String(format: "  Erkennung neu (SmartLists.format):    p50 %.2f ms · p95 %.2f ms", q(detTimes, 0.5), q(detTimes, 0.95)))
        print("Genau je Art (alle Ziel-Apps): " + perTag.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value.0)/\($0.value.1)" }.joined(separator: " · "))
        return failed == 0 ? 0 : 1
    }
}
