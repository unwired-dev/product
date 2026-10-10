import type { Draft } from '../src/drafts.ts';
import type { SemanticDocument } from '../src/semantic-document.ts';

import { captureDraftText, replyInput } from '../src/assistance.ts';

describe('bounded reply input', () => {
  it('inspects at most 100 recipients for display names', () => {
    expect.hasAssertions();
    const many = Array.from({ length: 100 }, (_, index) => ({
      address: `person${index}@example.invalid`,
    }));
    Object.defineProperty(many, 100, {
      enumerable: true,
      get: () => {
        throw new Error('Read beyond the recipient limit');
      },
    });
    const quoted: SemanticDocument = [
      { kind: 'quote', spans: [{ text: 'Shall we meet?' }] },
    ];
    const reply = replyInput({ authored: 'Yes', recipients: many, quoted });
    expect(reply?.purpose).toBe('reply');
    // Both recipient arrays are bounded before the capture combines them.
    const draft: Draft = {
      id: 'draft',
      connection: 'connection',
      from: 'alex@example.invalid',
      to: many,
      cc: many,
      bcc: [],
      subject: 'Re: Plans',
      body: [{ kind: 'paragraph', spans: [{ text: 'Yes' }] }],
      quoted,
      updatedAt: 0,
    };
    const capture = captureDraftText('reply', draft, { start: 0, end: 0 });
    expect(capture.input).toStrictEqual({
      purpose: 'reply',
      text: JSON.stringify({
        operation: 'reply',
        recipientNames: '',
        authoredText: 'Yes',
        quotedText: 'Shall we meet?',
      }),
      omitted: false,
    });
  });
});
