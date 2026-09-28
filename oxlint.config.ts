import { correctness, recommended, presets } from '@effect/tsgo/oxlint-presets';
import { buildOxlintConfig } from '@rajzik/oxlint-config';

export default buildOxlintConfig({
  jsdoc: true,
  node: true,
  turbo: true,
  overrides: {
    extends: [correctness],
    ignorePatterns: ['**/convex/_generated/**'],
    rules: {
      // The shared config enables all categories; select Effect rule sets explicitly.
      ...Object.fromEntries(
        Object.values(presets).flatMap((preset) =>
          Object.keys(preset.rules ?? {}).map((rule) => [rule, 'allow']),
        ),
      ),
      ...correctness.rules,
      'unicorn/max-nested-calls': 'allow',
      'eslint/one-var': 'allow',
    },
    overrides: [
      {
        files: ['packages/mail-core/src/**/*.ts'],
        rules: recommended.rules,
      },
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
