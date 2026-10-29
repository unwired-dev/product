import { english } from '@private-email/localization';
import * as Base64 from 'effect/encoding/Base64';
import * as Option from 'effect/Option';
import PostalMime from 'postal-mime';

import type { RegistrationSnapshot } from '../src/registration.ts';
import type { ResponseKind } from '../src/responses.ts';

import { createComposerNavigation } from '../src/composer-navigation.ts';
import { assetsOf, sendingMailboxes } from '../src/drafts.ts';
import { createImapInbox } from '../src/imap-inbox.ts';
import { createMailboxes } from '../src/mailboxes.ts';
import { decodeBodyDocument } from '../src/message-body.ts';
import { createOutbox, undoSendWindow } from '../src/outbox.ts';
import { defaultProfile, mailboxesOf } from '../src/registration.ts';
import { startResponse } from '../src/responses.ts';
import { plainText } from '../src/semantic-document.ts';
import { createSyntheticProductSync } from '../src/testing/drafts.ts';
import { syntheticConnections } from '../src/testing/gmail-mailbox.ts';
import { createSyntheticImap } from '../src/testing/imap-mailbox.ts';
import { device, present } from './draft-sync-fixture.ts';
import { account, write } from './outbox-fixture.ts';

// Two Standards-Based Mailbox Connections; each has its own IMAP and SMTP server.
const work = { id: 'connection-work', address: 'alex@work.example.invalid' };
const home = { id: 'connection-home', address: 'alex@home.example.invalid' };

const connection = (
  mailbox: Readonly<{ id: string; address: string }>,
  smtp: boolean,
) => ({
  ...mailbox,
  provider: 'imap',
  state: 'connected',
  imap: { host: 'imap.example.invalid', port: 993, username: mailbox.address },
  ...(smtp
    ? {
        smtp: {
          host: 'smtp.example.invalid',
          port: 465,
          security: 'tls',
          username: mailbox.address,
        },
      }
    : {}),
});
const snapshot = (smtp = true): RegistrationSnapshot => ({
  kind: 'connected',
  productAccountId: account,
  signInProvider: 'google',
  mailboxes: JSON.stringify([connection(work, smtp), connection(home, smtp)]),
});

const pdf = new TextEncoder().encode('%PDF-1.4\n');

// Maya's reply in an earlier conversation, to Alex's work address and Sam, copying Jo, with the
// agenda attached.
const received = [
  'From: Maya Chen <maya@example.invalid>',
  'Reply-To: Maya Chen <maya.desk@example.invalid>',
  'To: Alex <alex@work.example.invalid>, Sam Lee <sam@example.invalid>',
  'Cc: Jo <jo@example.invalid>',
  'Subject: Plans',
  'Date: Tue, 01 Sep 2026 09:00:00 +0000',
  'Message-ID: <m2@example.invalid>',
  'In-Reply-To: <m1@example.invalid>',
  'References: <m0@example.invalid> <m1@example.invalid>',
  'MIME-Version: 1.0',
  'Content-Type: multipart/mixed; boundary="mixed"',
  '',
  '--mixed',
  'Content-Type: text/plain; charset=utf-8',
  '',
  'Lunch at noon?',
  '--mixed',
  'Content-Type: application/pdf; name="agenda.pdf"',
  'Content-Disposition: attachment; filename="agenda.pdf"',
  'Content-Transfer-Encoding: base64',
  '',
  Base64.encode(pdf),
  '--mixed--',
].join('\r\n');

// Waiting for imports advances the controlled clock too, so time moves on from its current value.
const later = (milliseconds: number) => {
  vi.setSystemTime(Date.now() + milliseconds);
};

// A device whose work connection received Maya's message, opened in the reader.
async function answering(smtp = true) {
  const server = createSyntheticProductSync();
  const servers = {
    work: createSyntheticImap({ address: work.address }),
    home: createSyntheticImap({ address: home.address }),
  };
  servers.work.addFolder('Sent', ['sent']);
  servers.home.addFolder('Sent', ['sent']);
  servers.work.deliver('INBOX', { subject: 'Plans', raw: received });
  const phone = await device(server, account, 'phone');
  phone.change(snapshot(smtp));
  const mailboxes = createMailboxes(
    syntheticConnections(
      {},
      { [work.id]: servers.work.native, [home.id]: servers.home.native },
    ),
    phone.registration,
  );
  await mailboxes.load();
  const inbox = present(
    mailboxes
      .getConnections()
      .find(
        (each): each is Extract<typeof each, { provider: 'imap' }> =>
          each.id === work.id && each.provider === 'imap',
      )?.inbox,
    'the work Inbox',
  );
  const listed = () => {
    const state = inbox.getSnapshot();
    return present(
      state.kind === 'ready' ? state.messages[0] : undefined,
      'the received message',
    );
  };
  const message = listed();
  const release = inbox.retainMessage(message.id, Symbol('reader'));
  const connections = mailboxesOf(phone.registration.getSnapshot().snapshot);
  const navigation = createComposerNavigation();
  const outbox = createOutbox({
    drafts: phone.drafts,
    mailboxes,
    registration: phone.registration,
    claims: phone.storage.delivery,
  });
  const sender = sendingMailboxes(connections, defaultProfile).find(
    ({ id }) => id === work.id,
  );
  const start = (kind: ResponseKind) =>
    startResponse({ navigation, drafts: phone.drafts, inbox }, english, {
      kind,
      mailbox: present(sender, 'the sending work connection'),
      message,
      received: 'Sep 1, 2026',
      mailboxes: connections,
    });
  // Sends a Draft after its Undo Send window and returns what the work server accepted.
  const send = async (id: string) => {
    await outbox.send(() => phone.draft(id));
    later(undoSendWindow);
    await outbox.process();
    const { accepted } = servers.work.smtp;
    expect(accepted).toHaveLength(1);
    const { raw, recipients } = present(accepted[0], 'the accepted send');
    return {
      raw,
      parsed: await PostalMime.parse(raw),
      recipients,
    };
  };
  return {
    ...phone,
    servers,
    inbox,
    message,
    connections,
    sender,
    start,
    send,
    dispose: () => {
      release();
      outbox.dispose();
    },
  };
}

// Opens Maya's message again from a body an earlier build saved without the headers a response
// reads, with the server answering unless `failure` is set.
async function reopenOlder(failure?: string) {
  const reading = await answering();
  const { id } = reading.message;
  const headersOf = (document: string | undefined) =>
    Option.getOrUndefined(decodeBodyDocument(document))?.headers;
  try {
    await reading.inbox.readMessage(id);
    const { bodies, server } = reading.servers.work;
    const { headers: _, ...older } = present(
      Option.getOrUndefined(decodeBodyDocument(bodies.get(id))),
      'the saved body',
    );
    bodies.set(id, JSON.stringify(older));
    const relaunched = createImapInbox(reading.servers.work.native, {
      connection: work.id,
    });
    await relaunched.load();
    const release = relaunched.retainMessage(id, Symbol('reader'));
    try {
      server.failure = failure;
      await relaunched.readMessage(id);
      return {
        inbox: relaunched.getSnapshot(),
        body: relaunched.messageBody(id),
        answered: relaunched.responseSource(id)?.headers,
        saved: headersOf(bodies.get(id)),
      };
    } finally {
      release();
      relaunched.forget();
    }
  } finally {
    reading.dispose();
  }
}

describe('answering IMAP mail', () => {
  // oxlint-disable-next-line vitest/no-hooks -- Every journey runs on the same controlled clock.
  beforeEach(() => {
    vi.useFakeTimers({ toFake: ['Date'] });
    vi.setSystemTime(Date.UTC(2026, 9, 12, 12));
  });

  // oxlint-disable-next-line vitest/no-hooks -- Restore real timers after each journey.
  afterEach(() => {
    vi.useRealTimers();
  });

  it('replies from the receiving connection, threaded and quoted, without a provider thread', async () => {
    expect.hasAssertions();
    const reading = await answering();
    try {
      expect(reading.inbox.responseSource(reading.message.id)).toBeUndefined();
      await reading.inbox.readMessage(reading.message.id);
      const reply = reading.draft(
        present(await reading.start('reply'), 'the reply'),
      );
      expect(reply).toMatchObject({
        connection: work.id,
        from: work.address,
        to: [{ name: 'Maya Chen', address: 'maya.desk@example.invalid' }],
        cc: [],
        subject: 'Re: Plans',
      });
      expect(reply.response).toStrictEqual({
        kind: 'reply',
        message: reading.message.id,
        inReplyTo: '<m2@example.invalid>',
        references: [
          '<m0@example.invalid>',
          '<m1@example.invalid>',
          '<m2@example.invalid>',
        ],
      });
      expect(plainText(present(reply.quoted, 'the quote'))).toMatch(
        /^On Tue, 01 Sep 2026 09:00:00 \+0000, Maya Chen <maya@example\.invalid> wrote:\nLunch at noon\?/u,
      );
    } finally {
      reading.dispose();
    }
  });

  it('sends a reply through the receiving connection with its threading headers', async () => {
    expect.hasAssertions();
    const reading = await answering();
    try {
      await reading.inbox.readMessage(reading.message.id);
      const id = present(await reading.start('reply'), 'the reply');
      const reply = reading.draft(id);
      await reading.drafts.update(write(reply, 'Noon works.'), reply);
      const { parsed, recipients } = await reading.send(id);
      expect(recipients).toStrictEqual(['maya.desk@example.invalid']);
      expect(parsed).toMatchObject({
        from: { address: work.address },
        inReplyTo: '<m2@example.invalid>',
        references:
          '<m0@example.invalid> <m1@example.invalid> <m2@example.invalid>',
      });
      expect(parsed.text).toMatch(/Noon works\.[\s\S]*Lunch at noon\?/u);
      expect(reading.servers.home.smtp.accepted).toStrictEqual([]);
    } finally {
      reading.dispose();
    }
  });

  it('replies to all except the receiving address', async () => {
    expect.hasAssertions();
    const reading = await answering();
    try {
      await reading.inbox.readMessage(reading.message.id);
      const id = present(await reading.start('replyAll'), 'the reply');
      const reply = reading.draft(id);
      expect(reply).toMatchObject({
        connection: work.id,
        to: [
          { name: 'Maya Chen', address: 'maya.desk@example.invalid' },
          { name: 'Sam Lee', address: 'sam@example.invalid' },
        ],
        cc: [{ name: 'Jo', address: 'jo@example.invalid' }],
        response: { kind: 'replyAll', inReplyTo: '<m2@example.invalid>' },
      });
      expect(reply.response).not.toHaveProperty('thread');

      await reading.drafts.update(write(reply, 'See you all.'), reply);
      const { parsed, recipients } = await reading.send(id);
      expect(recipients).toStrictEqual([
        'maya.desk@example.invalid',
        'sam@example.invalid',
        'jo@example.invalid',
      ]);
      expect(parsed.inReplyTo).toBe('<m2@example.invalid>');
    } finally {
      reading.dispose();
    }
  });

  it('forwards the received attachment and sends it', async () => {
    expect.hasAssertions();
    const reading = await answering();
    try {
      await reading.inbox.readMessage(reading.message.id);
      reading.storage.holdImports();
      const id = present(await reading.start('forward'), 'the forward');
      for (const [file, { bytes }] of reading.servers.work.files.savedFiles) {
        reading.storage.addFile(file, String.fromCodePoint(...bytes));
      }
      reading.storage.releaseImports();
      await vi.waitFor(() => {
        expect(assetsOf(reading.draft(id))).toMatchObject([
          { name: 'agenda.pdf', state: 'complete' },
        ]);
      });
      const forward = reading.draft(id);
      expect({
        ...forward,
        quoted: plainText(present(forward.quoted, 'the quote')),
      }).toMatchObject({
        connection: work.id,
        to: [],
        subject: 'Fwd: Plans',
        response: { kind: 'forward', message: reading.message.id },
        quoted: expect.stringContaining(
          '---------- Forwarded message ---------',
        ),
      });

      await reading.drafts.update(
        {
          ...write(forward, 'For you.'),
          to: [{ name: 'Sam Lee', address: 'sam@example.invalid' }],
        },
        forward,
      );
      const [attachment] = assetsOf(forward);
      const { raw, parsed } = await reading.send(id);
      expect(parsed.inReplyTo).toBeUndefined();
      expect(parsed.attachments).toMatchObject([{ filename: 'agenda.pdf' }]);
      // The synthetic SMTP server names each asset in place of its bytes.
      expect(raw).toContain(`[asset ${present(attachment, 'the asset').id}]`);
    } finally {
      reading.dispose();
    }
  });

  it('offers no response from a receive-only connection', async () => {
    expect.hasAssertions();
    const reading = await answering(false);
    try {
      await reading.inbox.readMessage(reading.message.id);
      expect(reading.inbox.responseSource(reading.message.id)).toBeDefined();
      expect(reading.sender).toBeUndefined();
      expect(
        sendingMailboxes(reading.connections, defaultProfile),
      ).toStrictEqual([]);
    } finally {
      reading.dispose();
    }
  });

  it('reads a body saved before its headers were kept again, so it can be answered', async () => {
    expect.hasAssertions();
    const reopened = await reopenOlder();
    expect(reopened.body).toMatchObject({ kind: 'ready' });
    expect(reopened.answered).toMatchObject({
      messageId: '<m2@example.invalid>',
    });
    // The body read again replaces the saved one.
    expect(reopened.saved).toMatchObject({ messageId: '<m2@example.invalid>' });
  });

  it('opens a body saved before its headers were kept while offline, without a response', async () => {
    expect.hasAssertions();
    const reopened = await reopenOlder('offline');
    expect(reopened.body).toMatchObject({ kind: 'ready' });
    expect(reopened.answered).toBeUndefined();
    expect(reopened.saved).toBeUndefined();
  });

  it.each([
    { failure: 'locked', expected: { kind: 'locked' } },
    { failure: 'mailbox-revoked', expected: { kind: 'failed' } },
    { failure: 'mailbox-invalidated', expected: { kind: 'failed' } },
    {
      failure: 'imap-refused',
      expected: { kind: 'ready', status: 'authentication' },
    },
  ])(
    'preserves access recovery after $failure while completing an older body',
    async ({ failure, expected }) => {
      expect.hasAssertions();
      const reopened = await reopenOlder(failure);
      expect(reopened.inbox).toMatchObject(expected);
      expect(reopened.body?.kind).not.toBe('ready');
      expect(reopened.answered).toBeUndefined();
    },
  );

  it('answers nothing once a new UIDVALIDITY supersedes the opened message', async () => {
    expect.hasAssertions();
    const reading = await answering();
    try {
      await reading.inbox.readMessage(reading.message.id);
      expect(reading.inbox.responseSource(reading.message.id)).toBeDefined();
      reading.servers.work.renumber('INBOX');
      await reading.inbox.load();
      expect(reading.inbox.responseSource(reading.message.id)).toBeUndefined();
    } finally {
      reading.dispose();
    }
  });
});
