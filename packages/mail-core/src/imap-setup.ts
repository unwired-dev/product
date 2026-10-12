import * as Schema from 'effect/Schema';

// A reviewed IMAP endpoint: implicit TLS on `port`, and the address the mailbox receives at.
export type ImapSetup = Readonly<{
  address: string;
  host: string;
  port: number;
  username: string;
  password: string;
}>;

// A connection's reviewed endpoint as native storage projects it; never its password.
export const ImapEndpointSchema = Schema.Struct({
  host: Schema.NonEmptyString,
  port: Schema.Int.check(Schema.isBetween({ minimum: 1, maximum: 65_535 })),
  username: Schema.NonEmptyString,
});
// An IMAP connection carries its endpoint, and no other connection has one.
export const endpointMatchesProvider = (
  mailbox: Readonly<{ provider: string; imap?: unknown }>,
) => (mailbox.provider === 'imap') === (mailbox.imap !== undefined);

// Reviewed IMAP endpoints. Each uses implicit TLS on 993 and an app-specific password; a manual
// server names its own endpoint, which the person reviews before connecting.
export const imapProviders = {
  icloud: {
    host: 'imap.mail.me.com',
    port: 993,
    // iCloud Mail signs in with the name part of the address.
    username: (address: string) => address.split('@')[0] ?? '',
  },
  fastmail: {
    host: 'imap.fastmail.com',
    port: 993,
    username: (address: string) => address,
  },
} as const;
export type ImapProvider = keyof typeof imapProviders | 'other';

// The setup to try once more when the server refuses this one: iCloud Mail accepts the full
// address where it refuses the name part, as Apple's mail settings direct.
export const imapFallback = (setup: ImapSetup): ImapSetup | undefined =>
  setup.host === imapProviders.icloud.host && setup.username !== setup.address
    ? { ...setup, username: setup.address }
    : undefined;

export type ImapFields = Readonly<{
  address: string;
  password: string;
  // Only a manual server's are used; reviewed providers supply their own.
  host: string;
  port: string;
  username: string;
}>;

// The endpoint a form describes, or undefined while any field is missing or malformed. The
// native vault validates the endpoint again before connecting.
export function imapSetup(
  provider: ImapProvider,
  fields: ImapFields,
): ImapSetup | undefined {
  const address = fields.address.trim();
  if (!/^[^\s@]+@[^\s@]+$/u.test(address) || fields.password === '') {
    return undefined;
  }
  if (provider !== 'other') {
    const { host, port, username } = imapProviders[provider];
    return {
      address,
      host,
      port,
      username: username(address),
      password: fields.password,
    };
  }
  const port = Number(fields.port.trim());
  const host = fields.host.trim().toLowerCase();
  const username =
    fields.username.trim() === '' ? address : fields.username.trim();
  if (
    !Number.isInteger(port) ||
    port < 1 ||
    port > 65_535 ||
    !/^[\da-z](?:[\da-z-]{0,61}[\da-z])?(?:\.[\da-z](?:[\da-z-]{0,61}[\da-z])?)+$/u.test(
      host,
    )
  ) {
    return undefined;
  }
  return { address, host, port, username, password: fields.password };
}
