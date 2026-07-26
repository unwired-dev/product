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
        files: ['**/*.test.ts'],
        rules: {
          'node/no-sync': 'allow',
        },
      },
    ],
  },
});
