import { readFileSync } from 'node:fs';

import {
  channelsOf,
  palette,
  profilePalette,
  radius,
  spacing,
} from '@private-email/mail-core/theme';
import * as Schema from 'effect/Schema';

// The Figma file's variables, as scripts/export-figma-variables.js exports them. A new collection or
// mode fails to decode until theme.ts and this test learn it.
const Value = Schema.Union([Schema.String, Schema.Finite]);
const snapshot = Schema.decodeSync(
  Schema.fromJsonString(
    Schema.Struct({
      fileKey: Schema.String,
      exportedAt: Schema.String,
      collections: Schema.Tuple([
        Schema.Struct({
          name: Schema.Literal('Unwired'),
          modes: Schema.Tuple([
            Schema.Literal('Light'),
            Schema.Literal('Dark'),
          ]),
          variables: Schema.Record(
            Schema.String,
            Schema.Struct({ Light: Value, Dark: Value }),
          ),
        }),
      ]),
    }),
  ),
)(readFileSync(new URL('figma-variables.json', import.meta.url), 'utf8'));

type Token = typeof Value.Type;

// Variables whose theme.ts name leaves out their group.
const renamed: Record<string, string> = {
  'accent/focus-ring': 'focusRing',
  'material/glass-tint': 'glassTint',
};

// theme.ts names a variable in camel case: `accent/fill` is `accentFill`, `radius/ipad-sheet` is
// `radius.ipadSheet` and `profile/blue` is `profilePalette.blue`.
const tokenName = (variable: string) =>
  renamed[variable] ??
  variable.replaceAll(/[/-]\w/gu, (separated) =>
    separated.slice(1).toUpperCase(),
  );
const grouped = (group: string, tokens: Record<string, Token>) =>
  Object.entries(tokens).map(
    ([name, value]) =>
      [
        `${group}${name.charAt(0).toUpperCase()}${name.slice(1)}`,
        value,
      ] as const,
  );
const themeTokens = (mode: 'light' | 'dark') =>
  new Map<string, Token>([
    ...Object.entries(palette[mode]),
    ...grouped('profile', profilePalette[mode]),
    ...grouped('space', spacing),
    ...grouped('radius', radius),
  ]);

// theme.ts tokens with no Figma variable. Each is deliberate; a new token joins the variables or
// this list.
const codeOnly = new Set([
  // Mac Liquid Glass and shadows: composite effects and AppKit equivalents measured against the
  // frames, which a single color or number variable cannot hold.
  'macGlassFill',
  'macGlassOpacity',
  'macGlassEdge',
  'macSearchGlassEdge',
  'macPanelGlassEdge',
  'macPanelGlassFill',
  'smallGlassShadow',
  'largeGlassShadow',
  'menuGlassShadow',
  'macMenuGlassShadow',
  'menuShadow',
  'toastShadow',
  // Graphite is `brand/monogram`.
  'profileGraphite',
  // Single values with no variable yet.
  'statusSuccess',
  'radiusMenu',
  'radiusAlertMac',
  'radiusAlertTouch',
  'radiusTouchMenu',
  'radiusTouchMenuItem',
  'radiusSearchField',
]);

// `transparent`, `#RRGGBB` or `rgba(r, g, b, a)`; any other format never matches.
const rgba = (color: string) => {
  if (color === 'transparent') {
    return [0, 0, 0, 0];
  }
  if (/^#[\dA-F]{6}$/iu.test(color)) {
    return [...channelsOf(color), 1];
  }
  const channels =
    /^rgba\((?<red>\d+), (?<green>\d+), (?<blue>\d+), (?<alpha>[\d.]+)\)$/u.exec(
      color,
    )?.groups;
  return channels
    ? [channels.red, channels.green, channels.blue, channels.alpha].map(Number)
    : [Number.NaN];
};
// Figma stores numbers as 32-bit floats.
const near = (left: number, right: number | undefined) =>
  right !== undefined && Math.abs(left - right) < 0.001;
// A transparent Figma color keeps its channels; theme.ts writes `transparent`.
const sameColor = (left: string, right: string) => {
  const [expected, actual] = [rgba(left), rgba(right)];
  return (
    (expected[3] === 0 && actual[3] === 0) ||
    expected.every((channel, index) => near(channel, actual[index]))
  );
};
const same = (variable: Token, token: Token | undefined) =>
  typeof variable === 'number'
    ? typeof token === 'number' && near(variable, token)
    : typeof token === 'string' && sameColor(variable, token);

const [{ variables }] = snapshot.collections;
const modes = { Light: 'light', Dark: 'dark' } as const;
const differences = Object.entries(variables).flatMap(([variable, values]) =>
  (['Light', 'Dark'] as const)
    .map((mode) => ({
      variable,
      mode,
      figma: values[mode],
      token: themeTokens(modes[mode]).get(tokenName(variable)),
    }))
    .filter(({ figma, token }) => !same(figma, token)),
);
const covered = new Set(Object.keys(variables).map(tokenName));
const unlisted = [
  ...new Set([...themeTokens('light').keys(), ...themeTokens('dark').keys()]),
].filter((name) => !covered.has(name) && !codeOnly.has(name));

describe('theme.ts against the Figma variables', () => {
  it('holds each variable in Light and Dark', () => {
    expect.assertions(1);
    expect(differences).toStrictEqual([]);
  });

  it('lists every token without a variable', () => {
    expect.assertions(2);
    expect(unlisted).toStrictEqual([]);
    expect([...codeOnly].filter((name) => covered.has(name))).toStrictEqual([]);
  });
});
