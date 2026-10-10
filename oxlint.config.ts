import type { DummyRuleMap } from 'oxlint';

import convexPlugin from '@convex-dev/eslint-plugin';
import * as EffectPresets from '@effect/tsgo/oxlint-presets';
import { buildOxlintConfig } from '@rajzik/oxlint-config';

import {
  boundaryExemptions,
  boundaryRules,
  effectRules,
} from './scripts/oxlint-effect-policy.ts';

// oxlint-disable-next-line typescript/no-unsafe-type-assertion -- the plugin declares its recommended configuration as `any`.
const convexRecommended = convexPlugin.configs.recommended as ReadonlyArray<{
  files: string[];
  rules: DummyRuleMap;
}>;

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
      ...convexRecommended.map(({ files, rules }) => ({
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
        // Metro loads repository build helpers as CommonJS modules.
        files: ['scripts/**/*.cjs'],
        rules: {
          'import/unambiguous': 'allow',
          'typescript/no-require-imports': 'allow',
          'typescript/no-var-requires': 'allow',
        },
      },
      {
        // Repository tooling runs as short-lived Node scripts and configures itself from the environment.
        files: ['scripts/**'],
        rules: {
          'node/no-process-env': 'allow',
          'node/no-sync': 'allow',
        },
      },
      {
        files: ['**/*.test.ts', '**/*.test.tsx'],
        // Vitest rule settings only apply where an override enables the plugin.
        plugins: ['vitest'],
        rules: {
          'node/no-sync': 'allow',
          // Conflicts with vitest/prefer-strict-boolean-matchers.
          'vitest/prefer-to-be-falsy': 'allow',
        },
      },
    ],
  },
});
