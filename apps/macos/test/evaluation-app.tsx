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
}: {
  readonly drafts: ReturnType<typeof createDrafts>;
  readonly onNavigation?: (
    navigation: ReturnType<typeof useComposerNavigation>,
  ) => void;
}) {
  const mailboxes = useMemo(
    () =>
      createMailboxes(
        syntheticConnections({ [alex]: createSyntheticGmail({ messages: 1 }) }),
        registration,
      ),
    [],
  );
  const [composing, setComposing] = useState<string>();
  return (
    <AccountContext
      value={{
        mailboxes: mailboxesOf(registration.getSnapshot().snapshot),
        openAccount: () => undefined,
        authorizeMailbox: () => Promise.resolve(),
        refreshInbox: (load) => load(),
        profiles: [],
        createProfile: () => Promise.resolve(undefined),
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
