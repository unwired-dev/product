import PostalMime from 'postal-mime';

import type { Draft } from '../src/drafts.ts';

import { base64Lines, outgoingMessage } from '../src/outgoing-message.ts';

const draft = (patch: Partial<Draft> = {}): Draft => ({
  id: 'd1',
  connection: 'connection-alex',
  from: 'alex@example.invalid',
  to: [{ address: 'sam@example.invalid' }],
  cc: [],
  bcc: [],
  subject: 'Hello',
  body: [{ kind: 'paragraph', spans: [{ text: 'Hi' }] }],
  updatedAt: 0,
  ...patch,
});

const bytes = new Map([
  ['a1b2c3d4e5', new TextEncoder().encode('x'.repeat(200))],
]);
const assemble = (message: ReturnType<typeof outgoingMessage>) =>
  message.segments
    .map((segment) =>
      'text' in segment
        ? segment.text
        : base64Lines(bytes.get(segment.asset.id) ?? new Uint8Array()),
    )
    .join('');
const build = (next: Draft) =>
  outgoingMessage(next, { date: Date.UTC(2026, 9, 9, 8, 5, 3), boundary: 'b' });

describe('building an outgoing message', () => {
  /* oxlint-disable vitest/max-expects -- Each message checks its whole header block and parsed result. */
  it('keeps headers on folded lines, encodes what is not ASCII and counts its exact size', async () => {
    expect.hasAssertions();
    const recipients = [
      { name: 'Ševčík, Jan', address: 'person0@example.invalid' },
      ...Array.from({ length: 11 }, (_, index) => ({
        name: `Person "${index + 1}"`,
        address: `person${index + 1}@example.invalid`,
      })),
    ];
    const message = build(
      draft({
        to: recipients,
        // A line break in a name or subject must not start another header.
        subject: 'Plán\r\nBcc: someone@example.invalid',
        attachments: [
          {
            id: 'a1b2c3d4e5',
            name: 'zpráva o stavu.txt',
            type: 'text/plain\r\nX-Injected: yes',
            state: 'complete',
            size: 200,
            digest: '0'.repeat(64),
          },
        ],
      }),
    );
    const raw = assemble(message);

    expect(message.size).toBe(new TextEncoder().encode(raw).length);
    const [head = ''] = raw.split('\r\n\r\n');
    const lines = head.split('\r\n');
    expect(lines.every((line) => line.length <= 78)).toBe(true);
    expect(lines.filter((line) => line.startsWith('Bcc:'))).toStrictEqual([]);
    expect(raw).not.toContain('X-Injected');
    expect(head).toContain('Date: Fri, 09 Oct 2026 08:05:03 +0000');
    const parsed = await PostalMime.parse(raw);
    expect(parsed.subject).toBe('Plán Bcc: someone@example.invalid');
    expect(parsed.to).toStrictEqual(recipients);
    expect(parsed.bcc).toBeUndefined();
    expect(
      parsed.attachments.map(({ filename, mimeType }) => ({
        filename,
        mimeType,
      })),
    ).toStrictEqual([
      { filename: 'zpráva o stavu.txt', mimeType: 'application/octet-stream' },
    ]);
  });

  it('renders headings, lists, quotes and code with a readable plain-text alternative', async () => {
    expect.hasAssertions();
    const parsed = await PostalMime.parse(
      assemble(
        build(
          draft({
            body: [
              { kind: 'heading2', spans: [{ text: 'Agenda' }] },
              { kind: 'numbered', spans: [{ text: 'First' }] },
              {
                kind: 'numbered',
                spans: [{ text: 'Second', marks: ['italic'] }],
              },
              { kind: 'bulleted', spans: [{ text: 'a < b & c' }] },
              { kind: 'paragraph', spans: [] },
              { kind: 'code', spans: [{ text: 'let x = 1;' }] },
              { kind: 'code', spans: [{ text: 'x += 1;' }] },
              { kind: 'quote', spans: [{ text: 'Quoted', marks: ['code'] }] },
            ],
          }),
        ),
      ),
    );

    expect(parsed.html).toBe(
      '<!DOCTYPE html><html><body><h2>Agenda</h2><ol><li>First</li><li><em>Second</em></li></ol>' +
        '<ul><li>a &lt; b &amp; c</li></ul><p><br></p><pre><code>let x = 1;\nx += 1;</code></pre>' +
        '<blockquote><p><code>Quoted</code></p></blockquote></body></html>',
    );
    expect(parsed.text).toBe(
      'Agenda\n1. First\n2. Second\n- a < b & c\n\nlet x = 1;\nx += 1;\n> Quoted',
    );
  });
});
