// Dictation ↔ Agent-Prompts: „Prompt: …“ is handed over BEFORE pasting (nothing pasted, no normal history entry), with the
// mouse target's capture; a normal dictation is pasted and then offered to the offer check; setting „Aus“ skips the hook.
import { describe, expect, it } from 'vitest';
import { Dictation, type AgentPromptLike } from '../../src/main/dictation';
import { DEFAULTS, type Settings } from '../../src/shared/settings';

function make(text: string, s: Partial<Settings> = {}, take = true) {
  const seq: string[] = [];
  const settings = { ...DEFAULTS, keepInClipboard: true, learnFromEdits: false, ...s };
  const ap: AgentPromptLike = {
    consume: (cleaned, info) => { seq.push(`consume:${cleaned}|${info.exe}|${info.duration}`); return take && cleaned.startsWith('Prompt'); },
    offerLater: (t, info) => { seq.push(`offer:${t}|${info.exe}`); },
  };
  const noop = () => {};
  const d = new Dictation({
    mic: { start: async () => {}, stop: async () => new Float32Array(16000), cancel: noop } as never,
    asr: { ready: true, state: { status: 'ready' }, getEngine: () => ({ transcribe: async () => ({ text, ms: 5, segments: 1 }) }) } as never,
    pill: { state: noop, toast: (m: string) => seq.push('toast:' + m) } as never,
    history: { add: () => seq.push('history') } as never,
    settings: () => settings, clipboard: { snapshot: () => ({ text: '', formats: {} }), restore: noop, writeText: noop, readText: () => '' },
    keys: { paste: () => { seq.push('paste'); } }, foregroundExe: () => 'Code.exe', waitKeysReleased: async () => {}, markInjecting: noop,
    onClipboardWrite: noop, setWriting: noop, agentPrompt: ap,
  });
  return { d, seq };
}

describe('dictation with Agent-Prompts', () => {
  it('„Prompt: …“ → handed over, nothing pasted, no normal history entry', async () => {
    const { d, seq } = make('Prompt: bau den Export um und prüf die Tests');
    await d.start(); await d.stop();
    expect(seq).toEqual(['consume:Prompt: bau den Export um und prüf die Tests|Code.exe|1']);
    expect(d.state).toBe('idle');
  });
  it('normal dictation → pasted, history, then the offer check with the pasted text', async () => {
    const { d, seq } = make('hallo zusammen wie geht es euch');
    await d.start(); await d.stop();
    expect(seq[0]!.startsWith('consume:')).toBe(true);
    expect(seq.slice(1)).toEqual(['paste', 'history', 'offer:Hallo zusammen wie geht es euch.|Code.exe']);
  });
  it('setting „Aus“ → the hook is not even asked', async () => {
    const { d, seq } = make('Prompt: bau den Export um', { agentPrompts: 'off' });
    await d.start(); await d.stop();
    expect(seq.some((x) => x.startsWith('consume'))).toBe(false);
    expect(seq).toContain('paste');
  });
});
