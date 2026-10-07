import type { NativeGmailMailboxes } from '@private-email/mail-core/mailboxes';
import type { NativeRegistration } from '@private-email/mail-core/registration';
import type { TurboModule } from 'react-native';

import { createMailboxes } from '@private-email/mail-core/mailboxes';
import { createRegistration } from '@private-email/mail-core/registration';
import { TurboModuleRegistry } from 'react-native';

interface RegistrationModule
  extends TurboModule, NativeRegistration, NativeGmailMailboxes {}
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

// One Gmail Inbox per Mailbox Connection; each forgets its mail when its connection or owner leaves.
export const gmailMailboxes = createMailboxes(
  {
    gmailRequest: (path, query, mailbox) =>
      native().gmailRequest(path, query, mailbox),
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
  },
  registration,
  {
    removed: () => {
      void registration.deviceRemoved();
    },
  },
);
