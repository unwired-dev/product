import { fireEvent, renderAsync, within } from '@testing-library/react-native';
import { View } from 'react-native';

import { languageStorage } from '../src/language-storage.ts';
import { localization } from '../src/localization.ts';
import { InboxWindow } from '../src/window.tsx';

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
// oxlint-disable-next-line vitest/prefer-import-in-mock -- Native private storage boundary.
jest.mock('../src/private-storage.ts', () => {
  const { createPersistentInbox } = jest.requireActual(
    '@private-email/mail-core/persistent-inbox',
  );
  const { makeMockInboxStorage } = jest.requireActual(
    '@private-email/mail-core/mock-storage',
  );
  return { inbox: createPersistentInbox(makeMockInboxStorage()) };
});
function Surface() {
  return (
    <View>
      <View testID="first">
        <InboxWindow windowId="first" />
      </View>
      <View testID="second">
        <InboxWindow windowId="second" />
      </View>
    </View>
  );
}

async function prepare() {
  jest.restoreAllMocks();
  await localization.setLanguage('en');
  localization.i18n.addResourceBundle('fr', 'translation', {
    inbox: {
      title: 'Boîte de réception',
      heading: 'Boîte de réception. Preview mailbox',
    },
  });
}

describe('language selection', () => {
  it('switches the visible interface to the device language and back to the saved override', async () => {
    expect.hasAssertions();
    await prepare();
    const app = await renderAsync(<Surface />);
    const first = within(app.getByTestId('first'));
    await fireEvent.press(first.getByRole('radio', { name: 'System default' }));
    await expect(first.findByText('Boîte de réception')).resolves.toBeVisible();
    expect(first.getByRole('radio', { name: 'System default' })).toBeChecked();
    const second = within(app.getByTestId('second'));
    expect(second.getByText('Boîte de réception')).toBeVisible();
    await fireEvent.press(first.getByRole('radio', { name: 'English' }));
    await expect(first.findByText('Inbox')).resolves.toBeVisible();
    expect(first.getByRole('radio', { name: 'English' })).toBeChecked();
  });

  it('shows a recoverable save error while retaining the selected language', async () => {
    expect.hasAssertions();
    await prepare();
    jest
      .spyOn(languageStorage, 'setLanguage')
      .mockRejectedValueOnce(new Error('unavailable'));
    const app = await renderAsync(<Surface />);
    const first = within(app.getByTestId('first'));
    await fireEvent.press(first.getByRole('radio', { name: 'System default' }));
    await expect(first.findByRole('alert')).resolves.toHaveTextContent(
      'The language could not be saved. Try again.',
    );
    expect(first.getByRole('radio', { name: 'English' })).toBeChecked();
    await fireEvent.press(first.getByRole('radio', { name: 'System default' }));
    await expect(first.findByText('Boîte de réception')).resolves.toBeVisible();
    expect(first.queryByRole('alert')).toBeNull();
  });
});
