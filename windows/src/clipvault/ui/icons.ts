// Inline line icons (24×24, 1.6 px stroke, currentColor) – no icon font, no network.
const P: Record<string, string> = {
  search: '<circle cx="11" cy="11" r="6.5"/><path d="m20 20-4.2-4.2"/>',
  pin: '<path d="M9 4h6l-1 5 3 3v2H7v-2l3-3-1-5Z"/><path d="M12 14v6"/>',
  pinFill: '<path fill="currentColor" d="M9 4h6l-1 5 3 3v2H7v-2l3-3-1-5Z"/><path d="M12 14v6"/>',
  trash: '<path d="M4 7h16"/><path d="M9 7V4.8c0-.4.4-.8.8-.8h4.4c.4 0 .8.4.8.8V7"/><path d="M6.5 7l.8 12.2c0 .5.5.8 1 .8h7.4c.5 0 1-.3 1-.8L17.5 7"/>',
  copy: '<rect x="8.5" y="8.5" width="11" height="11" rx="2.2"/><path d="M15.5 8.5V6.2c0-1-.8-1.7-1.7-1.7H6.2c-1 0-1.7.8-1.7 1.7v7.6c0 1 .8 1.7 1.7 1.7h2.3"/>',
  paste: '<path d="M9 5H7.2C6 5 5 6 5 7.2v11.6C5 20 6 21 7.2 21h9.6c1.2 0 2.2-1 2.2-2.2V7.2C19 6 18 5 16.8 5H15"/><rect x="9" y="3" width="6" height="4" rx="1.2"/><path d="m9 14 2.2 2.2L15.5 12"/>',
  folder: '<path d="M3.5 7.2c0-1 .8-1.7 1.7-1.7h4l2 2.2h7.6c1 0 1.7.8 1.7 1.7v7.4c0 1-.8 1.7-1.7 1.7H5.2c-1 0-1.7-.8-1.7-1.7Z"/>',
  folderOpen: '<path d="M3.5 17.5V7.2c0-1 .8-1.7 1.7-1.7h4l2 2.2h6.3c1 0 1.7.8 1.7 1.7v1.1"/><path d="M3.5 17.5 6 11.3c.3-.6.8-.9 1.4-.9H20c.8 0 1.3.8 1 1.5l-2.3 5.8c-.2.5-.8.8-1.3.8Z"/>',
  briefcase: '<rect x="3.5" y="7" width="17" height="12" rx="2"/><path d="M9 7V5.5c0-.6.4-1 1-1h4c.6 0 1 .4 1 1V7"/><path d="M3.5 12.5h17"/>',
  lock: '<rect x="5" y="10.5" width="14" height="9.5" rx="2"/><path d="M8.5 10.5V8a3.5 3.5 0 0 1 7 0v2.5"/>',
  image: '<rect x="3.5" y="4.5" width="17" height="15" rx="2.2"/><circle cx="9" cy="10" r="1.6"/><path d="m20.5 16-4.8-4.8L7 19.5"/>',
  file: '<path d="M14 3.5H7.2c-1 0-1.7.8-1.7 1.7v13.6c0 1 .8 1.7 1.7 1.7h9.6c1 0 1.7-.8 1.7-1.7V8Z"/><path d="M14 3.5V8h4.5"/>',
  link: '<path d="M10 14a4 4 0 0 0 5.7 0l3-3a4 4 0 0 0-5.7-5.7l-1 1"/><path d="M14 10a4 4 0 0 0-5.7 0l-3 3a4 4 0 0 0 5.7 5.7l1-1"/>',
  globe: '<circle cx="12" cy="12" r="8.5"/><path d="M3.5 12h17"/><path d="M12 3.5c2.3 2.4 3.4 5.2 3.4 8.5s-1.1 6.1-3.4 8.5c-2.3-2.4-3.4-5.2-3.4-8.5S9.7 5.9 12 3.5Z"/>',
  text: '<path d="M5 6.5h14"/><path d="M5 11h14"/><path d="M5 15.5h9"/>',
  share: '<path d="M12 15V4"/><path d="m8 7.5 4-4 4 4"/><path d="M5.5 12v6.3c0 .9.8 1.7 1.7 1.7h9.6c.9 0 1.7-.8 1.7-1.7V12"/>',
  x: '<path d="M6 6l12 12M18 6 6 18"/>',
  left: '<path d="m14.5 6-6 6 6 6"/>',
  right: '<path d="m9.5 6 6 6-6 6"/>',
  zoomIn: '<circle cx="11" cy="11" r="6.5"/><path d="m20 20-4.2-4.2M11 8.3v5.4M8.3 11h5.4"/>',
  zoomOut: '<circle cx="11" cy="11" r="6.5"/><path d="m20 20-4.2-4.2M8.3 11h5.4"/>',
  fit: '<path d="M4 9V5.2c0-.7.5-1.2 1.2-1.2H9M15 4h3.8c.7 0 1.2.5 1.2 1.2V9M20 15v3.8c0 .7-.5 1.2-1.2 1.2H15M9 20H5.2c-.7 0-1.2-.5-1.2-1.2V15"/>',
  save: '<path d="M12 4v10.5"/><path d="m7.5 10 4.5 4.5 4.5-4.5"/><path d="M5 19.5h14"/>',
  plus: '<path d="M12 5v14M5 12h14"/>',
  sparkles: '<path d="M11 4.5 12.6 9l4.4 1.6-4.4 1.6L11 16.7l-1.6-4.5L5 10.6 9.4 9Z"/><path d="M17.5 14.5l.8 2.2 2.2.8-2.2.8-.8 2.2-.8-2.2-2.2-.8 2.2-.8Z"/>',
  mic: '<rect x="9" y="3.5" width="6" height="11" rx="3"/><path d="M5.5 11.5a6.5 6.5 0 0 0 13 0M12 18v2.5"/>',
  code: '<path d="m8.5 7.5-4.5 4.5 4.5 4.5M15.5 7.5l4.5 4.5-4.5 4.5M13.3 5l-2.6 14"/>',
  mail: '<rect x="3.5" y="5.5" width="17" height="13" rx="2.2"/><path d="m4.5 7 7.5 6 7.5-6"/>',
  phone: '<path d="M6.2 4h2.6l1.6 4-2 1.3a10.5 10.5 0 0 0 6.3 6.3l1.3-2 4 1.6v2.6c0 .9-.8 1.7-1.7 1.7C10.4 19.5 4.5 13.6 4.5 5.7 4.5 4.8 5.3 4 6.2 4Z"/>',
  palette: '<path d="M12 3.5a8.5 8.5 0 1 0 0 17c1.1 0 1.7-.9 1.4-1.8-.4-1.2.4-2.4 1.7-2.4h2.1a3.3 3.3 0 0 0 3.3-3.3c0-5.2-3.8-9.5-8.5-9.5Z"/><circle cx="7.8" cy="11" r="1"/><circle cx="10.5" cy="7.5" r="1"/><circle cx="15" cy="7.8" r="1"/>',
  settings: '<circle cx="12" cy="12" r="3"/><path d="M12 3.5v2M12 18.5v2M3.5 12h2M18.5 12h2M6 6l1.4 1.4M16.6 16.6 18 18M6 18l1.4-1.4M16.6 7.4 18 6"/>',
  external: '<path d="M13.5 4.5h6v6"/><path d="m19.5 4.5-8.5 8.5"/><path d="M17.5 13.5v4.3c0 .9-.8 1.7-1.7 1.7H6.2c-.9 0-1.7-.8-1.7-1.7V8.2c0-.9.8-1.7 1.7-1.7h4.3"/>',
  check: '<path d="m5 12.5 4.5 4.5L19 7.5"/>',
  eye: '<path d="M2.5 12S6 5.5 12 5.5 21.5 12 21.5 12 18 18.5 12 18.5 2.5 12 2.5 12Z"/><circle cx="12" cy="12" r="2.8"/>',
  more: '<circle cx="6" cy="12" r="1.2" fill="currentColor"/><circle cx="12" cy="12" r="1.2" fill="currentColor"/><circle cx="18" cy="12" r="1.2" fill="currentColor"/>',
  cloud: '<path d="M7.5 18.5h9.8a4.2 4.2 0 0 0 .6-8.4A6 6 0 0 0 6.4 11a3.8 3.8 0 0 0 1.1 7.5Z"/>',
  star: '<path d="m12 4 2.4 5 5.3.6-3.9 3.7 1 5.3L12 16l-4.8 2.6 1-5.3-3.9-3.7 5.3-.6Z"/>',
  heart: '<path d="M12 19.5s-7.5-4.4-7.5-10A4.3 4.3 0 0 1 12 7a4.3 4.3 0 0 1 7.5 2.5c0 5.6-7.5 10-7.5 10Z"/>',
  bookmark: '<path d="M7 4.5h10v15l-5-3.5-5 3.5Z"/>',
};

export const COLLECTION_ICONS = ['folder', 'briefcase', 'lock', 'star', 'heart', 'bookmark', 'code', 'sparkles'];

export function icon(name: string, size = 16, cls = ''): string {
  const body = P[name] ?? P.folder;
  return `<svg class="ic ${cls}" width="${size}" height="${size}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${body}</svg>`;
}
