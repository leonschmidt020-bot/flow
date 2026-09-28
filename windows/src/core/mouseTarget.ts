// „Text dorthin, wo die Maus ist“ – pure rules (no windows, no UI Automation, unit-tested).
// Port of MouseTargetRules.swift for Windows. The part that really brings windows to the front, clicks and pastes lives
// in src/main/mouse/mouseTarget.ts (orchestration) and src/main/mouse/win32Windows.ts (koffi → user32/dwmapi).
//
// Coordinates: Flow's main process is per-monitor-DPI aware (Chromium sets PER_MONITOR_AWARE_V2), so GetCursorPos,
// WindowFromPoint, GetWindowRect and DwmGetWindowAttribute(EXTENDED_FRAME_BOUNDS) all speak PHYSICAL pixels of the
// virtual desktop. The primary monitor's top-left is (0,0); monitors left of / above it have negative coordinates.
// Electron windows are placed in DIP – `physToDipRect` converts per monitor (each monitor has its own scale).

export interface Point { x: number; y: number }
export interface Rect { x: number; y: number; width: number; height: number }

/** one top-level window (all coordinates physical px) */
export interface WinInfo {
  hwnd: number;
  pid: number;
  /** process image name, e.g. "WindowsTerminal.exe" */
  exe: string;
  /** window class, e.g. "CASCADIA_HOSTING_WINDOW_CLASS" */
  cls: string;
  /** only used to recognise web chats in browsers – never logged */
  title: string;
  /** visible frame (DWM extended frame bounds, falls back to GetWindowRect) */
  rect: Rect;
  style: number;
  exStyle: number;
  visible: boolean;
  iconic: boolean;
  /** DWMWA_CLOAKED ≠ 0: on another virtual desktop, suspended UWP app, hidden shell surface … */
  cloaked: boolean;
}

/** one UI Automation node (element under the mouse / focused element + ancestors) */
export interface UiaNode {
  /** control type without prefix: "Edit", "Document", "Button", "Text", "Pane", … */
  ct: string;
  /** ClassName – for Chromium/Electron this is the DOM class attribute ("xterm-helper-textarea", "monaco-editor" …) */
  cls: string;
  pwd?: boolean;
  /** ValuePattern available and not read-only (Win32 Edit, RichEdit, input/textarea, contenteditable) */
  editable?: boolean;
}

export const WS = { CHILD: 0x40000000, DISABLED: 0x08000000 } as const;
export const WS_EX = { TOPMOST: 0x8, TRANSPARENT: 0x20, TOOLWINDOW: 0x80, APPWINDOW: 0x40000, LAYERED: 0x80000, NOACTIVATE: 0x08000000 } as const;
export const HTCLIENT = 1;
export const MIN_SIZE = 40;

// MARK: geometry

export const rectContains = (r: Rect, p: Point): boolean => p.x >= r.x && p.x < r.x + r.width && p.y >= r.y && p.y < r.y + r.height;
export const ltrb = (left: number, top: number, right: number, bottom: number): Rect => ({ x: left, y: top, width: right - left, height: bottom - top });

export function overlap(a: Rect, b: Rect): number {
  const w = Math.min(a.x + a.width, b.x + b.width) - Math.max(a.x, b.x);
  const h = Math.min(a.y + a.height, b.y + b.height) - Math.max(a.y, b.y);
  return w > 0 && h > 0 ? w * h : 0;
}

/** a monitor in both coordinate systems (Electron: `bounds` in DIP, `screen.dipToScreenRect` → physical) */
export interface DisplayMap { dip: Rect; phys: Rect; scale: number }

function displayFor(displays: readonly DisplayMap[], r: Rect): DisplayMap | undefined {
  let best: DisplayMap | undefined, bestA = 0;
  for (const d of displays) { const a = overlap(d.phys, r); if (a > bestA) { bestA = a; best = d; } }
  if (best) return best;
  // outside every monitor (window dragged off-screen): nearest monitor by centre distance
  const cx = r.x + r.width / 2, cy = r.y + r.height / 2;
  let bestD = Infinity;
  for (const d of displays) {
    const dx = Math.max(d.phys.x - cx, 0, cx - (d.phys.x + d.phys.width));
    const dy = Math.max(d.phys.y - cy, 0, cy - (d.phys.y + d.phys.height));
    const dist = dx * dx + dy * dy;
    if (dist < bestD) { bestD = dist; best = d; }
  }
  return best;
}

/** physical rect → DIP, using the monitor that holds most of the rect (a window spanning two monitors with different
 *  scales can only be approximated – Windows itself resizes such windows to one monitor's DPI). */
export function physToDipRect(r: Rect, displays: readonly DisplayMap[]): Rect {
  const d = displayFor(displays, r);
  if (!d) return { ...r };
  const s = d.scale || 1;
  return {
    x: Math.round(d.dip.x + (r.x - d.phys.x) / s),
    y: Math.round(d.dip.y + (r.y - d.phys.y) / s),
    width: Math.round(r.width / s),
    height: Math.round(r.height / s),
  };
}

export function physToDipPoint(p: Point, displays: readonly DisplayMap[]): Point {
  const r = physToDipRect({ x: p.x, y: p.y, width: 1, height: 1 }, displays);
  return { x: r.x, y: r.y };
}

/** DIP → physical for one monitor (how Chromium lays out mixed-DPI setups: each monitor keeps its own origin) */
export function dipToPhysRect(r: Rect, d: DisplayMap): Rect {
  const s = d.scale || 1;
  return { x: Math.round(d.phys.x + (r.x - d.dip.x) * s), y: Math.round(d.phys.y + (r.y - d.dip.y) * s), width: Math.round(r.width * s), height: Math.round(r.height * s) };
}

/** scale of the monitor under a physical point (1 = 96 dpi) */
export function scaleAt(p: Point, displays: readonly DisplayMap[]): number {
  return displayFor(displays, { x: p.x, y: p.y, width: 1, height: 1 })?.scale ?? 1;
}

/** SendInput MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK: 0…65535 spans the whole virtual desktop */
export function absoluteInput(p: Point, virtualScreen: Rect): { dx: number; dy: number } {
  const n = (v: number, o: number, size: number) => Math.min(65535, Math.max(0, Math.round(((v - o) * 65535) / Math.max(1, size - 1))));
  return { dx: n(p.x, virtualScreen.x, virtualScreen.width), dy: n(p.y, virtualScreen.y, virtualScreen.height) };
}

/** MAKELPARAM(x, y) for WM_NCHITTEST – screen coordinates as signed 16-bit halves (negative monitors!) */
export function makeLParam(x: number, y: number): number {
  return (((y & 0xffff) << 16) | (x & 0xffff)) >>> 0;
}

/** the visible frame: DWM's extended frame bounds if plausible (maximized windows stick 8 px out of the monitor with
 *  GetWindowRect because of the invisible resize borders), else the window rect */
export function visibleFrame(windowRect: Rect, frame: Rect | null): Rect {
  if (!frame || frame.width <= 0 || frame.height <= 0) return windowRect;
  const inside = frame.x >= windowRect.x - 1 && frame.y >= windowRect.y - 1 &&
    frame.x + frame.width <= windowRect.x + windowRect.width + 1 && frame.y + frame.height <= windowRect.y + windowRect.height + 1;
  return inside ? frame : windowRect;
}

export const moved = (a: Point | null, b: Point, tol = 4): boolean => !a || Math.abs(a.x - b.x) > tol || Math.abs(a.y - b.y) > tol;

// MARK: apps

const base = (exe: string) => exe.toLowerCase().replace(/^.*[\\/]/u, '').replace(/\.exe$/u, '');

/** terminals: a click only sets the focus there, Enter = run/send */
export const TERMINAL_EXES = new Set(['windowsterminal', 'wt', 'openconsole', 'conhost', 'cmd', 'powershell', 'pwsh', 'wezterm-gui', 'alacritty',
  'mintty', 'tabby', 'hyper', 'warp', 'kitty', 'putty', 'kitty_portable', 'mobaxterm', 'termius', 'fluentterminal.app']);
export const TERMINAL_CLASSES = new Set(['ConsoleWindowClass', 'CASCADIA_HOSTING_WINDOW_CLASS', 'PuTTY', 'mintty', 'VirtualConsoleClass']);
/** editors with a built-in terminal (xterm.js) – click/Enter only when the mouse/focus really is in the terminal */
export const XTERM_EDITOR_EXES = new Set(['code', 'code - insiders', 'code-insiders', 'cursor', 'windsurf', 'vscodium', 'codium', 'antigravity', 'trae', 'positron']);
/** chat apps: Enter = send */
export const CHAT_EXES = new Set(['claude', 'chatgpt', 'discord', 'slack', 'whatsapp', 'whatsapp.root', 'telegram', 'signal', 'teams', 'ms-teams',
  'element', 'threema', 'messenger', 'beeper', 'rocket.chat', 'mattermost', 'zulip', 'wire', 'viber', 'skype', 'lmstudio', 'jan', 'msty']);
export const BROWSER_EXES = new Set(['chrome', 'msedge', 'firefox', 'brave', 'opera', 'vivaldi', 'arc', 'zen', 'librewolf', 'waterfox', 'thorium', 'chromium', 'floorp', 'iexplore']);
/** never read, never targeted: password managers, Windows credential/consent/lock screens */
export const PASSWORD_EXES = new Set(['1password', 'bitwarden', 'keepass', 'keepassxc', 'lastpass', 'dashlane', 'enpass', 'roboform', 'nordpass', 'keeper',
  'keeperpasswordmanager', 'protonpass', 'proton pass', 'credentialuibroker', 'consent', 'logonui', 'lockapp', 'passwordsafe', 'pwsafe', 'kwallet']);
/** desktop, taskbar, start menu, search, quick settings … – the mouse is NOT on a window → normal behaviour */
export const SHELL_CLASSES = new Set(['Progman', 'WorkerW', '#32769', 'Shell_TrayWnd', 'Shell_SecondaryTrayWnd', 'NotifyIconOverflowWindow',
  'TopLevelWindowForOverflowXamlIsland', 'Shell_InputSwitchTopLevelWindow', 'XamlExplorerHostIslandWindow', 'MultitaskingViewFrame',
  'ForegroundStaging', 'TaskListThumbnailWnd', 'Windows.UI.Input.InputSite.WindowClass']);
export const SHELL_EXES = new Set(['startmenuexperiencehost', 'searchhost', 'searchapp', 'shellexperiencehost', 'shellhost', 'textinputhost', 'lockapp',
  'searchui', 'cortana', 'screenclippinghost', 'snippingtool']);

export type AppKind = 'terminal' | 'xtermEditor' | 'chat' | 'browser' | 'other';

export function appKind(exe: string, cls = ''): AppKind {
  const e = base(exe);
  if (TERMINAL_CLASSES.has(cls) || TERMINAL_EXES.has(e)) return 'terminal';
  if (XTERM_EDITOR_EXES.has(e)) return 'xtermEditor';
  if (CHAT_EXES.has(e)) return 'chat';
  if (BROWSER_EXES.has(e)) return 'browser';
  return 'other';
}

export const isPasswordApp = (exe: string): boolean => PASSWORD_EXES.has(base(exe));

/** Web chats in the browser are only detectable via the window title (the tab title). Exact names only – a page about
 *  „Claude Monet“ must not count. Separators: " - ", " – ", " — ", " | ", " · ", ": ". */
export const CHAT_TITLES = ['chatgpt', 'claude', 'gemini', 'google gemini', 'whatsapp', 'whatsapp web', 'slack', 'discord', 'telegram', 'telegram web',
  'perplexity', 'le chat', 'mistral', 'le chat mistral', 'copilot', 'microsoft copilot', 'deepseek', 'grok', 'microsoft teams', 'teams',
  'google messages', 'messages for web', 'signal', 'poe', 'hugging chat', 'huggingchat', 'mistral ai'];
const BROWSER_SUFFIX = /\s[-–—]\s(google chrome|microsoft edge|mozilla firefox|firefox|brave|opera|vivaldi|arc|chromium|zen browser|librewolf|waterfox|thorium|floorp)\s*$/iu;

export function chatTitle(title: string): boolean {
  let t = title.replace(/[\u200b-\u200f\u2060\ufeff]/gu, '').trim();
  const m = BROWSER_SUFFIX.exec(t);
  // Edge puts the profile name in front of its own name („Seite - Persönlich - Microsoft Edge“)
  const profileSeg = !!m && /edge/iu.test(m[1] ?? '');
  if (m) t = t.slice(0, m.index).trim();
  t = t.replace(/^\(\d+\+?\)\s*/u, '').replace(/^[•●*]\s*/u, '').trim(); // unread counters „(3) WhatsApp“
  if (!t) return false;
  const segs = t.split(/\s+[-–—|·]\s+|:\s+/u).map((x) => x.trim().toLowerCase()).filter(Boolean);
  if (!segs.length) return false;
  const cand = [segs[0]!, segs[segs.length - 1]!];
  if (profileSeg && segs.length >= 2) cand.push(segs[segs.length - 2]!);
  return cand.some((c) => CHAT_TITLES.includes(c));
}

// MARK: window list

export type SkipReason = 'own' | 'tool' | 'noactivate' | 'clickThrough' | 'small' | 'invisible' | 'iconic' | 'cloaked' | 'child' | 'disabled' | 'shell' | 'password';
const PASS_THROUGH: ReadonlySet<SkipReason> = new Set(['own', 'tool', 'noactivate', 'clickThrough', 'small']);
const NOT_THERE: ReadonlySet<SkipReason> = new Set(['invisible', 'iconic', 'cloaked', 'child']);

/** why a window can not be the target (null = it can) */
export function skipReason(w: WinInfo, ownPid: number): SkipReason | null {
  if (!w.visible) return 'invisible';
  if (w.iconic) return 'iconic';
  if (w.cloaked) return 'cloaked';
  if (w.style & WS.CHILD) return 'child';
  if (w.pid === ownPid) return 'own';
  if (SHELL_CLASSES.has(w.cls) || SHELL_EXES.has(base(w.exe))) return 'shell';
  if (isPasswordApp(w.exe)) return 'password';
  // click-through overlays (DimAll-style dimmers, screen recorders' frames, our own highlight in another instance)
  if ((w.exStyle & WS_EX.TRANSPARENT) && (w.exStyle & WS_EX.LAYERED)) return 'clickThrough';
  // tool windows (palettes, floating toolbars, Flow's pill) – unless they explicitly want a taskbar button
  if ((w.exStyle & WS_EX.TOOLWINDOW) && !(w.exStyle & WS_EX.APPWINDOW)) return 'tool';
  if (w.exStyle & WS_EX.NOACTIVATE) return 'noactivate';
  if (w.style & WS.DISABLED) return 'disabled';
  if (w.rect.width < MIN_SIZE || w.rect.height < MIN_SIZE) return 'small';
  return null;
}

export type Pick =
  | { t: 'target'; win: WinInfo; covered: boolean }
  | { t: 'blocked'; why: string }
  | { t: 'none'; why: string };

const WHY: Record<SkipReason, string> = {
  own: 'eigenes Fenster', tool: 'Werkzeugfenster', noactivate: 'nicht aktivierbar', clickThrough: 'durchklickbares Overlay', small: 'zu klein',
  invisible: 'unsichtbar', iconic: 'minimiert', cloaked: 'verborgen (cloaked)', child: 'Kindfenster', disabled: 'gesperrt (Dialog offen?)',
  shell: 'Desktop/Taskleiste/Startmenü', password: 'Passwort-App',
};

/**
 * Pick the target at point `p` from the window list (front → back, EnumWindows/GetWindow order).
 * Own windows, tool windows, click-through overlays and tiny windows are looked THROUGH (but then `covered` = true:
 * something visible lies above the point → no click). Desktop/taskbar/start menu on top → no target.
 */
export function pickFromList(list: readonly WinInfo[], p: Point, ownPid: number): Pick {
  let covered = false;
  for (const w of list) {
    if (!rectContains(w.rect, p)) continue;
    const why = skipReason(w, ownPid);
    if (why === null) return { t: 'target', win: w, covered };
    if (NOT_THERE.has(why)) continue;
    if (PASS_THROUGH.has(why)) { covered = true; continue; }
    if (why === 'disabled') return { t: 'none', why: WHY[why] };
    if (why === 'password') return { t: 'none', why: WHY[why] };
    return { t: 'blocked', why: WHY[why] };
  }
  return { t: 'none', why: 'kein Fenster unter der Maus' };
}

/** fast path: the root of WindowFromPoint is usable as it is; otherwise walk the Z-order list */
export function resolveTarget(fromPoint: WinInfo | null, zOrder: () => readonly WinInfo[], p: Point, ownPid: number): Pick {
  if (fromPoint) {
    const why = skipReason(fromPoint, ownPid);
    if (why === null) return { t: 'target', win: fromPoint, covered: false };
    if (why === 'shell') return { t: 'blocked', why: WHY.shell };
    if (why === 'password') return { t: 'none', why: WHY.password };
  }
  return pickFromList(zOrder(), p, ownPid);
}

// MARK: text field under the mouse

export const isSecure = (n: UiaNode): boolean => n.pwd === true;
export const isEditable = (n: UiaNode): boolean => !isSecure(n) && n.editable === true;
export const hasClass = (chain: readonly UiaNode[], needle: string): boolean => chain.some((n) => n.cls.toLowerCase().split(/\s+/u).some((c) => c.includes(needle)));

export type EditablePick = { t: 'at'; i: number } | { t: 'secure' } | { t: 'none' };

/** element under the mouse + ancestors (index 0 = the element): first text field within `maxUp` levels.
 *  A password field on the way → never a target. */
export function pickEditable(chain: readonly UiaNode[], maxUp = 4): EditablePick {
  for (let i = 0; i < Math.min(chain.length, maxUp + 1); i++) {
    const n = chain[i]!;
    if (isSecure(n)) return { t: 'secure' };
    if (isEditable(n)) return { t: 'at', i };
    if (n.ct === 'Window') break;
  }
  return { t: 'none' };
}

// MARK: click allowed? (method c)

/** control types that are never clicked blindly (buttons, links, tabs, menus, scroll bars, list rows …) */
export const CLICKABLE_TYPES = new Set(['Button', 'Hyperlink', 'CheckBox', 'RadioButton', 'ComboBox', 'SplitButton', 'MenuItem', 'MenuBar', 'Menu',
  'TabItem', 'Tab', 'ToolBar', 'TitleBar', 'Slider', 'Spinner', 'ScrollBar', 'Thumb', 'ListItem', 'TreeItem', 'DataItem', 'Header', 'HeaderItem',
  'Image', 'Calendar', 'ProgressBar', 'Separator', 'StatusBar', 'ToolTip', 'AppBar', 'SemanticZoom']);
/** in terminals: only on the terminal surface itself */
export const TERMINAL_SURFACE_TYPES = new Set(['Document', 'Text', 'Pane', 'Edit', 'Custom', 'Group', 'Window']);
/** Windows Terminal's tab strip lives inside the client area – without UI Automation never click in its top band */
export const WT_TAB_STRIP_DIP = 44;

export interface ClickInput {
  kind: AppKind;
  /** browser tab with a web chat (window title) */
  chatSite: boolean;
  exe: string;
  cls: string;
  /** WM_NCHITTEST result at the point (null = no answer / hung) */
  hit: number | null;
  /** UI Automation element under the mouse + ancestors (null = UI Automation not available) */
  chain: readonly UiaNode[] | null;
  covered: boolean;
  /** point relative to the window's top-left (physical) + monitor scale */
  offset: Point;
  scale: number;
}

/** May a single left click at the point set the focus? Terminals and chat inputs only, only on the client area, never
 *  on buttons, links, tabs; nothing may lie above the point. */
export function clickAllowed(c: ClickInput): boolean {
  if (c.covered || c.hit !== HTCLIENT) return false;
  const chain = c.chain;
  if (chain) {
    if (chain.some(isSecure)) return false;
    if (chain.slice(0, 4).some((n) => CLICKABLE_TYPES.has(n.ct))) return false;
  }
  switch (c.kind) {
    case 'terminal': {
      if (!chain || !chain.length) {
        const wt = base(c.exe) === 'windowsterminal' || c.cls === 'CASCADIA_HOSTING_WINDOW_CLASS';
        return !wt || c.offset.y > WT_TAB_STRIP_DIP * (c.scale || 1);
      }
      return TERMINAL_SURFACE_TYPES.has(chain[0]!.ct);
    }
    case 'xtermEditor':
      // xterm.js: a click only focuses the terminal. Editor (Monaco), side bar, tabs: never.
      return !!chain && hasClass(chain, 'xterm') && !hasClass(chain, 'monaco-editor');
    case 'chat':
      return !!chain && chain.slice(0, 5).some(isEditable);
    case 'browser':
      return c.chatSite && !!chain && chain.some((n) => n.ct === 'Document') && chain.slice(0, 5).some(isEditable);
    default:
      return false;
  }
}

// MARK: Enter allowed? („Danach automatisch abschicken“)

export type SendDecision = { send: true } | { send: false; why: string };
const NO = (why: string): SendDecision => ({ send: false, why });

/**
 * When „Danach automatisch abschicken“ really presses Enter. `chain` = focused element + ancestors AFTER pasting
 * (null = UI Automation not available). Enter must mean „send“ there, never „new line“:
 *   • terminals (Windows Terminal, conhost, WezTerm, Alacritty, mintty …) – always
 *   • VS Code / Cursor / Windsurf – only in the terminal (xterm, e.g. Claude Code), in webview chats (Claude Code
 *     extension) and chat inputs (Copilot); NEVER in the code editor (Monaco), Enter would only be a new line there
 *   • chat apps: Claude, ChatGPT, Discord, Slack, WhatsApp, Telegram, Signal, Teams …
 *   • browsers: only text fields INSIDE a page whose tab title is a web chat, never the address bar
 *   • everything else (Word, Outlook, Notepad, search boxes …): never
 */
export function autoSend(kind: AppKind, chatSite: boolean, chain: readonly UiaNode[] | null): SendDecision {
  const ch = chain ?? [];
  if (ch.some(isSecure)) return NO('Passwortfeld');
  switch (kind) {
    case 'terminal': return { send: true };
    case 'xtermEditor': {
      if (hasClass(ch, 'xterm')) return { send: true };
      if (hasClass(ch, 'monaco-editor')) {
        return hasClass(ch, 'interactive-input') || hasClass(ch, 'chat-input') || hasClass(ch, 'chat-editor') ? { send: true } : NO('Code-Editor – Enter wäre eine neue Zeile');
      }
      // webview (extension like Claude Code): a second web document in the window
      if (ch.filter((n) => n.ct === 'Document').length >= 2 && ch[0] && isEditable(ch[0])) return { send: true };
      return NO('kein Terminal/Chat im Editor');
    }
    case 'chat': return { send: true };
    case 'browser': {
      if (!ch.some((n) => n.ct === 'Document')) return NO('Browser außerhalb der Seite (Adressleiste?)');
      if (!ch.slice(0, 5).some(isEditable)) return NO('kein Textfeld');
      if (!chatSite) return NO('keine Chat-Seite');
      return { send: true };
    }
    default: return NO('App nicht auf der Enter-Liste');
  }
}

/** Did the paste really work? A readable field value must contain the text (end, normalised).
 *  Empty/unreadable field (terminals, xterm helper) → undefined: only the focus check counts. */
export function pasteConfirmed(inserted: string, fieldValue: string | null | undefined, valueBefore?: string | null): boolean | undefined {
  const n = (s: string) => s.replace(/[\s\u00a0]+/gu, ' ').trim();
  if (fieldValue === null || fieldValue === undefined || !n(fieldValue)) return undefined;
  if (valueBefore !== null && valueBefore !== undefined && n(valueBefore) === n(fieldValue)) return false;
  const tail = Array.from(n(inserted)).slice(-24).join('');
  return tail ? n(fieldValue).includes(tail) : undefined;
}

/** methods, as in the Mac log: 0 = mouse over the active window, a = text field under the mouse focused (UI Automation),
 *  c = one click into the terminal/chat input, b = the field the window remembered, d = failed → pasted normally,
 *  – = no target / switched off */
export type Method = '0' | 'a' | 'b' | 'c' | 'd' | '–';
export const SENDS_AFTER: ReadonlySet<Method> = new Set(['0', 'a', 'b', 'c']);
