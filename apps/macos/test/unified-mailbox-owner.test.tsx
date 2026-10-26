import type { ImapInbox } from '@private-email/mail-core/imap-inbox';

import { createImapInbox } from '@private-email/mail-core/imap-inbox';
import { defaultProfile } from '@private-email/mail-core/registration';
import { createSyntheticImap } from '@private-email/mail-core/testing/imap-mailbox';
import { renderHook, waitFor } from '@testing-library/react-native';
import { useSyncExternalStore } from 'react';

import { useListedMailbox } from '../src/mailbox-folders.tsx';

const keepView = () => undefined;

describe('unified mailbox owner replacement', () => {
  it('opens the replacement store’s role folder even when the connection and folder names stay the same', async () => {
    expect.hasAssertions();
    const original = createSyntheticImap();
    original.addFolder('Archive', ['archive']);
    original.deliver('Archive', { subject: 'Original archive' });
    const first = createImapInbox(original.native);
    await first.load();
    const replacement = createSyntheticImap();
    replacement.addFolder('Archive', ['archive']);
    replacement.deliver('Archive', { subject: 'Replacement archive' });
    const second = createImapInbox(replacement.native);
    await second.load();
    const app = await renderHook(
      ({ inbox }: Readonly<{ inbox: ImapInbox }>) => {
        const state = useSyncExternalStore(inbox.subscribe, inbox.getSnapshot);
        return useListedMailbox(
          [
            {
              id: 'connection',
              provider: 'imap',
              profile: defaultProfile,
              inbox,
              state,
            },
          ],
          [],
          { view: { unified: 'ARCHIVE' }, onView: keepView },
        );
      },
      { initialProps: { inbox: first } },
    );
    try {
      await waitFor(() => {
        expect(
          app.result.current.listed.map(({ message }) => message.subject),
        ).toStrictEqual(['Original archive']);
      });
      await app.rerender({ inbox: second });
      await waitFor(() => {
        expect(
          app.result.current.listed.map(({ message }) => message.subject),
        ).toStrictEqual(['Replacement archive']);
      });
    } finally {
      await app.unmount();
    }
  });
});
