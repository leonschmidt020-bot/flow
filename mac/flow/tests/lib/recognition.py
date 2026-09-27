#!/usr/bin/env python3
"""Release-Tor, Schritt „Erkennung“: festes TTS-Testset durch die echte Pipeline (vorhandene CLI-Werkzeuge).

  recognition.py --bin <abs. Pfad Flow> --work <temp> --out <ergebnis.json> [--rebaseline]

In einem frischen FLOW_HOME (eigenes settings.json mit neutralem Test-Woerterbuch, Stimmprofil der Teststimme):
  1. --enroll voice/enroll.wav                   Stimmprofil der Teststimme (Rocko) im Temp-Home
  2. --engine-bench manifest --only hybrid       WER / Namen / Latenz p50 (Parakeet + Hybrid, eigener whisper-server)
  3. --voicemask-bench voice/own voice/foreign   Urteile: eigene Stimme bleibt, fremde Stimme wird gestummt
  4. --dictation-sim voice/own/…                 „Diktat … gesamt“ in Echtzeit (Zeit ab dem Loslassen)
Vergleich mit tests/baseline/recognition.json:
  WER (nach Regeln) und Namen-Treffer: FAIL bei > 1,5 Prozentpunkten schlechter
  Latenz: hybrid p50 FAIL bei > 30 % langsamer; Diktat-Simulation je Aufnahme > 30 % + 100 ms Rauschpolster (Werte ab ~40 ms);
    nur Latenz daneben → einmal neu messen (Maschine kann kurz belastet sein), das bessere Ergebnis zaehlt
  Stimmabgleich: jedes Urteil identisch zur Baseline + feste Regeln (eigene Stimme unveraendert, fremd = „nicht ich“)
"""
import argparse, json, os, platform, re, shutil, subprocess, sys, time, uuid

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gatelib import Leftovers, Report, run  # noqa: E402

TESTS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
AUDIO = os.path.join(TESTS, "audio")
BASELINE = os.path.join(TESTS, "baseline", "recognition.json")
SIM_FILES = ["own_de_short.wav", "own_de_names.wav", "own_en_long.wav"]
WER_PTS, NAME_PTS, LAT_FACTOR, SIM_SLACK_S = 1.5, 1.5, 1.30, 0.10


def setup_home(work):
    home = os.path.join(work, "home")
    shutil.rmtree(home, ignore_errors=True)
    os.makedirs(home)
    d = json.load(open(os.path.join(AUDIO, "dictionary.json")))
    for e in d:
        e["id"] = str(uuid.uuid5(uuid.NAMESPACE_URL, e["heard"] + "→" + e["write"])).upper()
    json.dump({"dictionary": d, "onboardingDone": True, "myName": "Testperson", "languageMode": "both"},
              open(os.path.join(home, "settings.json"), "w"), ensure_ascii=False, indent=1)
    m = json.load(open(os.path.join(AUDIO, "manifest.json")))
    for i in m:
        i["file"] = os.path.join(AUDIO, i["file"])
    mf = os.path.join(work, "manifest.json")
    json.dump(m, open(mf, "w"), ensure_ascii=False)
    return home, mf


def cli(binary, home, args, timeout=300):
    lo = Leftovers(binary)
    code, out, dt = run([binary] + args, env={"FLOW_HOME": home}, timeout=timeout)
    killed = lo.sweep()
    return code, out, dt, killed


def bench(binary, home, mf, work, tag):
    out_json = os.path.join(work, f"bench-{tag}.json")
    code, out, dt, killed = cli(binary, home, ["--engine-bench", mf, "--only", "hybrid", "--out", out_json])
    summ = out_json.replace(".json", "-summary.json")
    if code != 0 or not os.path.exists(summ):
        raise RuntimeError(f"--engine-bench exit {code}: {out[-600:]}")
    s = {x["config"]: x for x in json.load(open(summ))}
    recs = json.load(open(out_json))
    hyps = {r["clip"]: r["hyp"] for r in recs if r["config"] == "hybrid"}
    eng = {r["clip"]: r.get("engine") for r in recs if r["config"] == "hybrid"}
    res = {c: {"wer": round(s[c]["werRules"] * 100, 2), "names": round(s[c]["nameAcc"] * 100, 2), "p50": s[c]["p50"], "p95": s[c]["p95"]}
           for c in ("parakeet", "hybrid") if c in s}
    return res, hyps, eng, dt, killed


LABEL = r"(?:unverändert|gestummt [\d.]+s|nicht ich \([\d.]+\))"
MAIN_RE = re.compile(r"^(?P<name>.{30}) +[\d.]+s .*? ms \(.*?vorab\)  (?P<v>" + LABEL + r"(?: \| " + LABEL + r")+)\s*$")
CHUNK_RE = re.compile(r"^(?P<name>.{30}) +\d+ +[\d.]+s +\d+ +\d+ \(\d+/\d+ vorab\) +(?P<v>" + LABEL + r"(?: \| " + LABEL + r")+)\s*$")


def voicemask(binary, home):
    code, out, dt, killed = cli(binary, home, ["--voicemask-bench", os.path.join(AUDIO, "voice", "own"), os.path.join(AUDIO, "voice", "foreign.wav")])
    if code != 0:
        raise RuntimeError(f"--voicemask-bench exit {code}: {out[-600:]}")
    cases, section = {}, "haupt"
    for line in out.splitlines():
        if line.startswith("== Stücke"):
            section = "stuecke"
        m = (MAIN_RE if section == "haupt" else CHUNK_RE).match(line)
        if m:
            cases[f"{section}: {m.group('name').strip()}"] = [v.strip() for v in m.group("v").split(" | ")]
    if not cases:
        raise RuntimeError("--voicemask-bench: keine Urteile gefunden:\n" + out[-800:])
    return cases, dt, killed


SIM_RE = re.compile(r"^(?P<name>\S+)\s+[\d.]+s\s+(?P<chunks>\d+)\s+(?P<alt>[\d.]+) s\s+(?P<neu>[\d.]+) s\s+\((?P<m0>-?\d+) → (?P<m1>-?\d+) ms\)\s*(?P<eng>.*)$")


def dictation_sim(binary, home):
    files = [os.path.join(AUDIO, "voice", "own", f) for f in SIM_FILES]
    code, out, dt, killed = cli(binary, home, ["--dictation-sim"] + files, timeout=400)
    if code != 0:
        raise RuntimeError(f"--dictation-sim exit {code}: {out[-600:]}")
    res = {}
    for line in out.splitlines():
        m = SIM_RE.match(line.strip())
        if m:
            res[m.group("name")] = {"neu_s": float(m.group("neu")), "alt_s": float(m.group("alt")), "chunks": int(m.group("chunks")),
                                    "engines": m.group("eng").strip()}
    if len(res) != len(SIM_FILES):
        raise RuntimeError("--dictation-sim: nicht alle Aufnahmen gemessen:\n" + out[-800:])
    return res, dt, killed


def median(xs):
    xs = sorted(xs)
    n = len(xs)
    return 0 if n == 0 else (xs[n // 2] if n % 2 else (xs[n // 2 - 1] + xs[n // 2]) / 2)


def kind(label):
    return label.split(" ")[0]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bin", required=True)
    ap.add_argument("--work", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--rebaseline", action="store_true")
    a = ap.parse_args()
    binary = os.path.abspath(a.bin)
    os.makedirs(a.work, exist_ok=True)
    rep = Report("recognition")
    t_all = time.time()
    home, mf = setup_home(a.work)
    timings = {}

    code, out, dt, killed = cli(binary, home, ["--enroll", os.path.join(AUDIO, "voice", "enroll.wav")])
    timings["enroll"] = round(dt, 1)
    ok = code == 0 and os.path.exists(os.path.join(home, "meine-stimme.json"))
    rep.add("Stimmprofil der Teststimme im Temp-Home (--enroll)", ok, "" if ok else out[-300:])
    if not ok:
        rep.save(a.out); return 1

    try:
        b, hyps, eng, dt, k1 = bench(binary, home, mf, a.work, "1")
        timings["engine-bench"] = round(dt, 1)
        vm, dt, k2 = voicemask(binary, home)
        timings["voicemask-bench"] = round(dt, 1)
        ds, dt, k3 = dictation_sim(binary, home)
        timings["dictation-sim"] = round(dt, 1)
    except RuntimeError as e:
        rep.add("Messwerkzeuge laufen", False, str(e)[:400]); rep.save(a.out); return 1
    killed = k1 + k2 + k3
    unreadable = [f for f in os.listdir(home) if f.startswith("settings.unlesbar")]
    rep.add("Test-settings.json wurde gelesen (Test-Wörterbuch aktiv)", not unreadable, ", ".join(unreadable))
    current = {"bench": b, "voicemask": vm, "dictation_sim": ds, "hyps": hyps, "engines": eng}

    # feste Regeln (unabhaengig von der Baseline)
    own = {k: v for k, v in vm.items() if k.startswith("haupt: eigen ") and "fremd" not in k}
    bad_own = [k for k, v in own.items() if any(kind(x) != "unverändert" for x in v)]
    rep.add(f"eigene Stimme bleibt ({len(own)} Fälle)", bool(own) and not bad_own, ", ".join(bad_own))
    foreign = vm.get("haupt: fremd allein")
    rep.add("fremde TTS-Stimme allein → „nicht ich“", bool(foreign) and all(kind(x) == "nicht" for x in foreign), str(foreign))
    mixed = {k: v for k, v in vm.items() if k.startswith("haupt: eigen+fremd") or k.startswith("haupt: eigen lang+fremd")}
    bad_mixed = [k for k, v in mixed.items() if kind(v[-1]) != "gestummt"]
    rep.add(f"fremde Stimme im eigenen Diktat wird gestummt ({len(mixed)} Fälle)", bool(mixed) and not bad_mixed, ", ".join(bad_mixed))

    if a.rebaseline:
        base = dict(current)
        base.update({"created": time.strftime("%Y-%m-%d %H:%M"), "machine": platform.machine() + " " + platform.mac_ver()[0],
                     "cpu": subprocess.run(["sysctl", "-n", "machdep.cpu.brand_string"], capture_output=True, text=True, errors="replace").stdout.strip(),
                     "git": subprocess.run(["git", "-C", TESTS, "describe", "--tags", "--always", "--dirty"], capture_output=True, text=True, errors="replace").stdout.strip()})
        base["note"] = ("regeneriert (--rebaseline) – synthetisches TTS-Testset (macOS `say`, erfundene Namen), "
                        "keine echten Aufnahmen; Latenzwerte gelten nur fuer diese Maschine")
        os.makedirs(os.path.dirname(BASELINE), exist_ok=True)
        with open(BASELINE, "w") as f:
            json.dump(base, f, ensure_ascii=False, indent=1)
        rep.add("Baseline neu geschrieben", True, os.path.relpath(BASELINE, os.path.dirname(TESTS)))
        rep.save(a.out, {"current": current, "timings": timings, "seconds": round(time.time() - t_all, 1)})
        return 0 if rep.passed else 1

    if not os.path.exists(BASELINE):
        rep.add("Baseline vorhanden", False, "tests/baseline/recognition.json fehlt – scripts/release.sh --rebaseline")
        rep.save(a.out); return 1
    base = json.load(open(BASELINE))

    def quality_rows():
        for cfg in ("parakeet", "hybrid"):
            nb, ob = b.get(cfg), base["bench"].get(cfg)
            if not nb or not ob:
                rep.add(f"{cfg}: Messung vorhanden", False); continue
            rep.add(f"{cfg}: WER {nb['wer']:.1f} % (Baseline {ob['wer']:.1f} %)", nb["wer"] - ob["wer"] <= WER_PTS,
                    f"{nb['wer'] - ob['wer']:+.1f} Punkte")
            rep.add(f"{cfg}: Namen {nb['names']:.1f} % (Baseline {ob['names']:.1f} %)", ob["names"] - nb["names"] <= NAME_PTS,
                    f"{nb['names'] - ob['names']:+.1f} Punkte")
    quality_rows()
    changed = [c for c in hyps if base.get("hyps", {}).get(c) not in (None, hyps[c])]
    if changed:
        rep.add(f"Texte anders als Baseline: {len(changed)} Clip(s)", None,
                "; ".join(f"{c}: „{hyps[c][:70]}“ statt „{base['hyps'][c][:70]}“" for c in changed[:3]))

    # Latenz (bei Ueberschreitung einmal neu messen, bestes zaehlt)
    bp = base["bench"]["hybrid"]["p50"]
    bsim = base["dictation_sim"]

    def sim_over(cur):
        return [f for f, v in cur.items() if f in bsim and v["neu_s"] > bsim[f]["neu_s"] * LAT_FACTOR + SIM_SLACK_S]
    p50, sim_best = b["hybrid"]["p50"], {f: dict(v) for f, v in ds.items()}
    okb, over = p50 <= bp * LAT_FACTOR, sim_over(sim_best)
    retried = False
    if not okb or over:
        retried = True
        print("  … Latenz über der Grenze – messe einmal neu (Maschine evtl. kurz belastet)", flush=True)
        if not okb:
            b2, _, _, dt, k = bench(binary, home, mf, a.work, "2"); killed += k
            p50 = min(p50, b2["hybrid"]["p50"]); timings["engine-bench (2.)"] = round(dt, 1)
        if over:
            ds2, dt, k = dictation_sim(binary, home); killed += k
            for f, v in ds2.items():
                if f in sim_best: sim_best[f]["neu_s"] = min(sim_best[f]["neu_s"], v["neu_s"])
            timings["dictation-sim (2.)"] = round(dt, 1)
        okb, over = p50 <= bp * LAT_FACTOR, sim_over(sim_best)
    rep.add(f"Latenz hybrid p50 {p50} ms (Baseline {bp} ms, Grenze {int(bp * LAT_FACTOR)} ms)", okb,
            f"{(p50 / bp - 1) * 100:+.0f} %" + (" (2. Messung)" if retried else ""))
    rep.add(f"Diktat „gesamt“ nach dem Loslassen je Aufnahme ≤ Baseline × {LAT_FACTOR} + {int(SIM_SLACK_S * 1000)} ms", not over,
            ", ".join(f"{f} {v['neu_s']:.2f} s (Baseline {bsim.get(f, {}).get('neu_s', 0):.2f} s)" for f, v in sim_best.items()))
    eng_diff = [f for f, v in ds.items() if f in bsim and v["engines"] != bsim[f]["engines"]]
    if eng_diff:
        rep.add("Diktat-Simulation: andere Motoren als Baseline", None, ", ".join(f"{f}: {ds[f]['engines']} statt {bsim[f]['engines']}" for f in eng_diff))

    # Stimmabgleich: jedes Urteil identisch
    diffs = []
    for k, v in base["voicemask"].items():
        if vm.get(k) != v:
            diffs.append(f"{k}: {vm.get(k)} statt {v}")
    for k in vm:
        if k not in base["voicemask"]:
            diffs.append(f"neu: {k}")
    rep.add(f"Stimmabgleich: {len(vm)} Urteile identisch zur Baseline", not diffs, "; ".join(diffs[:3]))
    rep.add("Reste (Prozesse) aufgeräumt", None, f"{len(killed)} beendet: {killed[:2]}" if killed else "keine")
    rep.save(a.out, {"current": current, "timings": timings, "seconds": round(time.time() - t_all, 1)})
    return 0 if rep.passed else 1


if __name__ == "__main__":
    sys.exit(main())
