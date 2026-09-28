// What the UI Automation helper answers (src/main/uia/flow-uia.ps1). Never contains text unless a command asks for it
// (`read`, `focused` with value) – and nothing of it is ever logged.
import type { Point, UiaNode } from '../../core/mouseTarget';
import type { ReadResult } from '../../core/learner';

export interface UiaElement {
  /** the element + its ancestors (index 0 = the element itself), up to the top-level window */
  chain: UiaNode[];
  /** top-level window (HWND as number) the element belongs to, 0 = unknown */
  root: number;
  pid: number;
  pwd: boolean;
  editable: boolean;
  /** only with `focused({ value: true })`: the field's value (end of it, at most ~4000 chars) */
  value?: string;
}

export interface UiaRead extends ReadResult { root?: number }

export interface UiaPort {
  /** helper can run (Windows, PowerShell present, not given up after repeated failures) */
  readonly available: boolean;
  /** coordinate commands (`at`, `setFocusAt`) need a per-monitor-DPI-aware helper */
  readonly dpiAware: boolean;
  at(p: Point): Promise<UiaElement | null>;
  focused(opts?: { value?: boolean }): Promise<UiaElement | null>;
  /** focus the text field under the point (not a password field); true = it is focused now */
  setFocusAt(p: Point): Promise<boolean>;
  /** read the focused element (field value, terminal rows, xterm.js rows); remembers the element for `reread` */
  read(): Promise<UiaRead | null>;
  /** read the element remembered by the last `read` again (falls back to the focused element of the same process) */
  reread(): Promise<UiaRead | null>;
  dispose(): void;
}

/** a UiaPort that does nothing (macOS dev runs, helper unavailable) */
export const noUia: UiaPort = {
  available: false, dpiAware: false,
  at: async () => null, focused: async () => null, setFocusAt: async () => false, read: async () => null, reread: async () => null, dispose: () => {},
};
