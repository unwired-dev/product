import type { GmailInboxState } from '../src/gmail-inbox.ts';
import type { Mailbox, NativeGmailMailboxes } from '../src/mailboxes.ts';

import { gmailAction } from '../src/gmail-actions.ts';
import {
  createMailboxes,
  inboxMessages,
  searchMessages,
} from '../src/mailboxes.ts';
import { createRegistration, mailboxesOf } from '../src/registration.ts';
import {
  createSyntheticGmail,
  syntheticConnections,
} from '../src/testing/gmail-mailbox.ts';
import {
  createMockRegistrationSession,
  syntheticMailboxes,
} from '../src/testing/registration-session.ts';

const alex = syntheticMailboxes['alex@example.invalid'];
const other = syntheticMailboxes['other@example.invalid'];

const ready = (state: GmailInboxState) => {
  if (state.kind !== 'ready') {
    throw new Error(`Expected a ready Inbox, received ${state.kind}`);
  }
  return state;
};

const mailbox = (mailboxes: readonly Mailbox[], id: string) => {
  const found = mailboxes.find((item) => item.id === id);
  if (found === undefined) {
    throw new Error(`Expected mailbox ${id}`);
  }
  return found;
};

const at = (day: number) => Date.UTC(2026, 8, day);

const firstOf = <T>(items: readonly T[]) => {
  const [item] = items;
  if (item === undefined) {
    throw new Error('Expected an item');
  }
  return item;
};

// Holds every body download until released, counting how many run at once overall and per
// connection.
function holdingBodies(base: NativeGmailMailboxes) {
  let active = 0;
  let most = 0;
  let mostPerConnection = 0;
  let started = 0;
  const starts: Array<{ total: number; resolve: () => void }> = [];
  const perConnection = new Map<string, number>();
  const waiting: Array<() => void> = [];
  const native: NativeGmailMailboxes = {
    ...base,
    gmailRequest: async (path, query, scope) => {
      if (
        query.some(([name, value]) => name === 'format' && value === 'full')
      ) {
        active += 1;
        most = Math.max(most, active);
        const count = (perConnection.get(scope.connection) ?? 0) + 1;
        perConnection.set(scope.connection, count);
        mostPerConnection = Math.max(mostPerConnection, count);
        const held = Promise.withResolvers<undefined>();
        waiting.push(() => {
          held.resolve(undefined);
        });
        started += 1;
        for (const start of starts) {
          if (started >= start.total) {
            start.resolve();
          }
        }
        await held.promise;
        active -= 1;
        perConnection.set(
          scope.connection,
          (perConnection.get(scope.connection) ?? 1) - 1,
        );
      }
      return base.gmailRequest(path, query, scope);
    },
  };
  return {
    native,
    active: () => active,
    most: () => most,
    mostPerConnection: () => mostPerConnection,
    whenStarted: (total: number) => {
      if (started >= total) {
        return Promise.resolve();
      }
      const reached = Promise.withResolvers<undefined>();
      starts.push({ total, resolve: () => reached.resolve(undefined) });
      return reached.promise;
    },
    // Releases the oldest held download, if any.
    release: () => {
      waiting.shift()?.();
      return waiting.length + active > 0;
    },
  };
}

// A Product Account with Alex's mailbox, then Other's added through the chooser, each backed by
// its own controlled Gmail.
async function twoMailboxes(
  native?: (base: NativeGmailMailboxes) => NativeGmailMailboxes,
) {
  const gmail = {
    alex: createSyntheticGmail({ address: 'alex@example.invalid' }),
    other: createSyntheticGmail({ address: 'other@example.invalid' }),
  };
  const session = createMockRegistrationSession('registration-success');
  const registration = createRegistration(session.native);
  await registration.register('google');
  await registration.addMailbox(true);
  const base = syntheticConnections({
    [alex]: gmail.alex,
    [other]: gmail.other,
  });
  const mailboxes = createMailboxes(native?.(base) ?? base, registration);
  return { gmail, session, registration, mailboxes };
}

describe('mailbox connections and the unified Inbox', () => {
  /* oxlint-disable vitest/max-expects -- Each journey proves one multi-connection path end to end. */
  it('shows every connection newest first, or one connection on its own, with stable ties', async () => {
    expect.hasAssertions();
    const { gmail, mailboxes, registration } = await twoMailboxes();
    gmail.alex.deliver({ subject: 'Alex, oldest', at: at(1) });
    gmail.other.deliver({ subject: 'Other, middle', at: at(2) });
    gmail.alex.deliver({ subject: 'Alex, newest', at: at(4) });
    // Both mailboxes received a message at the same time.
    gmail.alex.deliver({ subject: 'Alex, tied', at: at(3) });
    gmail.other.deliver({ subject: 'Other, tied', at: at(3) });
    await mailboxes.load();

    const current = mailboxes.getSnapshot();
    expect(current.map(({ id, address }) => [id, address])).toStrictEqual([
      [alex, 'alex@example.invalid'],
      [other, 'other@example.invalid'],
    ]);
    const unified = inboxMessages(current, undefined);
    expect(
      unified.map(({ mailbox: { address }, message }) => [
        address,
        message.subject,
      ]),
    ).toStrictEqual([
      ['alex@example.invalid', 'Alex, newest'],
      ['alex@example.invalid', 'Alex, tied'],
      ['other@example.invalid', 'Other, tied'],
      ['other@example.invalid', 'Other, middle'],
      ['alex@example.invalid', 'Alex, oldest'],
    ]);
    // The same order holds on every render, and each connection can be shown alone.
    expect(inboxMessages(mailboxes.getSnapshot(), undefined)).toStrictEqual(
      unified,
    );
    expect(
      inboxMessages(current, other).map(({ message }) => message.subject),
    ).toStrictEqual(['Other, tied', 'Other, middle']);
    // Registration lists each connection once, in the order it was added.
    expect(mailboxesOf(registration.getSnapshot().snapshot)).toStrictEqual([
      { id: alex, address: 'alex@example.invalid', state: 'connected' },
      { id: other, address: 'other@example.invalid', state: 'connected' },
    ]);
  });

  it('searches saved senders and subjects without Gmail, within the chosen scope, and forgets a removed connection', async () => {
    expect.hasAssertions();
    const { gmail, registration, mailboxes } = await twoMailboxes();
    // Recent mail, so prefetch saves the single-part body and marks the multipart one excluded.
    const now = Date.now();
    const studio = gmail.alex.deliver({
      from: 'Maya Chen <maya@example.invalid>',
      subject: 'Studio review',
      at: now - 120_000,
      content: { text: 'Notes', single: true },
    });
    const cafe = gmail.alex.deliver({
      from: 'Oliver Park <oliver@example.invalid>',
      subject: 'Café on Saturday',
      at: now - 180_000,
      content: { text: 'Coffee', html: '<p>Coffee</p>' },
    });
    // Other's synthetic Gmail reuses Alex's message IDs.
    expect(
      gmail.other.deliver({
        from: 'Maya Chen <maya@example.invalid>',
        subject: 'Invoice',
        at: now - 60_000,
        content: { text: 'Invoice', single: true },
      }),
    ).toBe(studio);
    await mailboxes.load();
    await vi.waitFor(() => {
      expect(gmail.alex.bodyCommits).toHaveLength(2);
    });
    await vi.waitFor(async () => {
      await expect(
        mailbox(mailboxes.getSnapshot(), other).inbox.savedBodies([studio]),
      ).resolves.toStrictEqual(new Set([studio]));
    });

    // Relaunched during a known network outage, only the saved Inboxes open, and searching and
    // checking saved bodies ask Gmail nothing.
    // The saved Inbox only, as native code opens it after a known network outage.
    const savedOnly = (synthetic: ReturnType<typeof createSyntheticGmail>) => ({
      native: {
        ...synthetic.native,
        openMailbox: async () => ({
          ...(await synthetic.native.openMailbox()),
          availability: 'retry',
        }),
      },
    });
    const offline = createMailboxes(
      syntheticConnections({
        [alex]: savedOnly(gmail.alex),
        [other]: savedOnly(gmail.other),
      }),
      registration,
    );
    const requests = gmail.alex.requests.length + gmail.other.requests.length;
    await offline.load();
    const alexInbox = mailbox(offline.getSnapshot(), alex).inbox;
    const otherInbox = mailbox(offline.getSnapshot(), other).inbox;
    expect(ready(mailbox(offline.getSnapshot(), alex).state).sync).toBe(
      'retry',
    );
    const search = (scope: string | undefined, query: string) =>
      searchMessages(inboxMessages(offline.getSnapshot(), scope), query).map(
        ({ mailbox: { address }, message }) => [address, message.subject],
      );
    expect(search(undefined, 'maya')).toStrictEqual([
      ['other@example.invalid', 'Invoice'],
      ['alex@example.invalid', 'Studio review'],
    ]);
    // Every word must match, ignoring case and accents, in the name, address or subject.
    expect(search(undefined, '  MAYA   studio ')).toStrictEqual([
      ['alex@example.invalid', 'Studio review'],
    ]);
    expect(search(undefined, 'cafe oliver@example')).toStrictEqual([
      ['alex@example.invalid', 'Café on Saturday'],
    ]);
    expect(search(undefined, 'nothing like this')).toStrictEqual([]);
    expect(search(undefined, ' ')).toHaveLength(3);
    // One mailbox's view searches only its own mail.
    expect(search(other, 'maya')).toStrictEqual([
      ['other@example.invalid', 'Invoice'],
    ]);
    expect(search(alex, 'invoice')).toStrictEqual([]);
    // The excluded multipart message is not saved; each connection answers for its own cache.
    await expect(alexInbox.savedBodies([studio, cafe])).resolves.toStrictEqual(
      new Set([studio]),
    );
    await expect(otherInbox.savedBodies([studio, cafe])).resolves.toStrictEqual(
      new Set([studio]),
    );
    expect(gmail.alex.requests.length + gmail.other.requests.length).toBe(
      requests,
    );

    // Opening a saved result through the reader needs no Gmail either.
    await alexInbox.readMessage(studio);
    expect(alexInbox.messageBody(studio)?.kind).toBe('ready');
    expect(gmail.alex.requests.length + gmail.other.requests.length).toBe(
      requests,
    );

    // Online, opening an unsaved result through the reader downloads and saves its body.
    const onlineAlex = mailbox(mailboxes.getSnapshot(), alex).inbox;
    await onlineAlex.readMessage(cafe);
    expect(onlineAlex.messageBody(cafe)?.kind).toBe('ready');
    await expect(onlineAlex.savedBodies([studio, cafe])).resolves.toStrictEqual(
      new Set([studio, cafe]),
    );

    // A removed connection's mail leaves the results, and its store names no saved bodies.
    await registration.removeMailbox(other);
    expect(search(undefined, 'maya')).toStrictEqual([
      ['alex@example.invalid', 'Studio review'],
    ]);
    expect(
      searchMessages(inboxMessages(mailboxes.getSnapshot(), undefined), 'maya'),
    ).toHaveLength(1);
    await expect(otherInbox.savedBodies([studio])).resolves.toStrictEqual(
      new Set(),
    );
  });

  it('keeps one connection usable and isolated while another needs Gmail again', async () => {
    expect.hasAssertions();
    const { gmail, session, registration, mailboxes } = await twoMailboxes();
    const shared = gmail.alex.deliver({ subject: 'In Alex', at: at(2) });
    expect(gmail.other.deliver({ subject: 'In Other', at: at(1) })).toBe(
      shared,
    );
    await mailboxes.load();

    // Gmail refuses Alex's grant during a synchronization; Other's mail stays available.
    gmail.alex.fail({ status: 401 });
    await mailboxes.load();
    expect(ready(mailbox(mailboxes.getSnapshot(), alex).state).sync).toBe(
      'authentication',
    );
    const otherInbox = mailbox(mailboxes.getSnapshot(), other);
    expect(ready(otherInbox.state).sync).toBe('current');
    const message = firstOf(ready(otherInbox.state).messages);
    expect(message.subject).toBe('In Other');
    // Organizing in Other reaches only Other's Gmail, though Alex has a message with the same ID.
    await otherInbox.inbox.organize(message, gmailAction.star);
    expect(gmail.other.modifies).toStrictEqual([
      { id: shared, add: ['STARRED'], remove: [] },
    ]);
    expect(gmail.alex.modifies).toStrictEqual([]);
    expect(gmail.alex.labelsOf(shared)).not.toContain('STARRED');
    expect(
      ready(mailbox(mailboxes.getSnapshot(), alex).state).messages.map(
        ({ subject }) => subject,
      ),
    ).toStrictEqual(['In Alex']);

    // Verification then finds Alex's grant refused: its Inbox closes, and Other's stays open.
    session.expire('alex@example.invalid');
    await registration.restore();
    expect(registration.getSnapshot().snapshot.kind).toBe('connected');
    expect(mailboxes.getSnapshot().map(({ id }) => id)).toStrictEqual([other]);
    expect(
      ready(mailbox(mailboxes.getSnapshot(), other).state).messages,
    ).toHaveLength(1);

    // Authorizing Alex again reopens its Inbox, which synchronizes on its own.
    await registration.authorizeGmail(alex);
    expect(mailboxes.getSnapshot().map(({ id }) => id)).toStrictEqual([
      alex,
      other,
    ]);
    await mailboxes.load();
    expect(
      ready(mailbox(mailboxes.getSnapshot(), alex).state).messages.map(
        ({ subject }) => subject,
      ),
    ).toStrictEqual(['In Alex']);
  });

  it('removes a connection with the mail it held, leaving the other connection and Gmail untouched', async () => {
    expect.hasAssertions();
    const held = Promise.withResolvers<undefined>();
    let holding = false;
    const { gmail, registration, mailboxes } = await twoMailboxes((base) => ({
      ...base,
      gmailRequest: async (path, query, scope) => {
        // oxlint-disable-next-line vitest/no-conditional-in-test -- Only Other's next history read is held.
        if (holding && scope.connection === other && path === 'history') {
          holding = false;
          await held.promise;
        }
        return base.gmailRequest(path, query, scope);
      },
    }));
    gmail.alex.deliver({ subject: 'Stays', at: at(2) });
    const leaving = gmail.other.deliver({ subject: 'Leaves', at: at(1) });
    await mailboxes.load();
    const removed = mailbox(mailboxes.getSnapshot(), other).inbox;

    // A synchronization of Other is still running when Other is removed.
    gmail.other.deliver({ subject: 'Arrived during removal', at: at(3) });
    holding = true;
    const running = mailboxes.load();
    await registration.removeMailbox(other);
    expect(mailboxesOf(registration.getSnapshot().snapshot)).toStrictEqual([
      { id: alex, address: 'alex@example.invalid', state: 'connected' },
    ]);
    expect(mailboxes.getSnapshot().map(({ id }) => id)).toStrictEqual([alex]);
    expect(removed.getSnapshot()).toStrictEqual({ kind: 'loading' });
    held.resolve(undefined);
    await running;
    // The late result cannot bring Other's mail back into memory or the unified Inbox.
    expect(removed.getSnapshot()).toStrictEqual({ kind: 'loading' });
    expect(
      inboxMessages(mailboxes.getSnapshot(), undefined).map(
        ({ message }) => message.subject,
      ),
    ).toStrictEqual(['Stays']);
    // Removing a connection never changes mail in Gmail.
    expect(gmail.other.modifies).toStrictEqual([]);
    expect(gmail.other.labelsOf(leaving)).toContain('INBOX');
  });

  it('forgets every connection held in memory when its account leaves, including a late result', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail({ messages: 2 });
    const mailboxList = JSON.stringify([
      { id: alex, address: 'alex@example.invalid', state: 'connected' },
    ]);
    let snapshot: unknown = {
      kind: 'connected',
      productAccountId: 'account-a',
      signInProvider: 'google',
      mailboxes: mailboxList,
    };
    const unused = () => Promise.reject(new Error('Not used'));
    const registration = createRegistration({
      restore: () => Promise.resolve(snapshot),
      signIn: unused,
      addMailbox: unused,
      authorizeGmail: unused,
      removeMailbox: unused,
      link: unused,
      confirmRecoveryKey: unused,
      recoverWithRecoveryKey: unused,
      approveEnrollment: unused,
      declineEnrollment: unused,
      revokeTrustedDevice: unused,
      refreshPrivateSync: unused,
      signOut: () => Promise.resolve({ kind: 'signed-out' }),
      deleteProductAccount: unused,
    });
    let release: () => void = () => undefined;
    let paused = false;
    const base = syntheticConnections({ [alex]: gmail });
    const mailboxes = createMailboxes(
      {
        ...base,
        gmailRequest: async (path, query, scope) => {
          // oxlint-disable-next-line vitest/no-conditional-in-test -- Only the paused history read is held.
          if (paused && path === 'history') {
            // oxlint-disable-next-line promise/avoid-new -- Hold the history response across sign-out.
            await new Promise<void>((resolve) => {
              release = resolve;
            });
          }
          return base.gmailRequest(path, query, scope);
        },
      },
      registration,
    );
    await registration.restore();
    const [first] = mailboxes.getSnapshot();
    await mailboxes.load();
    expect(
      ready(mailbox(mailboxes.getSnapshot(), alex).state).messages,
    ).toHaveLength(2);

    // Signing out forgets the mail at once; a synchronization still running cannot bring it back.
    paused = true;
    const running = mailboxes.load();
    await registration.signOut();
    expect(mailboxes.getSnapshot()).toStrictEqual([]);
    expect(first?.inbox.getSnapshot()).toStrictEqual({ kind: 'loading' });
    gmail.fail({ code: 'mailbox-invalidated' });
    paused = false;
    release();
    await running;
    expect(first?.inbox.getSnapshot()).toStrictEqual({ kind: 'loading' });

    // Another Product Account connecting the same mailbox gets a new Inbox; nothing carries over.
    snapshot = {
      kind: 'connected',
      productAccountId: 'account-b',
      signInProvider: 'google',
      mailboxes: mailboxList,
    };
    await registration.restore();
    const [next] = mailboxes.getSnapshot();
    expect(next?.id).toBe(alex);
    expect(next?.inbox).not.toBe(first?.inbox);
    expect(first?.inbox.getSnapshot()).toStrictEqual({ kind: 'loading' });
    await mailboxes.load();
    snapshot = {
      kind: 'connected',
      productAccountId: 'account-b',
      signInProvider: 'google',
      mailboxes: JSON.stringify([
        {
          id: alex,
          address: 'alex@example.invalid',
          state: 'connected',
          epoch: 'recreated',
        },
      ]),
    };
    await registration.restore();
    const recreated = mailbox(mailboxes.getSnapshot(), alex);
    expect(recreated.inbox).not.toBe(next?.inbox);
    expect(next?.inbox.getSnapshot()).toStrictEqual({ kind: 'loading' });
  });

  it('shares the image budget across connections and returns only a closed connection’s reservations', async () => {
    expect.hasAssertions();
    const { gmail, mailboxes, registration } = await twoMailboxes();
    // One small single-frame GIF on a 4096-square canvas costs 16 Mi decoded pixels.
    const image = Buffer.from(
      'R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7',
      'base64',
    );
    image.writeUInt16LE(4096, 6);
    image.writeUInt16LE(4096, 8);
    const content = {
      html: '<p>Photo <img src="cid:photo" alt="Photo"></p>',
      images: [
        { contentId: 'photo', mimeType: 'image/gif', bytes: [...image] },
      ],
    };
    const first = gmail.alex.deliver({ content });
    const second = gmail.alex.deliver({ content });
    const third = gmail.other.deliver({ content });
    await mailboxes.load();
    const a = mailbox(mailboxes.getSnapshot(), alex).inbox;
    const b = mailbox(mailboxes.getSnapshot(), other).inbox;
    a.retainMessage(first);
    a.retainMessage(second);
    const closeThird = b.retainMessage(third);
    await a.readMessage(first);
    await a.readMessage(second);
    await b.readMessage(third);
    expect(a.messageBody(first)).toMatchObject({
      kind: 'ready',
      presentation: {
        rich: { document: expect.stringContaining('data:image/gif') },
      },
    });
    expect(a.messageBody(second)).toMatchObject({
      kind: 'ready',
      presentation: {
        rich: { document: expect.stringContaining('data:image/gif') },
      },
    });
    expect(b.messageBody(third)).toMatchObject({
      kind: 'ready',
      presentation: {
        rich: { document: expect.not.stringContaining('data:image') },
      },
    });
    // Forgetting A releases A's budget; B's existing reader is still live and unchanged.
    await registration.removeMailbox(alex);
    closeThird();
    const closeReopened = b.retainMessage(third);
    await b.readMessage(third);
    expect(b.messageBody(third)).toMatchObject({
      kind: 'ready',
      presentation: {
        rich: { document: expect.stringContaining('data:image/gif') },
      },
    });
    closeReopened();
  });

  it('runs at most two body downloads per connection and four across connections', async () => {
    expect.hasAssertions();
    const connections = ['a', 'b', 'c'].map((letter) => {
      const gmail = createSyntheticGmail({
        address: `${letter}@example.invalid`,
      });
      return {
        id: `synthetic-connection-${letter}`,
        address: `${letter}@example.invalid`,
        gmail,
        delivered: [1, 2, 3].map((day) => gmail.deliver({ at: at(day) })),
      };
    });
    const held = holdingBodies(
      syntheticConnections(
        Object.fromEntries(connections.map(({ id, gmail }) => [id, gmail])),
      ),
    );
    const snapshot = {
      kind: 'connected',
      productAccountId: 'account-a',
      signInProvider: 'google',
      mailboxes: JSON.stringify(
        connections.map(({ id, address }) => ({
          id,
          address,
          state: 'connected',
        })),
      ),
    };
    const unused = () => Promise.reject(new Error('Not used'));
    const registration = createRegistration({
      restore: () => Promise.resolve(snapshot),
      signIn: unused,
      addMailbox: unused,
      authorizeGmail: unused,
      removeMailbox: unused,
      link: unused,
      confirmRecoveryKey: unused,
      recoverWithRecoveryKey: unused,
      approveEnrollment: unused,
      declineEnrollment: unused,
      revokeTrustedDevice: unused,
      refreshPrivateSync: unused,
      signOut: unused,
      deleteProductAccount: unused,
    });
    const mailboxes = createMailboxes(held.native, registration);
    await registration.restore();
    await mailboxes.load();
    const inboxes = connections.map(({ id, delivered }) => ({
      inbox: mailbox(mailboxes.getSnapshot(), id).inbox,
      delivered,
    }));
    const reads = inboxes.flatMap(({ inbox, delivered }) =>
      delivered.map((id) => inbox.readMessage(id)),
    );
    await held.whenStarted(4);
    expect(held.active()).toBe(4);
    // Release one download at a time until every read finished.
    for (let total = 1; total <= reads.length; total += 1) {
      await held.whenStarted(total);
      held.release();
    }
    await Promise.all(reads);
    expect(held.most()).toBe(4);
    expect(held.mostPerConnection()).toBe(2);
    expect(
      inboxes.flatMap(({ inbox, delivered }) =>
        delivered.map((id) => inbox.messageBody(id)?.kind),
      ),
    ).toStrictEqual(Array.from({ length: 9 }, () => 'ready'));
  });
  /* oxlint-enable vitest/max-expects */
});
