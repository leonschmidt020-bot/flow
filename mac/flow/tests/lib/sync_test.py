#!/usr/bin/env python3
"""Release-Tor, Schritt „Sync + Teilen“: zwei Test-Geraete gegen einen LOKALEN Worker (wrangler dev), nie ein echter Tresor.

  sync_test.py --cv <clipvault-binary> --flow <abs. Pfad Flow> --worker <ordner mit wrangler.toml>
               --wrangler <wrangler-binary> --work <temp> --out <json> [--quick]

  1. wrangler dev --local (freier Port, eigener --persist-to Ordner)
  2. Geraete A/B: je CLIPVAULT_HOME + eigener Schluesselbund-Name (CLIPVAULT_KEYCHAIN_SUFFIX), `clipvault sync-agent`
  3. Kopplung: A `pair create` → B `pair join` → beide „connected“
  4. Teilen in beide Richtungen: Text, Bild, 5-MB-Datei (grosser Eintrag in Teilen) – beim Empfaenger byte-identisch
     (--quick: nur Text)
  5. Gruener Punkt „neu“: ClipVault `sharedNew` UND die Regel der Pille (`Flow --selftest-shared-new`, liest
     shared.json + shared-seen.json) zeigen genau die Eintraege des Partners; markSeen (ClipVault) und
     „alle gesehen“ (Flow schreibt shared-seen.json) wirken jeweils auf der anderen Seite
  6. Server-Speicher (Durable-Object-SQLite) enthaelt keinen Klartext: Marker-Texte, Dateiinhalt, PNG-Kopf, Namen
Am Ende: Agents + wrangler beendet, Test-Schluesselbund-Eintraege geloescht.
"""
import argparse, glob, hashlib, json, os, secrets, shutil, signal, socket, struct, subprocess, sys, time, urllib.request, zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gatelib import Report  # noqa: E402

A = None  # argparse-Ergebnis


def free_port():
    s = socket.socket(); s.bind(("127.0.0.1", 0)); p = s.getsockname()[1]; s.close(); return p


def wait(cond, timeout=20, step=0.05):
    t0 = time.time()
    while time.time() - t0 < timeout:
        try:
            if cond():
                return time.time() - t0
        except Exception:
            pass
        time.sleep(step)
    return None


class Device:
    def __init__(self, name, me, partner, work):
        self.name = name
        self.dir = os.path.join(work, "dev" + name)
        shutil.rmtree(self.dir, ignore_errors=True)
        os.makedirs(self.dir)
        open(os.path.join(self.dir, "shared-me.txt"), "w").write(me)
        open(os.path.join(self.dir, "shared-partner.txt"), "w").write(partner)
        self.suffix = "gate" + name + secrets.token_hex(4)
        self.env = dict(os.environ, CLIPVAULT_HOME=self.dir, CLIPVAULT_KEYCHAIN_SUFFIX=self.suffix)
        self.proc = None
        self.me = me

    def start(self):
        self.proc = subprocess.Popen([A.cv, "sync-agent"], env=self.env, stdout=open(os.path.join(self.dir, "agent.out"), "a"),
                                     stderr=subprocess.STDOUT, start_new_session=True)
        return wait(lambda: os.path.exists(os.path.join(self.dir, "token")) and "pid=" in self.status_raw(), 15)

    def stop(self):
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(5)
            except subprocess.TimeoutExpired:
                self.proc.kill()

    def cli(self, *args, timeout=40):
        r = subprocess.run([A.cv] + list(args), env=self.env, capture_output=True, text=True, errors="replace", timeout=timeout)
        return r.stdout.strip()

    def send(self, action, **kw):
        out = self.cli("send", action, *[f"{k}={v}" for k, v in kw.items()])
        try:
            return json.loads(out.splitlines()[-1])
        except Exception:
            return {"ok": False, "error": out[-200:]}

    def status_raw(self):
        try:
            return open(os.path.join(self.dir, "status.txt")).read()
        except OSError:
            return ""

    def status(self):
        return dict(l.split("=", 1) for l in self.status_raw().splitlines() if "=" in l)

    def shared(self):
        try:
            return {i["id"].lower(): i for i in json.load(open(os.path.join(self.dir, "shared.json")))["items"]}
        except Exception:
            return {}

    def shared_file(self, iid, kind, name=None):
        if kind == "image":
            return os.path.join(self.dir, "shared", iid + ".png")
        for p in (os.path.join(self.dir, "shared", "files", iid, name), os.path.join(self.dir, "shared", iid, name)):
            if os.path.exists(p):
                return p
        return os.path.join(self.dir, "shared", "files", iid, name)

    def flow_new(self, mark_all=False):
        args = [A.flow, "--selftest-shared-new"] + (["--mark-all"] if mark_all else [])
        r = subprocess.run(args, env=dict(self.env, FLOW_HOME=os.path.join(A.work, "flow-home-" + self.name)),
                           capture_output=True, text=True, errors="replace", timeout=30)
        try:
            return json.loads(r.stdout.strip().splitlines()[-1])
        except Exception:
            return {"error": (r.stdout + r.stderr)[-300:]}

    def cleanup_keychain(self):
        svc = "app.flowdictation.clipvault.sync." + self.suffix
        for acct in ("vault-key", "vault-token", "init-secret"):
            subprocess.run(["/usr/bin/security", "delete-generic-password", "-s", svc, "-a", acct], capture_output=True)


def png(path, w=320, h=200):
    """Kleines, echtes PNG mit Zufallsrauschen (nicht komprimierbar genug, um trivial zu sein)"""
    raw = b"".join(b"\x00" + secrets.token_bytes(w * 3) for _ in range(h))
    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
    data = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")
    open(path, "wb").write(data)
    return data


def sha(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def main():
    global A
    ap = argparse.ArgumentParser()
    for k in ("--cv", "--flow", "--worker", "--wrangler", "--work", "--out"):
        ap.add_argument(k, required=True)
    ap.add_argument("--quick", action="store_true")
    A = ap.parse_args()
    A.flow = os.path.abspath(A.flow)
    os.makedirs(A.work, exist_ok=True)
    rep = Report("sync")
    t_all = time.time()
    port = free_port()
    url = f"http://127.0.0.1:{port}"
    state = os.path.join(A.work, "wrangler-state")
    wlog = open(os.path.join(A.work, "wrangler.log"), "w")
    init_secret = secrets.token_hex(24)          # Audit #16: der Worker legt Tresore nur mit INIT_SECRET an
    wr = subprocess.Popen([A.wrangler, "dev", "--local", "--ip", "127.0.0.1", "--port", str(port), "--persist-to", state,
                           "--var", f"INIT_SECRET:{init_secret}",
                           "--config", os.path.join(A.worker, "wrangler.toml"), "--log-level", "warn"],
                          cwd=A.worker, stdout=wlog, stderr=subprocess.STDOUT, start_new_session=True,
                          env=dict(os.environ, WRANGLER_SEND_METRICS="false", NO_COLOR="1", CI="1"))
    tag = secrets.token_hex(3)
    na, nb = f"Alpha{tag}", f"Beta{tag}"          # lange, eindeutige Namen: im Chiffrat zufaellig praktisch nie zu finden
    devs = [Device("A", na, nb, A.work), Device("B", nb, na, A.work)]
    a, b = devs
    markers = []
    try:
        def health():
            with urllib.request.urlopen(url + "/health", timeout=1) as r:
                return r.status == 200
        dt = wait(health, 40, 0.25)
        rep.add("lokaler Worker (wrangler dev --local) läuft", dt is not None, f"{url}, {dt:.1f} s" if dt is not None else open(wlog.name).read()[-300:])
        if dt is None:
            return finish(rep, devs, wr, t_all)
        ok = all(d.start() is not None for d in devs)
        rep.add("zwei Test-Geräte (sync-agent, eigenes CLIPVAULT_HOME + Schlüsselbund-Name)", ok)
        if not ok:
            return finish(rep, devs, wr, t_all)

        # --- Kopplung
        # Ohne Init-Geheimnis darf kein Tresor entstehen (403), mit richtigem schon
        a.cli("sync", "setup", url)
        refused = a.cli("pair", "create")
        rep.add("Worker verweigert Tresor ohne INIT_SECRET (Audit #16)", "cvpair1." not in refused and "Init-Geheimnis" in refused, refused.strip()[:120])
        a.cli("sync", "setup", url, init_secret)
        code = next((l.strip() for l in a.cli("pair", "create").splitlines() if l.strip().startswith("cvpair1.")), "")
        joined = b.cli("pair", "join", code) if code else ""
        dt = wait(lambda: a.status().get("sync_state") == "connected" and b.status().get("sync_state") == "connected", 25)
        rep.add("Kopplung A → B, beide „connected“", bool(code) and dt is not None,
                f"{dt:.1f} s" if dt is not None else f"A={a.status().get('sync_state')} B={b.status().get('sync_state')} {joined[:120]}")
        if dt is None:
            return finish(rep, devs, wr, t_all)
        cfg = json.load(open(os.path.join(a.dir, "sync.json")))
        import re
        secretish = [k for k, v in cfg.items() if re.search(r"(token|key|secret)", k, re.I)
                     or (isinstance(v, str) and re.fullmatch(r"[0-9a-fA-F]{32,}|[A-Za-z0-9+/=_-]{40,}", v))]
        rep.add("sync.json ohne Geheimnis (Schlüssel nur im Schlüsselbund)", not secretish, ", ".join(sorted(cfg)) + (f" – verdächtig: {secretish}" if secretish else ""))

        # --- Teilen in beide Richtungen
        sent = {"A": [], "B": []}
        orig = {}
        big = os.path.join(A.work, "big")
        os.makedirs(big, exist_ok=True)

        def share(src, dst, kind, payload, name=None):
            if kind == "text":
                r = src.send("addText", text=payload)
            elif kind == "image":
                r = src.send("addImage", path=payload)
            else:
                r = src.send("addFile", path=payload)
            if not r.get("ok"):
                return None, f"add: {r}"
            s = src.send("share", id=r["id"])
            if not s.get("ok"):
                return None, f"share: {s}"
            orig[s["id"].lower()] = s["id"]
            iid = s["id"].lower()
            t0 = time.time()

            def arrived():
                it = dst.shared().get(iid)
                if not it or it.get("deleted"):
                    return False
                if kind == "text":
                    return it.get("text") == payload
                if kind == "image":
                    p = dst.shared_file(iid, "image")
                    return os.path.exists(p) and sha(p) == sha(src.shared_file(iid, "image"))
                p = dst.shared_file(iid, "file", name)
                return os.path.exists(p) and os.path.getsize(p) == os.path.getsize(payload) and sha(p) == sha(payload)
            dt = wait(arrived, 45 if kind == "file" else 20, 0.02)
            sent[src.name].append(iid)
            return (None if dt is None else round((time.time() - t0) * 1000)), iid

        kinds = [("text", "Text")] if A.quick else [("text", "Text"), ("image", "Bild"), ("file", "5-MB-Datei")]
        for src, dst in ((a, b), (b, a)):
            for kind, label in kinds:
                if kind == "text":
                    m = f"GATE-KLARTEXT-{src.name}{dst.name}-{secrets.token_hex(6)}"
                    markers.append(m.encode())
                    ms, info = share(src, dst, "text", m)
                elif kind == "image":
                    p = os.path.join(big, f"bild-{src.name}.png"); png(p)
                    ms, info = share(src, dst, "image", p)
                else:
                    name = f"gate-datei-{src.name}-{secrets.token_hex(3)}.bin"
                    p = os.path.join(big, name)
                    m = f"GATE-DATEI-{secrets.token_hex(8)}".encode()
                    markers.append(m); markers.append(name.encode())
                    with open(p, "wb") as f:
                        f.write(m + secrets.token_bytes(5 * 1024 * 1024) + m)
                    ms, info = share(src, dst, "file", p, name)
                rep.add(f"{label} {src.name} → {dst.name} kommt an{' (byte-identisch)' if kind != 'text' else ''}", ms is not None,
                        f"{ms} ms" if ms is not None else str(info)[:200])
        if kinds[-1][0] == "file":
            it = b.shared().get(sent["A"][-1], {})
            rep.add("5-MB-Datei lief als großer Eintrag (in Teilen)", (it.get("parts") or 0) > 0, f"parts={it.get('parts')}, size={it.get('size')}")

        # --- Gruener Punkt „neu“
        def ids(x):
            return sorted(i.lower() for i in x)
        for me, other in ((b, a), (a, b)):
            cvn = me.send("sharedNew")
            mn = me.flow_new()
            want = ids(sent[other.name])
            rep.add(f"{me.name}: grüner Punkt = genau die {len(want)} Einträge von {other.name} (ClipVault + Pille)",
                    ids(cvn.get("ids", [])) == want and ids(mn.get("new", [])) == want and not set(ids(mn.get("new", []))) & set(sent[me.name]),
                    f"ClipVault {cvn.get('count')}, Pille {len(mn.get('new', []))} ({mn.get('error', '')})")
        first = sent["A"][0]
        r = b.send("markSeen", id=orig[first])
        mn = b.flow_new()
        rep.add("B: ClipVault markSeen → Pille zählt einen weniger (shared-seen.json)",
                r.get("ok") and r.get("count") == len(sent["A"]) - 1 and len(mn.get("new", [])) == len(sent["A"]) - 1 and first not in ids(mn.get("new", [])),
                f"ClipVault {r.get('count')}, Pille {len(mn.get('new', []))}")
        mn = b.flow_new(mark_all=True)
        b.send("reload")
        cvn = b.send("sharedNew")
        seen = json.load(open(os.path.join(b.dir, "shared-seen.json")))
        rep.add("B: Pille „alle gesehen“ → ClipVault zählt 0 (Punkt aus)", cvn.get("count") == 0 and mn.get("marked") == len(sent["A"]) - 1,
                f"ClipVault {cvn.get('count')}, status shared_new={b.status().get('shared_new')}, seen={len(seen.get('seen', []))}")
        rep.add("shared-seen.json nur für den eigenen Benutzer (0600)", oct(os.stat(os.path.join(b.dir, "shared-seen.json")).st_mode & 0o777) == "0o600")

        # --- Gemeinsame Namen (PartnerVocab über unsichtbare „vocab“-Einträge im Tresor)
        word = f"Quistorp{secrets.token_hex(2)}"
        markers.append(word.encode())

        def pv(dev, *args, timeout=40):
            r = subprocess.run([A.flow] + list(args), env=dict(dev.env, FLOW_HOME=os.path.join(A.work, "flow-home-" + dev.name)),
                               capture_output=True, text=True, errors="replace", timeout=timeout)
            return r.returncode, (r.stdout + r.stderr).strip()
        rc, out = pv(a, "--partner-vocab-learn", word, "manual", "person")
        rep.add(f"Gemeinsame Namen: A lernt „{word}“ → an B gesendet", rc == 0 and "GESENDET" in out, out.splitlines()[-1] if out else "")
        got = {}

        def arrived_vocab():
            rc2, o2 = pv(b, "--partner-vocab-inbox", "annehmen")
            got["out"] = o2
            return f"„{word}“" in o2 and "Wörterbuch: heard" in o2
        dt = wait(arrived_vocab, 20, 0.5)
        rep.add("Gemeinsame Namen: B bekommt die Karte, „Annehmen“ → im Wörterbuch von B", dt is not None,
                next((l for l in got.get("out", "").splitlines() if word in l and "Wörterbuch" in l), got.get("out", "")[-200:]))
        cvn = b.send("sharedNew")
        rep.add("vocab-Einträge sind unsichtbar (kein grüner Punkt)", cvn.get("count") == 0 and not any(
            (i.get("kind") not in ("text", "link", "image", "file")) for i in b.shared().values() if not i.get("deleted")),
            f"ClipVault sharedNew {cvn.get('count')}")

        # --- Kein Klartext auf dem Server
        for d in devs:
            d.stop()          # Server-Zustand ist nach dem Teilen vollstaendig; sqlite-Dateien lesen
        files = [f for f in glob.glob(os.path.join(state, "**", "*"), recursive=True) if os.path.isfile(f)]
        total = sum(os.path.getsize(f) for f in files)
        needles = markers + [b"\x89PNG\r\n\x1a\n", na.encode(), nb.encode()]
        hits = []
        for f in files:
            data = open(f, "rb").read()
            for n in needles:
                if n in data:
                    hits.append(f"{os.path.basename(f)}: {n[:24]!r}")
        min_total = 10 * 1024 * 1024 if not A.quick else 1
        rep.add(f"Server speichert nur Chiffrat ({len(files)} Dateien, {total / 1e6:.1f} MB, {len(needles)} Marker gesucht)",
                not hits and total >= min_total, "; ".join(hits[:3]) or ("zu wenig Daten auf dem Server?" if total < min_total else ""))
    finally:
        pass
    return finish(rep, devs, wr, t_all)


def finish(rep, devs, wr, t_all):
    for d in devs:
        d.stop()
        d.cleanup_keychain()
    if wr.poll() is None:
        try:
            os.killpg(wr.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            wr.wait(8)
        except subprocess.TimeoutExpired:
            os.killpg(wr.pid, signal.SIGKILL)
    left = [d.name for d in devs if d.proc and d.proc.poll() is None]
    rep.add("aufgeräumt (Agents, wrangler, Test-Schlüsselbund)", not left and wr.poll() is not None, ", ".join(left))
    rep.save(A.out, {"seconds": round(time.time() - t_all, 1)})
    return 0 if rep.passed else 1


if __name__ == "__main__":
    sys.exit(main())
