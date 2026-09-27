// Entry of the quick panel window (bundled to dist/clipvault/ui/panel.js, IIFE). API comes from preload.ts.
import { ClipVaultView, type UiApi } from './app';

declare global {
  interface Window { clipvault?: UiApi & { material?: string } }
}

function start() {
  const api = window.clipvault;
  const host = document.getElementById('cv-root')!;
  if (!api) { host.textContent = 'ClipVault: preload missing'; return; }
  const root = host.attachShadow({ mode: 'open' });
  new ClipVaultView(root, api, 'panel', api.material ?? 'solid');
}

if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start); else start();
