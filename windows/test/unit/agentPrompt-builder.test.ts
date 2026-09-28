// Agent-Prompt builder with a mocked Claude CLI (no real Claude, no network) + the CLI runner (fake process, stream-json,
// Windows .cmd quoting, finding the CLI).
import { describe, expect, it } from 'vitest';
import { EventEmitter } from 'node:events';
import { PassThrough } from 'node:stream';
import { chmodSync, existsSync, mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { APBuilder, buildInput, cleanOutput, errorKind, SYSTEM_PROMPT, type Runner, type RunnerArgs } from '../../src/agentPrompt/builder';
import {
  claudeCandidates, claudeStream, escapeCmdArg, escapeCmdCommand, findClaudeBin, minimalEnv, parseStreamLine, spawnPlan, streamArgs, SYSTEM_FILE,
} from '../../src/agentPrompt/claudeCli';
import { FALLBACK_DE, SAMPLE_PROMPT_DE } from '../../src/agentPrompt/testSet';

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const mk = (runner: Runner, o: Partial<{ available: boolean; timeoutMs: number; ruleFallback: boolean }> = {}) =>
  new APBuilder({ runner, available: () => o.available ?? true, timeoutMs: o.timeoutMs, ruleFallback: o.ruleFallback });

describe('builder (mocked Claude)', () => {
  it('success: sonnet/low passed, live text arrives, introduction removed', async () => {
    let seen: RunnerArgs | null = null;
    const b = mk(async (a) => {
      seen = a;
      a.onText('**Ziel:** Settings');
      await sleep(20);
      a.onText(SAMPLE_PROMPT_DE);
      return 'Hier ist dein Prompt:\n\n' + SAMPLE_PROMPT_DE;
    });
    const parts: string[] = [];
    const r = await b.build({ transcript: FALLBACK_DE }, (p) => parts.push(p));
    expect(r.t).toBe('ok');
    if (r.t !== 'ok') return;
    expect(r.res.source).toBe('claude/sonnet/low');
    expect(r.res.prompt.startsWith('**Ziel:**')).toBe(true);
    expect(seen!.model).toBe('sonnet');
    expect(seen!.effort).toBe('low');
    expect(seen!.timeoutMs).toBe(45_000);
    expect(seen!.system).toBe(SYSTEM_PROMPT);
    expect(seen!.input).toContain('<diktat sprache="de">');
    expect(seen!.input).toContain(FALLBACK_DE);
    expect(parts.length).toBeGreaterThanOrEqual(2);
  });

  it('time limit → rule prompt (fast), the runner is told to stop', async () => {
    let aborted = false;
    const b = mk((a) => new Promise<string>(() => { a.signal.addEventListener('abort', () => { aborted = true; }); }), { timeoutMs: 300 });
    const t0 = Date.now();
    const r = await b.build({ transcript: FALLBACK_DE });
    expect(Date.now() - t0).toBeLessThan(3000);
    expect(r.t).toBe('ok');
    if (r.t !== 'ok') return;
    expect(r.res.source).toBe('regeln');
    expect(r.res.note).toContain('Zeitlimit');
    expect(r.res.prompt).toContain('users.controller.ts');
    expect(aborted).toBe(true);
  });

  it('runner reports its own time limit → „Zeitlimit (45 s)“', async () => {
    const r = await mk(async () => { throw new Error('Zeitlimit (45 s)'); }).build({ transcript: FALLBACK_DE });
    expect(r.t === 'ok' && r.res.note).toBe('Zeitlimit (45 s)');
  });

  it('error → rule prompt „Claude nicht erreichbar“, logged without text', async () => {
    const lines: string[] = [];
    const b = new APBuilder({ runner: async () => { throw new Error(`Claude-CLI Fehler (1)`); }, available: () => true, log: (l) => lines.push(l) });
    const r = await b.build({ transcript: FALLBACK_DE });
    expect(r.t === 'ok' && r.res.source).toBe('regeln');
    expect(r.t === 'ok' && r.res.note).toBe('Claude nicht erreichbar');
    expect(lines).toEqual(['Agent-Prompt: Claude-Fehler (Exit 1)']);
    expect(errorKind('Claude-CLI startet nicht: ENOENT')).toBe('ENOENT');
    expect(errorKind('irgendwas mit Text vom Diktat')).toBe('unbekannt');
  });

  it('CLI missing → rule prompt „Claude-CLI fehlt“, runner never called', async () => {
    let ran = false;
    const r = await mk(async () => { ran = true; return ''; }, { available: false }).build({ transcript: FALLBACK_DE });
    expect(r.t === 'ok' && r.res.note).toBe('Claude-CLI fehlt');
    expect(ran).toBe(false);
  });

  it('nonsense answer (too short) → rules', async () => {
    const r = await mk(async () => 'OK.').build({ transcript: FALLBACK_DE });
    expect(r.t === 'ok' && r.res.source).toBe('regeln');
    expect(r.t === 'ok' && r.res.note).toContain('zu kurz');
  });

  it('without fallback: failure instead of rules', async () => {
    const r = await mk(async () => { throw new Error('Claude-CLI Fehler (1)'); }, { ruleFallback: false }).build({ transcript: FALLBACK_DE });
    expect(r).toEqual({ t: 'failed', why: 'Claude nicht erreichbar' });
  });

  it('cancel → cancelled at once (no rule prompt), even if the runner ignores the signal', async () => {
    const ac = new AbortController();
    const b = mk(() => new Promise<string>((res) => setTimeout(() => res(SAMPLE_PROMPT_DE), 5000)));
    const t0 = Date.now();
    setTimeout(() => ac.abort(), 100);
    const r = await b.build({ transcript: FALLBACK_DE }, () => {}, ac.signal);
    expect(r).toEqual({ t: 'cancelled' });
    expect(Date.now() - t0).toBeLessThan(1000);
  });

  it('empty dictation → failed', async () => {
    expect(await mk(async () => '').build({ transcript: '  ' })).toEqual({ t: 'failed', why: 'Nichts gehört' });
  });

  it('wrapping removed: code fence, introduction', () => {
    expect(cleanOutput('```markdown\n**Ziel:** X\n## Aufgabe\n1. Y\n```')).toBe('**Ziel:** X\n## Aufgabe\n1. Y');
    expect(cleanOutput('Gern! Hier:\n**Goal:** X')).toBe('**Goal:** X');
  });

  it('input: English dictation asks for English headings, context only for agent apps', () => {
    const en = buildInput({ transcript: 'Please add a CSV export to the report view and make sure the tests pass.' });
    expect(en).toContain('<diktat sprache="en">');
    expect(en).toContain('**Goal:**');
    const ctx = buildInput({ transcript: FALLBACK_DE, context: { appName: 'Visual Studio Code', exe: 'Code.exe', windowTitle: 'app.ts - shop', selection: '' } });
    expect(ctx).toContain('<kontext>\nApp: Visual Studio Code\nFenstertitel: app.ts - shop\n</kontext>');
    const mail = buildInput({ transcript: FALLBACK_DE, context: { appName: 'Outlook', exe: 'OUTLOOK.EXE', windowTitle: 'Re: Gehalt', selection: '' } });
    expect(mail).not.toContain('Gehalt');
  });
});

// ── the CLI runner ──

/** cmd.exe parse pass: ^x → x outside quotes, quotes toggle */
function cmdPass(s: string): string {
  let out = '', inQ = false;
  for (let i = 0; i < s.length; i++) {
    const c = s[i]!;
    if (c === '"') { inQ = !inQ; out += c; } else if (c === '^' && !inQ) { i++; out += s[i] ?? ''; } else out += c;
  }
  return out;
}
/** CommandLineToArgvW / msvcrt rules */
function argv(s: string): string[] {
  const out: string[] = [];
  let cur = '', inQ = false, has = false;
  for (let i = 0; i < s.length; i++) {
    const c = s[i]!;
    if (c === '\\') {
      let n = 0;
      while (s[i] === '\\') { n++; i++; }
      if (s[i] === '"') { cur += '\\'.repeat(Math.floor(n / 2)); if (n % 2) { cur += '"'; } else { inQ = !inQ; } has = true; } else { cur += '\\'.repeat(n); i--; has = true; }
      continue;
    }
    if (c === '"') { inQ = !inQ; has = true; continue; }
    if ((c === ' ' || c === '\t') && !inQ) { if (has) { out.push(cur); cur = ''; has = false; } continue; }
    cur += c; has = true;
  }
  if (has) out.push(cur);
  return out;
}

describe('Windows: .cmd shim through cmd.exe (argument quoting)', () => {
  const bin = 'C:\\Users\\Jo Beispiel\\AppData\\Roaming\\npm\\claude.cmd';
  it('plan: cmd.exe /d /s /c "…", verbatim, no shell', () => {
    const plan = spawnPlan(bin, streamArgs('sonnet', 'low'), 'win32', 'C:\\Windows\\system32\\cmd.exe');
    expect(plan.file).toBe('C:\\Windows\\system32\\cmd.exe');
    expect(plan.args.slice(0, 3)).toEqual(['/d', '/s', '/c']);
    expect(plan.verbatim).toBe(true);
    expect(plan.args[3]!.startsWith('""C:\\Users\\Jo Beispiel')).toBe(true);
    expect(plan.args[3]!.endsWith('"')).toBe(true);
  });
  it('.exe is started directly (no cmd.exe)', () => {
    const plan = spawnPlan('C:\\Users\\jo\\.local\\bin\\claude.exe', ['-p'], 'win32');
    expect(plan).toEqual({ file: 'C:\\Users\\jo\\.local\\bin\\claude.exe', args: ['-p'], verbatim: false });
  });
  it('every argument survives cmd.exe + the shim re-parse + CommandLineToArgvW', () => {
    const args = [...streamArgs('sonnet', 'low'), 'a b', 'x"y', 'C:\\dir\\', 'C:\\a\\"q', '100%', 'a&b|c<d>e^f!g(h)', ''];
    const line = spawnPlan(bin, args, 'win32', 'cmd.exe').args[3]!;
    // cmd /s /c strips the outer quotes, then parses once
    const pass1 = cmdPass(line.slice(1, -1));
    const cmdTok = pass1.slice(0, pass1.indexOf('" ') + 1);
    expect(cmdTok).toBe(`"${bin}"`);
    // the shim substitutes %* and parses once more, node splits the command line
    const rest = cmdPass(pass1.slice(cmdTok.length + 1));
    expect(argv(rest)).toEqual(args);
  });
  it('empty arguments stay empty („--tools ""“)', () => {
    expect(escapeCmdArg('')).toBe('^^^"^^^"');
    expect(escapeCmdArg('-p')).toBe('^^^"-p^^^"');
    expect(escapeCmdArg('-p', false)).toBe('^"-p^"');
    expect(() => escapeCmdCommand('C:\\bad"path')).toThrow();
  });
  it('the command line holds no user text: system prompt via file, dictation via stdin', () => {
    const a = streamArgs('sonnet', 'low');
    expect(a).toEqual(['-p', '--model', 'sonnet', '--effort', 'low', '--system-prompt-file', SYSTEM_FILE, '--tools', '', '--strict-mcp-config',
      '--setting-sources', '', '--no-session-persistence', '--output-format', 'stream-json', '--verbose', '--include-partial-messages']);
  });
});

describe('finding the CLI', () => {
  it('Windows: native installer, npm shim, PATH', () => {
    const env = { USERPROFILE: 'C:\\Users\\jo', APPDATA: 'C:\\Users\\jo\\AppData\\Roaming', LOCALAPPDATA: 'C:\\Users\\jo\\AppData\\Local', PATH: 'C:\\tools;"C:\\Program Files\\nodejs"' };
    const c = claudeCandidates(env, 'win32');
    expect(c[0]).toBe('C:\\Users\\jo\\.local\\bin\\claude.exe');
    expect(c).toContain('C:\\Users\\jo\\AppData\\Roaming\\npm\\claude.cmd');
    expect(c).toContain('C:\\Program Files\\nodejs\\claude.cmd');
    expect(c).toContain('C:\\tools\\claude.exe');
    expect(findClaudeBin(env, 'win32', (p) => p === 'C:\\Users\\jo\\AppData\\Roaming\\npm\\claude.cmd')).toBe('C:\\Users\\jo\\AppData\\Roaming\\npm\\claude.cmd');
    expect(findClaudeBin(env, 'win32', () => false)).toBeNull();
  });
  it('minimal environment: no keys, no proxies', () => {
    const e = minimalEnv({ PATH: 'x', USERPROFILE: 'u', ANTHROPIC_API_KEY: 'secret', HTTPS_PROXY: 'p', ComSpec: 'cmd.exe' });
    expect(e).toEqual({ PATH: 'x', USERPROFILE: 'u', ComSpec: 'cmd.exe' });
  });
});

describe('stream-json', () => {
  it('text deltas accumulate, result wins', () => {
    const st = { acc: '', final: null as string | null, isError: false };
    const delta = (t: string) => JSON.stringify({ type: 'stream_event', event: { type: 'content_block_delta', delta: { type: 'text_delta', text: t } } });
    expect(parseStreamLine(delta('**Ziel:** '), st)).toBe(true);
    expect(parseStreamLine(delta('X'), st)).toBe(true);
    expect(parseStreamLine('not json', st)).toBe(false);
    expect(parseStreamLine(JSON.stringify({ type: 'system', subtype: 'init' }), st)).toBe(false);
    expect(st.acc).toBe('**Ziel:** X');
    parseStreamLine(JSON.stringify({ type: 'result', result: '**Ziel:** X!', is_error: false }), st);
    expect(st.final).toBe('**Ziel:** X!');
  });

  class FakeProc extends EventEmitter {
    stdout = new PassThrough(); stderr = new PassThrough(); stdin = new PassThrough();
    exitCode: number | null = null; signalCode: string | null = null; pid = 4242; killed = 0;
    kill() { this.killed++; this.signalCode = 'SIGTERM'; setTimeout(() => this.emit('close', null), 5); return true; }
  }

  it('fake process: args, cwd with the system prompt file, stdin, streamed text', async () => {
    let got: { file: string; args: string[]; opts: Record<string, unknown> } | null = null;
    let sys = '';
    let stdin = '';
    const proc = new FakeProc();
    proc.stdin.on('data', (d) => { stdin += String(d); });
    const fakeSpawn = ((file: string, args: string[], opts: Record<string, unknown>) => {
      got = { file, args, opts };
      sys = readFileSync(path.join(String(opts.cwd), SYSTEM_FILE), 'utf8');
      setTimeout(() => {
        const d = (t: string) => JSON.stringify({ type: 'stream_event', event: { type: 'content_block_delta', delta: { type: 'text_delta', text: t } } }) + '\n';
        proc.stdout.write(d('**Ziel:** A'));
        setTimeout(() => {
          proc.stdout.write(d(' B') + JSON.stringify({ type: 'result', result: '**Ziel:** A B', is_error: false }));
          proc.exitCode = 0;
          proc.stdout.end();
          setTimeout(() => proc.emit('close', 0), 5);
        }, 80);
      }, 10);
      return proc;
    }) as unknown as typeof import('node:child_process').spawn;
    const texts: string[] = [];
    const run = claudeStream({ bin: () => '/opt/claude', spawn: fakeSpawn, platform: 'darwin', env: { PATH: '/bin', ANTHROPIC_API_KEY: 'k' } });
    const out = await run({ system: 'SYS', input: 'DIKTAT', model: 'sonnet', effort: 'low', timeoutMs: 5000, onText: (t) => texts.push(t), signal: new AbortController().signal });
    expect(out).toBe('**Ziel:** A B');
    expect(got!.file).toBe('/opt/claude');
    expect(got!.args).toEqual(streamArgs('sonnet', 'low'));
    expect(got!.opts.shell).toBe(false);
    expect((got!.opts.env as Record<string, string>).ANTHROPIC_API_KEY).toBeUndefined();
    expect(sys).toBe('SYS');
    expect(stdin).toBe('DIKTAT');
    expect(texts[0]).toBe('**Ziel:** A');
    expect(texts[texts.length - 1]).toBe('**Ziel:** A B');
    expect(existsSync(String(got!.opts.cwd))).toBe(false); // temp folder removed
  });

  it('fake process: time limit kills the process', async () => {
    const proc = new FakeProc();
    const run = claudeStream({ bin: () => '/opt/claude', spawn: (() => proc) as unknown as typeof import('node:child_process').spawn, platform: 'darwin' });
    await expect(run({ system: 's', input: 'i', model: 'sonnet', effort: 'low', timeoutMs: 100, onText: () => {}, signal: new AbortController().signal }))
      .rejects.toThrow('Zeitlimit');
    expect(proc.killed).toBe(1);
  });

  it('fake process: abort kills the process', async () => {
    const proc = new FakeProc();
    const ac = new AbortController();
    const run = claudeStream({ bin: () => '/opt/claude', spawn: (() => proc) as unknown as typeof import('node:child_process').spawn, platform: 'darwin' });
    setTimeout(() => ac.abort(), 30);
    await expect(run({ system: 's', input: 'i', model: 'sonnet', effort: 'low', timeoutMs: 5000, onText: () => {}, signal: ac.signal })).rejects.toThrow('abgebrochen');
    expect(proc.killed).toBe(1);
  });

  it('missing binary → error', async () => {
    const run = claudeStream({ bin: () => null });
    await expect(run({ system: 's', input: 'i', model: 'sonnet', effort: 'low', timeoutMs: 100, onText: () => {}, signal: new AbortController().signal })).rejects.toThrow('nicht gefunden');
  });

  it.skipIf(process.platform === 'win32')('real process (a fake „claude“ script): exit code ≠ 0 → error, success → text', async () => {
    const dir = mkdtempSync(path.join(os.tmpdir(), 'flow-fake-claude-'));
    const ok = path.join(dir, 'claude-ok');
    writeFileSync(ok, '#!/bin/sh\ncat >/dev/null\nprintf \'%s\\n\' \'{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"**Ziel:** Echt"}}}\' \'{"type":"result","result":"**Ziel:** Echt","is_error":false}\'\n');
    chmodSync(ok, 0o755);
    const bad = path.join(dir, 'claude-bad');
    writeFileSync(bad, '#!/bin/sh\ncat >/dev/null\necho "kaputt" >&2\nexit 3\n');
    chmodSync(bad, 0o755);
    const args = { system: 's', input: 'i', model: 'sonnet', effort: 'low', timeoutMs: 5000, onText: () => {}, signal: new AbortController().signal };
    expect(await claudeStream({ bin: () => ok })(args)).toBe('**Ziel:** Echt');
    await expect(claudeStream({ bin: () => bad })(args)).rejects.toThrow('Claude-CLI Fehler (3)');
  });
});
