import * as EffectPresets from '@effect/tsgo/oxlint-presets';
import { buildOxlintConfig } from '@rajzik/oxlint-config';

export default buildOxlintConfig({
  jsdoc: true,
  node: true,
  turbo: true,
  overrides: {
    jsPlugins: [
      {
        name: 'effect-imports',
        specifier: './scripts/oxlint-effect-imports.mjs',
      },
    ],
    extends: [EffectPresets.correctness],
    ignorePatterns: ['**/convex/_generated/**'],
    rules: {
      'effect-imports/namespace-imports': 'deny',
      'import/no-namespace': ['warn', { ignore: ['effect/**', '@effect/**'] }],
      // The shared config enables all categories; select Effect rule sets explicitly.
      ...Object.fromEntries(
        Object.values(EffectPresets.presets).flatMap((preset) =>
          Object.keys(preset.rules ?? {}).map((rule) => [rule, 'allow']),
        ),
      ),
      ...EffectPresets.correctness.rules,
      'unicorn/max-nested-calls': 'allow',
      'eslint/one-var': 'allow',
    },
    overrides: [
      {
        files: ['packages/mail-core/src/**/*.ts'],
        rules: EffectPresets.recommended.rules,
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
