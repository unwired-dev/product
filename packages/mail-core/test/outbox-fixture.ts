import type { Draft } from '../src/drafts.ts';
import type { SyntheticProductSync } from '../src/testing/drafts.ts';

import { createMailboxes } from '../src/mailboxes.ts';
import { createOutbox } from '../src/outbox.ts';
import { applyText } from '../src/semantic-document.ts';
import { createSyntheticProductSync } from '../src/testing/drafts.ts';
import {
  createSyntheticGmail,
  syntheticConnections,
} from '../src/testing/gmail-mailbox.ts';
import { alex, device, present } from './draft-sync-fixture.ts';

export type Device = Awaited<ReturnType<typeof device>>;

export const account = 'account-a';

// A Trusted Device that sends through `gmail`, the mailbox every device of the account connects.
export async function sender(
  server: Readonly<SyntheticProductSync>,
  gmail: Parameters<typeof syntheticConnections>[0][string],
  name: string,
) {
  const phone = await device(server, account, name);
  const mailboxes = createMailboxes(
    syntheticConnections({ [alex.id]: gmail }),
    phone.registration,
  );
  await mailboxes.load();
  const open = () =>
    createOutbox({
      drafts: phone.drafts,
      mailboxes,
      registration: phone.registration,
      claims: phone.storage.delivery,
    });
  let outbox = open();
  return {
    ...phone,
    mailboxes,
    get drafts() {
      return phone.drafts;
    },
    get outbox() {
      return outbox;
    },
    // A relaunch reopens storage and starts a new Outbox over it.
    relaunch: async () => {
      outbox.dispose();
      await phone.relaunch();
      outbox = open();
    },
  };
}

// Synthetic Gmail and Product Sync shared by the account's devices. Gmail reads each sent file's
// bytes from whichever device's Draft storage holds them, as that device's native code would.
export function sharedAccount(
  ...devices: ReadonlyArray<() => Readonly<Device> | undefined>
) {
  // oxlint-disable-next-line node/no-sync -- This synchronous in-memory fixture performs no I/O.
  const server = createSyntheticProductSync();
  const gmail = createSyntheticGmail({
    assets: (id, digest) =>
      devices
        .map((each) => each()?.storage.bytesOf(account, id, digest))
        .find((bytes) => bytes !== undefined),
  });
  return { server, gmail };
}

export const write = (draft: Draft, text: string): Draft => ({
  ...draft,
  body: applyText(draft.body, text).document,
});

// A Draft with recipients and a subject, ready to send.
export async function addressed(
  phone: Readonly<{
    draft: Device['draft'];
    drafts: Readonly<Pick<Device['drafts'], 'create' | 'update'>>;
  }>,
  text = 'See you there',
) {
  const id = present(await phone.drafts.create(alex), 'a new Draft');
  const created = phone.draft(id);
  await phone.drafts.update(
    {
      ...write(created, text),
      to: [{ name: 'Sam Lee', address: 'sam@example.invalid' }],
      subject: 'Lunch',
    },
    created,
  );
  return id;
}
