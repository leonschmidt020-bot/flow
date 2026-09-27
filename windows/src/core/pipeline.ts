// Dictation text pipeline (same order as the Mac app):
// TextCleaner.applyRules (fillers → dictionary → voice commands → tidy) → QuickPolish (rules) or list hints only.
import { applyRules, type DictEntry } from './textCleaner';
import * as QuickPolish from './quickPolish';
import * as SmartLists from './smartLists';

export interface PipelineOptions {
  removeFillers: boolean;
  voiceCommands: boolean;
  dictionary: readonly DictEntry[];
  polish: boolean;
  target?: SmartLists.Target;
}

export function processTranscript(raw: string, o: PipelineOptions): string {
  const text = raw.trim();
  if (!text) return '';
  const cleaned = applyRules(text, o);
  if (!cleaned) return '';
  const target = o.target ?? 'plain';
  if (o.polish) return QuickPolish.apply(cleaned, target).text;
  // polish off: only an explicitly spoken "als Liste" / "keine Liste" applies
  return SmartLists.pass(cleaned, target, false).text;
}

export const wordCount = (s: string) => s.split(/\s+/).filter((w) => /[\p{L}\p{N}]/u.test(w)).length;
