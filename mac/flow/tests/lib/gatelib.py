"""Gemeinsame Helfer fuers Release-Tor (nur Standardbibliothek, laeuft mit /usr/bin/python3 3.9).

Wichtig: Die Dev-Binary laeuft hier NUR mit CLI-Befehlen und immer ueber ihren absoluten Pfad – so lassen sich
Reste eindeutig finden (andere Agents starten ihre eigenen .build/release/Flow mit relativem Pfad).
"""
import json, os, signal, subprocess, time


def ps():
    """[(pid, ppid, command)] aller Prozesse des Benutzers"""
    out = subprocess.run(["ps", "-axo", "pid=,ppid=,command="], capture_output=True, text=True, errors="replace").stdout
    rows = []
    for line in out.splitlines():
        parts = line.strip().split(None, 2)
        if len(parts) == 3 and parts[0].isdigit() and parts[1].isdigit():
            rows.append((int(parts[0]), int(parts[1]), parts[2]))
    return rows


def test_whisper_servers():
    """Test-Whisper-Server der Messwerkzeuge (nie die der App: die haben --request-path /flow-)"""
    return {p for p, _, c in ps() if "whisper-server" in c and ("/vfbench-" in c or "/vftest-" in c)}


class Leftovers:
    """Vorher/Nachher-Abgleich: eigene Flow-Prozesse (absoluter Pfad) + verwaiste Test-Whisper-Server (ppid 1),
    die waehrend des Schritts entstanden sind. Fremde Prozesse (andere Agents) werden nie angefasst."""

    def __init__(self, binary):
        self.binary = binary
        self.before = test_whisper_servers()

    def sweep(self):
        killed = []
        for p, pp, c in ps():
            mine = c.startswith(self.binary + " ") or c == self.binary
            orphan_ws = p not in self.before and pp == 1 and "whisper-server" in c and ("/vfbench-" in c or "/vftest-" in c)
            if (mine and p != os.getpid()) or orphan_ws:
                try:
                    os.kill(p, signal.SIGTERM); killed.append(c[:90])
                except ProcessLookupError:
                    pass
        if killed:
            time.sleep(0.5)
        return killed


def run(cmd, env=None, timeout=600, cwd=None):
    e = dict(os.environ)
    e.update(env or {})
    t0 = time.time()
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, errors="replace", env=e, timeout=timeout, cwd=cwd)
        return r.returncode, r.stdout + r.stderr, time.time() - t0
    except subprocess.TimeoutExpired as ex:
        out = (ex.stdout or b"").decode("utf-8", "replace") if isinstance(ex.stdout, bytes) else (ex.stdout or "")
        return 124, out + "\n[Zeitlimit]", time.time() - t0


class Report:
    """Ergebniszeilen eines Schritts: name, ok (True/False/None=Info), detail"""

    def __init__(self, step):
        self.step = step
        self.rows = []

    def add(self, name, ok, detail=""):
        self.rows.append({"name": name, "ok": ok, "detail": detail})
        mark = "ok  " if ok is True else ("FAIL" if ok is False else "info")
        print(f"  {mark} {name}{(' – ' + detail) if detail else ''}", flush=True)

    @property
    def passed(self):
        return all(r["ok"] is not False for r in self.rows) and any(r["ok"] is True for r in self.rows)

    def save(self, path, extra=None):
        d = {"step": self.step, "passed": self.passed, "rows": self.rows}
        d.update(extra or {})
        with open(path, "w") as f:
            json.dump(d, f, ensure_ascii=False, indent=1)


if __name__ == "__main__":
    # gatelib.py sweep <abs. Pfad Flow>   → eigene Reste beenden, Zeilen „beendet: …“ ausgeben
    import sys
    if len(sys.argv) == 3 and sys.argv[1] == "sweep":
        lo = Leftovers(os.path.abspath(sys.argv[2]))
        lo.before = set()          # jeder verwaiste Test-Whisper-Server (ppid 1) zaehlt als Rest
        for k in lo.sweep():
            print("beendet: " + k)
