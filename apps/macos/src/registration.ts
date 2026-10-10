import type {
  NativeDrafts,
  NativeDraftSync,
} from '@private-email/mail-core/drafts';
import type { NativeGmailMailboxes } from '@private-email/mail-core/mailboxes';
import type { NativeDeliveryClaim } from '@private-email/mail-core/outbox';
import type { NativeRegistrationVault } from '@private-email/mail-core/registration-flow';
import type { TurboModule } from 'react-native';

import { createDrafts } from '@private-email/mail-core/drafts';
import { createMailboxes } from '@private-email/mail-core/mailboxes';
import { createOutbox } from '@private-email/mail-core/outbox';
import { createRegistration } from '@private-email/mail-core/registration';
import { createRegistrationFlow } from '@private-email/mail-core/registration-flow';
import { TurboModuleRegistry } from 'react-native';

interface RegistrationModule
  extends
    TurboModule,
    NativeRegistrationVault,
    NativeGmailMailboxes,
    NativeDrafts,
    NativeDraftSync,
    NativeDeliveryClaim {
  readonly cancelGmailRequest: (request: string) => void;
}
const native = () =>
  TurboModuleRegistry.getEnforcing<RegistrationModule>('UnwiredRegistration');

export const registration = createRegistration(
  createRegistrationFlow({
    registration: () => native().registration(),
    signInIdentity: (provider, hint) => native().signInIdentity(provider, hint),
    renewIdentity: () => native().renewIdentity(),
    appleCredentialState: () => native().appleCredentialState(),
    reuseSession: () => native().reuseSession(),
    saveIdentity: (replacing) => native().saveIdentity(replacing),
    connect: (mode) => native().connect(mode),
    synchronize: () => native().synchronize(),
    forgetMailboxAccess: () => native().forgetMailboxAccess(),
    retryMailboxCleanup: () => native().retryMailboxCleanup(),
    refreshMailbox: (connection) => native().refreshMailbox(connection),
    signInMailbox: (connection, suggest) =>
      native().signInMailbox(connection, suggest),
    verifyGmail: () => native().verifyGmail(),
    confirmMailbox: (connection) => native().confirmMailbox(connection),
    storeMailbox: () => native().storeMailbox(),
    markMailbox: (connection, access) =>
      native().markMailbox(connection, access),
    recordMailboxSetup: (reason) => native().recordMailboxSetup(reason),
    saveSignInProviders: (providers) => native().saveSignInProviders(providers),
    recordRemoval: (operation) => native().recordRemoval(operation),
    prepareSignOut: () => native().prepareSignOut(),
    endSession: () => native().endSession(),
    purge: (notice) => native().purge(notice),
    call: (request) => native().call(request),
    removeMailbox: (connection) => native().removeMailbox(connection),
    confirmRecoveryKey: (entry) => native().confirmRecoveryKey(entry),
    readsAsRecoveryKey: (entry) => native().readsAsRecoveryKey(entry),
    recoverWithRecoveryKey: (entry) => native().recoverWithRecoveryKey(entry),
    approveEnrollment: (requestId, code) =>
      native().approveEnrollment(requestId, code),
    declineEnrollment: (requestId) => native().declineEnrollment(requestId),
    revokeTrustedDevice: (trustedDeviceId) =>
      native().revokeTrustedDevice(trustedDeviceId),
  }),
);

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
    gmailSend: (message, mailbox) => native().gmailSend(message, mailbox),
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

// The signed-in Product Account's encrypted Drafts on this device, synchronized through Product
// Sync with its other Trusted Devices.
export const drafts = createDrafts(
  {
    openDrafts: () => native().openDrafts(),
    commitDrafts: (owner, expectedRevision, commit) =>
      native().commitDrafts(owner, expectedRevision, commit),
    importDraftAsset: (owner, id, source) =>
      native().importDraftAsset(owner, id, source),
    readDraftAsset: (owner, asset) => native().readDraftAsset(owner, asset),
    discardDraftAsset: (owner, id) => native().discardDraftAsset(owner, id),
    pickDraftFiles: (source) => native().pickDraftFiles(source),
    discardPickedDraftFiles: (uris) => native().discardPickedDraftFiles(uris),
  },
  registration,
  {
    removed: () => {
      void registration.deviceRemoved();
    },
    native: {
      pullDrafts: (owner, known) => native().pullDrafts(owner, known),
      pushDraft: (owner, record) => native().pushDraft(owner, record),
      uploadDraftAsset: (owner, asset) =>
        native().uploadDraftAsset(owner, asset),
      downloadDraftAsset: (owner, asset) =>
        native().downloadDraftAsset(owner, asset),
    },
  },
);

// Messages sent on this device: each waits out the Undo Send Window, is claimed through Convex so no
// other Trusted Device sends the same Draft, and is handed to Gmail once.
export const outbox = createOutbox({
  drafts,
  mailboxes: gmailMailboxes,
  registration,
  claims: {
    claimDraftDelivery: (owner, id) => native().claimDraftDelivery(owner, id),
  },
});
