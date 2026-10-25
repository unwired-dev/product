import { fireEvent, render, within } from '@testing-library/react-native';
import { View } from 'react-native';

import { LanguageSettings } from '../src/language-selector.tsx';
import { languageStorage } from '../src/language-storage.ts';
import { localization } from '../src/localization.ts';
import { PreviewWindow } from '../src/window.tsx';
import { chooseMenuItem, menuItems } from './native-menu.ts';

jest.mock(
  // oxlint-disable-next-line vitest/prefer-import-in-mock -- Test-only language; production ships English.
  '../../../packages/localization/catalogs.bundle/languages.json',
  () => [
    { code: 'en', name: 'English' },
    { code: 'fr', name: 'Français' },
  ],
);
// oxlint-disable-next-line vitest/prefer-import-in-mock -- Native preference boundary.
jest.mock('../src/language-storage.ts', () => ({
  languageStorage: {
    initial: { preference: 'en', language: 'en', locale: 'en' },
    getSettings: async () => ({
      preference: null,
      language: 'fr',
      locale: 'fr-CA',
    }),
    setLanguage: async (preference: string | null) => ({
      preference,
      language: preference ?? 'fr',
      locale: preference ?? 'fr-CA',
    }),
    subscribe: jest.fn(),
  },
}));
// oxlint-disable-next-line vitest/prefer-import-in-mock -- Jest's host adapter boundary.
jest.mock('../src/private-storage.ts', () => {
  const { createPersistentInbox } = jest.requireActual(
    '@private-email/mail-core/persistent-inbox',
  );
  const { makeMockInboxStorage } = jest.requireActual(
    '@private-email/mail-core/testing/mock-storage',
  );
  const { singleMailbox } = jest.requireActual(
    '@private-email/mail-core/mailboxes',
  );
  return {
    __esModule: true,
    mailboxes: singleMailbox(
      createPersistentInbox(makeMockInboxStorage()),
      'preview',
    ),
  };
});

function Surface() {
  return (
    <View>
      <View testID="first">
        <PreviewWindow windowId="first" />
      </View>
      <View testID="second">
        <PreviewWindow windowId="second" />
      </View>
      <LanguageSettings />
    </View>
  );
}

// Settings' Language pop-up, and choosing an interface language from its menu.
const languagePopUp = (app: Awaited<ReturnType<typeof render>>) =>
  app.getByRole('button', { name: 'Language' });

async function choose(app: Awaited<ReturnType<typeof render>>, name: string) {
  await fireEvent.press(languagePopUp(app));
  await chooseMenuItem(name);
}

async function prepare() {
  jest.restoreAllMocks();
  await localization.setLanguage('en');
  localization.i18n.addResourceBundle('fr', 'translation', {
    inbox: {
      title: 'Boîte de réception',
      unifiedTitle: 'Boîte de réception',
      rowLabel: 'Courrier : {{row}}',
      subtitleLabel: '{{status}} pour {{scope}}',
    },
  });
}

describe('language selection', () => {
  /* oxlint-disable vitest/max-expects -- One language-change journey checks copy order and retained selection together. */
  it('switches the visible interface to the device language and back to the saved override', async () => {
    expect.hasAssertions();
    await prepare();
    const app = await render(<Surface />);
    const first = within(app.getByTestId('first'));
    await choose(app, 'System Default');
    await expect(
      first.findByRole('header', {
        name: /^Boîte de réception\. .* pour Preview mailbox$/u,
      }),
    ).resolves.toBeVisible();
    expect(languagePopUp(app)).toHaveAccessibilityValue({
      text: 'System Default',
    });
    expect(
      first.getByText(/unread(?: messages)? pour Preview mailbox$/u),
    ).toBeVisible();
    expect(
      first.getByRole('button', {
        name: 'Courrier : Unread. Oliver Park. Saturday, by the river?',
      }),
    ).toBeVisible();
    const second = within(app.getByTestId('second'));
    expect(
      second.getByRole('header', {
        name: /^Boîte de réception\. .* pour Preview mailbox$/u,
      }),
    ).toBeVisible();
    await fireEvent.press(languagePopUp(app));
    expect(
      menuItems().map(({ title, checked }) => [title, checked]),
    ).toStrictEqual([
      ['System Default', true],
      ['English', false],
      ['Français', false],
    ]);
    await chooseMenuItem('English');
    await expect(first.findByText('All Inboxes')).resolves.toBeVisible();
    expect(languagePopUp(app)).toHaveAccessibilityValue({ text: 'English' });
  });
  /* oxlint-enable vitest/max-expects */

  it('shows a recoverable save error while retaining the selected language', async () => {
    expect.hasAssertions();
    await prepare();
    jest
      .spyOn(languageStorage, 'setLanguage')
      .mockRejectedValueOnce(new Error('unavailable'));
    const app = await render(<Surface />);
    const first = within(app.getByTestId('first'));
    await choose(app, 'System Default');
    await expect(app.findByRole('alert')).resolves.toHaveTextContent(
      'The language could not be saved. Try again.',
    );
    expect(languagePopUp(app)).toHaveAccessibilityValue({ text: 'English' });
    await choose(app, 'System Default');
    await expect(
      first.findByRole('header', {
        name: /^Boîte de réception\. .* pour Preview mailbox$/u,
      }),
    ).resolves.toBeVisible();
    expect(app.queryByRole('alert')).toBeNull();
  });
});
