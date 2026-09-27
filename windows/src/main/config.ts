import release from '../../release.config.json';

declare const __FLOW_VERSION__: string;
export const VERSION: string = typeof __FLOW_VERSION__ === 'string' ? __FLOW_VERSION__ : '0.0.0-dev';
export const RELEASE = release as { provider: 'github'; owner: string; repo: string; homepage: string };
export const APP_ID = 'app.flowdictation.flow';
