// ClipVault — Zustandsautomat der Aktions-Leiste in der Liste (01.10.2026, Fassung 2)
//
// Warum: Joel traf beim Klick auf eine Zeile oder auf „Kopieren" immer wieder aus Versehen
// eines der Icons rechts in der Zeile (in Bereich legen, Löschen, Anheften …).
// Jetzt gibt es rechts nur noch EINEN kleinen Griff (•••):
//   rest     Maus nicht ueber der Zeile: nur der Pin-Status wie bisher
//   compact  Maus ueber der Zeile: nur der Griff (plus Pin-Status, falls angeheftet).
//            Kurzer Klick auf den Griff = harmloses Wackeln + Hinweis „Gedrückt halten"
//   holding  Griff gedrueckt: Ring fuellt sich (0,4 s)
//   armed    Icons sind links aus dem Griff herausgeglitten. Auswahl auf zwei Wegen:
//            - gedrueckt halten, auf ein Icon ziehen, loslassen -> Aktion
//              (loslassen auf dem Griff / daneben -> nichts, Icons bleiben offen)
//            - danach normal auf ein Icon klicken -> Aktion; Klick auf den Griff -> zu
// Zurueck zu compact: nach einer Aktion, nach 4 s ohne Bedienung, mit Esc. Zu rest: Maus verlaesst die Zeile.
//
// Reines Swift ohne AppKit, damit es sich ohne Oberflaeche pruefen laesst (`clipvault actionbar-test`).
import Foundation

enum ActionBarPhase: Equatable { case rest, compact, holding, armed }

/// Was unter der Maus liegt
enum ActionBarTarget: Equatable { case handle, icon(Int), none }

enum ActionBarEffect: Equatable {
    case none
    case armed            // gerade scharf geschaltet -> Icons gleiten heraus
    case collapsed        // wieder eingefahren (Aktion, Zeitablauf, Esc, Griff, Maus weg)
    case nudge            // kurzer Klick auf den Griff: Wackeln + Hinweis, sonst nichts
    case perform(Int)     // Icon i ausgewaehlt
}

struct ActionBarMachine {
    static let holdDuration: TimeInterval = 0.4
    static let idleTimeout: TimeInterval = 4.0
    static let dragSlop: Double = 6          // so weit darf die Maus beim Halten wandern (Punkte)

    private(set) var phase: ActionBarPhase = .rest
    private(set) var holdStart: TimeInterval = 0
    private(set) var lastInteraction: TimeInterval = 0
    /// Ziel, auf dem im offenen Zustand die Taste gedrueckt wurde (Klick zaehlt nur, wenn dort auch losgelassen wird)
    private(set) var pressed: ActionBarTarget? = nil
    /// Die Taste, mit der geoeffnet wurde, ist noch unten (Ziehen-und-Loslassen-Auswahl laeuft)
    private(set) var armingPressDown = false
    /// Maus hat die Zeile verlassen, waehrend die Taste unten war (wird beim Loslassen ausgewertet)
    private(set) var leftRowDuringPress = false

    var isActive: Bool { phase == .holding || phase == .armed }
    var isArmed: Bool { phase == .armed }
    var buttonDown: Bool { phase == .holding || armingPressDown || pressed != nil }

    /// 0…1 waehrend des Haltens, 1 wenn offen, sonst 0
    func holdProgress(_ t: TimeInterval) -> Double {
        switch phase {
        case .holding: return max(0, min(1, (t - holdStart) / ActionBarMachine.holdDuration))
        case .armed: return 1
        default: return 0
        }
    }

    /// Maus betritt / verlaesst die Zeile
    mutating func hover(_ inside: Bool) -> ActionBarEffect {
        if inside {
            leftRowDuringPress = false
            if phase == .rest { phase = .compact }
            return .none
        }
        if phase == .armed && (armingPressDown || pressed != nil) {   // beim Ziehen kurz aus der Zeile: erst beim Loslassen entscheiden
            leftRowDuringPress = true
            return .none
        }
        let was = isActive
        reset(to: .rest)
        return was ? .collapsed : .none
    }

    /// Maustaste gedrueckt. Zu: nur der Griff reagiert. Offen: Icon/Griff/Luecke merken.
    mutating func press(at t: TimeInterval, target: ActionBarTarget) -> ActionBarEffect {
        switch phase {
        case .rest, .compact:
            if target == .handle { phase = .holding; holdStart = t; pressed = nil }
        case .holding:
            break
        case .armed:
            pressed = target; lastInteraction = t
        }
        return .none
    }

    /// Maus bewegt sich bei gedrueckter Taste (Abstand zum Druckpunkt)
    mutating func dragged(distance: Double, at t: TimeInterval) -> ActionBarEffect {
        if phase == .holding && distance > ActionBarMachine.dragSlop {
            reset(to: .compact)          // vom Griff weggezogen, bevor er offen war: abgebrochen
            return .none
        }
        if phase == .armed { lastInteraction = t }
        return .none
    }

    /// Maustaste losgelassen (target = was beim Loslassen unter der Maus liegt)
    mutating func release(at t: TimeInterval, target: ActionBarTarget) -> ActionBarEffect {
        switch phase {
        case .holding:
            if t - holdStart >= ActionBarMachine.holdDuration {   // Zeitgeber kam zu spaet: trotzdem oeffnen
                arm(at: t); armingPressDown = false
                return .armed
            }
            reset(to: .compact)
            return .nudge
        case .armed:
            lastInteraction = t
            let left = leftRowDuringPress; leftRowDuringPress = false
            if armingPressDown {                       // Ziehen-und-Loslassen
                armingPressDown = false
                if case .icon(let i) = target { reset(to: .compact); return .perform(i) }
                if left { reset(to: .rest); return .collapsed }
                return .none                           // auf dem Griff / daneben: offen lassen
            }
            let p = pressed; pressed = nil
            if left { reset(to: .rest); return .collapsed }
            guard let p = p, p == target else { return .none }
            switch p {
            case .icon(let i): reset(to: .compact); return .perform(i)
            case .handle: reset(to: .compact); return .collapsed
            case .none: return .none
            }
        default:
            return .none
        }
    }

    /// Zeitgeber: Halten fertig? Zu lange nichts getan?
    mutating func tick(_ t: TimeInterval) -> ActionBarEffect {
        switch phase {
        case .holding where t - holdStart >= ActionBarMachine.holdDuration:
            arm(at: t)
            return .armed
        case .armed where !buttonDown && t - lastInteraction >= ActionBarMachine.idleTimeout:
            reset(to: .compact)
            return .collapsed
        default:
            return .none
        }
    }

    /// Maus bewegt sich ueber der offenen Leiste: Zeitablauf neu starten
    mutating func interaction(_ t: TimeInterval) { if phase == .armed { lastInteraction = t } }

    /// Esc: true = die Leiste hat die Taste verbraucht
    mutating func escape() -> Bool {
        guard isActive else { return false }
        reset(to: .compact)
        return true
    }

    private mutating func arm(at t: TimeInterval) {
        phase = .armed; lastInteraction = t; armingPressDown = true; pressed = nil
    }
    private mutating func reset(to p: ActionBarPhase) {
        phase = p; pressed = nil; armingPressDown = false; leftRowDuringPress = false
    }
}

/// Feder: gedaempfte Schwingung von 0 nach 1 (zeta < 1 = leichtes Ueberschwingen)
func cvSpring(_ t: Double, period: Double, damping zeta: Double) -> Double {
    if t <= 0 { return 0 }
    let w0 = 2 * Double.pi / period
    if zeta >= 1 { return 1 - (1 + w0 * t) * exp(-w0 * t) }   // kritisch gedaempft: kein Ueberschwingen
    let wd = w0 * sqrt(1 - zeta * zeta)
    return 1 - exp(-zeta * w0 * t) * (cos(wd * t) + (zeta * w0 / wd) * sin(wd * t))
}
