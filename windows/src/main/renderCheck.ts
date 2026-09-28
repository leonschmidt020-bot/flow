// Offscreen render check: draws pill + hub states into PNGs without showing any window.
import { hardExit } from './hardExit';
import { app, BrowserWindow } from 'electron';
import { mkdirSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { paths } from './paths';
import { t } from '../shared/i18n';

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
  const jobs: [string, string, number, number, number][] = [
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
  ];
  for (const [f, url, w, h, ms] of jobs) {
    await shot(path.join(outDir, f), url, w, h, ms);
    console.log('rendered', f);
  }
  for (const w of wins.values()) w.destroy();
  hardExit(0);
}
