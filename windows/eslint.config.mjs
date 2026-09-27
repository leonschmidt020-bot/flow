import js from '@eslint/js';
import tseslint from 'typescript-eslint';

export default tseslint.config(
  { ignores: ['dist/**', 'dist-scripts/**', 'release/**', 'node_modules/**', '.cache/**', 'src/clipvault/**'] },
  js.configs.recommended,
  ...tseslint.configs.recommended,
  {
    languageOptions: { ecmaVersion: 2023, sourceType: 'module', globals: { console: 'readonly', process: 'readonly', __dirname: 'readonly', require: 'readonly', Buffer: 'readonly', setTimeout: 'readonly', clearTimeout: 'readonly', setInterval: 'readonly' } },
    rules: {
      '@typescript-eslint/no-unused-vars': ['error', { argsIgnorePattern: '^_', varsIgnorePattern: '^_' }],
      'no-empty': ['error', { allowEmptyCatch: true }],
      '@typescript-eslint/no-require-imports': 'off',
    },
  },
  { files: ['**/*.cjs'], languageOptions: { sourceType: 'commonjs' } },
);
