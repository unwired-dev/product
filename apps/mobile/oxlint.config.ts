import { correctness, presets } from '@effect/tsgo/oxlint-presets';
import { buildOxlintConfig } from '@rajzik/oxlint-config';

export default buildOxlintConfig({
  react: true,
  overrides: {
    extends: [correctness],
    ignorePatterns: ['ios/**', '.expo/**', 'dist/**'],
    rules: {
      // The shared config enables all categories; select Effect rule sets explicitly.
      ...Object.fromEntries(
        Object.values(presets).flatMap((preset) =>
          Object.keys(preset.rules ?? {}).map((rule) => [rule, 'allow']),
        ),
      ),
      ...correctness.rules,
      'eslint/one-var': 'allow',
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
    ],
  },
});
