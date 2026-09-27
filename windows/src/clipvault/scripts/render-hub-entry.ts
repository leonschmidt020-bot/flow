// Render-check only: mounts the Hub page into a shadow root, like Flow's Hub does.
import { mount } from '../ui/index';
import type { ClipVaultUiApi } from '../contract';

const api = (window as unknown as { clipvault: ClipVaultUiApi }).clipvault;
const host = document.getElementById('hub')!;
mount(host.attachShadow({ mode: 'open' }), api);
