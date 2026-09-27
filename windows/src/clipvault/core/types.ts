// ClipVault (Windows) – data model.
// Field names follow the Mac ClipVault's index.json (PROTOCOL.md §2) so both formats stay readable
// by the same tools. Windows-only fields are optional additions.

export type ItemKind = 'text' | 'image' | 'file';

export interface FileRef {
  /** display name (basename) */
  name: string;
  /** path of the stored copy relative to the data dir, or null (folder / too large) */
  stored: string | null;
  /** absolute original path (may be gone by now) */
  orig: string;
  /** bytes of the stored copy (Windows addition) */
  size?: number;
}

export interface ClipItem {
  id: string;
  kind: ItemKind;
  text?: string | null;
  /** image file name relative to the data dir (kind === 'image') */
  image?: string | null;
  files?: FileRef[] | null;
  /** last used, unix seconds */
  ts: number;
  source?: string | null;
  pinned?: boolean;
  /** collection ("Bereich") id or null = plain history */
  collection?: string | null;
  ocrText?: string | null;
  shared?: boolean;
  collectedAt?: number | null;
  edited?: number | null;
  origin?: string | null;
  /** info only, recomputed on save */
  badges?: string[];
  // ---- Windows additions ----
  /** thumbnail file relative to the data dir (images) */
  thumb?: string | null;
  /** pixel size of the image */
  w?: number;
  h?: number;
  /** perceptual print for dedupe: 16×16 gray as hex (512 chars) */
  print?: string | null;
  /** bytes this entry occupies on disk (image + thumb + stored files), for the quota */
  bytes?: number;
}

export interface Collection {
  id: string;
  name: string;
  /** icon key (Windows: a small set of built-in glyph names, see ui/icons.ts) */
  symbol: string;
  /** secret collection: masked + expires 24 h after collectedAt unless pinned */
  secret?: boolean;
}

export type TypeFilter = 'all' | 'text' | 'links' | 'images' | 'files';

export interface StoreLimits {
  /** history age in seconds (default 2 days) */
  maxAgeSec: number;
  /** max history entries (pinned + collection entries don't count) */
  maxItems: number;
  /** total bytes for images/files of *history* entries before the oldest are dropped */
  quotaBytes: number;
  /** secret collection TTL (24 h) */
  secretTtlSec: number;
  /** largest single file copied into the vault */
  maxFileCopyBytes: number;
}

export const DEFAULT_LIMITS: StoreLimits = {
  maxAgeSec: 2 * 24 * 3600,
  maxItems: 200,
  quotaBytes: 1024 * 1024 * 1024,
  secretTtlSec: 24 * 3600,
  maxFileCopyBytes: 200 * 1024 * 1024,
};

/** What the UI receives (no absolute paths needed except for "show in Explorer"). */
export interface ItemView {
  id: string;
  kind: ItemKind;
  isLink: boolean;
  title: string;
  subtitle: string;
  badges: string[];
  ts: number;
  pinned: boolean;
  collection: string | null;
  masked: boolean;
  shared: boolean;
  source: string | null;
  /** file: URL of the thumbnail (images) */
  thumbUrl?: string;
  /** file: URL of the full image (viewer); UI falls back to invoke('image') */
  imageUrl?: string;
  w?: number;
  h?: number;
  fileNames?: string[];
  /** full text, only for non-masked text items (preview pane) */
  text?: string;
  color?: string;
  expiresInH?: number | null;
}
