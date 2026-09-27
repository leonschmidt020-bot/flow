import { describe, expect, it } from 'vitest';
import { flagsReason, textReason, looksLikePassword, luhnValid, isPasswordManager } from './sensitive';

describe('clipboard format flags (Windows clipboard-history rules)', () => {
  it('ExcludeClipboardContentFromMonitorProcessing -> skip', () => {
    expect(flagsReason({ excludeFromMonitor: true })).toBe('exclude-format');
  });
  it('CanIncludeInClipboardHistory = 0 -> skip, = 1 -> keep', () => {
    expect(flagsReason({ canIncludeInHistory: 0 })).toBe('history-disallowed');
    expect(flagsReason({ canIncludeInHistory: 1 })).toBeNull();
  });
  it('Clipboard Viewer Ignore and macOS concealed/transient markers -> skip', () => {
    expect(flagsReason({ viewerIgnore: true })).toBe('viewer-ignore');
    expect(flagsReason({ concealed: true })).toBe('concealed');
    expect(flagsReason({ transient: true })).toBe('concealed');
  });
  it('password manager as clipboard owner -> skip', () => {
    expect(flagsReason({ ownerProcess: 'C:\\Program Files\\KeePassXC\\KeePassXC.exe' })).toBe('password-manager');
    expect(flagsReason({ ownerProcess: '1Password.exe' })).toBe('password-manager');
    expect(flagsReason({ ownerProcess: 'Bitwarden.exe' })).toBe('password-manager');
    expect(flagsReason({ ownerProcess: 'notepad.exe' })).toBeNull();
    expect(isPasswordManager('MyVault.exe', ['myvault'])).toBe(true);
    expect(flagsReason({ ownerProcess: 'MyVault.exe' }, { skipPasswordLike: true, ignoredApps: ['MyVault.exe'] })).toBe('ignored-app');
  });
});

describe('content heuristics', () => {
  it('private keys, API tokens, JWTs, pairing codes', () => {
    expect(textReason('-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXk=\n-----END OPENSSH PRIVATE KEY-----')).toBe('private-key');
    expect(textReason('-----BEGIN RSA PRIVATE KEY-----\nMIIE\n-----END RSA PRIVATE KEY-----')).toBe('private-key');
    expect(textReason('sk-proj-abcdefghijklmnopqrstuvwxyz0123456789')).toBe('api-token');
    expect(textReason('ghp_abcdefghijklmnopqrstuvwxyz0123456789AB')).toBe('api-token');
    expect(textReason('AKIAABCDEFGHIJKLMNOP')).toBe('api-token');
    expect(textReason('eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U')).toBe('api-token');
    expect(textReason('cvpair1.AT8lBOBPiUHTmgwDBegsMwEPHi08S1ppeIeWpbTD0uHwAAECAwQFBgcICQoL')).toBe('api-token');
  });
  it('credit card numbers (Luhn)', () => {
    expect(luhnValid('4111111111111111')).toBe(true);
    expect(textReason('4111 1111 1111 1111')).toBe('credit-card');
    expect(textReason('4111 1111 1111 1112')).toBeNull();
  });
  it('password-like strings are skipped, normal words/ids/urls are not', () => {
    expect(looksLikePassword('Tr0ub4dor&3xK')).toBe(true);
    expect(looksLikePassword('xQ9!mZ2#pL7@')).toBe(true);
    for (const ok of ['Hallo', 'Hallo Welt!', 'https://example.com/a?b=C1', 'lena@example.com', '3f2504e0-4f89-41d3-9a0c-0305e82c3301',
      'd41d8cd98f00b204e9800998ecf8427e', 'C:\\Users\\Lena\\Desktop', 'Rechnung2026.pdf', 'getElementById', 'user_name_2', 'Passwort123']) {
      expect(looksLikePassword(ok), ok).toBe(false);
    }
    expect(textReason('Tr0ub4dor&3xK', { skipPasswordLike: false, ignoredApps: [] })).toBeNull();
    expect(textReason('Ein ganz normaler Satz mit Zahl 42.')).toBeNull();
  });
});
