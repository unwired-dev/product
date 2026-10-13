import type {
  NativeDrafts,
  NativeDraftSync,
} from '@private-email/mail-core/drafts';
import type { NativeWakes } from '@private-email/mail-core/freshness';
import type { NativeGmailMailboxes } from '@private-email/mail-core/mailboxes';
import type { NativeDeliveryClaim } from '@private-email/mail-core/outbox';
import type { NativeRegistrationVault } from '@private-email/mail-core/registration-flow';
import type { TurboModule } from 'react-native';

import { createDrafts } from '@private-email/mail-core/drafts';
import { createMailboxes } from '@private-email/mail-core/mailboxes';
import { createOutbox } from '@private-email/mail-core/outbox';
import {
  createRegistration,
  microsoftMailAvailable,
} from '@private-email/mail-core/registration';
import { createRegistrationFlow } from '@private-email/mail-core/registration-flow';
import { TurboModuleRegistry } from 'react-native';

interface RegistrationModule
  extends
    TurboModule,
    NativeRegistrationVault,
    NativeGmailMailboxes,
    NativeDrafts,
    NativeDraftSync,
    NativeDeliveryClaim,
    NativeWakes {
  // Cancels a Gmail or Microsoft Graph read by its request name.
  readonly cancelGmailRequest: (request: string) => void;
}
const native = () =>
  TurboModuleRegistry.getEnforcing<RegistrationModule>('UnwiredRegistration');

// Whether this build can authorize Microsoft mail; without the native module it cannot.
export const microsoftMail = () =>
  microsoftMailAvailable(
    TurboModuleRegistry.get<RegistrationModule>(
      'UnwiredRegistration',
    )?.getConstants?.(),
  );

export const registration = createRegistration(
  createRegistrationFlow({
    registration: () => native().registration(),
    signInIdentity: (provider, hint) => native().signInIdentity(provider, hint),
    renewIdentity: () => native().renewIdentity(),
    appleCredentialState: () => native().appleCredentialState(),
    reuseSession: () => native().reuseSession(),
    saveIdentity: (replacing) => native().saveIdentity(replacing),
    connect: (mode) => native().connect(mode),
    createKeyRing: () => native().createKeyRing(),
    recordInitialization: (initialized) =>
      native().recordInitialization(initialized),
    reenroll: () => native().reenroll(),
    beginEnrollment: (notice) => native().beginEnrollment(notice),
    openEnrollment: (approval) => native().openEnrollment(approval),
    confirmAdmission: () => native().confirmAdmission(),
    recoverPendingDevice: (entry) => native().recoverPendingDevice(entry),
    recoverTrustedDevice: (entry, envelope) =>
      native().recoverTrustedDevice(entry, envelope),
    readsAsEnrollmentCode: (entry) => native().readsAsEnrollmentCode(entry),
    sealEnrollment: (code, request) => native().sealEnrollment(code, request),
    adoptRotation: (envelope) => native().adoptRotation(envelope),
    settleRevocation: (keyEpoch) => native().settleRevocation(keyEpoch),
    adoptIdentity: () => native().adoptIdentity(),
    prepareRevocation: (proposal) => native().prepareRevocation(proposal),
    submitRevocation: (entry) => native().submitRevocation(entry),
    withdrawRevocation: () => native().withdrawRevocation(),
    discardRevocation: () => native().discardRevocation(),
    finishSynchronization: () => native().finishSynchronization(),
    sealMailboxDescriptor: (record, descriptor) =>
      native().sealMailboxDescriptor(record, descriptor),
    openMailboxDescriptors: (records) =>
      native().openMailboxDescriptors(records),
    recordMailboxChanges: (connections, settledRemovals) =>
      native().recordMailboxChanges(connections, settledRemovals),
    purgeMailbox: (connection) => native().purgeMailbox(connection),
    removeQueuedPushRoutes: () => native().removeQueuedPushRoutes(),
    recordMailboxReadback: (addresses, confirmed, epochs) =>
      native().recordMailboxReadback(addresses, confirmed, epochs),
    sealProfileRecord: (record) => native().sealProfileRecord(record),
    openProfileRecords: (records) => native().openProfileRecords(records),
    recordProfiles: (state) => native().recordProfiles(state),
    forgetMailboxAccess: () => native().forgetMailboxAccess(),
    retryMailboxCleanup: () => native().retryMailboxCleanup(),
    refreshMailbox: (connection) => native().refreshMailbox(connection),
    signInMailbox: (connection, suggest, provider) =>
      native().signInMailbox(connection, suggest, provider),
    verifyMailbox: () => native().verifyMailbox(),
    connectImap: (setup) => native().connectImap(setup),
    verifyImap: (connection) => native().verifyImap(connection),
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
    routeMailboxes: () => native().routeMailboxes(),
    stopMailboxWatches: () => native().stopMailboxWatches(),
    confirmRecoveryKey: (entry) => native().confirmRecoveryKey(entry),
    readsAsRecoveryKey: (entry) => native().readsAsRecoveryKey(entry),
  }),
);

// APNs wake hints waiting for JavaScript, and the routes they may name.
export const wakes: NativeWakes = {
  nextWake: () => native().nextWake(),
  mailboxRoutes: () => native().mailboxRoutes(),
  completeWake: (id, result) => {
    native().completeWake(id, result);
  },
};

let nextRead = 0;

// One provider read native code can cancel by its request name when `signal` aborts.
const cancellable = async (
  {
    connection,
    generation,
  }: Readonly<{ connection: string; generation: string }>,
  signal: Readonly<AbortSignal> | undefined,
  read: (request: string) => Promise<unknown>,
) => {
  nextRead += 1;
  const request = `${connection}:${generation}:${nextRead}`;
  const cancel = () => {
    native().cancelGmailRequest(request);
  };
  if (signal?.aborted === true) {
    throw new Error('The mailbox request was cancelled.');
  }
  const pending = read(request);
  signal?.addEventListener('abort', cancel, { once: true });
  try {
    return await pending;
  } finally {
    signal?.removeEventListener('abort', cancel);
  }
};

// One Inbox per Mailbox Connection, from Gmail or Microsoft Graph; each forgets its mail when its
// connection or owner leaves.
export const gmailMailboxes = createMailboxes(
  {
    gmailRequest: (path, query, { signal, ...mailbox }) =>
      cancellable(mailbox, signal, (request) => {
        const scope = { ...mailbox, request };
        return native().gmailRequest(path, query, scope);
      }),
    graphRequest: (url, { signal, ...mailbox }) =>
      cancellable(mailbox, signal, (request) => {
        const scope = { ...mailbox, request };
        return native().graphRequest(url, scope);
      }),
    gmailModify: (change, mailbox) => native().gmailModify(change, mailbox),
    graphModify: (change, mailbox) => native().graphModify(change, mailbox),
    gmailSend: (message, mailbox) => native().gmailSend(message, mailbox),
    graphSend: (message, mailbox) => native().graphSend(message, mailbox),
    openMailbox: (connection) => native().openMailbox(connection),
    imapFolders: (mailbox) => native().imapFolders(mailbox),
    imapSynchronize: (mailbox, request) =>
      native().imapSynchronize(mailbox, request),
    imapMessage: (mailbox, message) => native().imapMessage(mailbox, message),
    imapModify: (mailbox, change) => native().imapModify(mailbox, change),
    imapSearch: (mailbox, request) => native().imapSearch(mailbox, request),
    imapIdle: (mailbox, request) => native().imapIdle(mailbox, request),
    imapSend: (message, mailbox) => native().imapSend(message, mailbox),
    imapFileSent: (mailbox, request) => native().imapFileSent(mailbox, request),
    imapFindSent: (mailbox, request) => native().imapFindSent(mailbox, request),
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
    openRemoteContent: (mailbox, resource) =>
      native().openRemoteContent(mailbox, resource),
    touchRemoteContent: (mailbox, resource) =>
      native().touchRemoteContent(mailbox, resource),
    fetchRemoteContent: (mailbox, url, request) =>
      native().fetchRemoteContent(mailbox, url, request),
    cancelRemoteContent: (mailbox, session, finished) =>
      native().cancelRemoteContent(mailbox, session, finished),
    commitRemoteContent: (mailbox, resource, admission) =>
      native().commitRemoteContent(mailbox, resource, admission),
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
    adoptKeyRotation: () => registration.adoptKeyRotation(),
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
