#!/usr/bin/env python3
"""Builds test/fixtures/mac-golden.json from the Mac app (read-only).

1. Parses the Swift regression sets PolishCases.swift and ListCases.swift (inputs + expectations).
2. Runs the Mac release binary's rule-only evaluators in a throw-away MURMUR_HOME
   (`--quality-polish-eval regeln --beide --show`, `--quality-lists-eval --beide|--holdout2|--holdout3 --show`)
   and records what the Mac rules ACTUALLY output ("mac"), per target app.

The TypeScript port is tested against "mac" (behavioural parity), not against "expected".
Usage: python3 scripts/extract_mac_golden.py [--mac-repo <path to the Mac app sources, default ../mac/flow>]
(needs a release build of the Mac app: `swift build -c release` in that folder)
"""
import json, os, re, subprocess, sys, tempfile

MAC = os.path.abspath(os.path.expanduser(sys.argv[sys.argv.index('--mac-repo') + 1] if '--mac-repo' in sys.argv
                                         else os.path.join(os.path.dirname(__file__), '..', '..', 'mac', 'flow')))
Q = next((os.path.join(MAC, 'Sources', d, 'VoiceFlow', 'Quality') for d in os.listdir(os.path.join(MAC, 'Sources'))
          if os.path.isdir(os.path.join(MAC, 'Sources', d, 'VoiceFlow', 'Quality'))), None)
BIN = next((os.path.join(MAC, '.build', 'release', n) for n in ('Flow', 'Murmur') if os.path.exists(os.path.join(MAC, '.build', 'release', n))),
           os.path.join(MAC, '.build', 'release', 'Flow'))
OUT = os.path.join(os.path.dirname(__file__), '..', 'test', 'fixtures', 'mac-golden.json')

CONSTS = {'vscode': 'com.microsoft.VSCode', 'mail': 'com.apple.mail', 'slack': 'com.tinyspeck.slackmacgap',
          'terminal': 'com.apple.Terminal', 'whatsapp': 'net.whatsapp.WhatsApp'}


def swift_string(src, i):
    assert src[i] == '"'
    i += 1
    out = []
    while True:
        c = src[i]
        if c == '\\':
            n = src[i + 1]
            if n == 'n': out.append('\n'); i += 2
            elif n == 't': out.append('\t'); i += 2
            elif n == 'u':
                j = src.index('}', i)
                out.append(chr(int(src[i + 3:j], 16))); i = j + 1
            else: out.append(n); i += 2
        elif c == '"':
            return ''.join(out), i + 1
        else:
            out.append(c); i += 1


def parse_cases(path, group_names):
    src = open(path, encoding='utf-8').read()
    groups = {}
    for g in group_names:
        m = re.search(r'static let ' + g + r': \[\w+\] = \[', src)
        if not m:
            continue
        i = m.end()
        depth = 1
        cases = []
        while depth > 0:
            if src.startswith('.init(', i):
                i += len('.init(')
                args = {}
                while True:
                    while src[i] in ' \n\t,': i += 1
                    if src[i] == ')': i += 1; break
                    km = re.match(r'(\w+):\s*', src[i:])
                    key = km.group(1); i += km.end()
                    if src[i] == '"':
                        val, i = swift_string(src, i)
                        # string concatenation "a" + "b"
                        while re.match(r'\s*\+\s*"', src[i:]):
                            i = src.index('"', i)
                            more, i = swift_string(src, i)
                            val += more
                    else:
                        vm = re.match(r'[\w.]+', src[i:]); val = CONSTS.get(vm.group(0), vm.group(0)); i += vm.end()
                    args[key] = val
                cases.append(args)
                continue
            c = src[i]
            if c == '"':
                _, i = swift_string(src, i); continue
            if c == '/' and src[i + 1] == '/':
                i = src.index('\n', i); continue
            if c == '[': depth += 1
            elif c == ']': depth -= 1
            i += 1
        groups[g] = cases
    return groups


# Optional: neutral stand-ins for real names/brands in the Mac regression sets, as a local JSON list of
# [from, to] pairs (not committed): FLOW_GOLDEN_SANITIZE=.cache/golden-sanitize.json. The Mac output for the
# neutralised sentence is produced by the same Mac rules binary (`--quality-polish`).
SANITIZE = [tuple(x) for x in json.load(open(os.environ['FLOW_GOLDEN_SANITIZE'], encoding='utf-8'))] if os.environ.get('FLOW_GOLDEN_SANITIZE') else []
BUNDLES = {'markdown': 'md.obsidian', 'plain': 'com.apple.Notes', 'mail': 'com.apple.mail', 'chat': 'net.whatsapp.WhatsApp', 'terminal': 'com.apple.Terminal'}


def sanitize(t):
    for a, b in SANITIZE:
        t = re.sub(r'(?<![\wäöüÄÖÜß])' + re.escape(a) + r'(?![\wäöüÄÖÜß])', b, t)
    return t


def mac_polish(text, bundle, home):
    env = dict(os.environ, MURMUR_HOME=home)
    p = subprocess.run([BIN, '--quality-polish', text, '--app', bundle, '--mode', 'schnell'], env=env, capture_output=True, text=True, timeout=120)
    lines = p.stdout.split('\n')
    assert lines[0].startswith('[regeln') or lines[0].startswith('[unver') or lines[0].startswith('[liste'), p.stdout
    return re.sub(r'[ \t]+', ' ', '\n'.join(lines[1:])).strip()


LINE = re.compile(r'^  [✓✗≈] (\S+) (\S+) \[[^\]]*\]: (.*)$')


def run(args):
    with tempfile.TemporaryDirectory() as home:
        env = dict(os.environ, MURMUR_HOME=home)
        p = subprocess.run([BIN] + args, env=env, capture_output=True, text=True, timeout=900)
    res = {}
    for line in p.stdout.splitlines():
        m = LINE.match(line)
        if m:
            res.setdefault(m.group(2), {})[m.group(1)] = m.group(3).replace('⏎', '\n')
    return res


def main():
    polish = parse_cases(os.path.join(Q, 'PolishCases.swift'), ['all', 'holdout'])
    lists = parse_cases(os.path.join(Q, 'ListCases.swift'), ['all', 'holdout', 'holdout2', 'holdout3'])
    pol_out = run(['--quality-polish-eval', 'regeln', '--beide', '--show'])
    lst_out = {}
    for flag in ['--beide', '--holdout2', '--holdout3']:
        for cid, per in run(['--quality-lists-eval', flag, '--show']).items():
            lst_out[cid] = per
    out = {'source': 'mac-apple-tools/murmur QuickPolish/SmartLists (rules only, no Apple Intelligence)',
           'polish': [], 'lists': []}
    for g, cases in polish.items():
        for c in cases:
            mac = pol_out.get(c['id'], {}).get('regeln')
            if mac is None: continue
            out['polish'].append({'id': c['id'], 'group': g, 'tag': c.get('tag'), 'input': c['input'], 'expected': c['expected'],
                                  'app': c.get('app', 'com.apple.Notes'), 'screen': c.get('screen', ''), 'mac': mac})
    seen = set()
    for g, cases in lists.items():
        for c in cases:
            if c['id'] in seen or c['id'] not in lst_out: continue
            seen.add(c['id'])
            out['lists'].append({'id': c['id'], 'group': g, 'tag': c.get('tag'), 'input': c['input'], 'expected': c['expected'],
                                 'mac': lst_out[c['id']]})
    # drop screen-context cases (need macOS accessibility; their screen texts contain real names)
    out['polish'] = [c for c in out['polish'] if not c['screen']]
    with tempfile.TemporaryDirectory() as home:
        for c in out['polish']:
            if sanitize(c['input']) != c['input']:
                c['input'], c['expected'] = sanitize(c['input']), sanitize(c['expected'])
                c['mac'] = mac_polish(c['input'], c['app'], home)
        for c in out['lists']:
            if sanitize(c['input']) != c['input']:
                c['input'], c['expected'] = sanitize(c['input']), sanitize(c['expected'])
                if 'chat' in c: c['chat'] = sanitize(c['chat'])
                c['mac'] = {t: mac_polish(c['input'], b, home) for t, b in BUNDLES.items()}
    blob = json.dumps(out, ensure_ascii=False)
    for a, _ in SANITIZE:
        assert re.search(r'(?<![\wäöüÄÖÜß])' + re.escape(a) + r'(?![\wäöüÄÖÜß])', blob) is None, a
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    json.dump(out, open(OUT, 'w', encoding='utf-8'), ensure_ascii=False, indent=1)
    print(f"polish {len(out['polish'])} cases, lists {len(out['lists'])} cases -> {os.path.relpath(OUT)}")


if __name__ == '__main__':
    main()
