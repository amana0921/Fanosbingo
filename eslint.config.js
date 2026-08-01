import js from '@eslint/js';
import globals from 'globals';
import reactHooks from 'eslint-plugin-react-hooks';
import reactRefresh from 'eslint-plugin-react-refresh';
import tseslint from 'typescript-eslint';

export default tseslint.config(
  { ignores: ['dist'] },
  {
    extends: [js.configs.recommended, ...tseslint.configs.recommended],
    files: ['**/*.{ts,tsx}'],
    languageOptions: {
      ecmaVersion: 2020,
      globals: globals.browser,
    },
    plugins: {
      'react-hooks': reactHooks,
      'react-refresh': reactRefresh,
    },
    rules: {
      ...reactHooks.configs.recommended.rules,
      'react-refresh/only-export-components': [
        'warn',
        { allowConstantExport: true },
      ],

      // Make the underscore convention the codebase already uses actually work.
      //
      // `_cardLayout` in src/App.tsx is deliberately accepted and ignored -- the
      // server derives the card layout, and the parameter stays only because
      // Lobby still passes it. tsc honours the leading underscore; eslint did
      // not, so the file has been carrying an error for a convention it was
      // following correctly. `_user` joined it for the same reason.
      //
      // Applied to arguments and to caught errors, not to variables: an unused
      // local is usually a mistake, where an unused parameter in the middle of a
      // signature cannot be removed without changing every caller.
      '@typescript-eslint/no-unused-vars': [
        'error',
        {
          argsIgnorePattern: '^_',
          caughtErrorsIgnorePattern: '^_',
          varsIgnorePattern: '^_',
        },
      ],
    },
  }
);
