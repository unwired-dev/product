import assert from 'node:assert/strict';

import * as Vitest from '@effect/vitest';
import * as Predicate from 'effect/Predicate';

import { createFreshness } from '../src/freshness.ts';
import {
  discoveredFields,
  imapFields,
  imapSetup,
  smtpSecurityOf,
  withDiscovered,
} from '../src/imap-setup.ts';
import { createMailboxes } from '../src/mailboxes.ts';
import { createRegistration, mailboxesOf } from '../src/registration.ts';
import { syntheticConnections } from '../src/testing/gmail-mailbox.ts';
import { createSyntheticImap } from '../src/testing/imap-mailbox.ts';
import {
  createSyntheticDevice,
  createSyntheticVault,
} from '../src/testing/registration-vault.ts';

const smtp = {
  host: 'smtp.mail.me.com',
  port: 587,
  security: 'starttls',
  username: 'alex@icloud.example.invalid',
} as const;

describe('decoding IMAP connections and repairing iCloud Mail', () => {
  const projectedImap = {
    id: 'imap-connection',
    provider: 'imap',
    address: 'alex@example.invalid',
    authorizationNeeded: false,
    access: 'verified',
  };

  it.each([
    { name: 'no endpoint', mailbox: projectedImap },
    {
      name: 'an out-of-range port',
      mailbox: {
        ...projectedImap,
        imap: { host: 'imap.example.invalid', port: 70_000, username: 'alex' },
      },
    },
  ])(
    'refuses a native projection whose IMAP connection has $name',
    async ({ mailbox }) => {
      expect.hasAssertions();
      const { vault } = createSyntheticVault();
      const store = createRegistration(vault);
      await store.register('google');
      const projected = await vault.registration();
      assert.ok(Predicate.isObject(projected));
      const malformed = { ...projected, mailboxes: [mailbox] };
      const refused = createRegistration({
        ...vault,
        registration: () => Promise.resolve(malformed),
      });
      await refused.restore();
      expect(refused.getSnapshot()).toMatchObject({ failed: true });
      expect(mailboxesOf(refused.getSnapshot().snapshot)).toStrictEqual([]);
    },
  );

  it('retries iCloud Mail once with the full address when it refuses the name part', async () => {
    expect.hasAssertions();
    const device = createSyntheticDevice();
    const store = createRegistration(createSyntheticVault(device).vault);
    await store.register('google');
    device.imap.refusedUsernames = ['alex'];
    await store.connectImap({
      address: 'alex@icloud.example.invalid',
      host: 'imap.mail.me.com',
      port: 993,
      username: 'alex',
      password: device.imap.password,
      smtp,
    });
    expect(mailboxesOf(store.getSnapshot().snapshot)).toStrictEqual([
      expect.objectContaining({
        provider: 'imap',
        imap: {
          host: 'imap.mail.me.com',
          port: 993,
          username: 'alex@icloud.example.invalid',
        },
      }),
    ]);
    expect(device.imap.logins).toBe(2);
    // Another server is not retried.
    device.imap.refusedUsernames = ['sam', 'sam@icloud.example.invalid'];
    const { logins } = device.imap;
    await store.connectImap({
      address: 'alex@example.invalid',
      host: 'imap.example.invalid',
      port: 993,
      username: 'sam',
      password: device.imap.password,
      smtp,
    });
    expect(device.imap.logins).toBe(logins + 1);
  });

  it.each([
    {
      username: 'alex@icloud.example.invalid',
      code: 'imap-refused',
      logins: 1,
    },
    { username: 'alex', code: 'imap-refused', logins: 2 },
    { username: 'alex', code: 'imap-offline', logins: 1 },
    { username: 'alex', code: 'imap-insecure', logins: 1 },
  ])(
    'keeps iCloud setup resumable after $code for $username with $logins login attempts',
    async ({ username, code, logins }) => {
      expect.hasAssertions();
      const device = createSyntheticDevice();
      const store = createRegistration(createSyntheticVault(device).vault);
      await store.register('google');
      device.imap.outcome = code;
      await store.connectImap({
        address: 'alex@icloud.example.invalid',
        host: 'imap.mail.me.com',
        port: 993,
        username,
        password: device.imap.password,
        smtp,
      });
      expect(store.getSnapshot()).toMatchObject({
        snapshot: { kind: 'mailbox-needed', reason: code },
        failed: false,
      });
      expect(mailboxesOf(store.getSnapshot().snapshot)).toStrictEqual([]);
      expect(device.imap.logins).toBe(logins);
    },
  );

  /* oxlint-disable vitest/max-expects -- This journey checks repair targeting, generation renewal and metadata removal. */
  it('reloads the existing full-address iCloud Inbox after a successful fallback repair', async () => {
    expect.hasAssertions();
    const device = createSyntheticDevice();
    const store = createRegistration(createSyntheticVault(device).vault);
    await store.register('google');
    const icloud = {
      address: 'alex@icloud.example.invalid',
      host: 'imap.mail.me.com',
      port: 993,
      username: 'alex@icloud.example.invalid',
      password: device.imap.password,
      smtp,
    };
    await store.connectImap(icloud);
    await store.connectImap({ ...icloud, username: 'alex' });
    const [connection, namePart] = mailboxesOf(store.getSnapshot().snapshot);
    Vitest.assert.isDefined(connection);
    Vitest.assert.isDefined(namePart);
    const imap = createSyntheticImap({ address: icloud.address });
    const other = createSyntheticImap({ address: icloud.address });
    const opened = vi.fn<typeof imap.native.imapOpen>(imap.native.imapOpen);
    const mailboxes = createMailboxes(
      syntheticConnections(
        {},
        {
          [connection.id]: { ...imap.native, imapOpen: opened },
          [namePart.id]: other.native,
        },
      ),
      store,
    );
    await mailboxes.load();
    imap.server.failure = 'imap-refused';
    other.server.failure = 'imap-refused';
    await mailboxes.load();
    expect(mailboxes.getConnections()[0]?.state).toMatchObject({
      kind: 'ready',
      status: 'authentication',
    });
    device.imap.refusedUsernames = ['alex'];
    imap.server.failure = undefined;
    imap.cache.generation = 'generation-2';
    imap.deliver('INBOX', { subject: 'Read after fallback repair' });
    const otherReads = other.server.reads.length;
    await store.connectImap({ ...icloud, username: 'alex' });
    await vi.waitFor(() => {
      expect(mailboxes.getConnections()[0]?.state).toMatchObject({
        kind: 'ready',
        messages: [
          expect.objectContaining({ subject: 'Read after fallback repair' }),
        ],
      });
    });
    expect(opened).toHaveBeenLastCalledWith(
      expect.objectContaining({ generation: 'generation-2' }),
    );
    expect(mailboxesOf(store.getSnapshot().snapshot)).toHaveLength(2);
    expect(other.server.reads).toHaveLength(otherReads);
    expect(mailboxes.getConnections()[1]?.state).toMatchObject({
      status: 'authentication',
    });
    expect(store.getSnapshot().snapshot).not.toHaveProperty('imapConnected');
  });
  /* oxlint-enable vitest/max-expects */

  // An IMAP connection with saved mail whose next restore checks an unreachable server: native
  // code forgets mailbox access when the restore starts and settles it once that check times out,
  // and meanwhile the connection's mailbox reads as invalidated (#2731).
  const outage = async () => {
    const device = createSyntheticDevice();
    const { vault } = createSyntheticVault(device);
    let { verifyImap } = vault;
    const store = createRegistration({
      ...vault,
      verifyImap: (id) => verifyImap(id),
    });
    await store.register('google');
    await store.connectImap({
      address: 'alex@icloud.example.invalid',
      host: 'imap.mail.me.com',
      port: 993,
      username: 'alex@icloud.example.invalid',
      password: device.imap.password,
      smtp,
    });
    const [connection] = mailboxesOf(store.getSnapshot().snapshot);
    Vitest.assert.isDefined(connection);
    const imap = createSyntheticImap({ address: connection.address });
    imap.deliver('INBOX', { subject: 'Saved before the outage' });
    let openMailbox: typeof imap.native.openMailbox = imap.native.openMailbox;
    const mailboxes = createMailboxes(
      syntheticConnections(
        {},
        {
          [connection.id]: { ...imap.native, openMailbox: () => openMailbox() },
        },
      ),
      store,
    );
    await mailboxes.load();
    const states: string[] = [];
    mailboxes.subscribe(() => {
      states.push(...mailboxes.getConnections().map(({ state }) => state.kind));
    });
    const checking = Promise.withResolvers<undefined>();
    const timedOut = Promise.withResolvers<undefined>();
    // Opens after the check, when the restore keeps the connection as saved mail only.
    const reopened = vi.fn<typeof imap.native.openMailbox>(
      imap.native.openMailbox,
    );
    verifyImap = async () => {
      checking.resolve(undefined);
      await timedOut.promise;
      openMailbox = reopened;
      throw Object.assign(new Error('Synthetic'), { code: 'offline' });
    };
    const invalidated = () =>
      Promise.reject(
        Object.assign(new Error('Synthetic'), { code: 'mailbox-invalidated' }),
      );
    return {
      store,
      mailboxes,
      states,
      reopened,
      checking: checking.promise,
      invalidated,
      // The server stops answering, and work on the forgotten access is invalidated.
      forget: (open: typeof imap.native.openMailbox = invalidated) => {
        imap.server.failure = 'offline';
        openMailbox = open;
      },
      timeOut: () => {
        imap.cache.availability = 'retry';
        imap.cache.generation = 'generation-2';
        timedOut.resolve(undefined);
      },
    };
  };
  const savedShown = {
    kind: 'ready',
    status: 'retry',
    messages: [expect.objectContaining({ subject: 'Saved before the outage' })],
  };

  it('keeps saved mail shown while a restore checks an unreachable IMAP server, then reopens it', async () => {
    expect.hasAssertions();
    const { store, mailboxes, states, reopened, checking, forget, timeOut } =
      await outage();
    forget();
    const restoring = store.resume();
    await checking;
    // Another load while the server check waits, as when the Inbox mounts again.
    await mailboxes.load();
    expect(mailboxes.getConnections()[0]?.state).toMatchObject(savedShown);
    timeOut();
    await restoring;
    await vi.waitFor(() => {
      expect(reopened).toHaveResolvedWith(
        expect.objectContaining({ generation: 'generation-2' }),
      );
    });
    expect(mailboxes.getConnections()[0]?.state).toMatchObject(savedShown);
    expect(states).not.toContain('failed');
  });

  it('reopens an IMAP Inbox after a five-minute check whose restore invalidated its work', async () => {
    expect.hasAssertions();
    const {
      store,
      mailboxes,
      states,
      reopened,
      checking,
      invalidated,
      forget,
      timeOut,
    } = await outage();
    const freshness = createFreshness(mailboxes, store.refreshInbox);
    // A load is opening the mailbox as the check's restore forgets access.
    const held = Promise.withResolvers<undefined>();
    forget(async () => {
      await held.promise;
      return invalidated();
    });
    const loading = mailboxes.load();
    const polling = freshness.refresh();
    await checking;
    held.resolve(undefined);
    await loading;
    expect(mailboxes.getConnections()[0]?.state).toMatchObject(savedShown);
    timeOut();
    await polling;
    expect(reopened).toHaveResolvedWith(
      expect.objectContaining({ generation: 'generation-2' }),
    );
    expect(mailboxes.getConnections()[0]?.state).toMatchObject(savedShown);
    expect(states).not.toContain('failed');
  });

  it('verifies SMTP on its own and adds nothing until it accepts', async () => {
    expect.hasAssertions();
    const device = createSyntheticDevice();
    const store = createRegistration(createSyntheticVault(device).vault);
    await store.register('google');
    const setup = {
      address: 'alex@example.invalid',
      host: 'imap.example.invalid',
      port: 993,
      username: 'alex',
      password: device.imap.password,
      smtp: {
        host: 'smtp.example.invalid',
        port: 587,
        security: 'starttls',
        username: 'alex-smtp',
      },
    } as const;
    device.imap.smtp.outcome = 'smtp-insecure';
    await store.connectImap(setup);
    expect(store.getSnapshot().snapshot).toMatchObject({
      kind: 'mailbox-needed',
      reason: 'smtp-insecure',
    });
    // The SMTP server takes another password than IMAP.
    device.imap.smtp.outcome = undefined;
    device.imap.smtp.password = 'smtp-password';
    await store.connectImap(setup);
    expect({
      snapshot: store.getSnapshot().snapshot,
      connections: device.device.record?.connections,
    }).toMatchObject({ snapshot: { reason: 'smtp-refused' }, connections: [] });
    await store.connectImap({
      ...setup,
      smtp: { ...setup.smtp, password: 'smtp-password' },
    });
    expect({
      logins: device.imap.smtp.logins,
      mailboxes: mailboxesOf(store.getSnapshot().snapshot),
    }).toStrictEqual({
      logins: ['alex-smtp', 'alex-smtp', 'alex-smtp'],
      mailboxes: [
        expect.objectContaining({
          provider: 'imap',
          smtp: {
            host: 'smtp.example.invalid',
            port: 587,
            security: 'starttls',
            username: 'alex-smtp',
          },
        }),
      ],
    });
    // Beside a connected mailbox, a refusal changes nothing and is reported in the form.
    await store.connectImap({ ...setup, username: 'sam' });
    expect({
      failure: store.getSnapshot().imapFailure,
      mailboxes: mailboxesOf(store.getSnapshot().snapshot).length,
    }).toStrictEqual({ failure: 'smtp-refused', mailboxes: 1 });
  });

  it('builds reviewed SMTP endpoints from each provider form', () => {
    expect.hasAssertions();
    const typed = {
      ...imapFields(),
      address: 'alex@example.invalid',
      password: 'app-password',
      host: 'imap.example.invalid',
      smtpHost: 'SMTP.example.invalid',
    };
    expect([
      imapSetup('icloud', typed)?.smtp,
      imapSetup('fastmail', typed)?.smtp,
      imapSetup('other', typed)?.smtp,
      imapSetup('other', { ...typed, smtpPort: '587' })?.smtp,
      imapSetup('other', {
        ...typed,
        smtpPort: '2525',
        smtpSecurity: 'tls',
        smtpUsername: 'alex-smtp',
        smtpPassword: 'smtp-password',
      })?.smtp,
      imapSetup('other', { ...typed, smtpHost: '' }),
    ]).toStrictEqual([
      {
        host: 'smtp.mail.me.com',
        port: 587,
        security: 'starttls',
        username: 'alex@example.invalid',
      },
      {
        host: 'smtp.fastmail.com',
        port: 465,
        security: 'tls',
        username: 'alex@example.invalid',
      },
      {
        host: 'smtp.example.invalid',
        port: 465,
        security: 'tls',
        username: 'alex@example.invalid',
      },
      {
        host: 'smtp.example.invalid',
        port: 587,
        security: 'starttls',
        username: 'alex@example.invalid',
      },
      {
        host: 'smtp.example.invalid',
        port: 2525,
        security: 'tls',
        username: 'alex-smtp',
        password: 'smtp-password',
      },
      undefined,
    ]);
    // Entering the password of a preset connection saved before SMTP fills in its SMTP endpoint.
    expect(
      imapFields({
        address: 'alex@icloud.example.invalid',
        imap: { host: 'imap.mail.me.com', port: 993, username: 'alex' },
      }),
    ).toMatchObject({
      smtpHost: 'smtp.mail.me.com',
      smtpPort: '587',
      smtpSecurity: 'starttls',
      smtpUsername: 'alex@icloud.example.invalid',
    });
  });

  // An answer that arrives after the person typed on, before the form drops the lookup (#2200).
  it('fills discovered endpoints only into the untouched form they were looked up for', () => {
    expect.hasAssertions();
    const address = 'mara@posteo.de';
    const found = discoveredFields(address, {
      imap: { host: 'posteo.de', port: 993 },
      smtp: { host: 'posteo.de', port: 465, security: 'tls' },
    });
    const untouched = { ...imapFields(), address, password: 'secret' };
    const edited = { ...untouched, host: 'imap.posteo.de' };
    const secured = { ...untouched, smtpSecurity: 'starttls' as const };
    const moved = { ...untouched, address: 'mara@example.org' };
    expect([
      withDiscovered(untouched, address, found),
      withDiscovered(edited, address, found),
      withDiscovered(secured, address, found),
      withDiscovered(moved, address, found),
    ]).toStrictEqual([
      { ...untouched, ...found.fields },
      edited,
      secured,
      moved,
    ]);
  });

  // `_submissions` is implicit TLS on any port; `_submission` leaves security to the port (#2200).
  it('keeps the security of the SMTP service a domain names', () => {
    expect.hasAssertions();
    const security = (port: number, service: 'tls' | 'starttls') =>
      smtpSecurityOf(
        discoveredFields('mara@example.org', {
          imap: { host: 'imap.example.org', port: 993 },
          smtp: { host: 'smtp.example.org', port, security: service },
        }).fields,
      );
    expect([
      security(2465, 'tls'),
      security(465, 'tls'),
      security(587, 'starttls'),
      security(465, 'starttls'),
    ]).toStrictEqual(['tls', 'tls', 'starttls', 'tls']);
  });
});
