#!/usr/bin/env node
// Generates the synthetic ASR test set with macOS `say` (DE + EN) → test/fixtures/asr/*.wav (16 kHz mono PCM16).
// The WAVs are committed, so CI on Windows uses the very same audio. macOS only.
import { execFileSync } from 'node:child_process';
import { mkdirSync, writeFileSync, rmSync, existsSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

if (process.platform !== 'darwin') { console.error('make-tts-fixtures: needs macOS (say + afconvert)'); process.exit(1); }
const dir = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'test', 'fixtures', 'asr');
mkdirSync(dir, { recursive: true });

const set = [
  { id: 'de_meeting', lang: 'de', voice: 'Anna', text: 'Hallo zusammen, ich wollte kurz Bescheid geben, dass das Meeting morgen um zehn Uhr stattfindet.' },
  { id: 'de_praesentation', lang: 'de', voice: 'Reed (Deutsch (Deutschland))', text: 'Bitte schick mir bis Freitag die aktualisierte Präsentation und die Zahlen für das dritte Quartal.' },
  { id: 'de_park', lang: 'de', voice: 'Sandy (Deutsch (Deutschland))', text: 'Wir treffen uns am Samstag im Park und bringen Kuchen, Kaffee und ein paar Decken mit.' },
  { id: 'de_lang', lang: 'de', voice: 'Anna', text: 'Ich möchte euch heute kurz erzählen, wie unser Wochenende gelaufen ist. Am Freitagabend sind wir mit dem Zug nach Hamburg gefahren und haben dort Freunde besucht. Am Samstag waren wir auf dem Markt, danach im Museum und am Abend in einem kleinen Restaurant am Hafen. Das Wetter war zwar kühl, aber meistens sonnig. Am Sonntag sind wir früh aufgestanden, haben noch einen langen Spaziergang an der Elbe gemacht und sind dann am Nachmittag wieder nach Hause gefahren. Nächstes Jahr wollen wir das auf jeden Fall wiederholen.' },
  { id: 'en_review', lang: 'en', voice: 'Samantha', text: 'Hey team, just a quick reminder that the project review is scheduled for Thursday afternoon.' },
  { id: 'en_report', lang: 'en', voice: 'Reed (Englisch (USA))', text: 'Could you please send me the latest version of the report before the end of the day?' },
  { id: 'en_shopping', lang: 'en', voice: 'Samantha', text: 'I need to buy eggs, milk, bread and butter on my way home tonight.' },
  { id: 'en_long', lang: 'en', voice: 'Samantha', text: 'I wanted to give you a short update on the new website. Most of the pages are finished, and the design team has already reviewed the home page and the contact form. We still need to write the text for the about page and choose a few photos for the gallery. Next week we will test everything on phones and tablets, and if nothing major comes up, we can launch the site at the end of the month. Please let me know if you have any questions or ideas before then.' },
];

for (const s of set) {
  const aiff = path.join(dir, s.id + '.aiff');
  const wav = path.join(dir, s.id + '.wav');
  execFileSync('say', ['-v', s.voice, '-r', '185', '-o', aiff, s.text]);
  execFileSync('afconvert', ['-f', 'WAVE', '-d', 'LEI16@16000', '-c', '1', aiff, wav]);
  if (existsSync(aiff)) rmSync(aiff);
  console.log('✓', s.id);
}
writeFileSync(path.join(dir, 'manifest.json'), JSON.stringify({ generator: 'macOS say + afconvert (16 kHz mono PCM16)', items: set }, null, 1));
