// electron-builder config. Release/update source comes from release.config.json (the one place).
const release = require('./release.config.json');

const FILES = ['dist/**/*', '!dist/**/*.map', 'package.json'];

/** @type {import('electron-builder').Configuration} */
module.exports = {
  appId: 'app.flowdictation.flow',
  productName: 'Flow',
  copyright: 'Flow contributors · MIT',
  directories: { output: 'release', buildResources: 'build' },
  files: FILES,
  asar: true,
  // native modules (prebuilt N-API binaries + their DLLs) must live outside the asar
  asarUnpack: [
    '**/node_modules/sherpa-onnx-*/**',
    '**/node_modules/uiohook-napi/**',
    '**/node_modules/koffi/**',
    '**/node_modules/@koromix/**',
    // UI Automation helper script is run by powershell.exe, which cannot read files inside app.asar
    'dist/helpers/**',
  ],
  npmRebuild: false, // all native deps are N-API prebuilds – nothing to compile
  win: {
    target: [{ target: 'nsis', arch: ['x64'] }],
    // keep only the Windows x64 native binaries
    files: [
      ...FILES,
      '!**/node_modules/sherpa-onnx-{darwin,linux}-*/**',
      '!**/node_modules/sherpa-onnx-win-ia32/**',
      '!**/node_modules/@koromix/koffi-{darwin,linux,freebsd,openbsd,musl}*/**',
      '!**/node_modules/uiohook-napi/prebuilds/{darwin,linux}-*/**',
      '!**/node_modules/uiohook-napi/prebuilds/win32-arm64/**',
      '!**/node_modules/uiohook-napi/{src,libuiohook}/**',
      '!**/node_modules/koffi/{src,vendor,doc}/**',
    ],
    icon: 'build/icon.ico',
    artifactName: 'Flow-Setup-${version}.${ext}',
  },
  nsis: {
    oneClick: true,
    perMachine: false, // per-user install: no admin rights needed
    createDesktopShortcut: true,
    createStartMenuShortcut: true,
    shortcutName: 'Flow',
    uninstallDisplayName: 'Flow',
    deleteAppDataOnUninstall: false,
    runAfterFinish: true,
  },
  mac: { target: 'dir', icon: 'build/icon.png', category: 'public.app-category.productivity' },
  publish: [{ provider: 'github', owner: release.owner, repo: release.repo, releaseType: 'release' }],
};
