// Hub page: Flow mounts this into an open shadow root (INTERFACE.md §2).
import type { ClipVaultUiApi } from '../contract';
import { ClipVaultView } from './app';

export function mount(root: ShadowRoot, api: ClipVaultUiApi): () => void {
  const view = new ClipVaultView(root, api, 'hub');
  return () => view.destroy();
}
