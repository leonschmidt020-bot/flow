// The native layer behind „Text dorthin, wo die Maus ist“ – an interface, so the orchestration (mouseTarget.ts) is
// unit-tested with a fake. The real implementation is win32Windows.ts (koffi → user32/dwmapi/kernel32).
import type { Point, Rect, WinInfo } from '../../core/mouseTarget';

export type FocusTechnique = 'direct' | 'attach' | 'alt';

export interface NativeWindows {
  /** mouse position, physical px */
  cursorPos(): Point;
  /** GetAncestor(WindowFromPoint(p), GA_ROOT) with its info, null if none */
  windowFromPoint(p: Point): WinInfo | null;
  /** all top-level windows, front → back (GetTopWindow/GetWindow(GW_HWNDNEXT)), at most a few hundred */
  zOrder(): WinInfo[];
  /** the foreground window (root) or null */
  foreground(): WinInfo | null;
  /** WM_NCHITTEST at the point (SendMessageTimeout, 100 ms), null = no answer (hung) */
  hitTest(hwnd: number, p: Point): number | null;
  /** one attempt to make `hwnd` the foreground window with the given technique (verification is the caller's job) */
  setForeground(hwnd: number, how: FocusTechnique): void;
  /** one left click at `p` (SendInput, absolute on the virtual desktop), the cursor then goes back to where it is now */
  click(p: Point): Promise<void> | void;
  /** Enter (VK_RETURN down/up, marked as Flow's own input) */
  pressEnter(): void;
  /** virtual desktop (all monitors), physical px */
  virtualScreen(): Rect;
}
