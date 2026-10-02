import * as EffectPresets from '@effect/tsgo/oxlint-presets';
import { buildOxlintConfig } from '@rajzik/oxlint-config';

import {
  boundaryExemptions,
  boundaryRules,
  effectRules,
} from '../../scripts/oxlint-effect-policy.ts';

export default buildOxlintConfig({
  react: true,
  overrides: {
    jsPlugins: [
      {
        name: 'effect-imports',
        specifier: '../../scripts/oxlint-effect-imports.mjs',
      },
      {
        name: 'effect-boundaries',
        specifier: '../../scripts/oxlint-effect-boundaries.mjs',
      },
    ],
    extends: [EffectPresets.recommended],
    ignorePatterns: ['ios/**', '.expo/**', 'dist/**'],
    rules: {
      'effect-imports/namespace-imports': 'deny',
      'import/no-namespace': ['warn', { ignore: ['effect/**', '@effect/**'] }],
      ...effectRules,
      ...boundaryRules,
      'eslint/one-var': 'allow',
      // Function declarations are hoisted.
      'eslint/no-use-before-define': ['deny', { functions: false }],
      'react/forbid-component-props': 'allow',
      'react/jsx-no-literals': 'allow',
      'react/style-prop-object': ['warn', { allow: ['StatusBar'] }],
    },
    overrides: [
      {
        files: ['*.cjs'],
        rules: {
          'import/unambiguous': 'allow',
          'typescript/no-require-imports': 'allow',
          'typescript/no-var-requires': 'allow',
        },
      },
      {
        files: ['**/*.tsx'],
        rules: { 'typescript/prefer-readonly-parameter-types': 'allow' },
      },
      {
        // Tests read trusted fixtures; their assertions check the shape.
        files: ['**/*.test.ts', '**/*.test.tsx'],
        rules: boundaryExemptions,
      },
    ],
  },
});
