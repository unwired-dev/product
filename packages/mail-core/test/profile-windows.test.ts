import { english } from '@private-email/localization';
import { menuState } from '@private-email/mail-core/context-menu';
import {
  createProfileChoices,
  profileMenu,
  profileMonogram,
  windowProfile,
} from '@private-email/mail-core/profile-windows';
import {
  defaultProfile,
  mailboxesOf,
  profilesOf,
} from '@private-email/mail-core/registration';
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
    const { sections, runs } = menuState(
      profileMenu(english, {
        profiles: profilesOf(snapshot),
        connections: mailboxesOf(snapshot),
        mailboxes: [],
        current: workId,
        onSwitch,
        onCreate,
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
          },
          {
            id: `profile\n${workId}`,
            title: 'Work',
            symbol: '',
            destructive: undefined,
            subtitle: 'Gmail',
            checked: true,
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
          },
        ],
      },
    ]);
    await runs.get(`profile\n${defaultProfile}`)?.();
    await runs.get('profile\nnew')?.();
    expect(onSwitch).toHaveBeenCalledExactlyOnceWith(defaultProfile);
    expect(onCreate.mock.calls).toStrictEqual([[]]);
  });

  it('shows the first letters of the first two words', () => {
    expect.hasAssertions();
    expect(profileMonogram('Primary Profile')).toBe('PP');
    expect(profileMonogram('  work ')).toBe('W');
    expect(profileMonogram('Émile Zola Fan')).toBe('ÉZ');
  });

  it('restores the saved window Profile and keeps the Startup Profile', async () => {
    expect.hasAssertions();
    const saved = new Map([['startup-profile', 'work']]);
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
    expect(choices.getSnapshot()).toBeUndefined();
    await choices.load();
    expect(choices.getSnapshot()).toStrictEqual({
      restored: undefined,
      startup: 'work',
    });
    await choices.restore('work');
    await choices.restore('work');
    expect(setPreference).toHaveBeenCalledExactlyOnceWith(
      'window-profile',
      'work',
    );
    // The next launch reads it back.
    const relaunched = createProfileChoices(native);
    await relaunched.load();
    expect(relaunched.getSnapshot()?.restored).toBe('work');
  });

  it('reads an unreadable saved choice as none', async () => {
    expect.hasAssertions();
    const choices = createProfileChoices({
      preference: () => Promise.reject(new Error('locked')),
      setPreference: () => Promise.resolve({}),
    });
    await choices.load();
    expect(choices.getSnapshot()).toStrictEqual({
      restored: undefined,
      startup: undefined,
    });
  });
});
