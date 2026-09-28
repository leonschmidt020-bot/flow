// Agent-Prompt: the user's own Claude Code CLI, streamed (port of APBuilder.claudeStream, Mac).
//
// Windows installs the CLI either natively (%USERPROFILE%\.local\bin\claude.exe) or through npm (%APPDATA%\npm\claude.cmd).
// A .cmd shim can only be started through cmd.exe – so every argument is a constant (no user text on the command line):
// the dictation goes in through stdin, the system prompt through a file in the process's own temporary working folder
// (`--system-prompt-file system.txt`). Arguments are still escaped properly (cmd.exe metacharacters + CommandLineToArgvW
// rules, doubled for the shim's %* re-parse), `shell` is never used.
//
// Arguments: -p --model sonnet --effort low, no tools, no MCP servers, no settings, no stored session, stream-json with
// partial messages (the card shows the text while it is written). Minimal environment (no keys/proxies from ours).
// Log: nothing from here – the builder logs model, effort, word counts and times only.
import { spawn, type ChildProcess } from 'node:child_process';
import { existsSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import type { RunnerArgs } from './builder';

// MARK: - finding the CLI

export function claudeCandidates(env: NodeJS.ProcessEnv = process.env, platform: NodeJS.Platform = process.platform): string[] {
  const P = platform === 'win32' ? path.win32 : path.posix;
  const home = env.USERPROFILE ?? env.HOME ?? '';
  const out: string[] = [];
  if (platform === 'win32') {
    if (home) out.push(P.join(home, '.local', 'bin', 'claude.exe'), P.join(home, '.claude', 'local', 'claude.exe'), P.join(home, '.claude', 'local', 'claude.cmd'));
    const appData = env.APPDATA ?? (home ? P.join(home, 'AppData', 'Roaming') : '');
    if (appData) out.push(P.join(appData, 'npm', 'claude.cmd'), P.join(appData, 'npm', 'claude.exe'));
    if (env.LOCALAPPDATA) out.push(P.join(env.LOCALAPPDATA, 'Programs', 'claude', 'claude.exe'), P.join(env.LOCALAPPDATA, 'Volta', 'bin', 'claude.exe'));
    if (home) out.push(P.join(home, 'scoop', 'shims', 'claude.exe'), P.join(home, 'scoop', 'shims', 'claude.cmd'));
    for (const d of (env.PATH ?? env.Path ?? '').split(';').map((x) => x.trim().replace(/^"|"$/gu, '')).filter(Boolean)) {
      out.push(P.join(d, 'claude.exe'), P.join(d, 'claude.cmd'));
    }
  } else {
    if (home) out.push(P.join(home, '.local', 'bin', 'claude'), P.join(home, '.claude', 'local', 'claude'));
    out.push('/opt/homebrew/bin/claude', '/usr/local/bin/claude');
    for (const d of (env.PATH ?? '').split(':').filter(Boolean)) out.push(P.join(d, 'claude'));
  }
  return [...new Set(out)];
}

export function findClaudeBin(env: NodeJS.ProcessEnv = process.env, platform: NodeJS.Platform = process.platform,
  exists: (p: string) => boolean = existsSync): string | null {
  return claudeCandidates(env, platform).find((c) => { try { return exists(c); } catch { return false; } }) ?? null;
}

// MARK: - arguments + Windows quoting

export const SYSTEM_FILE = 'system.txt';

export function streamArgs(model: string, effort: string): string[] {
  return ['-p', '--model', model, ...(effort ? ['--effort', effort] : []), '--system-prompt-file', SYSTEM_FILE, '--tools', '',
    '--strict-mcp-config', '--setting-sources', '', '--no-session-persistence',
    '--output-format', 'stream-json', '--verbose', '--include-partial-messages'];
}

const META = /([()\][%!^"`<>&|;, *?])/gu;

/** the program path for cmd.exe: quoted (spaces, parentheses in „Program Files (x86)“ …); a Windows path never contains `"` */
export function escapeCmdCommand(s: string): string {
  if (s.includes('"')) throw new Error('unsafe program path for cmd.exe');
  return `"${s}"`;
}

/** one argument for cmd.exe → a batch shim → CommandLineToArgvW (qntm.org/cmd; the same algorithm as cross-spawn) */
export function escapeCmdArg(arg: string, doubleEscape = true): string {
  let a = arg.replace(/(\\*)"/gu, '$1$1\\"');   // backslashes before a quote doubled, the quote escaped
  a = a.replace(/(\\*)$/u, '$1$1');              // trailing backslashes doubled (they precede the closing quote)
  a = `"${a}"`;
  a = a.replace(META, '^$1');
  if (doubleEscape) a = a.replace(META, '^$1');  // the shim re-parses %* once more
  return a;
}

export interface SpawnPlan { file: string; args: string[]; verbatim: boolean }

/** how to start `bin` with `args` without a shell: .exe directly, .cmd/.bat through `cmd.exe /d /s /c "…"` */
export function spawnPlan(bin: string, args: string[], platform: NodeJS.Platform = process.platform, comspec = process.env.ComSpec): SpawnPlan {
  if (platform === 'win32' && /\.(cmd|bat)$/iu.test(bin)) {
    const line = [escapeCmdCommand(bin), ...args.map((a) => escapeCmdArg(a, true))].join(' ');
    return { file: comspec || 'cmd.exe', args: ['/d', '/s', '/c', `"${line}"`], verbatim: true };
  }
  return { file: bin, args, verbatim: false };
}

/** only what the CLI needs (no API keys, no proxies) */
export function minimalEnv(src: NodeJS.ProcessEnv = process.env): NodeJS.ProcessEnv {
  const env: NodeJS.ProcessEnv = {};
  for (const k of ['HOME', 'USERPROFILE', 'HOMEDRIVE', 'HOMEPATH', 'USER', 'USERNAME', 'LOGNAME', 'LANG', 'TMP', 'TEMP', 'TMPDIR', 'APPDATA',
    'LOCALAPPDATA', 'ProgramData', 'ProgramFiles', 'SystemRoot', 'SystemDrive', 'windir', 'ComSpec', 'PATH', 'Path', 'PATHEXT', 'SHELL',
    'CLAUDE_CODE_GIT_BASH_PATH']) {
    if (src[k]) env[k] = src[k];
  }
  return env;
}

/** end the process and everything it started (cmd.exe → node → claude) */
export function killTree(p: ChildProcess, platform: NodeJS.Platform = process.platform): void {
  if (p.exitCode !== null || p.signalCode !== null) return;
  if (platform === 'win32' && p.pid) {
    try {
      const k = spawn('taskkill', ['/pid', String(p.pid), '/T', '/F'], { windowsHide: true, stdio: 'ignore' });
      k.on('error', () => { try { p.kill(); } catch { /* */ } });
      return;
    } catch { /* fall through */ }
  }
  try { p.kill('SIGTERM'); } catch { /* */ }
}

// MARK: - stream-json

export interface StreamState { acc: string; final: string | null; isError: boolean }

/** one line of `--output-format stream-json`; returns true when the text grew */
export function parseStreamLine(line: string, st: StreamState): boolean {
  const l = line.trim();
  if (!l) return false;
  let o: Record<string, unknown>;
  try { o = JSON.parse(l) as Record<string, unknown>; } catch { return false; }
  if (o.type === 'stream_event') {
    const ev = o.event as Record<string, unknown> | undefined;
    const d = ev?.delta as Record<string, unknown> | undefined;
    if (ev?.type === 'content_block_delta' && d?.type === 'text_delta' && typeof d.text === 'string') { st.acc += d.text; return true; }
  } else if (o.type === 'result') {
    st.final = typeof o.result === 'string' ? o.result : null;
    st.isError = o.is_error === true;
  }
  return false;
}

// MARK: - the runner

export interface StreamDeps {
  bin: () => string | null;
  spawn?: typeof spawn;
  platform?: NodeJS.Platform;
  env?: NodeJS.ProcessEnv;
}

/** Runner for APBuilder: `claude -p … --output-format stream-json`, prompt through stdin, killed on cancel/time limit */
export function claudeStream(deps: StreamDeps) {
  return (a: RunnerArgs): Promise<string> => new Promise<string>((resolve, reject) => {
    const bin = deps.bin();
    if (!bin) { reject(new Error('Claude-CLI nicht gefunden')); return; }
    const platform = deps.platform ?? process.platform;
    const tmp = mkdtempSync(path.join(os.tmpdir(), 'flow-prompt-'));
    const cleanup = () => { try { rmSync(tmp, { recursive: true, force: true }); } catch { /* */ } };
    writeFileSync(path.join(tmp, SYSTEM_FILE), a.system, { encoding: 'utf8', mode: 0o600 });
    const plan = spawnPlan(bin, streamArgs(a.model, a.effort), platform, (deps.env ?? process.env).ComSpec);
    let p: ChildProcess;
    try {
      p = (deps.spawn ?? spawn)(plan.file, plan.args, {
        cwd: tmp, env: minimalEnv(deps.env), windowsHide: true, windowsVerbatimArguments: plan.verbatim, shell: false, stdio: ['pipe', 'pipe', 'pipe'],
      });
    } catch (e) {
      cleanup();
      reject(new Error(`Claude-CLI startet nicht: ${(e as NodeJS.ErrnoException).code ?? 'Fehler'}`));
      return;
    }
    const st: StreamState = { acc: '', final: null, isError: false };
    let buf = '';
    let lastPush = 0;
    let timedOut = false, cancelled = false, done = false;
    const kill = () => killTree(p, platform);
    const timer = setTimeout(() => { timedOut = true; kill(); }, a.timeoutMs);
    const onAbort = () => { cancelled = true; kill(); };
    a.signal.addEventListener('abort', onAbort, { once: true });
    if (a.signal.aborted) onAbort();
    const end = (fn: () => void) => { if (done) return; done = true; clearTimeout(timer); a.signal.removeEventListener('abort', onAbort); cleanup(); fn(); };
    p.stdout?.setEncoding('utf8');
    p.stdout?.on('data', (chunk: string) => {
      buf += chunk;
      let nl: number;
      while ((nl = buf.indexOf('\n')) >= 0) {
        const line = buf.slice(0, nl);
        buf = buf.slice(nl + 1);
        // at most ~20× per second
        if (parseStreamLine(line, st) && Date.now() - lastPush > 50) { lastPush = Date.now(); a.onText(st.acc); }
      }
    });
    p.stderr?.on('data', () => { /* never logged: could echo the dictation */ });
    p.on('error', (e: NodeJS.ErrnoException) => end(() => reject(new Error(`Claude-CLI startet nicht: ${e.code ?? 'Fehler'}`))));
    p.on('close', (code) => {
      if (buf) { parseStreamLine(buf, st); buf = ''; }
      end(() => {
        if (cancelled) { reject(new Error('abgebrochen')); return; }
        if (timedOut) { reject(new Error(`Zeitlimit (${Math.round(a.timeoutMs / 1000)} s)`)); return; }
        const out = (st.final ?? st.acc).trim();
        if (code !== 0 || st.isError || !out) { reject(new Error(`Claude-CLI Fehler (${code})`)); return; }
        a.onText(out);
        resolve(out);
      });
    });
    p.stdin?.on('error', () => { /* process ended early – reported by close */ });
    p.stdin?.end(a.input, 'utf8');
  });
}
