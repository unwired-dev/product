import * as Effect from 'effect/Effect';

import type {
  NativeRegistrationVault,
  RegistrationRecord,
  SetupReason,
} from './registration-vault.ts';
import type { MailGrantProvider, MailProvider } from './registration.ts';

import { endsAccess, failWith, nativeSteps } from './registration-native.ts';
import { MailboxIdentity, MailboxReceipt } from './registration-vault.ts';

// Any of these grants reads the provider's mail; Microsoft may name scopes with Graph's prefix.
const mailScopes: Readonly<Record<MailGrantProvider, ReadonlySet<string>>> = {
  gmail: new Set([
    'https://www.googleapis.com/auth/gmail.modify',
    'https://mail.google.com/',
  ]),
  'microsoft-graph': new Set(['mail.read', 'mail.readwrite']),
};
const grantsMail = (provider: MailGrantProvider, scope: string) =>
  mailScopes[provider].has(
    provider === 'gmail'
      ? scope
      : scope.toLowerCase().replace(/^https:\/\/graph\.microsoft\.com\//u, ''),
  );
// The setup reason for a provider that refused the mailbox, its grant or its IMAP password.
export const unavailableReason = (provider: MailProvider): SetupReason => {
  if (provider === 'imap') {
    return 'imap-refused';
  }
  return provider === 'gmail' ? 'gmail-unavailable' : 'microsoft-unavailable';
};
// The first Gmail mailbox suggests the Google Product Sign-In's account. An Apple identity or its
// relay address is never a Google account hint, and a Google one never suggests another provider.
// Another mailbox is chosen without one.
export const suggestsSignIn = (
  value: RegistrationRecord,
  provider: MailGrantProvider,
  chooseAccount: boolean,
) =>
  provider === 'gmail' &&
  !chooseAccount &&
  value.mailboxes.length === 0 &&
  value.signInProvider === 'google';
// Why an authorization of the provider's mailbox ended without one.
export const setupReason = (
  provider: MailGrantProvider,
  code: string,
): SetupReason => {
  if (code === 'gmail-unavailable') {
    return unavailableReason(provider);
  }
  return code === 'cancelled' || code === 'declined' ? code : 'interrupted';
};

// Provider access verification is independent of Product Sign-In and its device admission.
export function createMailboxVerification(vault: NativeRegistrationVault) {
  const { native, step } = nativeSteps(vault);
  const checkedMailbox = Effect.fnUntraced(function* (
    provider: MailGrantProvider,
    scopes: readonly string[],
  ) {
    if (!scopes.some((scope) => grantsMail(provider, scope))) {
      return yield* failWith('declined');
    }
    return yield* native(vault.verifyMailbox, MailboxReceipt);
  });

  // An IMAP connection verifies by logging in again. Only a refused password asks for it again;
  // any other failure keeps the saved Inbox open, unless the password was refused before.
  const imapStatus = (mailbox: RegistrationRecord['mailboxes'][number]) =>
    step(() => vault.verifyImap(mailbox.id)).pipe(
      Effect.catchIf(
        (error) => !endsAccess.has(error.code),
        ({ code }) => {
          let access: 'cached' | 'authorization' | 'unverified' =
            mailbox.authorizationNeeded ? 'unverified' : 'cached';
          if (code === 'imap-refused') {
            access = 'authorization';
          }
          return step(() => vault.markMailbox(mailbox.id, access));
        },
      ),
    );

  // A connection authorized through its provider's sign-in verifies by renewing that grant.
  const grantStatus = (
    mailbox: RegistrationRecord['mailboxes'][number],
    provider: MailGrantProvider,
  ) =>
    native(() => vault.refreshMailbox(mailbox.id), MailboxIdentity).pipe(
      Effect.flatMap(({ scopes }) => checkedMailbox(provider, scopes)),
      Effect.andThen(step(() => vault.confirmMailbox(mailbox.id))),
      // Cached consent is never proof of usable mail access; a refused grant never opens its
      // saved mail.
      Effect.catchIf(
        (error) => !endsAccess.has(error.code),
        ({ code }) => {
          // Offline keeps the saved Inbox open unless its provider already refused this grant.
          const offline = mailbox.authorizationNeeded ? 'unverified' : 'cached';
          return step(() =>
            vault.markMailbox(
              mailbox.id,
              code === 'offline' ? offline : 'authorization',
            ),
          );
        },
      ),
    );

  return {
    checkedMailbox,
    verify: (mailbox: RegistrationRecord['mailboxes'][number]) =>
      mailbox.provider === 'imap'
        ? imapStatus(mailbox)
        : grantStatus(mailbox, mailbox.provider),
  };
}
