import type { LanguageSettings } from '../src/index.ts';

import { createLocalization } from '../src/index.ts';

vi.mock(import('../catalogs.bundle/languages.json'), () => ({
  default: [
    { code: 'en', name: 'English' },
    { code: 'fr', name: 'Français' },
  ],
}));

function storage() {
  let settings: LanguageSettings = {
    preference: null,
    language: 'en',
    locale: 'en-GB',
  };
  return {
    getSettings: async () => settings,
    async setLanguage(preference: string | null) {
      settings = {
        preference,
        language: preference ?? 'en',
        locale: preference ?? 'en-GB',
      };
      return settings;
    },
  };
}

describe('interface language', () => {
  it('rejects malformed native settings before publishing and accepts a later valid update', async () => {
    expect.hasAssertions();
    const native = storage();
    const initial = await native.getSettings();
    let reply: unknown = initial;
    const app = createLocalization(initial, {
      getSettings: async () => reply,
      setLanguage: async () => reply,
    });
    const listener = vi.fn<() => void>();
    app.subscribe(listener);
    for (const invalid of [
      {},
      { ...initial, preference: 'unsupported' },
      { ...initial, language: 42 },
      { ...initial, locale: 'not_a_locale' },
    ]) {
      expect(() => createLocalization(invalid, native)).toThrow(
        'Invalid native language settings.',
      );
      reply = invalid;
      await expect(app.refresh()).rejects.toThrow(
        'Invalid native language settings.',
      );
      await expect(app.setLanguage('en')).rejects.toThrow(
        'Invalid native language settings.',
      );
      expect({
        settings: app.getSnapshot(),
        language: app.i18n.language,
        publications: listener.mock.calls.length,
      }).toStrictEqual({ settings: initial, language: 'en', publications: 0 });
    }
    reply = { preference: 'en', language: 'en', locale: 'en' };
    await app.setLanguage('en');
    expect({
      settings: app.getSnapshot(),
      publications: listener.mock.calls.length,
    }).toStrictEqual({ settings: reply, publications: 1 });
  });

  it('renders English on first use, preserves message text, and falls back for untranslated keys', async () => {
    expect.hasAssertions();
    const native = storage();
    const app = createLocalization(await native.getSettings(), native);
    expect(app.i18n.t('inbox.title')).toBe('Inbox');
    expect(
      app.i18n.t('inbox.unreadRow', { sender: 'A & B', subject: '<Hello>' }),
    ).toBe('Unread. A & B. <Hello>');
    // A future, partial locale exercises the configured fallback and plural pipeline.
    app.i18n.addResourceBundle('fr', 'translation', {
      inbox: {
        title: 'Boîte de réception',
        messages_one: '{{count}} message',
        messages_other: '{{count}} messages',
      },
    });
    await app.i18n.changeLanguage('fr');
    expect(app.i18n.t('inbox.title')).toBe('Boîte de réception');
    expect(app.i18n.t('message.markRead')).toBe('Mark as read');
    expect([
      app.i18n.t('inbox.messages', { count: 1 }),
      app.i18n.t('inbox.messages', { count: 2 }),
    ]).toStrictEqual(['1 message', '2 messages']);
  });

  it('persists the explicit choice across recreation and returns to the system region', async () => {
    expect.hasAssertions();
    const native = storage();
    const app = createLocalization(await native.getSettings(), native);
    await app.setLanguage('en');
    const relaunched = createLocalization(await native.getSettings(), native);
    expect(relaunched.getSnapshot()).toStrictEqual({
      preference: 'en',
      language: 'en',
      locale: 'en',
    });
    await relaunched.setLanguage(null);
    expect(relaunched.getSnapshot()).toStrictEqual({
      preference: null,
      language: 'en',
      locale: 'en-GB',
    });
  });

  it('orders concurrent window changes and refreshes without reviving an older preference', async () => {
    expect.hasAssertions();
    const native = storage();
    const app = createLocalization(await native.getSettings(), native);
    await Promise.all([
      app.setLanguage('en'),
      app.refresh(),
      app.setLanguage(null),
    ]);
    expect(app.getSnapshot().preference).toBeNull();
    const saved = await native.getSettings();
    expect(saved.preference).toBeNull();
  });

  it('keeps the current language after a failed write and allows a later retry', async () => {
    expect.hasAssertions();
    const native = storage();
    let write: typeof native.setLanguage = () =>
      Promise.reject(new Error('unavailable'));
    const app = createLocalization(await native.getSettings(), {
      ...native,
      setLanguage: (language) => write(language),
    });
    await expect(app.setLanguage('en')).rejects.toThrow('unavailable');
    expect(app.getSnapshot().preference).toBeNull();
    write = native.setLanguage;
    await app.setLanguage('en');
    expect(app.getSnapshot().preference).toBe('en');
  });
});
