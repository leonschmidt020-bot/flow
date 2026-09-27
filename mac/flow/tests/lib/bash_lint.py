#!/usr/bin/env python3
"""Release-Tor: Bash-Skripte pruefen (macOS-/bin/bash = 3.2!).

  bash_lint.py <repo>   alle *.sh (versioniert + neu, ohne .build) → Exit 1 bei einem Fund

1. `/bin/bash -n` (Syntax mit bash 3.2)
2. `$NAME` direkt vor einem Mehrbyte-Zeichen („“ – … →): bash 3.2 liest das erste Byte des Zeichens als Teil des
   Variablennamens → mit `set -u` bricht das Skript ab („X\xe2: unbound variable“, so passiert in signing.sh 1.5.2).
   Richtig: `${NAME}“`. Reine Kommentarzeilen werden uebersprungen.
"""
import os, re, subprocess, sys

BAD = re.compile(rb"\$[A-Za-z_][A-Za-z0-9_]*(?=[\x80-\xff])")


def files(repo):
    out = subprocess.run(["git", "-C", repo, "ls-files", "--cached", "--others", "--exclude-standard", "*.sh"],
                         capture_output=True, text=True, errors="replace").stdout.split()
    return sorted(f for f in out if not f.startswith(".build/") and os.path.isfile(os.path.join(repo, f)))


def main():
    repo = sys.argv[1]
    problems = []
    fl = files(repo)
    for f in fl:
        p = os.path.join(repo, f)
        r = subprocess.run(["/bin/bash", "-n", p], capture_output=True, text=True, errors="replace")
        if r.returncode != 0:
            problems.append(f"{f}: bash -n: {r.stderr.strip()[:200]}")
        for i, line in enumerate(open(p, "rb").read().split(b"\n"), 1):
            if line.lstrip().startswith(b"#"):
                continue
            m = BAD.search(line)
            if m:
                problems.append(f"{f}:{i}: {m.group(0).decode()} direkt vor Mehrbyte-Zeichen → ${{{m.group(0)[1:].decode()}}} schreiben")
    for p in problems:
        print("  " + p)
    print(f"{len(fl)} Skripte geprüft ({', '.join(fl)}), {len(problems)} Fund(e)")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
