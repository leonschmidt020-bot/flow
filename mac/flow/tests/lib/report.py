#!/usr/bin/env python3
"""Release-Tor: Bericht.

  report.py add-json <rows.tsv> <schritt> <ergebnis.json>     Zeilen eines Python-Schritts uebernehmen
  report.py render <steps.tsv> <rows.tsv> <ausgabe.txt> <kopfzeile>   PASS/FAIL-Tabelle drucken + schreiben

steps.tsv: schritt \t titel \t PASS|FAIL|SKIP \t sekunden      rows.tsv: schritt \t ok|FAIL|info \t pruefung \t detail
Exit 0 = alles PASS (SKIP zaehlt nicht als Fehler), 1 = mindestens ein FAIL.
"""
import json, sys


def clean(s):
    return str(s).replace("\t", " ").replace("\n", " ⏎ ")


def add_json(rows, step, path):
    try:
        d = json.load(open(path))
    except Exception as e:  # noqa: BLE001
        d = {"rows": [{"name": "Ergebnisdatei lesbar", "ok": False, "detail": str(e)}]}
    with open(rows, "a") as f:
        for r in d.get("rows", []):
            st = "ok" if r["ok"] is True else ("FAIL" if r["ok"] is False else "info")
            f.write(f"{step}\t{st}\t{clean(r['name'])}\t{clean(r.get('detail', ''))}\n")


def render(steps_p, rows_p, out_p, header):
    steps = [l.rstrip("\n").split("\t") for l in open(steps_p) if l.strip()]
    rows = [l.rstrip("\n").split("\t") for l in open(rows_p) if l.strip()] if rows_p else []
    w = max([len(s[1]) for s in steps] + [20])
    lines = [header, "", f"  {'Schritt'.ljust(w)}  Ergebnis   Zeit   Prüfungen"]
    total, failed = 0.0, False
    for sid, title, status, secs in steps:
        mine = [r for r in rows if r[0] == sid]
        n_ok = sum(1 for r in mine if r[1] == "ok")
        n_fail = sum(1 for r in mine if r[1] == "FAIL")
        total += float(secs)
        failed |= status == "FAIL"
        lines.append(f"  {title.ljust(w)}  {status.ljust(8)} {float(secs):6.1f} s  {n_ok} ok" + (f", {n_fail} FAIL" if n_fail else ""))
    verdict = "FAIL" if failed else "PASS"
    lines.append(f"  {'Gesamt'.ljust(w)}  {verdict.ljust(8)} {total:6.1f} s")
    fails = [r for r in rows if r[1] == "FAIL"]
    infos = [r for r in rows if r[1] == "info"]
    if fails:
        lines += ["", "Fehlgeschlagen:"] + [f"  [{r[0]}] {r[2]}" + (f" – {r[3]}" if len(r) > 3 and r[3] else "") for r in fails]
    if infos:
        lines += ["", "Hinweise:"] + [f"  [{r[0]}] {r[2]}" + (f" – {r[3]}" if len(r) > 3 and r[3] else "") for r in infos]
    lines += ["", "Alle Prüfungen:"] + [f"  [{r[0]}] {r[1].ljust(4)} {r[2]}" + (f" – {r[3]}" if len(r) > 3 and r[3] else "") for r in rows]
    txt = "\n".join(lines) + "\n"
    open(out_p, "w").write(txt)
    # auf dem Terminal: Tabelle + Fehler + Hinweise (die lange Liste steht nur in der Datei)
    cut = txt.split("\nAlle Prüfungen:")[0]
    print(cut.rstrip() + f"\n\n(vollständig: {out_p})")
    return 1 if failed else 0


if __name__ == "__main__":
    if sys.argv[1] == "add-json":
        add_json(*sys.argv[2:5]); sys.exit(0)
    if sys.argv[1] == "render":
        sys.exit(render(*sys.argv[2:6]))
    sys.exit(2)
