import * as Schema from 'effect/Schema';

// How an SMTP session reaches TLS: from the first byte, or by STARTTLS before authentication.
export type SmtpSecurity = 'tls' | 'starttls';

// A reviewed SMTP endpoint. Without its own password, SMTP uses the IMAP password.
export type SmtpSetup = Readonly<{
  host: string;
  port: number;
  security: SmtpSecurity;
  username: string;
  password?: string;
}>;

// A reviewed IMAP endpoint: implicit TLS on `port`, the address the mailbox receives at, and the
// SMTP endpoint it sends through.
export type ImapSetup = Readonly<{
  address: string;
  host: string;
  port: number;
  username: string;
  password: string;
  smtp: SmtpSetup;
}>;

// A server's host name and port.
const ServerSchema = Schema.Struct({
  host: Schema.NonEmptyString,
  port: Schema.Int.check(Schema.isBetween({ minimum: 1, maximum: 65_535 })),
});
// A connection's reviewed endpoint as native storage projects it; never its password.
export const ImapEndpointSchema = Schema.Struct({
  ...ServerSchema.fields,
  username: Schema.NonEmptyString,
});
export const SmtpEndpointSchema = Schema.Struct({
  host: Schema.NonEmptyString,
  port: Schema.Int.check(Schema.isBetween({ minimum: 1, maximum: 65_535 })),
  security: Schema.Literals(['tls', 'starttls']),
  username: Schema.NonEmptyString,
});
// An IMAP connection carries its endpoint, and no other connection has one. Only an IMAP
// connection has an SMTP endpoint; one saved before SMTP has none and receives only.
export const endpointMatchesProvider = (
  mailbox: Readonly<{ provider: string; imap?: unknown; smtp?: unknown }>,
) =>
  (mailbox.provider === 'imap') === (mailbox.imap !== undefined) &&
  (mailbox.imap !== undefined || mailbox.smtp === undefined);

// Reviewed IMAP and SMTP endpoints. IMAP uses implicit TLS on 993, and one app-specific password
// signs in to both; a manual server names its own endpoints, which the person reviews before
// connecting.
export const imapProviders = {
  icloud: {
    host: 'imap.mail.me.com',
    port: 993,
    // iCloud Mail signs in with the name part of the address.
    username: (address: string) => address.split('@')[0] ?? '',
    // iCloud Mail sends only with STARTTLS on 587, signing in with the full address.
    smtp: { host: 'smtp.mail.me.com', port: 587, security: 'starttls' },
  },
  fastmail: {
    host: 'imap.fastmail.com',
    port: 993,
    username: (address: string) => address,
    smtp: { host: 'smtp.fastmail.com', port: 465, security: 'tls' },
  },
} as const;
export type ImapProvider = keyof typeof imapProviders | 'other';

// The reviewed provider a saved endpoint belongs to, whose guidance its password repair shows.
export const imapPresetOf = (
  endpoint: Readonly<{ host: string; port: number }>,
): ImapProvider =>
  (['icloud', 'fastmail'] as const).find(
    (preset) =>
      imapProviders[preset].host === endpoint.host &&
      imapProviders[preset].port === endpoint.port,
  ) ?? 'other';

// Reviewed endpoints for an address's domain, from each provider's own settings page
// (docs/imap-mailboxes.md). They sign in with the full address unless the provider says otherwise.
const catalog = [
  { domains: ['icloud.com', 'me.com', 'mac.com'], ...imapProviders.icloud },
  { domains: ['fastmail.com', 'fastmail.fm'], ...imapProviders.fastmail },
  {
    domains: [
      'yahoo.com',
      'ymail.com',
      'rocketmail.com',
      'yahoo.co.uk',
      'yahoo.de',
      'yahoo.fr',
    ],
    host: 'imap.mail.yahoo.com',
    smtp: { host: 'smtp.mail.yahoo.com', port: 465 },
  },
  {
    domains: ['aol.com'],
    host: 'imap.aol.com',
    smtp: { host: 'smtp.aol.com', port: 465 },
  },
  {
    domains: ['gmx.com'],
    host: 'imap.gmx.com',
    smtp: { host: 'mail.gmx.com', port: 465 },
  },
  {
    domains: ['gmx.net', 'gmx.de', 'gmx.at', 'gmx.ch'],
    host: 'imap.gmx.net',
    smtp: { host: 'mail.gmx.net', port: 465 },
  },
  {
    domains: ['web.de'],
    host: 'imap.web.de',
    smtp: { host: 'smtp.web.de', port: 465 },
  },
  {
    domains: ['mail.com'],
    host: 'imap.mail.com',
    smtp: { host: 'smtp.mail.com', port: 465 },
  },
  {
    domains: ['seznam.cz', 'email.cz', 'post.cz'],
    host: 'imap.seznam.cz',
    smtp: { host: 'smtp.seznam.cz', port: 465 },
  },
] as const;

// The server fields a form fills in for an address, and the domain they were found for.
export type FoundServers = Readonly<{
  domain: string;
  fields: Pick<ImapFields, (typeof serverFields)[number]>;
}>;

const hostPattern =
  /^[\da-z](?:[\da-z-]{0,61}[\da-z])?(?:\.[\da-z](?:[\da-z-]{0,61}[\da-z])?)+$/u;
const domainOf = (address: string) =>
  address.trim().split('@')[1]?.toLowerCase() ?? '';

// The server fields a manual form fills in for an address at a catalogued domain. SMTP signs in
// with the full address, so it needs its own user name only where IMAP uses a shorter one. Every
// entry uses the security its SMTP port implies, which the form follows until the person chooses.
export const catalogFields = (address: string): FoundServers | undefined => {
  const trimmed = address.trim();
  const domain = domainOf(address);
  const entry = catalog.find((provider) =>
    (provider.domains as readonly string[]).includes(domain),
  );
  if (entry === undefined) {
    return undefined;
  }
  const username = 'username' in entry ? entry.username(trimmed) : trimmed;
  return {
    domain,
    fields: {
      host: entry.host,
      port: '993',
      username,
      smtpHost: entry.smtp.host,
      smtpPort: String(entry.smtp.port),
      smtpUsername: username === trimmed ? '' : trimmed,
    },
  };
};

// The server fields the catalog or a discovery fills in.
const serverFields = [
  'host',
  'port',
  'username',
  'smtpHost',
  'smtpPort',
  'smtpUsername',
] as const;

// The endpoints an uncatalogued domain's RFC 6186 SRV records name, as the native lookup reports
// them: IMAP over implicit TLS, and SMTP submission.
export const DiscoveredServersSchema = Schema.NullOr(
  Schema.Struct({ imap: ServerSchema, smtp: ServerSchema }),
);

// The domain an address's servers are looked up for in DNS: one the catalog does not list.
export const discoveryDomain = (address: string) => {
  const domain = domainOf(address);
  return /^[^\s@]+@[^\s@]+$/u.test(address.trim()) &&
    hostPattern.test(domain) &&
    catalogFields(address) === undefined
    ? domain
    : undefined;
};

// The server fields a form fills in from the endpoints discovered for an address's domain, which
// sign in with the full address.
export const discoveredFields = (
  address: string,
  servers: NonNullable<typeof DiscoveredServersSchema.Type>,
): FoundServers => ({
  domain: domainOf(address),
  fields: {
    host: servers.imap.host,
    port: String(servers.imap.port),
    username: address.trim(),
    smtpHost: servers.smtp.host,
    smtpPort: String(servers.smtp.port),
    smtpUsername: '',
  },
});

// The domain whose found endpoints a form still holds, for the note that says they were found.
export const foundDomain = (
  fields: ImapFields,
  found: FoundServers | undefined,
) =>
  found !== undefined &&
  fields.smtpSecurity === undefined &&
  serverFields.every((name) => fields[name] === found.fields[name])
    ? found.domain
    : undefined;

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
  smtpHost: string;
  smtpPort: string;
  // Chosen by the person; until then, implicit TLS on 465 and STARTTLS on any other port.
  smtpSecurity?: SmtpSecurity;
  // Blank uses the IMAP user name and password.
  smtpUsername: string;
  smtpPassword: string;
}>;

// The transport security a form's SMTP endpoint uses.
export const smtpSecurityOf = (
  fields: Pick<ImapFields, 'smtpPort' | 'smtpSecurity'>,
): SmtpSecurity =>
  fields.smtpSecurity ??
  (fields.smtpPort.trim() === '465' ? 'tls' : 'starttls');

// A form's first values: empty for a new connection, or a saved connection's reviewed endpoints
// when its password is entered again. A saved connection without SMTP starts from its provider's
// reviewed SMTP endpoint, or an empty one for a manual server.
export const imapFields = (
  repair?: Readonly<{
    address: string;
    imap?: Readonly<{ host: string; port: number; username: string }>;
    smtp?: Readonly<{
      host: string;
      port: number;
      security: SmtpSecurity;
      username: string;
    }>;
  }>,
): ImapFields => {
  const blank = {
    address: repair?.address ?? '',
    password: '',
    host: '',
    port: '993',
    username: '',
    smtpHost: '',
    smtpPort: '465',
    smtpUsername: '',
    smtpPassword: '',
  };
  if (repair?.imap === undefined) {
    return blank;
  }
  const { address, imap } = repair;
  const preset = imapPresetOf(imap);
  const smtp =
    repair.smtp ??
    (preset === 'other'
      ? undefined
      : { ...imapProviders[preset].smtp, username: address });
  return {
    ...blank,
    host: imap.host,
    port: String(imap.port),
    username: imap.username,
    ...(smtp === undefined
      ? {}
      : {
          smtpHost: smtp.host,
          smtpPort: String(smtp.port),
          smtpSecurity: smtp.security,
          smtpUsername: smtp.username,
        }),
  };
};

// A port and host as entered, or undefined while either is malformed.
const hostAndPort = (host: string, port: string) => {
  const number = Number(port.trim());
  const name = host.trim().toLowerCase();
  return Number.isInteger(number) &&
    number >= 1 &&
    number <= 65_535 &&
    hostPattern.test(name)
    ? { host: name, port: number }
    : undefined;
};

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
    const { host, port, username, smtp } = imapProviders[provider];
    return {
      address,
      host,
      port,
      username: username(address),
      password: fields.password,
      smtp: { ...smtp, username: address },
    };
  }
  const imap = hostAndPort(fields.host, fields.port);
  const smtp = hostAndPort(fields.smtpHost, fields.smtpPort);
  if (imap === undefined || smtp === undefined) {
    return undefined;
  }
  const username =
    fields.username.trim() === '' ? address : fields.username.trim();
  return {
    address,
    ...imap,
    username,
    password: fields.password,
    smtp: {
      ...smtp,
      security: smtpSecurityOf(fields),
      username:
        fields.smtpUsername.trim() === ''
          ? username
          : fields.smtpUsername.trim(),
      ...(fields.smtpPassword === '' ? {} : { password: fields.smtpPassword }),
    },
  };
}
