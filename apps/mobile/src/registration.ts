import type { NativeGmailMailboxes } from '@private-email/mail-core/mailboxes';
import type { NativeRegistration } from '@private-email/mail-core/registration';
import type { TurboModule } from 'react-native';

import { createMailboxes } from '@private-email/mail-core/mailboxes';
import { createRegistration } from '@private-email/mail-core/registration';
import { TurboModuleRegistry } from 'react-native';

interface RegistrationModule
  extends TurboModule, NativeRegistration, NativeGmailMailboxes {
  readonly cancelGmailRequest: (request: string) => void;
}
const native = () =>
  TurboModuleRegistry.getEnforcing<RegistrationModule>('UnwiredRegistration');

export const registration = createRegistration({
  restore: () => native().restore(),
  signIn: (provider) => native().signIn(provider),
  addMailbox: (chooseAccount) => native().addMailbox(chooseAccount),
  authorizeGmail: (connection) => native().authorizeGmail(connection),
  removeMailbox: (connection) => native().removeMailbox(connection),
  link: (provider) => native().link(provider),
  confirmRecoveryKey: (entry) => native().confirmRecoveryKey(entry),
  recoverWithRecoveryKey: (entry) => native().recoverWithRecoveryKey(entry),
  approveEnrollment: (requestId, code) =>
    native().approveEnrollment(requestId, code),
  declineEnrollment: (requestId) => native().declineEnrollment(requestId),
  revokeTrustedDevice: (trustedDeviceId) =>
    native().revokeTrustedDevice(trustedDeviceId),
  refreshPrivateSync: () => native().refreshPrivateSync(),
  signOut: () => native().signOut(),
  deleteProductAccount: () => native().deleteProductAccount(),
});

let nextRead = 0;

// One Gmail Inbox per Mailbox Connection; each forgets its mail when its connection or owner leaves.
export const gmailMailboxes = createMailboxes(
  {
    gmailRequest: async (path, query, { signal, ...mailbox }) => {
      nextRead += 1;
      const request = `${mailbox.connection}:${mailbox.generation}:${nextRead}`;
      const scope = { ...mailbox, request };
      const cancel = () => {
        native().cancelGmailRequest(request);
      };
      if (signal?.aborted === true) {
        throw new Error('The Gmail request was cancelled.');
      }
      const pending = native().gmailRequest(path, query, scope);
      signal?.addEventListener('abort', cancel, { once: true });
      try {
        return await pending;
      } finally {
        signal?.removeEventListener('abort', cancel);
      }
    },
    gmailModify: (change, mailbox) => native().gmailModify(change, mailbox),
    openMailbox: (connection) => native().openMailbox(connection),
    commitMailbox: (mailbox, expectedRevision, document) =>
      native().commitMailbox(mailbox, expectedRevision, document),
    openMessageBody: (mailbox, id) => native().openMessageBody(mailbox, id),
    commitMessageBody: (mailbox, id, admission) =>
      native().commitMessageBody(mailbox, id, admission),
    listMessageBodies: (mailbox, ids) =>
      native().listMessageBodies(mailbox, ids),
    retainMessageBodies: (mailbox, ids, protectedIds) =>
      native().retainMessageBodies(mailbox, ids, protectedIds),
    saveAttachment: (mailbox, attachment) =>
      native().saveAttachment(mailbox, attachment),
    discardAttachment: (mailbox, file) =>
      native().discardAttachment(mailbox, file),
    presentAttachment: (mailbox, file, action) =>
      native().presentAttachment(mailbox, file, action),
  },
  registration,
  {
    removed: () => {
      void registration.deviceRemoved();
    },
  },
);
