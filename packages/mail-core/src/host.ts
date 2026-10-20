import type {
  ReportingBreadcrumb,
  ReportingCode,
} from '@private-email/contracts/errorReporting';
import type { Translate } from '@private-email/localization';

import { english } from '@private-email/localization';
import * as Option from 'effect/Option';
import * as Schema from 'effect/Schema';

import type { NativeDrafts, NativeDraftSync } from './drafts.ts';
import type { NativeErrorReporting } from './error-reporting.ts';
import type { NativeWakes } from './freshness.ts';
import type { NativeGmailMailboxes } from './mailboxes.ts';
import type { NativeNotifications } from './notifications.ts';
import type { NativeDeliveryClaim } from './outbox.ts';
import type { NativeRegistrationVault } from './registration-vault.ts';
import type { NativeRemoteContent } from './remote-content.ts';

import { rejectionCode } from './diagnostics.ts';
import { createDrafts } from './drafts.ts';
import { createErrorReporting } from './error-reporting.ts';
import { createFreshness, followWakes } from './freshness.ts';
import { createMailboxes } from './mailboxes.ts';
import { createNotifications } from './notifications.ts';
import { createOutbox } from './outbox.ts';
import { createRegistration } from './registration.ts';
import { createRemoteContentSettings } from './remote-content.ts';

const decodeReportingResponse = Schema.decodeUnknownOption(
  Schema.Struct({
    status: Schema.Int.check(Schema.isBetween({ minimum: 100, maximum: 599 })),
    body: Schema.optionalKey(Schema.String),
  }),
);
const failedEnvelope = Schema.decodeUnknownOption(
  Schema.fromJsonString(Schema.Struct({ status: Schema.Literal('error') })),
);

function reportingResponse(result: unknown, code: ReportingCode) {
  const reply = decodeReportingResponse(result);
  if (Option.isNone(reply)) {
    return { failed: false };
  }
  const { status, body } = reply.value;
  const failed =
    status >= 400 ||
    (code === 'backend-failed' &&
      body !== undefined &&
      Option.isSome(failedEnvelope(body)));
  return { status, failed };
}

// The native module both Apple hosts register as `UnwiredRegistration`.
export interface NativeHostModule
  extends
    NativeRegistrationVault,
    NativeGmailMailboxes,
    NativeDrafts,
    NativeDraftSync,
    NativeDeliveryClaim,
    NativeWakes,
    NativeRemoteContent,
    NativeNotifications {
  // Cancels a Gmail or Microsoft Graph read by its request name.
  readonly cancelGmailRequest: (request: string) => void;
}

// The host's mail-core stores over its native module, which each call looks up when it runs, so
// constructing the host requires nothing native. `translate` gives notification text the
// application's current language.
export function createHost(
  native: () => NativeHostModule,
  {
    reportingNative,
    initialReportingState,
    translate = () => english,
  }: Readonly<{
    reportingNative?: (() => NativeErrorReporting) | undefined;
    initialReportingState?: unknown;
    translate?: () => Translate;
  }> = {},
) {
  const reportingBridge = () => {
    if (reportingNative === undefined) {
      throw new Error('Reporting unavailable');
    }
    return reportingNative();
  };
  const errorReporting = createErrorReporting(
    {
      errorReportingRead: () => reportingBridge().errorReportingRead(),
      errorReportingConsent: (enabled, renew, generation) =>
        reportingBridge().errorReportingConsent(enabled, renew, generation),
      errorReportingSave: (generation, document) =>
        reportingBridge().errorReportingSave(generation, document),
      errorReportingRequest: (operation, body, generation) =>
        reportingBridge().errorReportingRequest(operation, body, generation),
      errorReportingTakeNative: () =>
        reportingBridge().errorReportingTakeNative(),
    },
    initialReportingState,
  );
  const observe = async <A>(
    operation: ReportingBreadcrumb['operation'],
    code: ReportingCode,
    request: () => Promise<A>,
  ): Promise<A> => {
    const started = Date.now();
    const elapsedMs = () =>
      Math.min(86_400_000, Math.max(0, Date.now() - started));
    errorReporting.breadcrumb({ operation, stage: 'start' });
    try {
      const result = await request();
      const { status, failed } = reportingResponse(result, code);
      errorReporting.breadcrumb({
        operation,
        stage: failed ? 'failed' : 'complete',
        elapsedMs: elapsedMs(),
        ...(status === undefined ? {} : { status }),
      });
      if (failed) {
        errorReporting.capture({ name: 'OperationError' }, code);
      }
      return result;
    } catch (error) {
      errorReporting.breadcrumb({
        operation,
        stage: 'failed',
        elapsedMs: elapsedMs(),
      });
      // Legacy transports also use unavailable for proven-unsent offline requests.
      if (rejectionCode(error) !== 'unavailable') {
        errorReporting.capture(error, code);
      }
      throw error;
    }
  };
  const withdrawReporting = async <A>(request: () => Promise<A>) => {
    // The store closes its local gate synchronously; native removal also purges
    // before account cleanup. An unavailable reporting server cannot delay sign-out.
    void errorReporting.setEnabled(false);
    return request();
  };
  const registration = createRegistration({
    registration: () => native().registration(),
    signInIdentity: (provider, hint) =>
      observe('sign-in', 'sign-in-failed', () =>
        native().signInIdentity(provider, hint),
      ),
    renewIdentity: () => native().renewIdentity(),
    appleCredentialState: () => native().appleCredentialState(),
    reuseSession: () => native().reuseSession(),
    saveIdentity: (replacing) => native().saveIdentity(replacing),
    connect: (mode) =>
      observe('sign-in', 'sign-in-failed', () => native().connect(mode)),
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
    recordRemoval: (operation) =>
      withdrawReporting(() => native().recordRemoval(operation)),
    prepareSignOut: () => native().prepareSignOut(),
    endSession: () => withdrawReporting(() => native().endSession()),
    purge: (notice) => withdrawReporting(() => native().purge(notice)),
    call: (request) =>
      observe('account', 'backend-failed', () => native().call(request)),
    removeMailbox: (connection) => native().removeMailbox(connection),
    routeMailboxes: () => native().routeMailboxes(),
    stopMailboxWatches: () => native().stopMailboxWatches(),
    confirmRecoveryKey: (entry) => native().confirmRecoveryKey(entry),
    readsAsRecoveryKey: (entry) => native().readsAsRecoveryKey(entry),
  });

  // Mailbox or Draft work found this device removed and native code purged it.
  const removed = () => {
    void errorReporting.setEnabled(false);
    void registration.deviceRemoved();
  };

  // APNs wake hints waiting for JavaScript, and the routes they may name.
  const wakes: NativeWakes = {
    nextWake: () => native().nextWake(),
    mailboxRoutes: () => native().mailboxRoutes(),
    completeWake: (id, result) => {
      native().completeWake(id, result);
    },
  };

  // This device's notification settings and the New Mail Notifications it posts.
  const notifications = createNotifications(
    {
      notificationSettings: () => native().notificationSettings(),
      requestNotifications: () => native().requestNotifications(),
      setNotificationPreviews: (previews) =>
        native().setNotificationPreviews(previews),
      openNotificationSettings: () => native().openNotificationSettings(),
      postNotifications: (posted) => native().postNotifications(posted),
    },
    translate,
  );

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
  const gmailMailboxes = createMailboxes(
    {
      gmailRequest: (path, query, { signal, ...mailbox }) =>
        cancellable(mailbox, signal, (request) => {
          const scope = { ...mailbox, request };
          return observe('sync', 'sync-failed', () =>
            native().gmailRequest(path, query, scope),
          );
        }),
      graphRequest: (url, { signal, ...mailbox }) =>
        cancellable(mailbox, signal, (request) => {
          const scope = { ...mailbox, request };
          return observe('sync', 'sync-failed', () =>
            native().graphRequest(url, scope),
          );
        }),
      gmailModify: (change, mailbox) => native().gmailModify(change, mailbox),
      graphModify: (change, mailbox) => native().graphModify(change, mailbox),
      gmailSend: (message, mailbox) =>
        observe('send', 'send-failed', () =>
          native().gmailSend(message, mailbox),
        ),
      graphSend: (message, mailbox) =>
        observe('send', 'send-failed', () =>
          native().graphSend(message, mailbox),
        ),
      openMailbox: (connection) => native().openMailbox(connection),
      imapFolders: (mailbox) => native().imapFolders(mailbox),
      imapSynchronize: (mailbox, request) =>
        observe('sync', 'sync-failed', () =>
          native().imapSynchronize(mailbox, request),
        ),
      imapMessage: (mailbox, message) => native().imapMessage(mailbox, message),
      imapModify: (mailbox, change) => native().imapModify(mailbox, change),
      imapSearch: (mailbox, request) => native().imapSearch(mailbox, request),
      imapIdle: (mailbox, request) => native().imapIdle(mailbox, request),
      imapSend: (message, mailbox) =>
        observe('send', 'send-failed', () =>
          native().imapSend(message, mailbox),
        ),
      imapFileSent: (mailbox, request) =>
        native().imapFileSent(mailbox, request),
      imapFindSent: (mailbox, request) =>
        native().imapFindSent(mailbox, request),
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
      removed,
      arrived: (connection, messages) => {
        void notifications.arrived(connection, messages);
      },
    },
  );

  // The signed-in Product Account's encrypted Drafts on this device, synchronized through Product
  // Sync with its other Trusted Devices.
  const drafts = createDrafts(
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
      removed,
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
  const outbox = createOutbox({
    drafts,
    mailboxes: gmailMailboxes,
    registration,
    claims: {
      claimDraftDelivery: (owner, id) => native().claimDraftDelivery(owner, id),
    },
  });
  // The host's application lifecycle grants execution; constructing stores grants none.
  outbox.pause();

  // This device's remote content policies and the Authorized Remote Content Cache.
  const remoteContent = createRemoteContentSettings({
    remoteContentSettings: () => native().remoteContentSettings(),
    setRemoteContentSettings: (settings) =>
      native().setRemoteContentSettings(settings),
    clearRemoteContent: () => native().clearRemoteContent(),
  });

  const freshness = createFreshness(gmailMailboxes, registration.refreshInbox);

  let started: Promise<unknown> | undefined = undefined;
  let following = false;
  return {
    registration,
    gmailMailboxes,
    drafts,
    outbox,
    wakes,
    freshness,
    remoteContent,
    errorReporting,
    notifications,
    // Restores Registration and reads the saved remote content policies once per process, however
    // many windows or screens open.
    start: () => {
      started ??= Promise.all([
        registration.restoreOnce(),
        remoteContent.load(),
        errorReporting.load(),
      ]);
      return started;
    },
    // Reads push wakes for the life of the process; a later call starts no second reader.
    followWakes: () => {
      if (!following) {
        following = true;
        void followWakes(freshness, wakes);
      }
    },
  };
}
