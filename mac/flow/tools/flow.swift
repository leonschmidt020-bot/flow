// flow – Fernsteuerung für Flow (Hammerspoon, Stream Deck, Terminal).
//   flow dictate | meeting | mictest     (brauchen den Schlüssel aus <Daten>/token)
//   flow open [diktat|notetaker|training|…] | settings | enroll | status
// Gebaut von build.sh nach <Daten>/bin/flow (Daten = ~/.config/flow oder FLOW_HOME).
import Foundation

let args = CommandLine.arguments
let cmd = args.count > 1 ? args[1] : ""
let secured: Set<String> = ["dictate", "meeting", "mictest"]
let open: Set<String> = ["open", "show", "settings", "enroll", "status"]

guard secured.contains(cmd) || open.contains(cmd) else {
    FileHandle.standardError.write("""
    Benutzung: flow dictate|meeting|mictest|open [bereich]|settings|enroll|status
      dictate   Freihand-Diktat starten/beenden
      meeting   Meeting-Aufnahme starten/beenden
      mictest   1,5 s Mikrofon-Pegel ins Protokoll
      open      Hub öffnen (z. B. „open training“)
      status    Freigaben/Modelle ins Protokoll (<Daten>/flow.log)

    """.data(using: .utf8)!)
    exit(2)
}

let env = ProcessInfo.processInfo.environment["FLOW_HOME"] ?? ""
let base = env.isEmpty
    ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/flow")
    : URL(fileURLWithPath: (env as NSString).expandingTildeInPath)

var object: String? = nil
if secured.contains(cmd) {
    guard let t = try? String(contentsOf: base.appendingPathComponent("token"), encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines), t.count >= 32 else {
        FileHandle.standardError.write("Kein Schlüssel in \(base.path)/token – Flow einmal starten.\n".data(using: .utf8)!)
        exit(1)
    }
    object = t
} else if cmd == "open", args.count > 2 {
    object = args[2]
}

// Namen der Meldungen sind fest (unabhängig von der Bundle-ID)
DistributedNotificationCenter.default().postNotificationName(.init("app.flowdictation.flow.\(cmd)"), object: object,
                                                             userInfo: nil, deliverImmediately: true)
exit(0)
