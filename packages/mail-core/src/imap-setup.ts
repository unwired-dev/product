// A reviewed IMAP endpoint: implicit TLS on `port`, and the address the mailbox receives at.
export type ImapSetup = Readonly<{
  address: string;
  host: string;
  port: number;
  username: string;
  password: string;
}>;

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
