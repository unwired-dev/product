import type { MailTemplate } from '@private-email/mail-core/mail-templates';
import type { NativeMailTemplates } from '@private-email/mail-core/mail-templates';
import type { RegistrationSnapshot } from '@private-email/mail-core/registration';
import type { SemanticDocument } from '@private-email/mail-core/semantic-document';

import {
  applyTemplate,
  createMailTemplates,
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
const imaged: SemanticDocument = [
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
];
const line = (text: string): SemanticDocument => [
  { kind: 'paragraph', spans: [{ text }] },
];

describe('the Mail Template model', () => {
  it('refuses a blank name and a body with an Inline Image', () => {
    expect.hasAssertions();
    const valid = Schema.is(MailTemplateSchema);
    expect(valid(template)).toBe(true);
    expect(valid({ ...template, name: '  ' })).toBe(false);
    expect(valid({ ...template, body: imaged })).toBe(false);
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

  it('keeps list items when the caret is in a marker or on an empty item', () => {
    expect.hasAssertions();
    const list: SemanticDocument = [
      { kind: 'bulleted', spans: [{ text: 'ab' }] },
      { kind: 'bulleted', spans: [] },
    ];
    const joined = applyTemplate(
      { subject: '', body: list },
      // Between "•" and its space.
      { start: 1, end: 1 },
      { ...template, body: line('XY') },
    ).edit;
    expect(joined.document).toStrictEqual([
      { kind: 'bulleted', spans: [{ text: 'XYab' }] },
      list[1],
    ]);
    expect(
      applyTemplate(
        { subject: '', body: list },
        // On the empty item.
        { start: 7, end: 7 },
        { ...template, body: line('XY') },
      ).edit.document,
    ).toStrictEqual([list[0], { kind: 'bulleted', spans: [{ text: 'XY' }] }]);
  });
});

// Native template storage as the store sees it: one document for the signed-in account, replaced
// only from the revision read.
const storage = () => {
  const state: {
    account: string;
    // `cached` while registration has not verified again, as offline after a relaunch.
    kind: 'connected' | 'cached';
    locked: boolean;
    revision: number;
    owner?: string;
    document?: string;
    commits: number;
    // Runs before the next commit, as another writer would.
    before?: () => void;
    // Holds the next read's reply, as a slow native read would.
    reading?: Promise<undefined>;
  } = {
    account: 'account-1',
    kind: 'connected',
    locked: false,
    revision: 0,
    commits: 0,
  };
  const refuse = (code: string) =>
    Promise.reject(Object.assign(new Error(code), { code }));
  const native: NativeMailTemplates = {
    openMailTemplates: async () => {
      if (state.locked) {
        return refuse('locked');
      }
      const reply = {
        owner: state.account,
        revision: state.revision,
        document: state.owner === state.account ? state.document : null,
      };
      await state.reading;
      return reply;
    },
    commitMailTemplates: (owner, expectedRevision, document) => {
      state.before?.();
      state.before = undefined;
      if (state.locked) {
        return refuse('locked');
      }
      if (owner !== state.account) {
        return refuse('mailbox-invalidated');
      }
      if (state.revision !== expectedRevision) {
        return refuse('conflict');
      }
      state.commits += 1;
      Object.assign(state, { revision: expectedRevision + 1, owner, document });
      return Promise.resolve({ owner, revision: state.revision });
    },
  };
  // Registration as the store reads it: whichever account is signed in now.
  const registration = {
    getSnapshot: () => ({
      snapshot: {
        kind: state.kind,
        productAccountId: state.account,
        signInProvider: 'google',
        mailboxes: '[]',
      } satisfies RegistrationSnapshot,
      busy: false,
      failed: false,
    }),
  };
  const relaunch = () => createMailTemplates(native, registration);
  return { state, store: relaunch(), relaunch };
};
const invoice = { ...template, id: 'invoice' };
const thanks = { ...template, id: 'thanks', name: 'Thanks' };

describe('stored Mail Templates', () => {
  it('keeps each Profile its own templates across a relaunch', async () => {
    expect.hasAssertions();
    const { store, relaunch } = storage();
    await expect(store.templates('work')).resolves.toStrictEqual([]);
    await store.save('work', invoice);
    await store.save('work', thanks);
    await store.save('home', { ...template, id: 'party', name: 'Party' });

    const relaunched = relaunch();
    await expect(relaunched.templates('work')).resolves.toStrictEqual([
      { ...invoice, profile: 'work' },
      { ...thanks, profile: 'work' },
    ]);
    await expect(relaunched.templates('home')).resolves.toStrictEqual([
      { ...template, id: 'party', name: 'Party', profile: 'home' },
    ]);
  });

  it('saves and removes without a verified Product Sign-In session', async () => {
    expect.hasAssertions();
    const { state, store, relaunch } = storage();
    state.kind = 'cached';
    await expect(store.save('work', invoice)).resolves.toBe(true);
    await expect(store.save('work', thanks)).resolves.toBe(true);
    await expect(store.remove('work', 'invoice')).resolves.toBe(true);
    await expect(relaunch().templates('work')).resolves.toStrictEqual([
      { ...thanks, profile: 'work' },
    ]);
  });

  it('replaces a template in place and removes one', async () => {
    expect.hasAssertions();
    const { state, store } = storage();
    await store.save('work', invoice);
    await store.save('work', thanks);
    await expect(
      store.save('work', { ...invoice, subject: 'Overdue' }),
    ).resolves.toBe(true);
    await expect(store.templates('work')).resolves.toStrictEqual([
      { ...invoice, profile: 'work', subject: 'Overdue' },
      { ...thanks, profile: 'work' },
    ]);
    await expect(store.remove('work', 'invoice')).resolves.toBe(true);
    const { commits } = state;
    // Removing a template that is not there writes nothing.
    await expect(store.remove('work', 'invoice')).resolves.toBe(true);
    expect(state.commits).toBe(commits);
  });

  it("refuses another Profile's template", async () => {
    expect.hasAssertions();
    const { state, store } = storage();
    await store.save('work', invoice);
    const { document } = state;
    await expect(
      store.save('home', { ...invoice, name: 'Taken' }),
    ).resolves.toBe(false);
    await expect(store.remove('home', 'invoice')).resolves.toBe(false);
    expect(state.document).toBe(document);
    await expect(store.templates('home')).resolves.toStrictEqual([]);
  });

  it('never stores a template the model refuses', async () => {
    expect.hasAssertions();
    const error = vi.spyOn(console, 'error');
    const { state, store } = storage();
    await expect(store.save('work', { ...invoice, name: ' ' })).resolves.toBe(
      false,
    );
    await expect(
      store.save('work', { ...invoice, body: imaged }),
    ).resolves.toBe(false);
    await expect(store.save('work', { ...invoice, id: '' })).resolves.toBe(
      false,
    );
    expect(state.commits + error.mock.calls.length).toBe(0);
  });

  it('changes nothing when another write moved the revision on', async () => {
    expect.hasAssertions();
    vi.spyOn(console, 'error').mockReturnValue();
    const { state, store } = storage();
    await store.save('work', invoice);
    const { document } = state;
    state.before = () => {
      state.revision += 1;
    };
    await expect(store.save('work', thanks)).resolves.toBe(false);
    expect(state.document).toBe(document);
  });

  it('reads and writes nothing while the device is locked', async () => {
    expect.hasAssertions();
    const { state, store } = storage();
    state.locked = true;
    await expect(store.save('work', invoice)).resolves.toBe(false);
    await expect(store.templates('work')).resolves.toBeUndefined();
    expect(state.commits).toBe(0);
  });

  it('writes nothing for an account that signed in meanwhile', async () => {
    expect.hasAssertions();
    vi.spyOn(console, 'error').mockReturnValue();
    const { state, store } = storage();
    await store.save('work', invoice);
    const { document } = state;
    state.before = () => {
      state.account = 'account-2';
    };
    await expect(store.remove('work', 'invoice')).resolves.toBe(false);
    expect(state.document).toBe(document);
    await expect(store.templates('work')).resolves.toStrictEqual([]);
  });

  it('keeps a save that waited for another account out of it', async () => {
    expect.hasAssertions();
    vi.spyOn(console, 'error').mockReturnValue();
    const { state, store } = storage();
    // The first save's commit finds another account signed in; the second waited behind it.
    state.before = () => {
      state.account = 'account-2';
    };
    const first = store.save('work', invoice);
    const second = store.save('work', thanks);
    await expect(Promise.all([first, second])).resolves.toStrictEqual([
      false,
      false,
    ]);
    expect(state.commits).toBe(0);
    await expect(store.templates('work')).resolves.toStrictEqual([]);
  });

  it("returns none of an account's templates read while another signed in", async () => {
    expect.hasAssertions();
    vi.spyOn(console, 'error').mockReturnValue();
    const { state, store } = storage();
    await store.save('work', invoice);
    const { promise, resolve } = Promise.withResolvers<undefined>();
    state.reading = promise;
    const listed = store.templates('work');
    state.account = 'account-2';
    resolve(undefined);
    await expect(listed).resolves.toBeUndefined();
  });

  it('lists nothing from a document that does not decode', async () => {
    expect.hasAssertions();
    vi.spyOn(console, 'error').mockReturnValue();
    const { state, store } = storage();
    Object.assign(state, {
      revision: 1,
      owner: 'account-1',
      document: JSON.stringify({
        templates: [{ ...invoice, profile: 'work', name: '' }],
      }),
    });
    await expect(store.templates('work')).resolves.toBeUndefined();
    await expect(store.save('work', invoice)).resolves.toBe(false);
    expect(state.revision).toBe(1);
  });
});
