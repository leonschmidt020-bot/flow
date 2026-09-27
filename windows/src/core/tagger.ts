// Small lexicon + morphology part-of-speech tagger (DE/EN).
// The Mac app uses Apple's NLTagger; Windows has no equivalent, so this approximates it well enough
// for the rule-based list/correction logic (measured against the Mac outputs in test/fixtures/mac-golden.json).
import { isUpper, isLetter, isNumber } from './chars';

export type Tag =
  | 'noun' | 'personalName' | 'placeName' | 'organizationName' | 'verb' | 'adjective' | 'adverb' | 'pronoun'
  | 'determiner' | 'preposition' | 'conjunction' | 'number' | 'particle' | 'interjection' | 'otherWord';
export type Lang = 'de' | 'en';

export interface Tagged { tag: Tag | null; lemma: string }

const set = (s: string) => new Set(s.split(/\s+/).filter(Boolean));

// ── German ──────────────────────────────────────────────────────────────────
const DE_DET = set(`der die das den dem des ein eine einen einem einer eines kein keine keinen keinem keiner keines
  mein meine meinen meinem meiner meines dein deine deinen deinem deiner sein seine seinen seinem seiner ihr ihre ihren ihrem ihrer
  unser unsere unseren unserem unserer euer eure euren eurem eurer dieser diese dieses diesen diesem jeder jede jedes jeden jedem
  alle allen aller welche welcher welches manche mancher einige einigen mehrere beide beiden viele vielen wenige`);
const DE_PRON = set(`ich du er sie es wir ihr mich dich sich uns euch mir dir ihm ihn ihnen man jemand jemanden niemand etwas nichts
  alles was wer wen wem mein dies das`);
const DE_PREP = set(`an auf aus bei bis durch für gegen hinter in mit nach neben ohne seit über um unter vor während wegen zu zum zur
  zwischen vom im am beim ins ans aufs fürs übers ums gegenüber trotz statt außer innerhalb außerhalb entlang ab per pro je via laut`);
const DE_CONJ = set(`und oder aber denn sondern dass weil wenn ob als wie damit obwohl falls sowie bevor nachdem sobald während sodass doch`);
const DE_ADV = set(`noch auch mal nur schon sehr gern gerne dann jetzt heute morgen übermorgen gestern hier dort da immer nie oft bald gleich
  später vielleicht wirklich eigentlich lieber eher besser also zuerst danach zuletzt schließlich unbedingt bitte kurz schnell
  nachher vorher erst erstmal zunächst anschließend endlich sofort dringend genau ganz fast wieder zusammen allein leider
  natürlich trotzdem deshalb dafür dabei damit darauf davon dazu hin her weg los zurück vorbei raus rein nicht nie niemals ja
  nein vorhin abends morgens mittags heute`);
const DE_PART = set(`zu nicht`);
const DE_ADJ = set(`gut gute guten guter gutes groß große großen großer klein kleine kleinen neu neue neuen neuer alt alte alten schön schöne
  frisch frische frischen rot rote grün grüne blau blaue weiß weiße schwarz schwarze warm kalt heiß lang lange kurz kurze wichtig wichtige
  richtig falsch fertig bereit leer voll billig teuer lecker gesund müde krank froh traurig einfach schwer leicht spät früh letzte letzten
  nächste nächsten erste ersten zweite dritte viel wenig mehr weniger ganze ganzen halbe halben eigene eigenen andere anderen verschiedene
  bio vegan glutenfrei laktosefrei`);
const DE_AUX_VERBS = set(`bin bist ist sind seid war waren warst wart sein gewesen habe hab hast hat haben habt hatte hatten hattest gehabt
  werde wirst wird werden werdet wurde wurden kann kannst können könnt konnte konnten könnte könnten muss musst müssen müsst musste mussten
  müsste soll sollst sollen sollt sollte sollten will willst wollen wollt wollte wollten möchte möchtest möchten mag magst mögen darf darfst
  dürfen durfte gibt gab`);
const DE_VERB_INF = set(`machen kaufen holen bringen nehmen gehen kommen fahren laufen rufen anrufen schreiben lesen senden schicken
  bestellen buchen packen einpacken mitnehmen mitbringen besorgen einkaufen brauchen benötigen treffen sehen schauen sagen fragen
  antworten zahlen bezahlen überweisen kochen backen waschen putzen aufräumen spülen gießen füttern lernen üben arbeiten spielen
  schlafen essen trinken denken vergessen erinnern suchen finden prüfen checken testen starten installieren laden drucken
  unterschreiben geben zeigen helfen besuchen reservieren kündigen verschieben beantworten erledigen notieren planen organisieren
  informieren kontaktieren melden stellen legen setzen tragen löschen speichern öffnen schließen drehen lüften sperren schalten
  klären stoppen gucken mieten wechseln tauschen entsorgen abonnieren erstellen leiten ziehen hören aktualisieren updaten pushen
  committen bauen fixen werfen bestätigen bereiten vorbereiten sortieren markieren kopieren abholen abgeben absagen zusagen einladen
  mitteilen reden sprechen erzählen erklären verstehen wissen glauben hoffen lieben mögen warten bleiben liegen stehen sitzen
  wohnen leben sterben beginnen anfangen aufhören enden öffnen fliegen reisen feiern tanzen singen beten danken`);
const DE_VERB_FORMS: Record<string, string> = {
  geh: 'gehen', gehe: 'gehen', gehst: 'gehen', geht: 'gehen', ging: 'gehen', gingen: 'gehen', gegangen: 'gehen',
  komm: 'kommen', komme: 'kommen', kommst: 'kommen', kommt: 'kommen', kam: 'kommen', kamen: 'kommen',
  nimm: 'nehmen', nehme: 'nehmen', nimmst: 'nehmen', nimmt: 'nehmen', nehmt: 'nehmen', nahm: 'nehmen',
  bring: 'bringen', bringe: 'bringen', bringst: 'bringen', bringt: 'bringen', brachte: 'bringen', gebracht: 'bringen',
  fahre: 'fahren', fährst: 'fahren', fährt: 'fahren', fuhr: 'fahren', fuhren: 'fahren', lauf: 'laufen', laufe: 'laufen', läuft: 'laufen', lief: 'laufen',
  sag: 'sagen', sage: 'sagen', sagst: 'sagen', sagt: 'sagen', sagte: 'sagen', frag: 'fragen', frage: 'fragen', fragt: 'fragen', fragte: 'fragen',
  sieh: 'sehen', sehe: 'sehen', siehst: 'sehen', sieht: 'sehen', sah: 'sehen', sahen: 'sehen', gib: 'geben', gebe: 'geben', gibst: 'geben',
  lies: 'lesen', lese: 'lesen', liest: 'lesen', las: 'lesen', iss: 'essen', esse: 'essen', isst: 'essen', aß: 'essen', aßen: 'essen',
  hilf: 'helfen', helfe: 'helfen', hilft: 'helfen', wirf: 'werfen', wirft: 'werfen', triff: 'treffen', treffe: 'treffen', trifft: 'treffen',
  vergiss: 'vergessen', vergesse: 'vergessen', vergisst: 'vergessen', dachte: 'denken', dachten: 'denken', fand: 'finden', stand: 'stehen',
  saß: 'sitzen', schrieb: 'schreiben', rief: 'rufen', machte: 'machen', machten: 'machen', brauche: 'brauchen', brauchst: 'brauchen',
  braucht: 'brauchen', benötige: 'benötigen', weiß: 'wissen', weißt: 'wissen', tu: 'tun', tue: 'tun', tust: 'tun', tut: 'tun', tun: 'tun',
  ruf: 'rufen', rufe: 'rufen', schick: 'schicken', schicke: 'schicken', schreib: 'schreiben', schreibe: 'schreiben', mach: 'machen', mache: 'machen',
  kauf: 'kaufen', kaufe: 'kaufen', hol: 'holen', hole: 'holen', pack: 'packen', packe: 'packen',
};
// Words that are verbs even when capitalised at the sentence start (NLTagger knows these)
const DE_VERB_AT_START = set(`kannst könntest hast bist willst möchtest sollen sollten soll können kann hat ist gibt habt seid sind
  muss musst müssen darf dürfen wird werden hab habe denk vergiss bitte`);

// ── English ─────────────────────────────────────────────────────────────────
const EN_DET = set(`the a an this that these those some any each every no my your his her its our their another either neither
  all both few several many much more most other such what which whose`);
const EN_PRON = set(`i you he she it we they me him us them myself yourself himself herself itself ourselves themselves
  something anything everything nothing someone anyone everyone nobody somebody anybody everybody one mine yours hers ours theirs who whom`);
const EN_PREP = set(`in on at to for with from by of about into onto over under after before between through during without near
  across against along among around behind below beneath beside beyond despite inside outside since toward towards upon via within per like`);
const EN_CONJ = set(`and or but so because if although though since unless while whereas nor yet whether than`);
const EN_ADV = set(`then also just still really now today tomorrow tonight yesterday later soon quickly please very too again already
  always never often sometimes maybe perhaps here there where when why how not actually finally first next last lastly afterwards
  instead rather even only almost back away out off up down together`);
const EN_ADJ = set(`good new old big small large little great long short high low right wrong ready fresh cold hot warm clean dirty
  important quick slow easy hard free full empty cheap expensive nice fine sure happy sad tired sick red green blue white black
  paper dish trash organic whole last next first second third final main own same different quiet calm loud busy safe
  soft strong weak dark bright light heavy fast`);
const EN_VERBS = set(`be is are am was were been being do does did done have has had having can could will would shall should may might must
  need want like love go come get got buy bought make made take took give gave call book email text check fix send sent update finish
  water feed lock answer prepare clean pay paid order schedule review write wrote read plan pick drop wash cancel renew submit file print
  sign return reply test deploy push merge ship set start stop open close restart install remove delete add invite ask tell told remind
  visit walk clear empty fill charge upload save find found change run ran create move copy paste try use turn click notify download post
  share record edit finalize draft confirm follow meet met bring brought grab say said see saw know knew think thought look feel felt
  keep kept let put leave left help show hear play work live believe hold stand understand eat ate drink sleep pack sign grab include
  includes matter matters goes went pick hire hiring think`);
const EN_NOUNISH_VERBS = set(`book water email text call order file print plan test answer review record draft share post charge back
  drop walk run show play work look help change turn use`);
const EN_IRREG: Record<string, string> = {
  was: 'be', were: 'be', is: 'be', are: 'be', am: 'be', been: 'be', went: 'go', goes: 'go', gone: 'go', got: 'get', gotten: 'get',
  took: 'take', taken: 'take', made: 'make', saw: 'see', seen: 'see', ate: 'eat', eaten: 'eat', said: 'say', drove: 'drive', driven: 'drive',
  left: 'leave', thought: 'think', found: 'find', bought: 'buy', brought: 'bring', felt: 'feel', met: 'meet', ran: 'run', sat: 'sit',
  told: 'tell', began: 'begin', began_: 'begin', had: 'have', has: 'have', did: 'do', does: 'do', done: 'do', came: 'come', gave: 'give',
  wrote: 'write', written: 'write', sent: 'send', paid: 'pay', knew: 'know', kept: 'keep', held: 'hold', stood: 'stand', children: 'child',
  people: 'person', men: 'man', women: 'woman', feet: 'foot', teeth: 'tooth', mice: 'mouse',
};

const FIRST_NAMES = set(`anna tom lisa peter paul maria marie max moritz jonas lukas leon finn felix paula emma mia hannah lena lea sophie
  julia laura sarah sara mark marc michael thomas andreas stefan markus jan tim tobias daniel david jakob jacob johannes simon
  jens kai lars nina eva julian noah ben elias luis louis emily olivia jack james john mary robert william oliver charlie
  harry george sophia isabella ava amelia mike chris alex sam kate anne jane joe oma opa mama papa`);
const PLACES = set(`berlin hamburg münchen köln frankfurt stuttgart düsseldorf leipzig dresden bielefeld detmold ingolstadt london paris
  rom wien zürich amsterdam madrid new york orlando deutschland germany austria england france spain italy europa europe amerika america`);
const ORGS = set(`rewe aldi lidl edeka netto penny kaufland dm rossmann amazon google apple microsoft ikea`);

// ── language guess (SmartLists.language) ────────────────────────────────────
const DE_COMMON = set(`ich und der die das ist nicht noch ein eine einen mit für auf wir du zu den dem muss will brauche dann zuerst danach
  auch mal bitte oder sind gehe morgen heute`);
const EN_COMMON = set(`i and the is not a an to for with we you need then first also please or are of my our have buy some get tomorrow today`);
const DE_EXTRA = set(`es sie er im am vom zum zur war hat haben habe hab sich wie was wenn aber nur schon kann können soll sollte wird
  werden gibt uns euch mir dir mein meine dein deine unser unsere diese dieser dieses kein keine sehr gut viel wo warum wann`);
const EN_EXTRA = set(`it he she they was were has had be been will would can could should this that these those what when where why
  how all just so at on in from by about your their his her its there here very good much many`);

export function language(s: string): Lang {
  let d = 0, e = 0;
  const words = s.toLowerCase().split(/[^\p{L}]+/u).filter(Boolean);
  for (const x of words) {
    if (DE_COMMON.has(x)) d++;
    if (EN_COMMON.has(x)) e++;
  }
  if (d !== e) return d > e ? 'de' : 'en';
  if (/[äöüß]/u.test(s)) return 'de';
  // stand-in for NLLanguageRecognizer
  let d2 = 0, e2 = 0;
  for (const x of words) {
    if (DE_EXTRA.has(x)) d2++;
    if (EN_EXTRA.has(x)) e2++;
    if (/(ung|keit|heit|schaft|chen|lich|isch|sch)$/u.test(x)) d2 += 0.5;
    if (/(tion|ing|ly|ed|th|ness)$/u.test(x)) e2 += 0.5;
  }
  return e2 > d2 ? 'en' : 'de';
}

const bareRe = /^[,.;:!?…–—"'„“”»«()]+|[,.;:!?…–—"'„“”»«()]+$/gu;
const bareOf = (w: string) => w.replace(bareRe, '');

function enLemma(w: string, asVerb: boolean): string {
  if (EN_IRREG[w]) return EN_IRREG[w]!;
  const L = w.length;
  if (asVerb) {
    if (w.endsWith('ing') && L > 5) {
      let st = w.slice(0, -3);
      if (EN_VERBS.has(st)) return st;
      if (EN_VERBS.has(st + 'e')) return st + 'e';
      if (st.length > 2 && st[st.length - 1] === st[st.length - 2]) st = st.slice(0, -1);
      return st;
    }
    if (w.endsWith('ed') && L > 4) {
      const st = w.slice(0, -2);
      if (EN_VERBS.has(st)) return st;
      if (EN_VERBS.has(st + 'e') || w.endsWith('ied')) return w.endsWith('ied') ? w.slice(0, -3) + 'y' : st + 'e';
      if (st.length > 2 && st[st.length - 1] === st[st.length - 2]) return st.slice(0, -1);
      return st;
    }
  }
  if (w.endsWith('ies') && L > 4) return w.slice(0, -3) + 'y';
  if (/(ss|sh|ch|x|z|o)es$/u.test(w) && L > 4) return w.slice(0, -2);
  if (w.endsWith('s') && !w.endsWith('ss') && !w.endsWith('us') && !w.endsWith('is') && L > 3) return w.slice(0, -1);
  return w;
}

function deVerbLemma(w: string): string {
  if (DE_VERB_FORMS[w]) return DE_VERB_FORMS[w]!;
  if (DE_VERB_INF.has(w) || /(en|ern|eln)$/u.test(w)) return w;
  for (const [suf, add] of [['st', 'en'], ['t', 'en'], ['e', 'n'], ['', 'en']] as const) {
    if (suf && !w.endsWith(suf)) continue;
    const stem = suf ? w.slice(0, -suf.length) : w;
    if (DE_VERB_INF.has(stem + add)) return stem + add;
    if (add === 'n' && DE_VERB_INF.has(stem + 'en')) return stem + 'en';
  }
  return w;
}

const deAdjSuffix = /(ig|lich|isch|bar|sam|los|haft|voll|ige|igen|iger|liche|lichen|licher|ische|ischen)$/u;
const enAdjSuffix = /(ful|ous|ive|able|ible|less|ish|ic|ical|ary)$/u;

/**
 * Tag space-separated tokens. `tokens` are the raw words (with punctuation), as SmartLists/QuickPolish split them.
 */
export function tagTokens(tokens: readonly string[], lang: Lang): Tagged[] {
  const bares = tokens.map(bareOf);
  const lowers = bares.map((b) => b.toLowerCase());
  const out: Tagged[] = [];
  const sentenceStart = (i: number) => {
    if (i === 0) return true;
    const p = tokens[i - 1]!;
    const c = p[p.length - 1];
    return c !== undefined && '.!?:'.includes(c);
  };
  for (let i = 0; i < tokens.length; i++) {
    const b = bares[i]!;
    const w = lowers[i]!;
    const hasAlnum = Array.from(tokens[i]!).some((c) => isLetter(c) || isNumber(c));
    if (!hasAlnum || !b) { out.push({ tag: null, lemma: w }); continue; }
    if (/^\p{N}+([.,]\p{N}+)?$/u.test(b)) { out.push({ tag: 'number', lemma: w }); continue; }
    const cap = isUpper(b[0]);
    const start = sentenceStart(i);
    const prev = i > 0 ? lowers[i - 1]! : '';
    const next = i + 1 < tokens.length ? bares[i + 1]! : '';
    const nextCapNoun = !!next && isUpper(next[0]) && lang === 'de';
    let tag: Tag;
    let lemma = w;
    // "iPhone-Ladekabel", "eBay" – inner capital / capitalised compound tail = name-like noun
    const innerCap = Array.from(b).slice(1).some((ch) => isUpper(ch)) && !cap;
    if (lang === 'de') {
      if (innerCap) tag = 'noun';
      else if (cap && !start) {
        if (FIRST_NAMES.has(w)) tag = 'personalName';
        else if (PLACES.has(w)) tag = 'placeName';
        else if (ORGS.has(w)) tag = 'organizationName';
        else if (w === 'sie' || w === 'ihr' || w === 'ihnen') tag = 'pronoun';
        else tag = 'noun';
      } else if (DE_DET.has(w)) {
        tag = (w === 'das' || w === 'die' || w === 'der') && !next ? 'pronoun' : 'determiner';
        if (w === 'ihr' && (start || !nextCapNoun)) tag = 'pronoun';
      } else if (DE_PRON.has(w)) tag = 'pronoun';
      else if (DE_PREP.has(w)) tag = w === 'zu' && i + 1 < tokens.length && /(en|ern|eln)$/u.test(lowers[i + 1]!) && !isUpper(bares[i + 1]![0]) ? 'particle' : 'preposition';
      else if (DE_CONJ.has(w)) tag = 'conjunction';
      else if (DE_AUX_VERBS.has(w)) { tag = 'verb'; lemma = deVerbLemma(w); }
      else if (DE_ADV.has(w)) tag = 'adverb';
      else if (DE_PART.has(w)) tag = 'particle';
      else if (cap && start) {
        if (FIRST_NAMES.has(w)) tag = 'personalName';
        else if (ORGS.has(w)) tag = 'organizationName';
        else if (DE_VERB_AT_START.has(w)) { tag = 'verb'; lemma = deVerbLemma(w); }
        else tag = 'noun';
      } else if (DE_ADJ.has(w) || deAdjSuffix.test(w)) tag = 'adjective';
      else if (nextCapNoun && /(e|en|er|es|em)$/u.test(w) && !DE_VERB_INF.has(w)) tag = 'adjective';
      else if (DE_VERB_FORMS[w] || DE_VERB_INF.has(w) || /(en|ern|eln|t|st|e)$/u.test(w) || /^ge.+(t|en)$/u.test(w)) { tag = 'verb'; lemma = deVerbLemma(w); }
      else { const lem = deVerbLemma(w); if (lem !== w) { tag = 'verb'; lemma = lem; } else tag = 'adverb'; }
    } else {
      if (cap && !start && w !== 'i') {
        if (FIRST_NAMES.has(w)) tag = 'personalName';
        else if (PLACES.has(w)) tag = 'placeName';
        else if (ORGS.has(w)) tag = 'organizationName';
        else tag = 'noun';
      } else if (EN_DET.has(w)) tag = 'determiner';
      else if (EN_PRON.has(w)) tag = 'pronoun';
      else if (w === 'to') tag = i + 1 < tokens.length && (EN_VERBS.has(lowers[i + 1]!)) ? 'particle' : 'preposition';
      else if (EN_PREP.has(w)) tag = 'preposition';
      else if (EN_CONJ.has(w)) tag = 'conjunction';
      else if (EN_ADV.has(w) && !(start && EN_VERBS.has(w))) tag = 'adverb';
      else {
        const afterDet = EN_DET.has(prev) || EN_ADJ.has(prev);
        const afterSubjOrTo = ['i', 'we', 'you', 'they', 'he', 'she', 'to', "i'll", "we'll", 'will', 'can', 'please', 'and', 'then', 'must', 'should', 'gotta', "don't", 'lets', "let's"].includes(prev);
        if (EN_ADJ.has(w) && !(start && EN_VERBS.has(w))) tag = 'adjective';
        else if (EN_VERBS.has(w) || EN_IRREG[w]) {
          if (afterDet) tag = 'noun';
          else if (start || afterSubjOrTo || !EN_NOUNISH_VERBS.has(w)) tag = 'verb';
          else tag = 'noun';
        } else if (/ly$/u.test(w) && w.length > 4) tag = 'adverb';
        else if (/(ing|ed)$/u.test(w) && w.length > 4 && !afterDet) tag = 'verb';
        else if (enAdjSuffix.test(w) && w.length > 5) tag = 'adjective';
        else if (/s$/u.test(w) && EN_VERBS.has(enLemma(w, false)) && !afterDet && ['it', 'he', 'she', 'that', 'this'].includes(prev)) tag = 'verb';
        else if (cap && start && FIRST_NAMES.has(w)) tag = 'personalName';
        else tag = 'noun';
      }
      lemma = enLemma(w, tag === 'verb');
      if (tag === 'verb' && EN_IRREG[w]) lemma = EN_IRREG[w]!;
    }
    out.push({ tag, lemma });
  }
  return out;
}

/** NLTagger .lexicalClass per space token, with QuickPolish's overrides (time words = adverb, number words = number) */
export function lexicalClasses(s: string, timeWords?: ReadonlySet<string>, numberWords?: ReadonlySet<string>): Tag[] {
  const toks = s.split(' ').filter(Boolean);
  const lang = language(s);
  const tagged = tagTokens(toks, lang);
  return toks.map((tk, i) => {
    let tag: Tag = tagged[i]!.tag ?? 'otherWord';
    if (tag === 'personalName' || tag === 'placeName' || tag === 'organizationName') tag = 'noun';
    const b = bareOf(tk).toLowerCase();
    if (timeWords?.has(b)) tag = 'adverb';
    if (numberWords?.has(b) || (b.length > 0 && /^\p{N}+$/u.test(b))) tag = 'number';
    return tag;
  });
}
