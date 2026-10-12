import assert from 'node:assert/strict';

import * as Vitest from '@effect/vitest';
import * as Predicate from 'effect/Predicate';

import { createMailboxes } from '../src/mailboxes.ts';
import { createRegistrationFlow } from '../src/registration-flow.ts';
import { createRegistration, mailboxesOf } from '../src/registration.ts';
import { syntheticConnections } from '../src/testing/gmail-mailbox.ts';
import { createSyntheticImap } from '../src/testing/imap-mailbox.ts';
import {
  createSyntheticDevice,
  createSyntheticVault,
} from '../src/testing/registration-vault.ts';

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
      const store = createRegistration(createRegistrationFlow(vault));
      await store.register('google');
      const projected = await vault.registration();
      assert.ok(Predicate.isObject(projected));
      const malformed = { ...projected, mailboxes: [mailbox] };
      const refused = createRegistration(
        createRegistrationFlow({
          ...vault,
          registration: () => Promise.resolve(malformed),
        }),
      );
      await refused.restore();
      expect(refused.getSnapshot()).toMatchObject({ failed: true });
      expect(mailboxesOf(refused.getSnapshot().snapshot)).toStrictEqual([]);
    },
  );

  it('retries iCloud Mail once with the full address when it refuses the name part', async () => {
    expect.hasAssertions();
    const device = createSyntheticDevice();
    const store = createRegistration(
      createRegistrationFlow(createSyntheticVault(device).vault),
    );
    await store.register('google');
    device.imap.refusedUsernames = ['alex'];
    await store.connectImap({
      address: 'alex@icloud.example.invalid',
      host: 'imap.mail.me.com',
      port: 993,
      username: 'alex',
      password: device.imap.password,
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
      const store = createRegistration(
        createRegistrationFlow(createSyntheticVault(device).vault),
      );
      await store.register('google');
      device.imap.outcome = code;
      await store.connectImap({
        address: 'alex@icloud.example.invalid',
        host: 'imap.mail.me.com',
        port: 993,
        username,
        password: device.imap.password,
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
    const store = createRegistration(
      createRegistrationFlow(createSyntheticVault(device).vault),
    );
    await store.register('google');
    const icloud = {
      address: 'alex@icloud.example.invalid',
      host: 'imap.mail.me.com',
      port: 993,
      username: 'alex@icloud.example.invalid',
      password: device.imap.password,
    };
    await store.connectImap(icloud);
    await store.connectImap({ ...icloud, username: 'alex' });
    const [connection, namePart] = mailboxesOf(store.getSnapshot().snapshot);
    Vitest.assert.isDefined(connection);
    Vitest.assert.isDefined(namePart);
    const imap = createSyntheticImap({ address: icloud.address });
    const other = createSyntheticImap({ address: icloud.address });
    const folders = vi.fn<typeof imap.native.imapFolders>(
      imap.native.imapFolders,
    );
    const mailboxes = createMailboxes(
      syntheticConnections(
        {},
        {
          [connection.id]: { ...imap.native, imapFolders: folders },
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
    expect(folders).toHaveBeenLastCalledWith(
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
});
