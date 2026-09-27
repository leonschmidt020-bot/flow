import { describe, expect, it } from 'vitest';
import { targetForExe } from '../../src/core/smartLists';
import { processTranscript } from '../../src/core/pipeline';

describe('list style follows the Windows foreground app', () => {
  it('maps process names', () => {
    expect(targetForExe('WINWORD.EXE')).toBe('mail');
    expect(targetForExe('C:\\Program Files\\Obsidian\\Obsidian.exe')).toBe('markdown');
    expect(targetForExe('Code.exe')).toBe('markdown');
    expect(targetForExe('WhatsApp.exe')).toBe('chat');
    expect(targetForExe('WindowsTerminal.exe')).toBe('terminal');
    expect(targetForExe('notepad.exe')).toBe('plain');
    expect(targetForExe('')).toBe('plain');
  });
  it('Word gets bullets, Obsidian gets Markdown checkboxes, chat waits for 4 items', () => {
    const o = { removeFillers: true, voiceCommands: true, dictionary: [], polish: true };
    const todo = 'Ich muss heute noch die Rechnung bezahlen, Mama anrufen und den Bericht schreiben.';
    expect(processTranscript(todo, { ...o, target: targetForExe('Obsidian.exe') })).toBe('To-dos (heute):\n- [ ] Die Rechnung bezahlen\n- [ ] Mama anrufen\n- [ ] Den Bericht schreiben');
    expect(processTranscript(todo, { ...o, target: targetForExe('WINWORD.EXE') })).toBe('To-dos (heute):\n• Die Rechnung bezahlen\n• Mama anrufen\n• Den Bericht schreiben');
    expect(processTranscript('Kauf bitte Tomaten, Gurken und Paprika.', { ...o, target: targetForExe('WhatsApp.exe') })).toBe('Kauf bitte Tomaten, Gurken und Paprika.');
  });
});
