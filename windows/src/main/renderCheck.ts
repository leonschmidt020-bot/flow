// Offscreen render check: draws pill + hub states into PNGs without showing any window.
import { hardExit } from './hardExit';
import { app, BrowserWindow } from 'electron';
import { mkdirSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { paths } from './paths';

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
  const jobs: [string, string, number, number, number][] = [
    ['pill_idle.png', pill('mode=idle'), 460, 150, 600],
    ['pill_idle_light.png', pill('mode=idle&bg=light'), 460, 150, 600],
    ['pill_recording.png', pill('mode=recording'), 460, 150, 700],
    ['pill_handsfree.png', pill('mode=handsfree'), 460, 150, 700],
    ['pill_transcribing.png', pill('mode=transcribing'), 460, 150, 700],
    ['pill_loading.png', pill('mode=loading&p=0.42'), 460, 150, 600],
    ['pill_toast.png', pill('mode=idle&toast=' + encodeURIComponent('In der Zwischenablage') + '&kind=success'), 460, 150, 600],
    ['pill_toast_error.png', pill('mode=recording&toast=' + encodeURIComponent('Mikrofon nicht verfügbar') + '&kind=error'), 460, 150, 600],
    ['hub_history.png', hub('page=history&state=ready'), 1080, 740, 900],
    ['hub_history_download.png', hub('page=history&state=download'), 1080, 740, 900],
    ['hub_history_first_run.png', hub('page=history&state=missing'), 1080, 740, 900],
    ['hub_dictionary.png', hub('page=dictionary&state=ready'), 1080, 740, 900],
    ['hub_settings.png', hub('page=settings&state=ready'), 1080, 740, 900],
    ['hub_settings_bottom.png', hub('page=settings&state=ready&scroll=2000'), 1080, 740, 900],
    ['hub_settings_en.png', hub('page=settings&state=ready&lang=en&scroll=520'), 1080, 740, 900],
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
