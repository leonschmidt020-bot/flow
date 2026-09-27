import AppKit
import Carbon.HIToolbox

/// Beobachtet die Diktier-Taste (Standard: Fn) über einen CGEventTap.
/// Halten = Push-to-Talk, Doppeltippen = Freihand. Esc bricht ab.
/// Wird die Taste zusammen mit einer anderen Taste gedrückt (z. B. Fn+F1), gilt das nicht als Diktat.
final class HotkeyMonitor {
    enum Event { case pressStart, holdEnd, tapCancelled, comboCancelled, doubleTap, singleTapWhileHandsFree, escape, commandStart, commandEnd }

    var onEvent: ((Event) -> Void)?
    /// Wird vom Controller gesetzt: befindet sich die App gerade im Freihand-Modus?
    var handsFreeActive: () -> Bool = { false }

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var isDown = false
    private var downAt: UInt64 = 0
    private var comboUsed = false
    /// fn + ⌃ gehalten → markierten Text per Sprache umschreiben (Transforms)
    private var commandMode = false
    private var lastTapAt: UInt64 = 0

    /// Unter dieser Haltedauer gilt ein Druck als Tippen (für Doppeltippen / Freihand-Stopp).
    private let tapThreshold: TimeInterval = 0.28
    private let doubleTapWindow: TimeInterval = 0.45

    var isRunning: Bool { tap != nil }

    func start() -> Bool {
        stop()
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                        options: .listenOnly, eventsOfInterest: CGEventMask(mask),
                                        callback: { _, type, event, refcon in
                                            guard let refcon else { return Unmanaged.passUnretained(event) }
                                            let me = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                                            me.handle(type: type, event: event)
                                            return Unmanaged.passUnretained(event)
                                        }, userInfo: refcon) else {
            log("EventTap konnte nicht erstellt werden (Eingabeüberwachung fehlt?)")
            return false
        }
        tap = t
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        log("EventTap aktiv (\(Settings.shared.hotkey.rawValue))")
        return true
    }

    func stop() {
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false) }
        if let s = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        tap = nil; source = nil; isDown = false
    }

    /// Markierung für Tastendrücke, die Flow selbst schickt (⌘C im Befehlsmodus, ⌘V beim Einfügen).
    /// Audit 27.09.2026: das eigene ⌘C kam hier als „andere Taste bei gehaltenem fn“ an → .comboCancelled →
    /// der Befehlsmodus brach sich in Terminals/VS Code/Chrome (⌘C-Weg) sofort selbst ab.
    static let syntheticTag: Int64 = 0x4D524D52   // "MRMR"
    static func markSynthetic(_ e: CGEvent?) { e?.setIntegerValueField(.eventSourceUserData, value: syntheticTag) }

    private func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            // Loslassen verpasst? Mit dem echten Tastenzustand abgleichen
            let held = CGEventSource.flagsState(.combinedSessionState).contains(Settings.shared.hotkey.flag)
            if isDown && !held { isDown = false; onEvent?(.holdEnd) }
            return
        }
        let hk = Settings.shared.hotkey
        if type == .keyDown {
            if event.getIntegerValueField(.eventSourceUserData) == HotkeyMonitor.syntheticTag { return }
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            if code == Int64(kVK_Escape) { onEvent?(.escape); return }
            if isDown && !comboUsed {
                comboUsed = true
                onEvent?(.comboCancelled)
            }
            return
        }
        guard type == .flagsChanged else { return }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        guard code == hk.keyCode else {
            // ⌃ (links 59 / rechts 62) zu gehaltenem fn → Befehlsmodus statt Abbruch
            if hk == .fn, code == 59 || code == 62 {
                if event.flags.contains(.maskControl), isDown, !comboUsed, !commandMode, !handsFreeActive() {
                    commandMode = true
                    onEvent?(.commandStart)
                    return
                }
                if commandMode { return }   // ⌃ loslassen im Befehlsmodus ignorieren
            }
            // Andere Modifier während gehaltener Taste → Kombination, kein Diktat.
            if isDown && !comboUsed {
                comboUsed = true
                onEvent?(.comboCancelled)
            }
            return
        }
        let pressed = event.flags.contains(hk.flag)
        if pressed && !isDown {
            isDown = true
            comboUsed = false
            downAt = event.timestamp
            if handsFreeActive() { return }  // Stopp passiert beim Loslassen
            if hk == .fn && event.flags.contains(.maskControl) {
                commandMode = true
                onEvent?(.commandStart)
                return
            }
            onEvent?(.pressStart)
        } else if !pressed && isDown {
            isDown = false
            let held = Double(event.timestamp &- downAt) / 1e9
            if commandMode {
                commandMode = false
                onEvent?(held < tapThreshold ? .tapCancelled : .commandEnd)
                return
            }
            if comboUsed { return }
            if handsFreeActive() {
                onEvent?(.singleTapWhileHandsFree)
                return
            }
            if held < tapThreshold {
                let now = event.timestamp
                if Settings.shared.doubleTapHandsFree && lastTapAt > 0 && Double(now &- lastTapAt) / 1e9 < doubleTapWindow {
                    lastTapAt = 0
                    onEvent?(.doubleTap)
                } else {
                    lastTapAt = now
                    onEvent?(.tapCancelled)
                }
            } else {
                onEvent?(.holdEnd)
            }
        }
    }
}

/// Globaler Kurzbefehl (Carbon), z. B. ⌃⌥M für Meeting starten/stoppen.
final class GlobalShortcut {
    private var ref: EventHotKeyRef?
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var installed = false
    private let id: UInt32

    init?(keyCode: Int, modifiers: Int, id: UInt32, action: @escaping () -> Void) {
        self.id = id
        GlobalShortcut.installHandler()
        GlobalShortcut.handlers[id] = action
        let hkID = EventHotKeyID(signature: OSType(0x4D524D52), id: id)  // 'MRMR'
        let st = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hkID, GetApplicationEventTarget(), 0, &ref)
        if st != noErr { log("Kurzbefehl \(id) nicht registriert: \(st)"); return nil }
    }

    deinit {
        if let r = ref { UnregisterEventHotKey(r) }
        GlobalShortcut.handlers[id] = nil
    }

    private static func installHandler() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, ev, _ in
            var hk = EventHotKeyID()
            GetEventParameter(ev, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            DispatchQueue.main.async { GlobalShortcut.handlers[id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
