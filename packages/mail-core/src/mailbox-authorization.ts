import type { RegistrationRecord, SetupReason } from './registration-vault.ts';
import type { MailProvider } from './registration.ts';

// Any of these grants reads the provider's mail; Microsoft may name scopes with Graph's prefix.
const mailScopes: Readonly<Record<MailProvider, ReadonlySet<string>>> = {
  gmail: new Set([
    'https://www.googleapis.com/auth/gmail.modify',
    'https://mail.google.com/',
  ]),
  'microsoft-graph': new Set(['mail.read', 'mail.readwrite']),
};
export const grantsMail = (provider: MailProvider, scope: string) =>
  mailScopes[provider].has(
    provider === 'gmail'
      ? scope
      : scope.toLowerCase().replace(/^https:\/\/graph\.microsoft\.com\//u, ''),
  );
// The setup reason for a provider that refused the mailbox or its grant.
export const unavailableReason = (provider: MailProvider) =>
  provider === 'gmail' ? 'gmail-unavailable' : 'microsoft-unavailable';
// The first Gmail mailbox suggests the Google Product Sign-In's account. An Apple identity or its
// relay address is never a Google account hint, and a Google one never suggests another provider.
// Another mailbox is chosen without one.
export const suggestsSignIn = (
  value: RegistrationRecord,
  provider: MailProvider,
  chooseAccount: boolean,
) =>
  provider === 'gmail' &&
  !chooseAccount &&
  value.mailboxes.length === 0 &&
  value.signInProvider === 'google';
// Why an authorization of the provider's mailbox ended without one.
export const setupReason = (
  provider: MailProvider,
  code: string,
): SetupReason => {
  if (code === 'gmail-unavailable') {
    return unavailableReason(provider);
  }
  return code === 'cancelled' || code === 'declined' ? code : 'interrupted';
};
