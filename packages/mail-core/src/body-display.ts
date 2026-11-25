import type { Block, BlockKind } from './semantic-document.ts';

import { channelsOf, luminanceOf, palette } from './theme.ts';

// How a Semantic Message Document body shows: list markers and the stored fonts and colors. It
// imports no schema library, so the Draft editor page can bundle it.

type Line = Pick<Block, 'kind' | 'indent'>;
type Span = Block['spans'][number];

export const isListKind = (kind: BlockKind) =>
  kind === 'bulleted' || kind === 'numbered';

// Each numbered item's number, zero for any other block. Consecutive numbered items of one level
// count from one, across items nested between them; any block that is not a list item restarts
// every count, and a bulleted item restarts its level's.
export const listNumbersOf = (lines: readonly Line[]) => {
  const levels: Array<Readonly<{ kind: BlockKind; count: number }>> = [];
  return lines.map(({ kind, indent = 0 }) => {
    if (!isListKind(kind)) {
      levels.length = 0;
      return 0;
    }
    levels.length = Math.min(levels.length, indent + 1);
    const previous = levels[indent];
    const count = previous?.kind === kind ? previous.count + 1 : 1;
    levels[indent] = { kind, count };
    return kind === 'numbered' ? count : 0;
  });
};

// One level of nesting before a list marker: an em and an en space, about the 25pt the frames
// indent each level at the body's size.
const nesting = '\u2003\u2002';

// Each line's list marker, empty for any other block.
export const markersOf = (lines: readonly Line[]) => {
  const numbers = listNumbersOf(lines);
  return lines.map(({ kind, indent = 0 }, index) => {
    if (!isListKind(kind)) {
      return '';
    }
    return (
      nesting.repeat(indent) +
      (kind === 'bulleted' ? '• ' : `${numbers[index] ?? 1}. `)
    );
  });
};

const darkSurface = luminanceOf(channelsOf(palette.dark.surfaceContent));

// An authored text color as Dark shows it on `surface/content`; near-black explicitly uses
// text/primary, including inside a quote with secondary ink. Below 4.5:1 it lightens toward white
// a tenth at a time.
const darkTextColor = (color: string) => {
  const channels = channelsOf(color);
  if (luminanceOf(channels) < 0.02) {
    return palette.dark.textPrimary;
  }
  for (let tenths = 0; ; tenths += 1) {
    const shown = channels.map((channel) =>
      Math.round(channel + ((255 - channel) * tenths) / 10),
    );
    if ((luminanceOf(shown) + 0.05) / (darkSurface + 0.05) >= 4.5) {
      return `#${shown.map((channel) => channel.toString(16).padStart(2, '0')).join('')}`;
    }
  }
};

// CSS generic families show in the matching system design.
const genericFamilies = new Map([
  ['serif', 'ui-serif'],
  ['sans-serif', 'system-ui'],
  ['monospace', 'ui-monospace'],
]);

// The first family of a stored list; a host shows its system font when that one is missing.
const familyOf = (font: string) => {
  const { 0: name = font, groups } =
    /^"(?<quoted>[^"]+)"|^[^,]+/u.exec(font) ?? {};
  return groups?.quoted ?? genericFamilies.get(name.toLowerCase()) ?? name;
};

// How a span's stored font and colors show. Light shows authored colors as stored; Dark adapts
// text colors, except on an authored background, whose text keeps Light ink. Nothing is stored.
export function formatStyleOf(span: Span, appearance: 'light' | 'dark') {
  if ('image' in span) {
    return {};
  }
  const { background, font, size } = span;
  let { color } = span;
  if (background !== undefined) {
    color ??= palette.light.textPrimary;
  } else if (appearance === 'dark' && color !== undefined) {
    color = darkTextColor(color);
  }
  return {
    ...(color === undefined ? {} : { color }),
    ...(background === undefined ? {} : { backgroundColor: background }),
    ...(font === undefined ? {} : { fontFamily: familyOf(font) }),
    // The approved frames lead sized text at 1.35.
    ...(size === undefined
      ? {}
      : { fontSize: size, lineHeight: Math.round(size * 1.35) }),
  };
}
