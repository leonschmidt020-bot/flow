// Prüft den FERTIG gepackten Windows-Build (release/win-unpacked): lassen sich die nativen Module laden?
// 05.10.2026: Der Installer schloss koffi/src aus → beim Freund „Cannot find module './src/koffi/index.cjs'“,
// Einfügen ging nicht. Läuft in der CI mit der gepackten Flow.exe (ELECTRON_RUN_AS_NODE=1, also Electrons Node-ABI).
const path = require('path');
// Über app.asar laden wie die echte App (Electron leitet .node-Dateien selbst nach app.asar.unpacked um);
// direkt aus app.asar.unpacked fehlen reine JS-Abhängigkeiten wie node-gyp-build.
const root = path.resolve(__dirname, '..', 'release', 'win-unpacked', 'resources', 'app.asar', 'node_modules');
let bad = 0;
function check(name, fn) {
  try { fn(require(path.join(root, name))); console.log('ok  ', name); }
  catch (e) { bad++; console.error('FAIL', name, '–', e && e.message); }
}
check('koffi', (k) => {
  const user32 = k.load('user32.dll');
  const f = user32.func('void * __stdcall GetForegroundWindow()');
  f();
});
check('uiohook-napi', (u) => { if (!u.uIOhook) throw new Error('uIOhook fehlt'); });
check('sherpa-onnx-node', (s) => { if (!s.OfflineRecognizer) throw new Error('OfflineRecognizer fehlt'); });
if (bad) { console.error(`${bad} natives Modul(e) im Installer kaputt`); process.exit(1); }
console.log('Gepackter Build: alle nativen Module laden');
