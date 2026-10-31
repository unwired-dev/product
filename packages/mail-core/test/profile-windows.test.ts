import { createLocalization, english } from '@private-email/localization';
import { menuState } from '@private-email/mail-core/context-menu';
import { createGmailInbox } from '@private-email/mail-core/gmail-inbox';
import {
  createProfileChoices,
  profileMenu,
  profileMonogram,
  profileRefusalText,
  profileRemoval,
  windowProfile,
} from '@private-email/mail-core/profile-windows';
import {
  createRegistration,
  defaultProfile,
  mailboxesOf,
  profilesOf,
} from '@private-email/mail-core/registration';
import { createSyntheticGmail } from '@private-email/mail-core/testing/gmail-mailbox';
import { createTwoProfileRegistration } from '@private-email/mail-core/testing/registration-scenarios';

const work = { id: 'work', name: 'Work' };

describe('window Profiles', () => {
  it('opens a link, then the restored, Startup and Default Profiles it still lists', () => {
    expect.hasAssertions();
    const profiles = [work];
    expect(windowProfile({ link: 'other', restored: 'work', profiles })).toBe(
      'other',
    );
    // A malformed link opens nothing rather than falling back.
    expect(windowProfile({ link: ['work', 'work'], profiles })).toBe('');
    expect(
      windowProfile({ restored: 'work', startup: defaultProfile, profiles }),
    ).toBe('work');
    expect(windowProfile({ restored: 'gone', startup: 'work', profiles })).toBe(
      'work',
    );
    expect(windowProfile({ restored: 'gone', startup: 'gone', profiles })).toBe(
      defaultProfile,
    );
  });

  it('lists the two-Profile session in the Profile Menu, checking the window’s own', async () => {
    expect.hasAssertions();
    const { registration, work: workId } = await createTwoProfileRegistration();
    const { snapshot } = registration.getSnapshot();
    const onSwitch = vi.fn<(profile: string) => void>();
    const onCreate = vi.fn<() => void>();
    const onManage = vi.fn<() => void>();
    const { sections, runs } = menuState(
      profileMenu(english, {
        profiles: profilesOf(snapshot),
        connections: mailboxesOf(snapshot),
        mailboxes: [],
        current: workId,
        onSwitch,
        onCreate,
        onManage,
      }),
    );
    expect(sections).toStrictEqual([
      {
        palette: undefined,
        items: [
          {
            id: `profile\n${defaultProfile}`,
            title: 'Primary Profile',
            symbol: '',
            destructive: undefined,
            subtitle: 'Gmail',
            checked: false,
            disabled: undefined,
            accessibilityLabel: undefined,
          },
          {
            id: `profile\n${workId}`,
            title: 'Work',
            symbol: '',
            destructive: undefined,
            subtitle: 'Gmail',
            checked: true,
            disabled: undefined,
            accessibilityLabel: undefined,
          },
        ],
      },
      {
        palette: undefined,
        items: [
          {
            id: 'profile\nnew',
            title: 'New Mail Profile…',
            symbol: 'plus',
            destructive: undefined,
            subtitle: undefined,
            checked: undefined,
            disabled: undefined,
            accessibilityLabel: undefined,
          },
          {
            id: 'profile\nmanage',
            title: 'Manage Mail Profiles…',
            symbol: 'gearshape',
            destructive: undefined,
            subtitle: undefined,
            checked: undefined,
            disabled: undefined,
            accessibilityLabel: undefined,
          },
        ],
      },
    ]);
    // The checked row is the window's own Profile; choosing it changes nothing.
    await runs.get(`profile\n${workId}`)?.();
    await runs.get(`profile\n${defaultProfile}`)?.();
    await runs.get('profile\nnew')?.();
    await runs.get('profile\nmanage')?.();
    expect(onSwitch).toHaveBeenCalledExactlyOnceWith(defaultProfile);
    expect(onCreate.mock.calls).toStrictEqual([[]]);
    expect(onManage.mock.calls).toStrictEqual([[]]);
  });

  it('counts each Profile’s own unread mail', async () => {
    expect.hasAssertions();
    const { registration, work: workId } = await createTwoProfileRegistration();
    const { snapshot } = registration.getSnapshot();
    const connections = mailboxesOf(snapshot);
    const unreadIn = async (count: number) => {
      const gmail = createSyntheticGmail();
      for (const subject of ['First', 'Second', 'Third'].slice(0, count)) {
        gmail.deliver({ subject });
      }
      const inbox = createGmailInbox(gmail.native);
      await inbox.load();
      return inbox.getSnapshot();
    };
    const mailboxes = await Promise.all(
      connections.map(async ({ id, profile }) => ({
        id,
        provider: 'gmail' as const,
        profile,
        // oxlint-disable-next-line vitest/no-conditional-in-test -- One unread message for the Primary Profile's mailbox, three for Work's.
        state: await unreadIn(profile === defaultProfile ? 1 : 3),
      })),
    );
    const { sections } = menuState(
      profileMenu(english, {
        profiles: profilesOf(snapshot),
        connections,
        mailboxes,
        current: defaultProfile,
        onSwitch: () => undefined,
        onCreate: () => undefined,
        onManage: () => undefined,
      }),
    );
    expect(sections[0]?.items.map(({ subtitle }) => subtitle)).toStrictEqual([
      'Gmail · 1 unread',
      'Gmail · 3 unread',
    ]);
    expect(sections[0]?.items[1]?.id).toBe(`profile\n${workId}`);
  });

  it('lets translations order the complete Profile subtitle and its provider list', async () => {
    expect.hasAssertions();
    const { registration, work: workId } = await createTwoProfileRegistration();
    const { snapshot } = registration.getSnapshot();
    const settings = { preference: null, language: 'en', locale: 'en-US' };
    const { i18n } = createLocalization(settings, {
      getSettings: async () => settings,
      setLanguage: async () => settings,
    });
    i18n.addResourceBundle(
      'en',
      'translation',
      {
        profiles: {
          connections: '{{provider}} / {{connections}}',
          detail_zero: '{{connections}}; idle',
          detail_authorization_zero: '{{connections}}; authorize',
        },
      },
      true,
      true,
    );
    const sections = profileMenu(i18n.getFixedT('en'), {
      profiles: profilesOf(snapshot),
      connections: [
        ...mailboxesOf(snapshot),
        {
          id: 'additional',
          address: 'additional@example.invalid',
          profile: defaultProfile,
          provider: 'microsoft-graph',
          state: 'authorization',
        },
      ],
      mailboxes: [],
      current: workId,
      onSwitch: () => undefined,
      onCreate: () => undefined,
      onManage: () => undefined,
    });
    expect(sections[0]?.items.map(({ subtitle }) => subtitle)).toStrictEqual([
      'Microsoft / Gmail; authorize',
      'Gmail; idle',
    ]);
  });

  it('names the mailboxes a Profile removal also removes', () => {
    expect.hasAssertions();
    const mailbox = {
      id: 'one',
      provider: 'imap' as const,
      address: 'bob@example.invalid',
      state: 'connected' as const,
      profile: 'work',
    };
    expect(profileRemoval(english, 'Family', [])).toStrictEqual({
      title: 'Remove “Family”?',
      message:
        'Family is removed from all your Trusted Devices. It owns no mailboxes.',
    });
    expect(profileRemoval(english, 'Work', [mailbox]).message).toBe(
      'bob@example.invalid is also removed from Unwired Mail on all your devices. Its mail stays with the mail server.',
    );
    expect(
      profileRemoval(english, 'Work', [
        mailbox,
        { ...mailbox, id: 'two', address: 'ann@example.invalid' },
      ]).message,
    ).toBe(
      'bob@example.invalid, ann@example.invalid are also removed from Unwired Mail on all your devices. Their mail stays with their providers.',
    );
    expect(
      profileRefusalText(english, 'move', 'profile-changed'),
    ).toStrictEqual({
      title: 'Mailbox Not Moved',
      message:
        'Another device changed these Mail Profiles first. Check them, then try again.',
    });
  });

  it('explains each refused move and removal', () => {
    expect.hasAssertions();
    expect(profileRefusalText(english, 'remove', 'failed').message).toBe(
      'The Mail Profile could not be removed. Try again.',
    );
    expect(
      profileRefusalText(english, 'move', 'upgrade-required').message,
    ).toBe(
      'Another Trusted Device runs a version of Unwired Mail that can’t keep Mail Profiles apart. Update it, then try again.',
    );
  });

  it('shows the first letters of the first two words', () => {
    expect.hasAssertions();
    expect(profileMonogram('Primary Profile')).toBe('PP');
    expect(profileMonogram('  work ')).toBe('W');
    expect(profileMonogram('Émile Zola Fan')).toBe('ÉZ');
  });

  it('restores the saved window Profile and saves the chosen Startup Profile', async () => {
    expect.hasAssertions();
    const saved = new Map([['startup-profile:account-a', 'work']]);
    const setPreference = vi.fn<
      (key: string, value: string) => Promise<unknown>
    >((key, value) => {
      saved.set(key, value);
      return Promise.resolve({});
    });
    const native = {
      preference: (key: string) =>
        // oxlint-disable-next-line vitest/no-conditional-in-test -- An unsaved key reads as null.
        Promise.resolve({ value: saved.get(key) ?? null }),
      setPreference,
    };
    const choices = createProfileChoices(native);
    expect(choices.getSnapshot('account-a')).toBeUndefined();
    await choices.load('account-a');
    expect(choices.getSnapshot('account-a')).toStrictEqual({
      restored: undefined,
      startup: 'work',
    });
    await choices.restore('account-a', 'work');
    await choices.restore('account-a', 'work');
    await choices.chooseStartup('account-a', defaultProfile);
    expect(setPreference.mock.calls).toStrictEqual([
      ['window-profile', 'work'],
      ['startup-profile:account-a', defaultProfile],
    ]);
    // The next launch reads both back.
    const relaunched = createProfileChoices(native);
    await relaunched.load('account-a');
    expect(relaunched.getSnapshot('account-a')).toStrictEqual({
      restored: 'work',
      startup: defaultProfile,
    });
  });

  it('keeps each Product Account’s Startup Profile after another account saves its choice', async () => {
    expect.hasAssertions();
    const saved = new Map<string, string>();
    const native = {
      preference: (key: string) =>
        // oxlint-disable-next-line vitest/no-conditional-in-test -- An unsaved key reads as null.
        Promise.resolve({ value: saved.get(key) ?? null }),
      setPreference: (key: string, value: string) => {
        saved.set(key, value);
        return Promise.resolve({});
      },
    };
    const first = createProfileChoices(native);
    const second = createProfileChoices(native);
    await first.load('account-a');
    await first.chooseStartup('account-a', 'work');
    await second.load('account-b');
    await second.chooseStartup('account-b', 'office');
    expect(first.getSnapshot('account-b')).toBeUndefined();
    await first.load('account-b');
    expect(first.getSnapshot('account-b')?.startup).toBe('office');
    expect(first.getSnapshot('account-a')?.startup).toBe('work');
    const reopened = createProfileChoices(native);
    await reopened.load('account-a');
    expect(
      windowProfile({
        startup: reopened.getSnapshot('account-a')?.startup,
        profiles: [work],
      }),
    ).toBe('work');
  });

  it.each([
    ['keeps', false, ['Office', 'Family']],
    ['retires', true, []],
  ] as const)(
    '%s queued Profile edits when activation finishes or the account leaves',
    async (_action, retire, names) => {
      expect.hasAssertions();
      const { vault, work: workId } = await createTwoProfileRegistration();
      let beforeRead: (() => Promise<void>) | undefined = undefined;
      const store = createRegistration({
        ...vault,
        registration: async () => {
          const hook = beforeRead;
          beforeRead = undefined;
          await hook?.();
          return vault.registration();
        },
      });
      await store.restore();
      const entered = Promise.withResolvers<undefined>();
      const release = Promise.withResolvers<undefined>();
      beforeRead = async () => {
        entered.resolve(undefined);
        await release.promise;
      };
      const resuming = store.resume();
      await entered.promise;
      try {
        const renaming = store.renameProfile(workId, 'Office');
        const creating = store.createProfile('Family');
        // oxlint-disable-next-line vitest/no-conditional-in-test -- The second fixed case removes the account during the held activation.
        if (retire) {
          await vault.purge('revoked');
        }
        release.resolve(undefined);
        await Promise.all([resuming, renaming, creating]);
        expect(
          profilesOf(store.getSnapshot().snapshot).map(({ name }) => name),
        ).toStrictEqual(names);
        expect(store.getSnapshot().profileFailure).toBeUndefined();
        expect(store.getSnapshot()).toMatchObject({
          busy: false,
          failed: false,
        });
      } finally {
        release.resolve(undefined);
        await resuming;
      }
    },
  );

  it.each([
    [false, ['alex@example.invalid', 'other@example.invalid']],
    [true, []],
  ] as const)(
    'keeps confirmed moves and removals through activation and retires them on account loss (%s)',
    async (retire, addresses) => {
      expect.hasAssertions();
      const { vault, work: workId } = await createTwoProfileRegistration();
      let beforeRead: (() => Promise<void>) | undefined = undefined;
      const store = createRegistration({
        ...vault,
        registration: async () => {
          const hook = beforeRead;
          beforeRead = undefined;
          await hook?.();
          return vault.registration();
        },
      });
      await store.restore();
      const confirmed = mailboxesOf(store.getSnapshot().snapshot)
        .filter(({ profile }) => profile === workId)
        .map(({ id }) => id);
      const entered = Promise.withResolvers<undefined>();
      const release = Promise.withResolvers<undefined>();
      beforeRead = async () => {
        entered.resolve(undefined);
        await release.promise;
      };
      const resuming = store.resume();
      await entered.promise;
      try {
        const moving = confirmed.map((id) =>
          store.moveMailbox(id, defaultProfile),
        );
        const removing = store.removeProfile(workId, confirmed);
        // oxlint-disable-next-line vitest/no-conditional-in-test -- The second case loses the account while foreground verification is held.
        if (retire) {
          await vault.purge('revoked');
        }
        release.resolve(undefined);
        await Promise.all([resuming, ...moving, removing]);
        expect(profilesOf(store.getSnapshot().snapshot)).toStrictEqual([]);
        expect(
          mailboxesOf(store.getSnapshot().snapshot).map(
            ({ address }) => address,
          ),
        ).toStrictEqual(addresses);
        expect(store.getSnapshot().profileFailure).toBeUndefined();
      } finally {
        release.resolve(undefined);
        await resuming;
      }
    },
  );

  it('reads a malformed saved choice as none', async () => {
    expect.hasAssertions();
    const choices = createProfileChoices({
      preference: () => Promise.resolve({ value: 5 }),
      setPreference: () => Promise.resolve({}),
    });
    await choices.load('account-a');
    expect(choices.getSnapshot('account-a')).toStrictEqual({
      restored: undefined,
      startup: undefined,
    });
  });

  it('reads an unreadable saved choice as none', async () => {
    expect.hasAssertions();
    const choices = createProfileChoices({
      preference: () => Promise.reject(new Error('locked')),
      setPreference: () => Promise.resolve({}),
    });
    await choices.load('account-a');
    expect(choices.getSnapshot('account-a')).toStrictEqual({
      restored: undefined,
      startup: undefined,
    });
  });
});
