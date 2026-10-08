import type { GmailInboxState } from '../src/gmail-inbox.ts';
import type { Mailbox, NativeGmailMailboxes } from '../src/mailboxes.ts';

import { gmailAction } from '../src/gmail-actions.ts';
import {
  createGmailSearch,
  createMailboxes,
  inboxMessages,
  searchGmail,
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

const onlineAnswer = <T>(answer: T | undefined): T => {
  if (answer === undefined) {
    throw new Error('Expected an online search answer');
  }
  return answer;
};

const at = (day: number) => Date.UTC(2026, 8, day);

// Whether a Gmail request from `connection` is an online search of `mailbox`.
const searchesIn = (
  mailbox: string,
  connection: string,
  query: ReadonlyArray<readonly [string, string]>,
) => connection === mailbox && query.some(([name]) => name === 'q');

const firstOf = <T>(items: readonly T[]) => {
  const [item] = items;
  if (item === undefined) {
    throw new Error('Expected an item');
  }
  return item;
};

const attachmentsOf = (inbox: Mailbox['inbox'], id: string) => {
  const attachments = inbox.messageAttachments(id);
  if (attachments === undefined) {
    throw new Error('Expected attachment metadata');
  }
  return attachments;
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

  it('searches Gmail online across connections, pages and opens results without saving them, and keeps each failure its own', async () => {
    expect.hasAssertions();
    // Holds Other's online searches until released, as a slow network would.
    const held: Array<() => void> = [];
    let holding = false;
    let locked = false;
    const { gmail, registration, mailboxes } = await twoMailboxes((base) => ({
      ...base,
      openMailbox: async (connection) => {
        // oxlint-disable-next-line vitest/no-conditional-in-test -- Protected storage fails closed.
        if (locked && connection === other) {
          throw Object.assign(new Error('Protected storage is locked'), {
            code: 'locked',
          });
        }
        return base.openMailbox(connection);
      },
      gmailRequest: async (path, query, scope) => {
        // oxlint-disable-next-line vitest/no-conditional-in-test -- Only Other's held searches wait.
        if (holding && searchesIn(other, scope.connection, query)) {
          const release = Promise.withResolvers<undefined>();
          held.push(() => {
            release.resolve(undefined);
          });
          await release.promise;
        }
        return base.gmailRequest(path, query, scope);
      },
    }));
    // Alex has 21 matching messages, more than one page; the oldest left the Inbox long ago.
    const archived = gmail.alex.deliver({
      subject: 'Quarterly report 2024',
      at: at(1),
      content: { text: 'Archived quarterly numbers', single: true },
    });
    gmail.alex.archive(archived);
    for (let day = 2; day <= 21; day += 1) {
      gmail.alex.deliver({ subject: `Quarterly report ${day}`, at: at(day) });
    }
    // The word is only in Other's content, and its trashed copy is not searched.
    const otherMatch = gmail.other.deliver({
      subject: 'Numbers',
      at: at(30),
      content: { text: 'The quarterly figures', single: true },
    });
    const trashed = gmail.other.deliver({
      subject: 'Quarterly draft',
      at: at(31),
    });
    gmail.other.setLabel(trashed, 'TRASH', true);
    await mailboxes.load();
    const shown = mailboxes.getSnapshot();
    const alexInbox = mailbox(shown, alex).inbox;
    const subjects = (
      search: Awaited<ReturnType<typeof searchGmail<Mailbox>>>,
    ) =>
      search.results.map(({ mailbox: { address }, message }) => [
        address,
        message.subject,
      ]);

    // The first page from each mailbox, newest first across them.
    const online = createGmailSearch(shown, 'QUARTERLY', undefined);
    await online.search();
    const first = onlineAnswer(online.getSnapshot().found);
    expect(first.failures).toStrictEqual([]);
    expect(first.results).toHaveLength(21);
    expect(subjects(first).slice(0, 2)).toStrictEqual([
      ['other@example.invalid', 'Numbers'],
      ['alex@example.invalid', 'Quarterly report 21'],
    ]);
    expect([...first.next.keys()]).toStrictEqual([alex]);
    const asked = gmail.alex.requests.filter(({ query }) => query.has('q'));
    expect(
      asked.map(({ path, query }) => [path, query.toString()]),
    ).toStrictEqual([['messages', 'q=QUARTERLY&maxResults=20']]);
    // The next page asks only the mailbox that has one, and reaches mail outside the Inbox.
    await online.more();
    const second = onlineAnswer(online.getSnapshot().found);
    expect(second.results).toHaveLength(22);
    expect(subjects(second).at(-1)).toStrictEqual([
      'alex@example.invalid',
      'Quarterly report 2024',
    ]);
    expect(second.next.size).toBe(0);
    expect(
      gmail.other.requests.filter(({ query }) => query.has('q')),
    ).toHaveLength(1);

    // An archived result opens through the reader from Gmail and is not saved on this device.
    const state = ready(mailbox(mailboxes.getSnapshot(), alex).state);
    expect(state.messages.some(({ id }) => id === archived)).toBe(false);
    expect(state.found?.some(({ id }) => id === archived)).toBe(true);
    await alexInbox.readMessage(archived);
    expect(alexInbox.messageBody(archived)?.kind).toBe('ready');
    expect(gmail.alex.bodyCommits.map(({ id }) => id)).not.toContain(archived);
    expect(gmail.alex.cachedBodies().has(archived)).toBe(false);
    // A synchronization keeps the open result readable.
    await alexInbox.load();
    expect(alexInbox.messageBody(archived)?.kind).toBe('ready');

    // One mailbox's outage or refused grant leaves the other's results.
    gmail.other.fail({ code: 'unavailable' });
    const outage = await searchGmail(shown, 'quarterly');
    expect(
      outage.failures.map(({ mailbox: { id }, reason }) => [id, reason]),
    ).toStrictEqual([[other, 'offline']]);
    expect(outage.results).toHaveLength(20);
    gmail.alex.fail({ status: 401 });
    const refused = await searchGmail(shown, 'quarterly');
    expect(
      refused.failures.map(({ mailbox: { id }, reason }) => [id, reason]),
    ).toStrictEqual([[alex, 'authentication']]);
    expect(subjects(refused)).toStrictEqual([
      ['other@example.invalid', 'Numbers'],
    ]);
    // The refused grant asks for Gmail again, as a reader would.
    expect(ready(mailbox(mailboxes.getSnapshot(), alex).state).sync).toBe(
      'authentication',
    );
    // A failed next page keeps its token, so asking again retries it.
    gmail.alex.failPage('20', { status: 503 });
    const retried = await searchGmail(shown, 'QUARTERLY', first);
    expect(retried.failures.map(({ reason }) => reason)).toStrictEqual([
      'offline',
    ]);
    expect(retried.next.get(alex)).toBe('20');
    expect(retried.results).toHaveLength(21);

    // A protected-storage rejection from search hides this connection's mail immediately.
    const protectedInbox = mailbox(mailboxes.getSnapshot(), other).inbox;
    gmail.other.fail({ code: 'locked' });
    const protectedSearch = await searchGmail(shown, 'quarterly');
    expect(protectedInbox.getSnapshot().kind).toBe('locked');
    expect(
      online.matches(mailboxes.getSnapshot(), 'QUARTERLY', undefined),
    ).toBe(false);
    expect(
      protectedSearch.results.every(({ mailbox: { id } }) => id === alex),
    ).toBe(true);
    await protectedInbox.load();

    // A pending reply cannot republish readable mail after protected storage has locked.
    holding = true;
    const beforeLock = searchGmail(mailboxes.getSnapshot(), 'quarterly');
    await vi.waitFor(() => {
      expect(held).toHaveLength(1);
    });
    const lockedInbox = mailbox(mailboxes.getSnapshot(), other).inbox;
    locked = true;
    await lockedInbox.load();
    expect(lockedInbox.getSnapshot().kind).toBe('locked');
    held.shift()?.();
    const afterLock = await beforeLock;
    expect(afterLock.results.every(({ mailbox: { id } }) => id === alex)).toBe(
      true,
    );
    expect(lockedInbox.getSnapshot().kind).toBe('locked');
    locked = false;
    await lockedInbox.load();

    // A connection removed while its search runs adds nothing, and its results leave memory.
    holding = true;
    const pending = searchGmail(mailboxes.getSnapshot(), 'quarterly');
    await vi.waitFor(() => {
      expect(held).toHaveLength(1);
    });
    const otherInbox = mailbox(mailboxes.getSnapshot(), other).inbox;
    await registration.removeMailbox(other);
    held.shift()?.();
    const late = await pending;
    expect(late.results.every(({ mailbox: { id } }) => id === alex)).toBe(true);
    expect(late.failures).toStrictEqual([]);
    expect(otherInbox.getSnapshot().kind).toBe('loading');
    await otherInbox.readMessage(otherMatch);
    expect(otherInbox.messageBody(otherMatch)).toBeUndefined();
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

  it('downloads an attachment only through its own connection and deletes it when that mailbox is removed', async () => {
    expect.hasAssertions();
    const { gmail, mailboxes, registration } = await twoMailboxes();
    const content = { text: 'Attached.' };
    // Gmail message IDs repeat across mailboxes.
    const alexMessage = gmail.alex.deliver({ content });
    const otherMessage = gmail.other.deliver({ content });
    expect(otherMessage).toBe(alexMessage);
    await mailboxes.load();
    const a = mailbox(mailboxes.getSnapshot(), alex).inbox;
    const b = mailbox(mailboxes.getSnapshot(), other).inbox;
    a.retainMessage(alexMessage);
    b.retainMessage(otherMessage);
    await a.readMessage(alexMessage);
    await b.readMessage(otherMessage);
    const otherRequests = gmail.other.requests.length;

    await a.downloadAttachment(
      alexMessage,
      firstOf(attachmentsOf(a, alexMessage)).locator,
    );

    expect(firstOf(attachmentsOf(a, alexMessage)).state).toStrictEqual({
      kind: 'downloaded',
    });
    expect(firstOf(attachmentsOf(b, otherMessage)).state).toStrictEqual({
      kind: 'available',
    });
    expect(gmail.alex.savedFiles.size).toBe(1);
    expect(gmail.other.savedFiles.size).toBe(0);
    expect(gmail.other.requests).toHaveLength(otherRequests);

    await registration.removeMailbox(alex);
    expect(gmail.alex.savedFiles.size).toBe(0);
    expect(firstOf(attachmentsOf(b, otherMessage)).state).toStrictEqual({
      kind: 'available',
    });
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

describe('searching saved metadata', () => {
  it('matches Unicode case and compatibility variants without accents', () => {
    expect.hasAssertions();
    const listing = [
      {
        id: 'saved',
        state: {
          kind: 'ready',
          messages: [
            {
              id: 'a',
              receivedAt: '2026-09-03T00:00:00Z',
              sender: 'Jörg Straße',
              address: 'joerg@example.invalid',
              subject: 'Plan ΑΛΦΑ',
            },
            {
              id: 'b',
              receivedAt: '2026-09-02T00:00:00Z',
              sender: 'Ayşe Yılmaz',
              address: 'ayse@example.invalid',
              subject: 'İstanbul trip',
            },
            {
              id: 'c',
              receivedAt: '2026-09-01T00:00:00Z',
              sender: 'Isparta Office',
              address: 'office@example.invalid',
              subject: 'ﬁle ΟΣΑ notes',
            },
            {
              id: 'd',
              receivedAt: '2026-08-31T00:00:00Z',
              sender: '𝐀lice',
              address: 'participant@example.invalid',
              subject: 'ⒷⓄⓄⓀ',
            },
            {
              id: 'e',
              receivedAt: '2026-08-30T00:00:00Z',
              sender: 'Jörg STRAẞE',
              address: 'jorg@example.invalid',
              subject: 'Plan',
            },
            {
              id: 'f',
              receivedAt: '2026-08-29T00:00:00Z',
              sender: 'ᾳλφα',
              address: 'greek@example.invalid',
              subject: 'Meeting',
            },
          ],
        },
      },
    ] as const;
    const search = (query: string) =>
      searchMessages(inboxMessages(listing, undefined), query).map(
        ({ message }) => message.id,
      );
    expect(
      [
        'STRASSE',
        'STRAẞE',
        'Straße',
        'istanbul yilmaz',
        'ıSPARTA FILE',
        'alice book',
        '𝐀LICE ⒷⓄⓄⓀ',
        'οσ',
        'ος',
        'αλφα',
        'ᾳλφα',
        'α\u0345λφα',
        'not saved',
      ].map((query) => [query, search(query)]),
    ).toStrictEqual([
      ['STRASSE', ['a', 'e']],
      ['STRAẞE', ['a', 'e']],
      ['Straße', ['a', 'e']],
      ['istanbul yilmaz', ['b']],
      ['ıSPARTA FILE', ['c']],
      ['alice book', ['d']],
      ['𝐀LICE ⒷⓄⓄⓀ', ['d']],
      ['οσ', ['c']],
      ['ος', ['c']],
      ['αλφα', ['a', 'f']],
      ['ᾳλφα', ['a', 'f']],
      ['α\u0345λφα', ['a', 'f']],
      ['not saved', []],
    ]);
  });
});
