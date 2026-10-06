import type { NativeGmailMailbox } from '@private-email/mail-core/gmail-inbox';
import type { NativeRegistration } from '@private-email/mail-core/registration';
import type { TurboModule } from 'react-native';

import {
  createGmailInbox,
  forgetMailOutsideInbox,
} from '@private-email/mail-core/gmail-inbox';
import { createRegistration } from '@private-email/mail-core/registration';
import { TurboModuleRegistry } from 'react-native';

interface RegistrationModule
  extends TurboModule, NativeRegistration, NativeGmailMailbox {}
const native = () =>
  TurboModuleRegistry.getEnforcing<RegistrationModule>('UnwiredRegistration');

export const registration = createRegistration({
  restore: () => native().restore(),
  signIn: (provider) => native().signIn(provider),
  authorizeGmail: (reselect) => native().authorizeGmail(reselect),
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

export const gmailInbox = createGmailInbox(
  {
    gmailRequest: (path, query, mailbox) =>
      native().gmailRequest(path, query, mailbox),
    gmailModify: (change, mailbox) => native().gmailModify(change, mailbox),
    openMailbox: () => native().openMailbox(),
    commitMailbox: (mailbox, expectedRevision, document) =>
      native().commitMailbox(mailbox, expectedRevision, document),
  },
  {
    removed: () => {
      void registration.deviceRemoved();
    },
  },
);

forgetMailOutsideInbox(registration, gmailInbox);
