import * as Vitest from '@effect/vitest';
import * as Effect from 'effect/Effect';
import PostalMime from 'postal-mime';

import type { GmailPart } from '../src/message-body.ts';

import { bodyParts, partText } from '../src/message-body.ts';
import { parseMime } from '../src/mime.ts';

// A part's text as the reader decodes it; absent parts read as undefined.
const decoded = (part: GmailPart | undefined) =>
  part === undefined ? Effect.void : partText(part, part.body?.data ?? '');

const treeOf = (bytes: Readonly<Uint8Array>) => {
  const tree = parseMime(bytes);
  if (tree === undefined) {
    throw new Error('Expected a MIME tree');
  }
  return tree;
};

const crlf = (lines: readonly string[]) => lines.join('\r\n');

describe('parsing raw IMAP messages into MIME trees', () => {
  const corpus = [
    crlf([
      'Subject: Plain',
      'Content-Type: text/plain; charset=utf-8',
      'Content-Transfer-Encoding: quoted-printable',
      '',
      'Soft =',
      'break and =C3=A9 accent',
    ]),
    crlf([
      'Subject: Alternative',
      'Content-Type: multipart/alternative; boundary=b1',
      '',
      'preamble',
      '--b1',
      'Content-Type: text/plain',
      '',
      'Plain text',
      '--b1',
      'Content-Type: text/html; charset="utf-8"',
      'Content-Transfer-Encoding: base64',
      '',
      btoa('<b>Bold</b>'),
      '--b1--',
      'epilogue',
    ]),
    // LF line endings and a missing close delimiter still end the last part.
    [
      'Subject: Unclosed',
      'Content-Type: multipart/mixed; boundary="u"',
      '',
      '--u',
      'Content-Type: text/plain',
      '',
      'Last part',
    ].join('\n'),
  ];

  // oxlint-disable-next-line vitest/require-hook -- This @effect/vitest call declares parameterized tests, not setup work.
  Vitest.it.effect.each(corpus)(
    'reads the same readable text as a reference parser (%#)',
    (raw) =>
      Effect.gen(function* () {
        /* oxlint-disable vitest/no-standalone-expect -- Oxlint does not recognize the @effect/vitest effect callback. */
        expect.hasAssertions();
        const bytes = new TextEncoder().encode(raw);
        const { text, html } = bodyParts(treeOf(bytes));
        const reference = yield* Effect.promise(() => PostalMime.parse(bytes));
        const [plain, rich] = yield* Effect.all([decoded(text), decoded(html)]);
        expect(plain?.trim()).toBe(reference.text?.trim());
        expect(rich?.trim()).toBe(reference.html?.trim());
        /* oxlint-enable vitest/no-standalone-expect */
      }),
  );

  it('retains multipart and HTML media types when the host omits named capture groups', () => {
    expect.hasAssertions();
    const { exec } = RegExp.prototype;
    const transformed = vi
      .spyOn(RegExp.prototype, 'exec')
      .mockImplementation(function (this: RegExp, text: string) {
        const match = exec.call(this, text);
        // oxlint-disable-next-line vitest/no-conditional-in-test -- Simulates the host transform only for successful regex matches.
        if (match !== null) {
          delete match.groups;
        }
        return match;
      });
    try {
      const tree = treeOf(new TextEncoder().encode(corpus[1]));
      const { text, html } = bodyParts(tree);
      expect(tree.mimeType).toBe('multipart/alternative');
      expect(text?.mimeType).toBe('text/plain');
      expect(html?.mimeType).toBe('text/html');
      // A quoted boundary with a quoted-pair still unescapes to the delimiter the parts use.
      const escaped = treeOf(
        new TextEncoder().encode(
          crlf([
            String.raw`Content-Type: multipart/mixed; boundary="part\=one"`,
            '',
            '--part=one',
            'Content-Type: text/plain',
            '',
            'Escaped boundary',
            '--part=one--',
          ]),
        ),
      );
      expect(escaped.parts?.map(({ mimeType }) => mimeType)).toStrictEqual([
        'text/plain',
      ]);
    } finally {
      transformed.mockRestore();
    }
  });

  it('refuses a tree deeper than the reader walks', () => {
    expect.hasAssertions();
    const nested = Array.from(
      { length: 40 },
      (_, depth) =>
        `Content-Type: multipart/mixed; boundary="d${depth}"\r\n\r\n--d${depth}\r\n`,
    ).join('');
    expect(parseMime(new TextEncoder().encode(nested))).toBeUndefined();
  });

  it('refuses excessive MIME parts before walking the remaining siblings', () => {
    expect.hasAssertions();
    const raw = `Content-Type: multipart/mixed; boundary=p\r\n\r\n${'--p\r\n\r\nx\r\n'.repeat(20_000)}--p--\r\n`;
    const bytes = new TextEncoder().encode(raw);
    const encoder = vi.spyOn(Uint8Array, 'from');
    try {
      expect(parseMime(bytes)).toBeUndefined();
      // Header and leaf decoding must stop at the cap rather than visit all siblings.
      expect(encoder.mock.calls.length).toBeLessThan(20_000);
    } finally {
      encoder.mockRestore();
    }
  });
});
