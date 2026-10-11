import type { Mailbox } from '../src/mailboxes.ts';

import {
  createGmailSearch,
  createMailboxes,
  inboxMessages,
  readingProfile,
  searchMessages,
} from '../src/mailboxes.ts';
import {
  createRegistration,
  defaultProfile,
  mailboxesOf,
} from '../src/registration.ts';
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
const everything = { profile: defaultProfile };
const at = (day: number) => Date.UTC(2026, 8, day);

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

describe('profile-scoped reading', () => {
  /* oxlint-disable vitest/max-expects -- One journey proves reading, search and ownership replacement together. */
  it('shows and searches only the named Profile’s connections, and follows a moved connection', async () => {
    expect.hasAssertions();
    const gmail = {
      alex: createSyntheticGmail({ address: 'alex@example.invalid' }),
      other: createSyntheticGmail({ address: 'other@example.invalid' }),
    };
    const session = createMockRegistrationSession('registration-success');
    const registration = createRegistration(session.native);
    await registration.register('google');
    await registration.addMailbox();
    await registration.addMailbox('gmail', true);
    gmail.alex.deliver({ subject: 'Quarterly plan', at: at(1) });
    gmail.other.deliver({ subject: 'Quarterly budget', at: at(2) });
    // Registration as if Other belonged to a second Mail Profile, which no host can create yet.
    let ownership: ReadonlyMap<string, string> = new Map([[other, 'work']]);
    const moved = new Set<() => void>();
    const owned: Parameters<typeof createMailboxes>[1] = {
      subscribe: (listener) => {
        moved.add(listener);
        const unsubscribe = registration.subscribe(listener);
        return () => {
          moved.delete(listener);
          unsubscribe();
        };
      },
      getSnapshot: () => {
        const current = registration.getSnapshot();
        const listed = mailboxesOf(current.snapshot).map((item) => ({
          ...item,
          // oxlint-disable-next-line vitest/no-conditional-in-test -- Ownership substitution keeps unmoved connections unchanged.
          profile: ownership.get(item.id) ?? item.profile,
        }));
        return {
          ...current,
          snapshot: { ...current.snapshot, mailboxes: JSON.stringify(listed) },
        };
      },
    };
    const mailboxes = createMailboxes(
      syntheticConnections({ [alex]: gmail.alex, [other]: gmail.other }),
      owned,
    );
    await mailboxes.load();
    const shown = mailboxes.getSnapshot();
    const subjects = (scope: Parameters<typeof inboxMessages>[1]) =>
      inboxMessages(shown, scope).map(({ message }) => message.subject);

    // Background synchronization continues for both Profiles, and each view names its own.
    expect(shown.map(({ id, profile }) => [id, profile])).toStrictEqual([
      [alex, defaultProfile],
      [other, 'work'],
    ]);
    expect(subjects(everything)).toStrictEqual(['Quarterly plan']);
    expect(subjects({ profile: 'work' })).toStrictEqual(['Quarterly budget']);
    // A connection named under another Profile, or a Profile owning nothing here, shows nothing.
    expect(subjects({ ...everything, mailbox: other })).toStrictEqual([]);
    expect(subjects({ profile: 'unknown' })).toStrictEqual([]);
    expect(subjects({ profile: readingProfile(undefined) })).toStrictEqual([
      'Quarterly plan',
    ]);
    for (const invalid of ['', null, [defaultProfile, 'work'], 7, {}]) {
      expect(subjects({ profile: readingProfile(invalid) })).toStrictEqual([]);
    }
    expect(
      searchMessages(inboxMessages(shown, everything), 'quarterly'),
    ).toHaveLength(1);

    // Online search asks only the scope's own Gmail.
    const searched = () =>
      gmail.other.requests.filter(({ query }) => query.has('q')).length;
    const online = createGmailSearch(shown, 'quarterly', everything);
    await online.search();
    expect(
      onlineAnswer(online.getSnapshot().found).results.map(
        ({ mailbox: { id } }) => id,
      ),
    ).toStrictEqual([alex]);
    expect(searched()).toBe(0);
    expect(online.matches(shown, 'quarterly', { profile: 'work' })).toBe(false);

    // Moving Other into the Default Profile keeps its Inbox and the mail it holds.
    const otherInbox = mailbox(shown, other).inbox;
    ownership = new Map();
    for (const listener of moved) {
      listener();
    }
    const after = mailboxes.getSnapshot();
    expect(mailbox(after, other)).toMatchObject({
      profile: defaultProfile,
      inbox: otherInbox,
    });
    expect(
      inboxMessages(after, everything).map(({ message }) => message.subject),
    ).toStrictEqual(['Quarterly budget', 'Quarterly plan']);
    expect(inboxMessages(after, { profile: 'work' })).toStrictEqual([]);

    // Profile identity is opaque: delimiter-containing values cannot hide an ownership change.
    ownership = new Map([
      [alex, 'a'],
      [other, `b\n${other}\tc`],
    ]);
    for (const listener of moved) {
      listener();
    }
    ownership = new Map([
      [alex, `a\n${other}\tb`],
      [other, 'c'],
    ]);
    for (const listener of moved) {
      listener();
    }
    expect(
      inboxMessages(mailboxes.getSnapshot(), { profile: 'a' }),
    ).toStrictEqual([]);
    expect(
      inboxMessages(mailboxes.getSnapshot(), { profile: 'c' }).map(
        ({ message }) => message.subject,
      ),
    ).toStrictEqual(['Quarterly budget']);
  });
  /* oxlint-enable vitest/max-expects */
});
