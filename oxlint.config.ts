import { buildOxlintConfig } from '@rajzik/oxlint-config';

export default buildOxlintConfig({
  jsdoc: true,
  node: true,
  turbo: true,
  overrides: {
    ignorePatterns: ['**/convex/_generated/**'],
    rules: {
      'unicorn/max-nested-calls': 'allow',
    },
    overrides: [
      {
        files: ['packages/mail-test-harness/**/*.ts'],
        rules: {
          'eslint/no-use-before-define': 'allow',
          'node/no-top-level-await': 'allow',
          'promise/avoid-new': 'allow',
          'typescript/prefer-readonly-parameter-types': 'allow',
        },
      },
      {
        files: ['**/*.test.ts'],
        rules: {
          'node/no-sync': 'allow',
        },
      },
    ],
  },
});
