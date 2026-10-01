import convexPlugin from '@convex-dev/eslint-plugin';
import * as EffectPresets from '@effect/tsgo/oxlint-presets';
import { buildOxlintConfig } from '@rajzik/oxlint-config';

import {
  boundaryExemptions,
  boundaryRules,
  effectRules,
} from './scripts/oxlint-effect-policy.ts';

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
      {
        name: 'effect-boundaries',
        specifier: './scripts/oxlint-effect-boundaries.mjs',
      },
      '@convex-dev/eslint-plugin',
    ],
    extends: [EffectPresets.recommended],
    ignorePatterns: ['**/convex/_generated/**'],
    rules: {
      'effect-imports/namespace-imports': 'deny',
      'import/no-namespace': ['warn', { ignore: ['effect/**', '@effect/**'] }],
      ...effectRules,
      ...boundaryRules,
      'unicorn/max-nested-calls': 'allow',
      'eslint/one-var': 'allow',
      // Function declarations are hoisted.
      'eslint/no-use-before-define': ['deny', { functions: false }],
    },
    overrides: [
      ...convexPlugin.configs.recommended.map(({ files, rules }) => ({
        files,
        rules,
      })),
      {
        // Convex documents expose `_id` and `_creationTime`.
        files: ['packages/convex/**/*.ts'],
        rules: {
          'eslint/no-underscore-dangle': 'allow',
          // Convex contexts, documents, and ids are generated mutable types.
          'typescript/prefer-readonly-parameter-types': 'allow',
        },
      },
      {
        // The legacy prototype harness is retired at cutover (#627).
        files: ['packages/mail-test-harness/**/*.ts'],
        rules: {
          ...boundaryExemptions,
          'eslint/no-use-before-define': 'allow',
          'node/no-top-level-await': 'allow',
          'promise/avoid-new': 'allow',
          'typescript/prefer-readonly-parameter-types': 'allow',
        },
      },
      {
        // Tests read trusted fixtures; their assertions check the shape.
        files: ['**/*.test.ts', '**/*.test.tsx'],
        // Vitest rule settings only apply where an override enables the plugin.
        plugins: ['vitest'],
        rules: {
          ...boundaryExemptions,
          'node/no-sync': 'allow',
          // Conflicts with vitest/prefer-strict-boolean-matchers.
          'vitest/prefer-to-be-falsy': 'allow',
        },
      },
    ],
  },
});
