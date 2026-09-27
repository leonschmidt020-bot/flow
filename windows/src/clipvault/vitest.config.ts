// Local vitest config for the ClipVault module only (Flow's own config also picks up src/**/*.test.ts).
// Standalone use without windows/node_modules (tooling installed elsewhere):
//   CV_TOOL_NODE_MODULES=/path/to/node_modules npx vitest run --config src/clipvault/vitest.config.ts
// No import from 'vitest/config' on purpose – this file must load even when vitest lives elsewhere.
import * as os from 'node:os';
import * as path from 'node:path';

const tool = process.env.CV_TOOL_NODE_MODULES;

export default {
  root: __dirname,
  cacheDir: path.join(os.tmpdir(), 'clipvault-vitest-cache'), // keep the repo clean
  resolve: tool ? { alias: { vitest: path.join(tool, 'vitest', 'dist', 'index.js') } } : undefined,
  test: {
    environment: 'node',
    include: ['**/*.test.ts'],
    exclude: ['**/node_modules/**'],
    testTimeout: 20000,
  },
};
