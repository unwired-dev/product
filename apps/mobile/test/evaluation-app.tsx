import type { createDrafts } from '@private-email/mail-core/drafts';
import type { RegistrationSnapshot } from '@private-email/mail-core/registration';

import { createMailboxes } from '@private-email/mail-core/mailboxes';
import { mailboxesOf } from '@private-email/mail-core/registration';
import {
  createSyntheticGmail,
  syntheticConnections,
} from '@private-email/mail-core/testing/gmail-mailbox';
import { syntheticMailboxes } from '@private-email/mail-core/testing/registration-vault';
import { useMemo, useState } from 'react';

import type { Recovered } from '../src/composer.tsx';

import { DraftComposer } from '../src/evaluation-composer.tsx';
import { Inbox } from '../src/inbox.tsx';
import { InboxProvider, useComposerNavigation } from '../src/mailbox.tsx';
import { AccountContext } from '../src/registration-gate.tsx';

export const alex = syntheticMailboxes['alex@example.invalid'];
export const registration = {
  getSnapshot: () => ({
    snapshot: {
      kind: 'connected',
      productAccountId: 'synthetic-product-account',
      signInProvider: 'google',
      mailboxes: JSON.stringify([
        { id: alex, address: 'alex@example.invalid', state: 'connected' },
      ]),
    } satisfies RegistrationSnapshot,
    busy: false,
    failed: false,
  }),
  subscribe: () => () => undefined,
};

function NavigationProbe({
  onNavigation,
}: {
  readonly onNavigation:
    | ((navigation: ReturnType<typeof useComposerNavigation>) => void)
    | undefined;
}) {
  const navigation = useComposerNavigation();
  onNavigation?.(navigation);
  return null;
}

export function App({
  drafts,
  onNavigation,
  onExpand,
  restore,
}: {
  readonly drafts: ReturnType<typeof createDrafts>;
  readonly onNavigation?: (
    navigation: ReturnType<typeof useComposerNavigation>,
  ) => void;
  // The window-level Expand, as a regular-width iPad window offers it.
  readonly onExpand?: () => void;
  // A composer recovery record the launch's offer restored, open from the start.
  readonly restore?: Recovered;
}) {
  const mailboxes = useMemo(
    () =>
      createMailboxes(
        syntheticConnections({ [alex]: createSyntheticGmail({ messages: 1 }) }),
        registration,
      ),
    [],
  );
  const [composing, setComposing] = useState(restore?.version.id);
  return (
    <AccountContext
      value={{
        mailboxes: mailboxesOf(registration.getSnapshot().snapshot),
        openAccount: () => undefined,
        authorizeMailbox: () => Promise.resolve(),
        refreshInbox: (load) => load(),
        account: 'synthetic-product-account',
        profiles: [],
        createProfile: () => Promise.resolve(undefined),
        chooseFolders: () => Promise.resolve(true),
      }}>
      <InboxProvider
        drafts={drafts}
        mailboxes={mailboxes}>
        <NavigationProbe onNavigation={onNavigation} />
        <Inbox
          composing={composing}
          onCompose={setComposing}
          onSelect={() => undefined}
          selected={undefined}
        />
        {composing === undefined ? null : (
          <DraftComposer
            id={composing}
            recovered={restore}
            onExpand={onExpand}
            onClose={() => {
              setComposing(undefined);
            }}
            onRebind={setComposing}
          />
        )}
      </InboxProvider>
    </AccountContext>
  );
}
