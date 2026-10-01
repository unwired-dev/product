import type { DummyRuleMap } from 'oxlint';

import * as EffectPresets from '@effect/tsgo/oxlint-presets';

// Effect code uses Effect services for console, time, randomness, HTTP, JSON and configuration.
const effectNativeRules: DummyRuleMap = Object.fromEntries(
  [
    'crypto-random-uuid-in-effect',
    'global-console-in-effect',
    'global-date-in-effect',
    'global-fetch-in-effect',
    'global-random-in-effect',
    'global-timers-in-effect',
    'prefer-schema-over-json',
    'process-env-in-effect',
  ].map((rule) => [`effecttsgo/${rule}`, 'deny']),
);

// The shared config enables all categories; select Effect rule sets explicitly.
export const effectRules: DummyRuleMap = {
  ...Object.fromEntries(
    Object.values(EffectPresets.presets).flatMap((preset) =>
      Object.keys(preset.rules ?? {}).map((rule) => [rule, 'allow']),
    ),
  ),
  ...EffectPresets.recommended.rules,
  ...effectNativeRules,
  // Effect values are immutable descriptions, though their types are not deeply readonly.
  'typescript/prefer-readonly-parameter-types': [
    'warn',
    {
      allow: [{ from: 'package', package: 'effect', name: ['Effect'] }],
      ignoreInferredTypes: true,
      treatMethodsAsReadonly: true,
    },
  ],
  // Schema.TaggedError<Self>()(…) is a class factory, not an Error call missing `new`.
  'unicorn/throw-new-error': 'allow',
};

// Untrusted input is decoded with Schema; errors are tagged.
export const boundaryRules: DummyRuleMap = {
  'effect-boundaries/no-json-parse': 'deny',
  'effect-boundaries/no-object-typeof-guard': 'deny',
  'effecttsgo/extends-native-error': 'deny',
};

export const boundaryExemptions: DummyRuleMap = Object.fromEntries(
  Object.keys(boundaryRules).map((rule) => [rule, 'allow']),
);
