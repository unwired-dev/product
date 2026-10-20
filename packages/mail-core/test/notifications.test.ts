import * as Schema from 'effect/Schema';

import { openedTarget } from '../src/notifications.ts';
import {
  defaultProfile,
  RegistrationSnapshotSchema,
  unavailableProfile,
} from '../src/registration.ts';

const connected = (mailboxes: ReadonlyArray<Record<string, string>>) =>
  Schema.decodeSync(RegistrationSnapshotSchema)({
    kind: 'connected',
    productAccountId: 'account',
    signInProvider: 'google',
    mailboxes: JSON.stringify(
      mailboxes.map((mailbox) => ({
        provider: 'gmail',
        address: 'alex@example.invalid',
        state: 'connected',
        ...mailbox,
      })),
    ),
  });

describe('opening a tapped New Mail Notification', () => {
  it('opens its message in the connection’s current Profile, and nothing once the connection or its owner is unknown', () => {
    expect.hasAssertions();
    const opened = { connection: 'work', message: '1a' };
    expect(
      openedTarget(connected([{ id: 'work', profile: 'p-work' }]), opened),
    ).toStrictEqual({ id: '1a', mailbox: 'work', profile: 'p-work' });
    expect(openedTarget(connected([{ id: 'work' }]), opened)).toStrictEqual({
      id: '1a',
      mailbox: 'work',
      profile: defaultProfile,
    });
    // Removed, or in another Product Account.
    expect(openedTarget(connected([{ id: 'home' }]), opened)).toBeUndefined();
    expect(
      openedTarget(
        connected([{ id: 'work', profile: unavailableProfile }]),
        opened,
      ),
    ).toBeUndefined();
  });
});
