import type { MailTemplate } from '@private-email/mail-core/mail-templates';
import type { SemanticDocument } from '@private-email/mail-core/semantic-document';

import {
  applyTemplate,
  MailTemplateSchema,
} from '@private-email/mail-core/mail-templates';
import {
  displayOf,
  emptyDocument,
  imageCharacter,
} from '@private-email/mail-core/semantic-document';
import * as Schema from 'effect/Schema';

const template: MailTemplate = {
  name: 'Invoice reminder',
  subject: 'Invoice due',
  body: [
    { kind: 'heading2', spans: [{ text: 'Reminder' }], align: 'center' },
    {
      kind: 'bulleted',
      spans: [
        { text: 'Pay ', marks: ['bold'] },
        { text: 'here', link: 'https://example.invalid/pay' },
      ],
    },
  ],
};
const line = (text: string): SemanticDocument => [
  { kind: 'paragraph', spans: [{ text }] },
];

describe('the Mail Template model', () => {
  it('refuses a blank name and a body with an Inline Image', () => {
    expect.hasAssertions();
    const valid = Schema.is(MailTemplateSchema);
    expect(valid(template)).toBe(true);
    expect(valid({ ...template, name: '  ' })).toBe(false);
    expect(
      valid({
        ...template,
        body: [
          {
            kind: 'paragraph',
            spans: [
              {
                text: imageCharacter,
                image: {
                  id: 'image0001',
                  name: 'a.png',
                  type: 'image/png',
                  state: 'importing',
                },
              },
            ],
          },
        ],
      }),
    ).toBe(false);
  });

  it('gives an empty Draft the template subject and exactly its body', () => {
    expect.hasAssertions();
    const { subject, edit } = applyTemplate(
      { subject: '', body: emptyDocument },
      { start: 0, end: 0 },
      template,
    );
    expect(subject).toBe('Invoice due');
    expect(edit.document).toStrictEqual(template.body);
    const end = displayOf(edit.document).text.length;
    expect(edit.selection).toStrictEqual({ start: end, end });
  });

  it('keeps authored text, the selection and subject, and the template formatting', () => {
    expect.hasAssertions();
    const body = line('Hello there');
    // "there" is selected: the template goes after it.
    const { subject, edit } = applyTemplate(
      { subject: 'Re: March', body },
      { start: 6, end: 11 },
      template,
    );
    expect(subject).toBe('Re: March');
    expect(edit.document).toStrictEqual([...body, ...template.body]);

    // Inside a line, the line splits around the template.
    const split = applyTemplate(
      { subject: '', body },
      { start: 5, end: 5 },
      template,
    ).edit;
    expect(split.document).toStrictEqual([
      { kind: 'paragraph', spans: [{ text: 'Hello' }] },
      ...template.body,
      { kind: 'paragraph', spans: [{ text: ' there' }] },
    ]);
    expect(
      displayOf(split.document).text.slice(0, split.selection?.start),
    ).toBe('Hello\nReminder\n• Pay here');
  });

  it('joins a one-paragraph template to the line at the caret', () => {
    expect.hasAssertions();
    const { edit } = applyTemplate(
      { subject: '', body: line('Thanks!') },
      { start: 6, end: 6 },
      {
        ...template,
        body: [
          { kind: 'paragraph', spans: [{ text: ' a lot', marks: ['italic'] }] },
        ],
      },
    );
    expect(edit.document).toStrictEqual([
      {
        kind: 'paragraph',
        spans: [
          { text: 'Thanks' },
          { text: ' a lot', marks: ['italic'] },
          { text: '!' },
        ],
      },
    ]);
    expect(edit.selection).toStrictEqual({ start: 12, end: 12 });
  });
});
