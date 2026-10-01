// ClipVault — Selbsttest des Aktions-Leisten-Automaten (actionbar_state.swift)
//   clipvault actionbar-test
// Reine Logik: fasst weder Verlauf noch Zwischenablage an.
import Foundation

func runActionBarTest() -> Never {
    var fails = 0, n = 0
    func check(_ name: String, _ ok: Bool) {
        n += 1
        print((ok ? "ok    " : "FEHLER ") + name)
        if !ok { fails += 1 }
    }
    let H = ActionBarMachine.holdDuration, T = ActionBarMachine.idleTimeout
    /// bis „offen, Halte-Taste noch unten"
    func opened() -> ActionBarMachine {
        var m = ActionBarMachine(); _ = m.hover(true)
        _ = m.press(at: 0, target: .handle); _ = m.tick(H); return m
    }

    // 1) Ruhe / Hover: nur der Griff reagiert
    do {
        var m = ActionBarMachine()
        check("Start: rest", m.phase == .rest)
        _ = m.hover(true)
        check("Hover: compact (nur Griff)", m.phase == .compact)
        _ = m.press(at: 1, target: .none)
        check("Druck neben den Griff: nichts", m.phase == .compact)
        _ = m.press(at: 2, target: .icon(3))
        check("zu: Icons nicht drueckbar", m.phase == .compact)
    }
    // 2) kurzer Klick auf den Griff = Wackeln, keine Aktion
    do {
        var m = ActionBarMachine(); _ = m.hover(true)
        _ = m.press(at: 10, target: .handle)
        check("Druck auf Griff: holding", m.phase == .holding)
        check("Halte-Fortschritt halb", abs(m.holdProgress(10 + H / 2) - 0.5) < 0.001)
        check("kurzer Klick -> nudge", m.release(at: 10.15, target: .handle) == .nudge)
        check("danach compact", m.phase == .compact)
    }
    // 3) lange halten -> offen
    do {
        var m = ActionBarMachine(); _ = m.hover(true)
        _ = m.press(at: 0, target: .handle)
        check("vor 0,4 s noch zu", m.tick(H - 0.01) == .none && m.phase == .holding)
        check("nach 0,4 s offen", m.tick(H) == .armed && m.isArmed)
    }
    // 4) Ziehen und Loslassen auf einem Icon -> Aktion
    do {
        var m = opened()
        _ = m.dragged(distance: 60, at: 0.6)
        check("Ziehen im offenen Zustand bricht nicht ab", m.isArmed)
        check("Loslassen auf Icon 2 -> perform(2)", m.release(at: 0.8, target: .icon(2)) == .perform(2))
        check("danach eingefahren", m.phase == .compact)
    }
    // 5) Loslassen auf dem Griff / daneben -> nichts, bleibt offen; danach Klick waehlt
    do {
        var m = opened()
        check("Loslassen auf dem Griff: nichts", m.release(at: 0.6, target: .handle) == .none && m.isArmed)
        var m2 = opened()
        check("Loslassen daneben: nichts, bleibt offen", m2.release(at: 0.6, target: .none) == .none && m2.isArmed)
        _ = m2.press(at: 1, target: .icon(4))
        check("Klick auf Icon -> perform(4)", m2.release(at: 1.1, target: .icon(4)) == .perform(4) && m2.phase == .compact)
        _ = m.press(at: 1, target: .icon(1))
        check("Druck Icon 1, loslassen Icon 2: nichts", m.release(at: 1.1, target: .icon(2)) == .none && m.isArmed)
        _ = m.press(at: 1.2, target: .none)
        check("Klick in die Luecke: nichts", m.release(at: 1.3, target: .none) == .none && m.isArmed)
        _ = m.press(at: 1.4, target: .handle)
        check("Klick auf den Griff klappt zu", m.release(at: 1.5, target: .handle) == .collapsed && m.phase == .compact)
    }
    // 6) Halten zu spaet ausgewertet: Loslassen nach >= 0,4 s oeffnet (keine Aktion)
    do {
        var m = ActionBarMachine(); _ = m.hover(true)
        _ = m.press(at: 0, target: .handle)
        check("spaetes Loslassen -> armed", m.release(at: H + 0.05, target: .handle) == .armed && m.isArmed)
    }
    // 7) vom Griff weggezogen, bevor er offen war -> abgebrochen
    do {
        var m = ActionBarMachine(); _ = m.hover(true)
        _ = m.press(at: 0, target: .handle)
        _ = m.dragged(distance: 3, at: 0.1)
        check("kleines Zittern erlaubt", m.phase == .holding)
        _ = m.dragged(distance: 12, at: 0.2)
        check("Wegziehen bricht ab", m.phase == .compact)
        check("Loslassen danach: nichts", m.release(at: 0.3, target: .handle) == .none)
        check("Timer danach: nichts", m.tick(1) == .none && m.phase == .compact)
    }
    // 8) 4 s ohne Bedienung -> einfahren; Bewegung verlaengert; Taste unten = kein Ablauf
    do {
        var m = opened()
        check("Taste unten: kein Zeitablauf", m.tick(H + T + 1) == .none && m.isArmed)
        _ = m.release(at: 5.5, target: .handle)
        check("3,9 s nach Loslassen noch offen", m.tick(5.5 + T - 0.1) == .none && m.isArmed)
        m.interaction(9.0)
        check("Bewegung verlaengert", m.tick(5.5 + T + 0.1) == .none && m.isArmed)
        check("4 s nach Bewegung zu", m.tick(9.0 + T) == .collapsed && m.phase == .compact)
    }
    // 9) Esc
    do {
        var m = ActionBarMachine(); _ = m.hover(true)
        check("Esc zu: nicht verbraucht (Panel schliesst)", m.escape() == false)
        m = opened()
        check("Esc klappt zu", m.escape() == true && m.phase == .compact)
        _ = m.press(at: 5, target: .handle)
        check("Esc waehrend des Haltens bricht ab", m.escape() == true && m.phase == .compact)
        check("danach kein spaetes Oeffnen", m.tick(6) == .none)
    }
    // 10) Maus verlaesst die Zeile
    do {
        var m = opened(); _ = m.release(at: 0.5, target: .handle)
        check("Zeile verlassen klappt zu", m.hover(false) == .collapsed && m.phase == .rest)
        _ = m.hover(true)
        check("wieder drueber: nur Griff", m.phase == .compact)
        _ = m.press(at: 1, target: .handle)
        check("Zeile verlassen beim Halten bricht ab", m.hover(false) == .collapsed && m.phase == .rest)
        check("kein spaetes Oeffnen", m.tick(3) == .none)
        // beim Ziehen kurz raus und wieder rein: bleibt offen, Loslassen auf Icon waehlt
        var d = opened()
        check("beim Ziehen raus: noch offen", d.hover(false) == .none && d.isArmed)
        _ = d.hover(true)
        check("wieder rein + Loslassen auf Icon -> perform", d.release(at: 1, target: .icon(0)) == .perform(0))
        // beim Ziehen raus und draussen losgelassen: zu
        var o = opened(); _ = o.hover(false)
        check("draussen losgelassen: zu", o.release(at: 1, target: .none) == .collapsed && o.phase == .rest)
    }
    // 11) Feder
    do {
        let peak = stride(from: 0.0, to: 1.0, by: 0.005).map { cvSpring($0, period: 0.38, damping: 0.68) }.max() ?? 0
        check("Feder 0 -> 1", cvSpring(0, period: 0.38, damping: 0.68) == 0 && abs(cvSpring(2, period: 0.38, damping: 0.68) - 1) < 0.001)
        check("Feder schwingt dezent ueber (1–10 %)", peak > 1.01 && peak < 1.10)
        let crit = stride(from: 0.0, to: 1.0, by: 0.005).map { cvSpring($0, period: 0.26, damping: 1) }.max() ?? 0
        check("Einfahren ohne Ueberschwingen", crit <= 1.0001)
    }
    print(fails == 0 ? "\nalle \(n) Pruefungen bestanden" : "\n\(fails) von \(n) Pruefungen FEHLGESCHLAGEN")
    exit(fails == 0 ? 0 : 1)
}
