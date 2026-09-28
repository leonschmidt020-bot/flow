// Offscreen render check: draws pill + hub states into PNGs without showing any window.
import { hardExit } from './hardExit';
import { app, BrowserWindow } from 'electron';
import { mkdirSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { paths } from './paths';
import { t } from '../shared/i18n';
import { detect, structure } from '../agentPrompt/core';
import { FALLBACK_DE, LONG_DE1, SAMPLE_ORIGINAL_DE, SAMPLE_PROMPT_DE, SAMPLE_PROMPT_EN, VSC } from '../agentPrompt/testSet';
import { phaseView } from './agentPrompt';
import type { APRecord } from '../agentPrompt/store';
import type { APPhase } from '../agentPrompt/flow';

const wins = new Map<string, BrowserWindow>();
async function shot(file: string, url: string, w: number, h: number, waitMs: number) {
  // one offscreen window per size, reused (destroying offscreen windows between shots aborts the next load)
  const key = `${w}x${h}`;
  let win = wins.get(key);
  if (!win) {
    win = new BrowserWindow({
      width: w, height: h, show: false, frame: false, backgroundColor: '#0b0c0f',
      webPreferences: { offscreen: true, contextIsolation: true, sandbox: true },
    });
    win.webContents.setFrameRate(30);
    wins.set(key, win);
  }
  await win.loadURL(url);
  await new Promise((r) => setTimeout(r, waitMs));
  const img = await win.webContents.capturePage();
  writeFileSync(file, img.toPNG());
}

export async function runRenderCheck(outDir: string) {
  if (process.platform === 'darwin') app.dock?.hide();
  mkdirSync(outDir, { recursive: true });
  const pill = (qs: string) => `file://${paths.renderer('pill', 'pill.html')}?render=1&${qs}`;
  const hub = (qs: string) => `file://${paths.renderer('hub', 'hub.html')}?render=1&${qs}`;
  const hl = (qs: string) => `file://${paths.renderer('highlight', 'highlight.html')}?render=1&${qs}`;
  const card = (c: object) => encodeURIComponent(JSON.stringify({ id: 1, timeoutMs: 20000, ...c }));
  const deCard = { title: t('de', 'learnTitle'), save: t('de', 'learnSave'), no: t('de', 'learnNo') };
  const enCard = { title: t('en', 'learnTitle'), save: t('en', 'learnSave'), no: t('en', 'learnNo') };
  // Agent-Prompt card: every state (pill window at its large size while the card is up)
  const now = Date.now();
  const rec = (prompt: string, original: string, source = 'claude/sonnet/low', note = '', buildMs = 11_400): APRecord => ({
    id: 'r', created: new Date(now).toISOString(), prompt, original, appName: 'Visual Studio Code', windowTitle: '', source, note, trigger: 'zuruf', buildMs,
  });
  const apv = (p: APPhase, claude = true) => encodeURIComponent(JSON.stringify(phaseView(p, claude)));
  const det = detect({ text: LONG_DE1, duration: 42, exe: VSC, title: 'SettingsPanel.tsx - admin-dashboard' });
  const partial = SAMPLE_PROMPT_DE.slice(0, 420);
  const done = rec(SAMPLE_PROMPT_DE, SAMPLE_ORIGINAL_DE);
  const rules = rec(structure(FALLBACK_DE), FALLBACK_DE, 'regeln', 'Zeitlimit (45 s)', 45_100);
  const noCli = rec(structure(FALLBACK_DE), FALLBACK_DE, 'regeln', 'Claude-CLI fehlt', 40);
  const en = rec(SAMPLE_PROMPT_EN, 'Agent prompt: add retry logic to the upload client, three attempts with backoff, keep the API the same and make sure tests pass.', 'claude/sonnet/low', '', 7_900);
  const AW = 1100, AH = 580;
  const apJobs: [string, string, number, number, number][] = [
    ['ap_1_vorschlag.png', pill('mode=idle&ap=' + apv({ kind: 'offer', detection: det })), AW, AH, 900],
    ['ap_2a_baut_start.png', pill('mode=idle&apbusy=1&apsecs=2&ap=' + apv({ kind: 'building', partial: '', words: 118, started: now })), AW, AH, 900],
    ['ap_2b_baut_live.png', pill('mode=idle&apbusy=1&apsecs=7&ap=' + apv({ kind: 'building', partial, words: 118, started: now })), AW, AH, 900],
    ['ap_3a_fertig.png', pill('mode=idle&apillu=illu_prompt_fertig&ap=' + apv({ kind: 'done', record: done })), AW, AH, 900],
    ['ap_3b_fertig_hover.png', pill('mode=idle&aphover=1&apillu=illu_prompt_fertig_2&ap=' + apv({ kind: 'done', record: done })), AW, AH, 900],
    ['ap_3c_fertig_original.png', pill('mode=idle&aporig=1&apillu=illu_prompt_fertig_3&ap=' + apv({ kind: 'done', record: done })), AW, AH, 900],
    ['ap_3d_fertig_kurz_en.png', pill('mode=idle&lang=en&apillu=illu_prompt_fertig_4&ap=' + apv({ kind: 'done', record: en })), AW, AH, 900],
    ['ap_3e_fertig_regeln.png', pill('mode=idle&ap=' + apv({ kind: 'done', record: rules })), AW, AH, 900],
    ['ap_4a_abgebrochen.png', pill('mode=idle&ap=' + apv({ kind: 'stopped', stop: 'cancelled', reason: 'Abgebrochen', original: SAMPLE_ORIGINAL_DE })), AW, AH, 900],
    ['ap_4b_fehlgeschlagen.png', pill('mode=idle&ap=' + apv({ kind: 'stopped', stop: 'failed', reason: 'Claude nicht erreichbar', original: SAMPLE_ORIGINAL_DE })), AW, AH, 900],
    ['ap_4c_fehlgeschlagen_en.png', pill('mode=idle&lang=en&ap=' + apv({ kind: 'stopped', stop: 'failed', reason: 'Zeitlimit (45 s)', original: SAMPLE_ORIGINAL_DE })), AW, AH, 900],
    ['ap_7a_ohne_claude_baut.png', pill('mode=idle&apbusy=1&apsecs=0&ap=' + apv({ kind: 'building', partial: '', words: 74, started: now }, false)), AW, AH, 900],
    ['ap_7b_ohne_claude_fertig.png', pill('mode=idle&ap=' + apv({ kind: 'done', record: noCli }, false)), AW, AH, 900],
    ['ap_8a_klein_ueber_pille.png', pill('mode=idle&apillu=illu_prompt_fertig&ap=' + apv({ kind: 'done', record: done })), 760, AH, 900],
    ['ap_8b_mit_toast.png', pill('mode=idle&toast=' + encodeURIComponent('Prompt liegt in der Zwischenablage') + '&ap=' + apv({ kind: 'offer', detection: det })), AW, AH, 900],
    ['ap_8c_vorrang_meeting.png', pill('mode=idle&mcard=' + encodeURIComponent('Zoom erkannt|Meeting aufnehmen?|Aufnehmen|Nicht jetzt') + '&ap=' + apv({ kind: 'offer', detection: det })), AW, AH, 900],
    ['ap_8d_vorrang_vor_lerner.png', pill('mode=idle&ap=' + apv({ kind: 'offer', detection: det }) + '&card=' + card({ ...deCard, text: t('de', 'learnText', { old: 'Klot', new: 'Claude' }), options: ['Claude'] })), AW, AH, 900],
    ['ap_8e_diktat_laeuft.png', pill('mode=recording&ap=' + apv({ kind: 'building', partial, words: 118, started: now })), AW, AH, 900],
    ['hub_prompts.png', hub('page=prompts&state=ready'), 1080, 740, 1000],
    ['hub_prompts_original.png', hub('page=prompts&state=ready&orig=1'), 1080, 740, 1000],
    ['hub_prompts_regeln_en.png', hub('page=prompts&state=ready&lang=en&select=p3'), 1080, 740, 1000],
    ['hub_prompts_empty.png', hub('page=prompts&state=ready&pstate=empty'), 1080, 740, 1000],
    ['hub_prompts_narrow.png', hub('page=prompts&state=ready'), 820, 560, 1000],
    ['hub_settings_agentprompts.png', hub('page=settings&state=ready&scroll=1250'), 1080, 740, 900],
    ['hub_settings_agentprompts_noclaude_en.png', hub('page=settings&state=noclaude&lang=en&scroll=1250'), 1080, 740, 900],
  ];
  const only = process.env.FLOW_RENDER_ONLY;
  const jobs: [string, string, number, number, number][] = only === 'ap' ? apJobs : [...apJobs, ...([
    ['pill_idle.png', pill('mode=idle'), 460, 230, 600],
    ['pill_idle_light.png', pill('mode=idle&bg=light'), 460, 230, 600],
    ['pill_recording.png', pill('mode=recording'), 460, 230, 700],
    ['pill_handsfree.png', pill('mode=handsfree'), 460, 230, 700],
    ['pill_transcribing.png', pill('mode=transcribing'), 460, 230, 700],
    ['pill_loading.png', pill('mode=loading&p=0.42'), 460, 230, 600],
    ['pill_toast.png', pill('mode=idle&toast=' + encodeURIComponent('In der Zwischenablage') + '&kind=success'), 460, 230, 600],
    ['pill_toast_error.png', pill('mode=recording&toast=' + encodeURIComponent('Mikrofon nicht verfügbar') + '&kind=error'), 460, 230, 600],
    ['pill_card.png', pill('mode=idle&card=' + card({ ...deCard, text: t('de', 'learnText', { old: 'Klot', new: 'Claude' }), options: ['Claude'] })), 460, 230, 700],
    ['pill_card_options.png', pill('mode=idle&card=' + card({ ...deCard, text: t('de', 'learnTextChoose', { old: 'auffixen' }), options: ['auch fixen', 'auch', 'auf fixen'] })), 460, 230, 700],
    ['pill_card_en_toast.png', pill('mode=idle&toast=' + encodeURIComponent(t('en', 'mtToastNormal')) + '&card=' + card({ ...enCard, text: t('en', 'learnText', { old: 'Lena Maier', new: 'Lena Mayer' }), options: ['Lena Mayer'] })), 460, 230, 700],
    ['highlight.png', hl('label=' + encodeURIComponent(t('de', 'mtLabel'))), 720, 440, 500],
    ['highlight_en_small.png', hl('lang=en&label=' + encodeURIComponent(t('en', 'mtLabel'))), 360, 220, 500],
    ['hub_history.png', hub('page=history&state=ready'), 1080, 740, 900],
    ['hub_history_download.png', hub('page=history&state=download'), 1080, 740, 900],
    ['hub_history_first_run.png', hub('page=history&state=missing'), 1080, 740, 900],
    ['hub_dictionary.png', hub('page=dictionary&state=ready'), 1080, 740, 900],
    ['hub_settings.png', hub('page=settings&state=ready'), 1080, 740, 900],
    ['hub_settings_bottom.png', hub('page=settings&state=ready&scroll=2000'), 1080, 740, 900],
    ['hub_settings_en.png', hub('page=settings&state=ready&lang=en&scroll=520'), 1080, 740, 900],
    ['hub_settings_insert.png', hub('page=settings&state=ready&scroll=900'), 1080, 740, 900],
    ['hub_settings_insert_en.png', hub('page=settings&state=mousetarget&lang=en&scroll=900'), 1080, 740, 900],
    ['hub_settings_micerror.png', hub('page=settings&state=micerror'), 1080, 740, 900],
    ['hub_clipvault.png', hub('page=clipvault&state=ready'), 1080, 740, 1200],
    ['hub_history_narrow.png', hub('page=history&state=ready'), 820, 560, 900],
    // notetaker
    ['pill_meeting.png', pill('mode=idle&meeting=723'), 460, 230, 700],
    ['pill_meeting_card.png', pill('mode=idle&mcard=' + encodeURIComponent('Microsoft Teams erkannt|Meeting aufnehmen?|Aufnehmen|Nicht jetzt')), 460, 230, 700],
    ['pill_meeting_toast.png', pill('mode=idle&meeting=1&toast=' + encodeURIComponent('Prompt kopiert ✓') + '&kind=success'), 460, 230, 700],
    ['pill_import.png', pill('mode=idle&task=' + encodeURIComponent('Audiodatei · 62 %') + '&p=0.62'), 460, 230, 600],
    ['pill_cards_priority.png', pill('mode=idle&mcard=' + encodeURIComponent('Zoom erkannt|Meeting aufnehmen?|Aufnehmen|Nicht jetzt') + '&card=' + card({ ...deCard, text: t('de', 'learnText', { old: 'Klot', new: 'Claude' }), options: ['Claude'] })), 460, 230, 700],
    ['pill_meeting_learner.png', pill('mode=idle&meeting=65&card=' + card({ ...deCard, text: t('de', 'learnText', { old: 'Klot', new: 'Claude' }), options: ['Claude'] })), 460, 230, 700],
    ['pill_drop.png', pill('mode=idle&drag=1'), 460, 230, 600],
    ['hub_notetaker.png', hub('page=notetaker&state=ready&mstate=ready'), 1080, 740, 1100],
    ['hub_notetaker_recording.png', hub('page=notetaker&state=ready&mstate=recording'), 1080, 740, 1100],
    ['hub_notetaker_processing.png', hub('page=notetaker&state=ready&mstate=ready&select=m2'), 1080, 740, 1100],
    ['hub_notetaker_empty.png', hub('page=notetaker&state=ready&mstate=empty'), 1080, 740, 1100],
    ['hub_notetaker_en.png', hub('page=notetaker&state=ready&mstate=ready&lang=en&select=m3'), 1080, 740, 1100],
    ['hub_notetaker_settings.png', hub('page=notetaker&state=ready&mstate=ready&scroll=2000'), 1080, 740, 1100],
    ['hub_notetaker_narrow.png', hub('page=notetaker&state=ready&mstate=ready'), 820, 560, 1100],
  ] as [string, string, number, number, number][])];
  for (const [f, url, w, h, ms] of jobs) {
    await shot(path.join(outDir, f), url, w, h, ms);
    console.log('rendered', f);
  }
  for (const w of wins.values()) w.destroy();
  hardExit(0);
}
