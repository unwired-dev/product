import type { MailboxDescriptor } from '@private-email/mail-core/testing/registration-vault';

import {
  createSyntheticProductSyncBackend,
  mailboxRecord,
  RegistrationRecordSchema,
  storeDescriptor,
  storedDescriptor,
} from '@private-email/mail-core/testing/registration-vault';
import * as Schema from 'effect/Schema';

import { launch } from './registration-flow-fixture.ts';

// oxlint-disable-next-line node/no-sync -- Decodes synthetic vault replies without synchronous Node I/O.
export const decodeRecord = Schema.decodeUnknownSync(RegistrationRecordSchema);
export const account = 'account-synthetic-product-subject';
export const productSubject = 'synthetic-product-subject';

// The registration flow on a host with Product Sync, over the synthetic native vault and Convex.
export const setup = () => {
  const launched = launch();
  const sync = createSyntheticProductSyncBackend();
  launched.backend.productSync = sync;
  const keysOf = (name = account) => {
    const entry = sync.accounts.get(name);
    if (entry === undefined) {
      throw new Error('No Product Sync account');
    }
    return entry;
  };
  const ring = () => {
    const keys = keysOf().ring;
    if (keys === undefined) {
      throw new Error('No account keys');
    }
    return keys;
  };
  const records = (name = account) => keysOf(name).records;
  const record = (subject = productSubject) =>
    mailboxRecord(sync, ring().id, `gmail:${subject}`);
  // Another device's write of the mailbox descriptor, or of one this device cannot open.
  const put = (
    descriptor: Partial<MailboxDescriptor> | undefined,
    subject = productSubject,
  ) => {
    storeDescriptor(sync, {
      account,
      record: record(subject),
      descriptor:
        descriptor === undefined
          ? undefined
          : {
              provider: 'gmail',
              address: 'alex@example.invalid',
              ...descriptor,
            },
    });
  };
  const descriptor = (subject = productSubject) =>
    storedDescriptor(sync, account, record(subject));
  // Runs `written` just before this device's `times`-th write of the subject's descriptor.
  const beforeWrite = (
    written: () => void,
    { subject = productSubject, times = 1 } = {},
  ) => {
    let writes = 0;
    sync.beforePut = (target) => {
      writes += target === record(subject) ? 1 : 0;
      if (writes === times) {
        sync.beforePut = undefined;
        written();
      }
    };
  };
  const failWrites = (subject: string) => {
    sync.beforePut = (target) => {
      if (target === record(subject)) {
        throw new Error('Synthetic write failure');
      }
    };
  };
  const failNextList = () => {
    sync.beforeList = () => {
      sync.beforeList = undefined;
      throw new Error('Synthetic list failure');
    };
  };
  // Another device's removal that moves the account to a newer key epoch.
  const rotate = (epoch: number) => {
    const keys = ring();
    keys.epochs.push(epoch);
    keys.current = epoch;
  };
  const connections = () => launched.device.record?.connections ?? [];
  const connection = () => {
    const [first] = connections();
    if (first === undefined) {
      throw new Error('No connection');
    }
    return first;
  };
  // This device's connections as a build from before epochs left them.
  const makeLegacy = () => {
    for (const entry of connections()) {
      delete entry.epoch;
      delete entry.published;
      delete entry.observed;
      delete entry.observedEpoch;
    }
  };
  const forgetConnections = () => {
    const { record: saved } = launched.device;
    if (saved !== undefined) {
      saved.connections = [];
    }
  };
  const confirmHeldKey = () => {
    const held = launched.device.productSync.vault;
    if (held === undefined) {
      throw new Error('No key ring');
    }
    held.recoveryKeyConfirmed = true;
  };
  const mailboxId = async () => {
    const state = decodeRecord(await launched.vault.registration());
    const [mailbox] = state.mailboxes;
    if (mailbox === undefined) {
      throw new Error('No mailbox');
    }
    return mailbox.id;
  };
  return {
    ...launched,
    sync,
    keysOf,
    ring,
    records,
    record,
    put,
    descriptor,
    beforeWrite,
    failWrites,
    failNextList,
    rotate,
    connections,
    connection,
    makeLegacy,
    forgetConnections,
    confirmHeldKey,
    mailboxId,
  };
};
