// Optional summary through a locally installed Claude Code CLI (like ClaudeCLI.swift). Flow itself has no cloud:
// without the CLI the summary UI is simply hidden. With it, the transcript goes to the user's own Claude account –
// that is why the automatic summary is off by default and the button says so.
// No tools, no MCP servers, no session is stored; only a minimal environment is passed on.
import { spawn } from 'node:child_process';
import { existsSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';

export function findClaude(env: NodeJS.ProcessEnv = process.env, platform = process.platform, exists: (p: string) => boolean = existsSync): string | null {
  const P = platform === 'win32' ? path.win32 : path.posix;
  const home = env.USERPROFILE ?? env.HOME ?? '';
  const cands: string[] = [];
  if (platform === 'win32') {
    if (home) cands.push(P.join(home, '.local', 'bin', 'claude.exe'), P.join(home, '.claude', 'local', 'claude.exe'));
    if (env.APPDATA) cands.push(P.join(env.APPDATA, 'npm', 'claude.cmd'));
    for (const d of (env.PATH ?? env.Path ?? '').split(';').filter(Boolean)) cands.push(P.join(d, 'claude.exe'), P.join(d, 'claude.cmd'));
  } else {
    if (home) cands.push(P.join(home, '.local', 'bin', 'claude'), P.join(home, '.claude', 'local', 'claude'));
    cands.push('/opt/homebrew/bin/claude', '/usr/local/bin/claude');
  }
  return cands.find((c) => exists(c)) ?? null;
}

export function claudeArgs(systemPromptFile: string, model = 'sonnet'): string[] {
  return ['-p', '--model', model, '--system-prompt-file', systemPromptFile, '--tools', '', '--strict-mcp-config',
    '--setting-sources', '', '--no-session-persistence', '--output-format', 'text'];
}

/** npm installs a .cmd shim, which Node can only start through cmd.exe – quote every argument, refuse unsafe ones */
export function cmdLine(bin: string, args: string[]): string {
  const q = (a: string) => {
    if (/["%^&|<>!\r\n]/.test(a)) throw new Error('unsafe argument for cmd.exe');
    return `"${a}"`;
  };
  return [q(bin), ...args.map(q)].join(' ');
}

export function runClaude(bin: string, system: string, input: string, o: { timeoutMs?: number; cwd?: string; env?: NodeJS.ProcessEnv } = {}): Promise<string> {
  const tmp = mkdtempSync(path.join(os.tmpdir(), 'flow-claude-'));
  const sp = path.join(tmp, 'system.txt');
  writeFileSync(sp, system, { encoding: 'utf8', mode: 0o600 });
  const src = o.env ?? process.env;
  const env: NodeJS.ProcessEnv = {};
  for (const k of ['HOME', 'USERPROFILE', 'USER', 'USERNAME', 'LOGNAME', 'LANG', 'TMP', 'TEMP', 'TMPDIR', 'APPDATA', 'LOCALAPPDATA', 'SystemRoot', 'ComSpec', 'PATH', 'Path', 'PATHEXT', 'SHELL']) if (src[k]) env[k] = src[k];
  const args = claudeArgs(sp);
  const isCmd = /\.cmd$/i.test(bin);
  return new Promise<string>((resolve, reject) => {
    const p = isCmd
      ? spawn(src.ComSpec ?? 'cmd.exe', ['/d', '/s', '/c', `"${cmdLine(bin, args)}"`], { env, cwd: o.cwd ?? tmp, windowsHide: true, windowsVerbatimArguments: true })
      : spawn(bin, args, { env, cwd: o.cwd ?? tmp, windowsHide: true });
    let out = '', err = '';
    const timer = setTimeout(() => p.kill(), o.timeoutMs ?? 240_000);
    p.stdout.on('data', (d) => { out += String(d); });
    p.stderr.on('data', (d) => { if (err.length < 4000) err += String(d); });
    p.on('error', (e) => { clearTimeout(timer); reject(new Error(`Claude CLI: ${e.message}`)); });
    p.on('close', (code) => {
      clearTimeout(timer);
      rmSync(tmp, { recursive: true, force: true });
      const text = out.trim();
      if (code !== 0 || !text) reject(new Error(`Claude CLI (${code}): ${(err || text).slice(0, 300)}`));
      else resolve(text);
    });
    p.stdin.end(input, 'utf8');
  });
}

export const SUMMARY_SYSTEM = `Du fasst ein Meeting-Transkript zusammen. Schreibe in der Sprache, die im Meeting überwiegend gesprochen wurde.
Erste Zeile exakt: TITEL: <kurzer, konkreter Titel, max. 6 Wörter>
Danach Markdown mit diesen Abschnitten (leere Abschnitte weglassen):
**Kurzfassung** – 2–3 Sätze.
**Kernpunkte** – Stichpunkte.
**Entscheidungen** – Stichpunkte.
**Aufgaben** – Stichpunkte im Format „Name: Aufgabe (bis wann, falls genannt)“.
**Offene Fragen** – Stichpunkte.
Keine Einleitung, keine Floskeln, nichts erfinden.`;

/** "TITEL: …" first line → title + summary body */
export function parseSummary(out: string): { title: string | null; summary: string } {
  const lines = out.split('\n');
  let title: string | null = null;
  if (lines[0] && /^(TITEL|TITLE):/i.test(lines[0].trim())) {
    title = lines[0].trim().replace(/^(TITEL|TITLE):/i, '').trim() || null;
    lines.shift();
  }
  return { title, summary: lines.join('\n').trim() };
}
