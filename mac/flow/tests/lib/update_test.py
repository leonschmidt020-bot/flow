#!/usr/bin/env python3
"""Release-Tor, Schritt „Update-Weg“: das Auto-Update eines Freundes nachgestellt – komplett in einem Temp-Ordner.

  update_test.py --src <flow-repo> --flow <abs. Pfad Flow> --prev <tag> --version <X.Y.Z> --work <temp> --out <json>
                 [--full-build]

  1. Nackter Temp-Remote auf dem Stand <prev>; Klon „als Freund“ (eigenes HOME mit .gitconfig)
  2. Der Freund hat lokal etwas geändert: README.md (versioniert) + eine unversionierte Notiz
  3. Kandidat = aktueller Arbeitsstand (git add -A in einen Temp-Index, VERSION = <X.Y.Z>) → auf den Temp-Remote
  4. Genau der Befehl des Updaters (`Flow --updater-command`, = Updater.installScript) läuft mit /bin/bash -lc –
     im Testmodus: FLOW_TEST_APP_DIR (App nur in den Temp-Ordner, kein launchctl/pkill/LaunchAgent),
     FLOW_TEST_PREBUILT (fertige Binary aus Schritt 1 statt 2,5 Min. Neukompilieren; --full-build = echt bauen),
     BUNDLE_ID=app.flowdictation.flow.releasegate, ad-hoc-Signatur, HOME = Temp
  Prueft: fast-forward auf den Kandidaten, lokale Aenderung im Stash (nichts verloren), unversionierte Datei unberuehrt,
  App-Bundle mit neuer Version + gueltiger Signatur, Exit 0, zweiter Lauf „nichts zu tun“ – und dass KEINE laufende App
  unter ~/Applications (auch keine andere Diktier-App) und kein whisper-server dabei angefasst wurden.
  Monorepo: das Repo enthaelt mac/flow + mac/clipvault (+ windows/); getestet wird der Mac-Teil (Pfade mit Praefix).
"""
import argparse, json, os, plistlib, secrets, shutil, subprocess, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gatelib import Report, ps  # noqa: E402


def git(repo, *args, env=None, check=True, inp=None):
    r = subprocess.run(["git", "-C", repo] + list(args), capture_output=True, text=True, errors="replace", env=env, input=inp)
    if check and r.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)}: {r.stderr.strip()[-300:]}")
    return r.stdout.strip()


def running_apps():
    """alle laufenden Apps unter ~/Applications und alle whisper-server (egal welche App) – duerfen nicht verschwinden"""
    home = os.path.expanduser("~")
    app = {p for p, _, c in ps() if c.startswith(home + "/Applications/") and ".app/Contents/MacOS/" in c}
    ws = {p for p, _, c in ps() if "whisper-server" in c}
    return app, ws


def main():
    ap = argparse.ArgumentParser()
    for k in ("--src", "--flow", "--prev", "--version", "--work", "--out"):
        ap.add_argument(k, required=True)
    ap.add_argument("--full-build", action="store_true")
    a = ap.parse_args()
    rep = Report("update")
    t_all = time.time()
    T = os.path.abspath(a.work)
    shutil.rmtree(T, ignore_errors=True)
    os.makedirs(T)
    src = os.path.abspath(a.src)
    # Monorepo: Praefix des Flow-Ordners im Repo (z. B. „mac/flow/“) und Wurzel
    pre = git(src, "rev-parse", "--show-prefix")
    root = git(src, "rev-parse", "--show-toplevel")
    jhome = os.path.join(T, "freund-home")
    os.makedirs(jhome)
    with open(os.path.join(jhome, ".gitconfig"), "w") as f:
        f.write("[user]\n\tname = Freund Test\n\temail = freund@example.invalid\n[init]\n\tdefaultBranch = main\n[advice]\n\tdetachedHead = false\n")
    ident = {"GIT_AUTHOR_NAME": "Release-Tor", "GIT_AUTHOR_EMAIL": "gate@example.invalid",
             "GIT_COMMITTER_NAME": "Release-Tor", "GIT_COMMITTER_EMAIL": "gate@example.invalid"}
    jenv = {k: v for k, v in os.environ.items() if not k.startswith(("FLOW_", "CLIPVAULT_", "GIT_"))}
    jenv.update({"HOME": jhome, "GIT_TERMINAL_PROMPT": "0"})
    try:
        # --- 1) Remote auf <prev>, Klon des Freundes
        remote = os.path.join(T, "remote.git")
        subprocess.run(["git", "init", "-q", "--bare", "-b", "main", remote], check=True)
        prev = git(src, "rev-parse", a.prev + "^{commit}")
        if subprocess.run(["git", "-C", src, "merge-base", "--is-ancestor", prev, "HEAD"]).returncode != 0:
            rep.add(f"{a.prev} ist Vorfahr von HEAD (sonst kein fast-forward möglich)", False)
            return done(rep, a, t_all)
        git(src, "push", "-q", remote, f"{prev}:refs/heads/main", f"refs/tags/{a.prev}:refs/tags/{a.prev}")
        jroot = os.path.join(T, "freund")
        os.makedirs(jroot)
        jrepo = os.path.join(jroot, "flow")
        subprocess.run(["git", "clone", "-q", remote, jrepo], check=True, env=jenv)
        jdir = os.path.join(jrepo, pre)
        rep.add(f"Temp-Remote auf {a.prev}, Klon „als Freund“", git(jdir, "rev-parse", "HEAD") == prev, prev[:9])

        # --- 2) lokale Aenderungen des Freundes
        note = f"lokale Notiz {secrets.token_hex(4)}"
        with open(os.path.join(jdir, "README.md"), "a") as f:
            f.write(f"\n{note}\n")
        untracked = os.path.join(jdir, "freund-notizen.txt")
        utext = f"nur lokal {secrets.token_hex(4)}\n"
        open(untracked, "w").write(utext)

        # --- 3) Kandidat = Arbeitsstand + VERSION
        idx = os.path.join(T, "kandidat.index")
        ienv = dict(os.environ, GIT_INDEX_FILE=idx, **ident)
        git(root, "read-tree", "HEAD", env=ienv)
        git(root, "add", "-A", "--", "mac", ".gitignore", env=ienv)     # nur der Mac-Teil (windows/ schreiben andere)
        blob = git(src, "hash-object", "-w", "--stdin", env=ienv, inp=a.version + "\n")
        git(root, "update-index", "--cacheinfo", f"100644,{blob},{pre}VERSION", env=ienv)
        tree = git(src, "write-tree", env=ienv)
        cand = git(src, "commit-tree", tree, "-p", "HEAD", "-m", f"Flow {a.version} (Release-Tor-Kandidat)", env=ienv)
        safe = "FLOW_TEST_APP_DIR" in git(src, "show", f"{cand}:{pre}build.sh")
        rep.add("Kandidat hat den Testmodus in build.sh (sonst würde der Test echt installieren)", safe)
        if not safe:
            return done(rep, a, t_all)
        git(src, "push", "-q", remote, f"{cand}:refs/heads/main")
        seen = git(jdir, "ls-remote", "origin", "HEAD", env=jenv).split("\t")[0]
        git(jdir, "fetch", "-q", "origin", env=jenv)
        pending = git(jdir, "log", "--no-merges", "--format=%s", "HEAD..@{u}", env=jenv)
        rep.add("Update-Prüfung sieht den neuen Stand (ls-remote + log HEAD..@{u}, roter Punkt)", seen == cand and bool(pending),
                f"{len(pending.splitlines())} Commit(s)")

        # --- 4) exakter Updater-Befehl
        log = os.path.join(T, "update.log")
        r = subprocess.run([a.flow, "--updater-command", jdir, log], capture_output=True, text=True, errors="replace",
                           env=dict(os.environ, FLOW_HOME=os.path.join(T, "gate-home")))
        cmd = r.stdout.strip()
        rep.add("Befehl aus Updater.installScript geholt (--updater-command)", r.returncode == 0 and "./update.sh" in cmd and "stash push" in cmd)
        apps = os.path.join(T, "apps")
        env = dict(jenv)
        env.update({"PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + os.environ.get("PATH", ""),
                    "BUNDLE_ID": "app.flowdictation.flow.releasegate", "FLOW_SIGN_IDENTITY": "-", "FLOW_TEST_APP_DIR": apps,
                    "FLOW_HOME": os.path.join(T, "freund-data")})
        if not a.full_build:
            env["FLOW_TEST_PREBUILT"] = os.path.join(src, ".build", "release")
        before_app, before_ws = running_apps()
        t0 = time.time()
        r = subprocess.run(["/bin/bash", "-lc", cmd], env=env, capture_output=True, text=True, errors="replace", timeout=900)
        dt = time.time() - t0
        logtxt = open(log).read() if os.path.exists(log) else ""
        rep.add(f"Updater-Befehl endet mit Exit 0 ({dt:.1f} s)", r.returncode == 0, "" if r.returncode == 0 else f"exit {r.returncode}: {logtxt[-400:]}")
        head = git(jdir, "rev-parse", "HEAD")
        rep.add("fast-forward auf den Kandidaten", head == cand, f"{head[:9]} (erwartet {cand[:9]})")
        stashes = git(jdir, "stash", "list", env=jenv)
        kept = note in git(jdir, "show", f"stash@{{0}}:{pre}README.md", check=False) if stashes else False
        rep.add("lokale Änderung liegt im Stash (nichts verloren)", "Flow Update" in stashes and kept, stashes.splitlines()[0] if stashes else "kein Stash")
        rep.add("unversionierte Datei unberührt", os.path.exists(untracked) and open(untracked).read() == utext)
        rep.add("Arbeitskopie danach sauber (versionierte Dateien)", git(jdir, "status", "--porcelain", "--untracked-files=no") == "")
        app = os.path.join(apps, "Flow.app")
        info = {}
        try:
            info = plistlib.load(open(os.path.join(app, "Contents", "Info.plist"), "rb"))
        except Exception:
            pass
        rep.add(f"App-Bundle neu gebaut in Temp-Ordner, Version {a.version}", info.get("CFBundleShortVersionString") == a.version,
                f"{info.get('CFBundleShortVersionString')} / {info.get('FlowGitDescribe')} / {info.get('CFBundleIdentifier')}")
        sig = subprocess.run(["codesign", "--verify", "--strict", app], capture_output=True, text=True, errors="replace")
        rep.add("Signatur des Bundles gültig", sig.returncode == 0, sig.stderr.strip()[-200:])
        v = subprocess.run([os.path.join(app, "Contents", "MacOS", "Flow"), "--version"], capture_output=True, text=True, errors="replace", timeout=20,
                           env=dict(os.environ, FLOW_HOME=os.path.join(T, "freund-data")))
        rep.add("Bundle-Binary startet (CLI --version)", v.returncode == 0 and a.version in v.stdout, v.stdout.strip()[:80])
        rep.add("kein LaunchAgent angelegt, nichts nach ~/Applications", not os.path.exists(os.path.join(jhome, "Library", "LaunchAgents"))
                and not os.path.exists(os.path.join(jhome, "Applications")))
        after_app, after_ws = running_apps()
        rep.add("laufende Apps unter ~/Applications + whisper-server nicht angefasst", before_app <= after_app and before_ws <= after_ws,
                f"App {sorted(before_app)} → {sorted(after_app)}, whisper {sorted(before_ws)} → {sorted(after_ws)}")

        # --- 5) Nochmal: nichts Neues
        r2 = subprocess.run(["/bin/bash", "-lc", cmd], env=env, capture_output=True, text=True, errors="replace", timeout=300)
        tail = open(log).read()[len(logtxt):]
        rep.add("zweiter Lauf ohne Neues: Exit 0, nichts gebaut", r2.returncode == 0 and "Nichts zu bauen" in tail, tail.strip().splitlines()[-1] if tail.strip() else "")
        # --- 6) Nächstes Update VON dieser Version aus, von Hand: ./update.sh mit lokaler Änderung
        #        (der Updater-Befehl legt vorher selbst beiseite – hier muss update.sh das allein schaffen)
        j2repo = os.path.join(T, "freund2", "flow")
        os.makedirs(os.path.dirname(j2repo))
        subprocess.run(["git", "clone", "-q", remote, j2repo], check=True, env=jenv)
        j2 = os.path.join(j2repo, pre)
        git(root, "read-tree", cand, env=ienv)
        blob = git(src, "hash-object", "-w", "--stdin", env=ienv, inp="naechstes Update (nur im Test)\n")
        git(root, "update-index", "--add", "--cacheinfo", f"100644,{blob},{pre}tests/.gate-next", env=ienv)
        nxt = git(src, "commit-tree", git(src, "write-tree", env=ienv), "-p", cand, "-m", "Flow nächste Version (Release-Tor)", env=ienv)
        git(src, "push", "-q", remote, f"{nxt}:refs/heads/main")
        with open(os.path.join(j2, "README.md"), "a") as f:
            f.write(f"\n{note}\n")
        env2 = dict(env, FLOW_TEST_APP_DIR=os.path.join(T, "apps2"))
        r3 = subprocess.run(["/bin/bash", "-lc", f"cd '{j2}' && ./update.sh"], env=env2, capture_output=True, text=True, errors="replace", timeout=900)
        out3 = r3.stdout + r3.stderr
        ok3 = r3.returncode == 0 and git(j2, "rev-parse", "HEAD") == nxt and note in git(j2, "show", f"stash@{{0}}:{pre}README.md", check=False)
        rep.add("./update.sh von Hand mit lokaler Änderung (nächstes Update ab dieser Version)", ok3,
                "" if ok3 else f"exit {r3.returncode}: {out3.strip()[-300:]}")
    except Exception as e:  # noqa: BLE001
        rep.add("Update-Test ohne Ausnahme", False, str(e)[:300])
    return done(rep, a, t_all)


def done(rep, a, t_all):
    rep.save(a.out, {"seconds": round(time.time() - t_all, 1)})
    return 0 if rep.passed else 1


if __name__ == "__main__":
    sys.exit(main())
