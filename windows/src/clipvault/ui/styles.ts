// Styles for panel + Hub. Flow's design tokens (--bg, --panel, --line, --text, --accent, …) are used
// when present (Hub); the panel window defines its own dark-glass fallbacks.
export const CSS = `
:host, .cv {
  --cv-font: var(--font, "Segoe UI Variable Text", "Segoe UI", -apple-system, BlinkMacSystemFont, system-ui, sans-serif);
  --cv-text: var(--text, #f3f3f5);
  --cv-dim: var(--text-dim, rgba(235, 235, 245, .56));
  --cv-faint: rgba(235, 235, 245, .34);
  --cv-line: var(--line, rgba(255, 255, 255, .085));
  --cv-surface: var(--panel-2, rgba(255, 255, 255, .045));
  --cv-hover: rgba(255, 255, 255, .055);
  --cv-sel: rgba(255, 255, 255, .095);
  --cv-accent: var(--accent, #8ea8ff);
  --cv-accent-2: var(--accent-2, #6f8cff);
  --cv-danger: var(--danger, #ff6b6b);
  --cv-pin: #f2c55c;
  --cv-radius: var(--radius, 14px);
  --cv-radius-sm: var(--radius-sm, 9px);
}
* { box-sizing: border-box; }
[hidden] { display: none !important; }
.cv { font-family: var(--cv-font); color: var(--cv-text); font-size: 13px; line-height: 1.35; -webkit-font-smoothing: antialiased;
  display: flex; flex-direction: column; height: 100%; min-height: 0; user-select: none; position: relative; }
.cv button { font: inherit; color: inherit; }
.ic { flex: none; display: block; }

/* ---------- panel shell ---------- */
.cv.panel { height: 100%; border-radius: 12px; overflow: hidden;
  background: linear-gradient(180deg, rgba(30, 31, 38, .70), rgba(16, 17, 21, .74));
  border: 1px solid rgba(255, 255, 255, .09); box-shadow: inset 0 1px 0 rgba(255, 255, 255, .06); }
.cv.panel.m-solid { background: linear-gradient(180deg, #1d1e24, #121317); }
.cv.panel.m-vibrancy { background: linear-gradient(180deg, rgba(28, 29, 36, .62), rgba(14, 15, 19, .70)); }

/* ---------- top bar ---------- */
.top { display: flex; align-items: center; gap: 8px; padding: 12px 12px 8px; }
.search { flex: 1; display: flex; align-items: center; gap: 8px; height: 36px; padding: 0 12px; border-radius: 10px;
  background: rgba(0, 0, 0, .22); border: 1px solid var(--cv-line); color: var(--cv-dim); transition: border-color .15s, background .15s; }
.search:focus-within { border-color: color-mix(in srgb, var(--cv-accent) 55%, transparent); background: rgba(0, 0, 0, .3); }
.search input { flex: 1; min-width: 0; background: none; border: 0; outline: 0; color: var(--cv-text); font: inherit; font-size: 14px; }
.search input::placeholder { color: var(--cv-faint); }
.search kbd { font: 11px var(--cv-font); color: var(--cv-faint); border: 1px solid var(--cv-line); border-radius: 5px; padding: 1px 5px; }
.iconbtn { width: 32px; height: 32px; display: grid; place-items: center; border-radius: 9px; border: 0; background: transparent; color: var(--cv-dim); cursor: pointer; }
.iconbtn:hover { background: var(--cv-hover); color: var(--cv-text); }
.iconbtn.on { color: var(--cv-pin); }
.iconbtn.danger:hover { color: var(--cv-danger); }

.chips { display: flex; gap: 6px; padding: 0 12px 8px; overflow-x: auto; scrollbar-width: none; }
.chips::-webkit-scrollbar { display: none; }
.chip { display: inline-flex; align-items: center; gap: 6px; height: 28px; padding: 0 11px; border-radius: 8px; white-space: nowrap;
  border: 1px solid var(--cv-line); background: transparent; color: var(--cv-dim); cursor: pointer; font-size: 12.5px; transition: background .12s, color .12s; }
.chip:hover { background: var(--cv-hover); color: var(--cv-text); }
.chip.on { background: var(--cv-sel); color: var(--cv-text); border-color: rgba(255, 255, 255, .14); }
.chip .n { color: var(--cv-faint); font-variant-numeric: tabular-nums; font-size: 11.5px; }
.chip.drop { border-style: dashed; border-color: var(--cv-accent); }

.filters { display: flex; align-items: center; gap: 2px; padding: 0 12px 8px; border-bottom: 1px solid var(--cv-line); }
.seg { height: 24px; padding: 0 10px; border-radius: 6px; border: 0; background: transparent; color: var(--cv-dim); cursor: pointer; font-size: 12px; }
.seg:hover { color: var(--cv-text); }
.seg.on { background: rgba(255, 255, 255, .08); color: var(--cv-text); }
.seg .n { margin-left: 4px; color: var(--cv-faint); font-size: 11px; }
.count { margin-left: auto; color: var(--cv-faint); font-size: 11.5px; font-variant-numeric: tabular-nums; }

/* ---------- body ---------- */
.body { flex: 1; display: flex; min-height: 0; }
.body.noprev .prev { display: none; }
.body.noprev .list { width: 100%; }
.list { width: 50%; min-width: 300px; overflow-y: auto; padding: 4px 6px 10px; scrollbar-width: thin; scrollbar-color: rgba(255,255,255,.14) transparent; }
.hub .list { width: 440px; flex: none; }
.sec { position: sticky; top: 0; z-index: 1; padding: 10px 10px 5px; font-size: 10.5px; font-weight: 600; letter-spacing: .08em; text-transform: uppercase;
  color: var(--cv-faint); display: flex; align-items: center; gap: 6px; background: rgba(20, 21, 27, .62); backdrop-filter: blur(10px); margin: 0 -6px; padding-left: 16px; }
.sec.pinned { color: color-mix(in srgb, var(--cv-pin) 80%, transparent); }
.row { display: flex; align-items: center; gap: 11px; padding: 7px 8px; margin: 1px 0; border-radius: 10px; cursor: default; position: relative; }
.row:hover { background: var(--cv-hover); }
.row.sel { background: var(--cv-sel); box-shadow: inset 0 0 0 1px rgba(255, 255, 255, .07); }
.row.sel::before { content: ""; position: absolute; left: 0; top: 11px; bottom: 11px; width: 2px; border-radius: 2px; background: var(--cv-accent); }
.tile { width: 38px; height: 38px; border-radius: 9px; flex: none; display: grid; place-items: center; overflow: hidden;
  background: rgba(255, 255, 255, .055); border: 1px solid rgba(255, 255, 255, .06); color: rgba(255, 255, 255, .78); }
.tile img { width: 100%; height: 100%; object-fit: cover; }
.tile.t-link { color: #72d4cb; } .tile.t-code { color: #b9a6ff; } .tile.t-email, .tile.t-phone { color: #8fb8ff; }
.tile.t-file { color: #e7c989; } .tile.t-lock { color: var(--cv-pin); } .tile.t-mic { color: #ffab73; } .tile.t-ai { color: #c9a0ff; }
.meta { flex: 1; min-width: 0; }
.title { font-size: 13.5px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; color: var(--cv-text); }
.sub { margin-top: 2px; font-size: 11.5px; color: var(--cv-dim); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; display: flex; gap: 6px; align-items: center; }
.tag { font-size: 9.5px; font-weight: 700; letter-spacing: .06em; text-transform: uppercase; padding: 1px 5px; border-radius: 4px;
  background: rgba(255, 255, 255, .07); color: var(--cv-dim); }
.tag.link { color: #72d4cb; } .tag.code { color: #b9a6ff; } .tag.email, .tag.phone { color: #8fb8ff; } .tag.color { color: #f0a9d0; }
.tag.secret { color: var(--cv-pin); } .tag.shared { color: #72d4cb; }
.quick { font-size: 11px; color: var(--cv-faint); font-variant-numeric: tabular-nums; }
.pinmark { color: var(--cv-pin); }
.rowacts { display: none; gap: 2px; }
.row:hover .rowacts, .row.sel .rowacts { display: flex; }
.row:hover .quick, .row.sel .quick, .row:hover .pinmark, .row.sel .pinmark { display: none; }
.rowacts .iconbtn { width: 26px; height: 26px; border-radius: 7px; }

/* ---------- preview ---------- */
.prev { flex: 1; min-width: 0; display: flex; flex-direction: column; border-left: 1px solid var(--cv-line); }
.phead { padding: 12px 14px 10px; display: flex; align-items: flex-start; gap: 10px; }
.phead .meta .title { font-size: 14px; font-weight: 600; white-space: normal; display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; }
.pacts { display: flex; gap: 6px; padding: 0 14px 10px; flex-wrap: wrap; }
.btn { height: 28px; padding: 0 11px; border-radius: 8px; border: 1px solid var(--cv-line); background: rgba(255, 255, 255, .04); color: var(--cv-text);
  display: inline-flex; align-items: center; gap: 6px; cursor: pointer; font-size: 12.5px; white-space: nowrap; }
.btn:hover { background: rgba(255, 255, 255, .09); }
.btn.primary { background: color-mix(in srgb, var(--cv-accent) 22%, transparent); border-color: color-mix(in srgb, var(--cv-accent) 42%, transparent); }
.btn.primary:hover { background: color-mix(in srgb, var(--cv-accent) 32%, transparent); }
.btn.danger:hover { color: var(--cv-danger); border-color: color-mix(in srgb, var(--cv-danger) 40%, transparent); }
.btn .k { color: var(--cv-faint); font-size: 11px; }
.pbody { flex: 1; min-height: 0; overflow: auto; margin: 0 14px 12px; border-radius: 10px; background: rgba(0, 0, 0, .2); border: 1px solid var(--cv-line); }
.pbody pre { margin: 0; padding: 12px 13px; white-space: pre-wrap; word-break: break-word; font: 12.5px/1.5 "Cascadia Mono", Consolas, ui-monospace, monospace; color: rgba(245,245,250,.9); user-select: text; }
.pbody .prose { padding: 12px 13px; white-space: pre-wrap; word-break: break-word; font-size: 13px; line-height: 1.55; user-select: text; }
.pbody.img { display: grid; place-items: center; background: repeating-conic-gradient(rgba(255,255,255,.035) 0 25%, transparent 0 50%) 0 0/16px 16px, rgba(0,0,0,.25); cursor: zoom-in; }
.pbody.img img { max-width: 100%; max-height: 100%; object-fit: contain; display: block; }
.pbody .files { padding: 8px; }
.pbody .frow { display: flex; align-items: center; gap: 10px; padding: 8px; border-radius: 8px; color: var(--cv-text); }
.pbody .frow + .frow { border-top: 1px solid var(--cv-line); }
.swatch { height: 90px; border-radius: 9px 9px 0 0; }
.masked .ic { margin: 0 auto; }
.masked { display: grid; place-items: center; height: 100%; color: var(--cv-dim); gap: 10px; text-align: center; padding: 20px; }
.ocr { margin: 0 14px 12px; padding: 9px 11px; border-radius: 9px; background: rgba(255,255,255,.04); color: var(--cv-dim); font-size: 12px; max-height: 88px; overflow: auto; user-select: text; white-space: pre-wrap; }
.menu { position: absolute; z-index: 20; min-width: 190px; padding: 5px; border-radius: 10px; background: rgba(30, 31, 37, .98);
  border: 1px solid rgba(255,255,255,.1); box-shadow: 0 16px 40px rgba(0,0,0,.45); }
.menu button { display: flex; align-items: center; gap: 9px; width: 100%; height: 30px; padding: 0 9px; border: 0; border-radius: 7px; background: none; cursor: pointer; font-size: 12.5px; text-align: left; }
.menu button:hover { background: var(--cv-hover); }
.menu hr { border: 0; border-top: 1px solid var(--cv-line); margin: 4px 2px; }

/* ---------- empty ---------- */
.empty { flex: 1; display: grid; place-items: center; text-align: center; padding: 30px; color: var(--cv-dim); }
.empty h3 { margin: 12px 0 6px; color: var(--cv-text); font-size: 15px; font-weight: 600; }
.empty p { margin: 0 auto; max-width: 300px; font-size: 12.5px; line-height: 1.5; }
.empty .ring { width: 52px; height: 52px; border-radius: 15px; display: grid; place-items: center; margin: 0 auto; background: rgba(255,255,255,.05); border: 1px solid var(--cv-line); color: var(--cv-dim); }

/* ---------- footer ---------- */
.foot { display: flex; gap: 14px; padding: 7px 14px; border-top: 1px solid var(--cv-line); color: var(--cv-faint); font-size: 11px; white-space: nowrap; overflow: hidden; }
.foot b { color: var(--cv-dim); font-weight: 600; }

/* ---------- viewer ---------- */
.viewer { position: absolute; inset: 0; z-index: 30; display: flex; flex-direction: column; background: rgba(9, 9, 12, .97); backdrop-filter: blur(24px); border-radius: inherit; }
.vbar { display: flex; align-items: center; gap: 6px; padding: 10px 12px; color: var(--cv-dim); }
.vbar .vt { flex: 1; min-width: 0; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; color: var(--cv-text); font-weight: 600; }
.vstage { flex: 1; min-height: 0; overflow: hidden; display: grid; place-items: center; position: relative; cursor: grab; }
.vstage.drag { cursor: grabbing; }
.vstage img { max-width: none; transform-origin: 0 0; position: absolute; left: 0; top: 0; image-rendering: auto; box-shadow: 0 10px 40px rgba(0,0,0,.5); }
.vnav { position: absolute; top: 50%; transform: translateY(-50%); width: 38px; height: 38px; border-radius: 19px; background: rgba(30,31,37,.8); border: 1px solid rgba(255,255,255,.1); display: grid; place-items: center; cursor: pointer; color: var(--cv-text); }
.vnav.l { left: 14px; } .vnav.r { right: 14px; }
.vnav[disabled] { opacity: .25; cursor: default; }
.vzoom { font-variant-numeric: tabular-nums; min-width: 46px; text-align: center; font-size: 12px; }

/* ---------- hub ---------- */
.cv.hub { flex-direction: row; min-height: 600px; height: 100%; }
.side { width: 210px; flex: none; padding: 14px 10px; border-right: 1px solid var(--cv-line); display: flex; flex-direction: column; gap: 2px; overflow-y: auto; }
.side h2 { font-size: 17px; font-weight: 650; margin: 2px 8px 2px; letter-spacing: -.01em; }
.side .subt { font-size: 11.5px; color: var(--cv-faint); margin: 0 8px 14px; }
.nav { display: flex; align-items: center; gap: 9px; height: 32px; padding: 0 9px; border-radius: 8px; border: 0; background: none; cursor: pointer; color: var(--cv-dim); font-size: 13px; text-align: left; width: 100%; }
.nav:hover { background: var(--cv-hover); color: var(--cv-text); }
.nav.on { background: var(--cv-sel); color: var(--cv-text); }
.nav .n { margin-left: auto; font-size: 11.5px; color: var(--cv-faint); }
.nav.drop { outline: 1px dashed var(--cv-accent); }
.side .grow { flex: 1; }
.side .lbl { font-size: 10.5px; letter-spacing: .08em; text-transform: uppercase; color: var(--cv-faint); margin: 14px 9px 4px; }
.main { flex: 1; min-width: 0; display: flex; flex-direction: column; }
.hub .top { padding: 14px 14px 8px; }
.settings { flex: 1; overflow-y: auto; padding: 18px 22px 30px; }
.settings h3 { font-size: 13px; letter-spacing: .02em; margin: 22px 0 8px; color: var(--cv-text); }
.settings h3:first-child { margin-top: 0; }
.card { border: 1px solid var(--cv-line); background: var(--cv-surface); border-radius: 12px; padding: 4px 14px; }
.opt { display: flex; align-items: center; gap: 14px; padding: 11px 0; }
.opt + .opt { border-top: 1px solid var(--cv-line); }
.opt .ot { flex: 1; } .opt .ot div:first-child { font-size: 13px; } .opt .ot div + div { font-size: 11.5px; color: var(--cv-dim); margin-top: 2px; }
.switch { width: 36px; height: 21px; border-radius: 11px; background: rgba(255,255,255,.14); position: relative; border: 0; cursor: pointer; flex: none; transition: background .15s; }
.switch::after { content: ""; position: absolute; top: 2.5px; left: 2.5px; width: 16px; height: 16px; border-radius: 50%; background: #fff; transition: transform .15s; }
.switch.on { background: var(--cv-accent-2); } .switch.on::after { transform: translateX(15px); }
.switch[disabled] { opacity: .4; cursor: default; }
.field { height: 30px; border-radius: 8px; border: 1px solid var(--cv-line); background: rgba(0,0,0,.2); color: var(--cv-text); padding: 0 10px; font: inherit; outline: 0; }
.field:focus { border-color: color-mix(in srgb, var(--cv-accent) 55%, transparent); }
textarea.field { height: 64px; padding: 7px 10px; resize: vertical; width: 100%; }
.num { width: 76px; text-align: right; }
.paircode { font: 12px "Cascadia Mono", Consolas, monospace; word-break: break-all; user-select: all; padding: 10px; border-radius: 8px; background: rgba(0,0,0,.3); border: 1px solid var(--cv-line); margin: 8px 0; }
.status { display: inline-flex; align-items: center; gap: 7px; font-size: 12px; color: var(--cv-dim); }
.dot { width: 8px; height: 8px; border-radius: 50%; background: #777; } .dot.ok { background: #34c759; } .dot.warn { background: #f2c55c; } .dot.bad { background: #ff6b6b; }
.banner { margin: 0 14px 10px; padding: 9px 12px; border-radius: 9px; font-size: 12px; background: rgba(242,197,92,.1); border: 1px solid rgba(242,197,92,.3); color: #f5d98f; }
.muted { color: var(--cv-dim); font-size: 12px; }
`;
