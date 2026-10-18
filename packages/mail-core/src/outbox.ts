import * as Effect from 'effect/Effect';
import * as Option from 'effect/Option';
import * as Schedule from 'effect/Schedule';
import * as Schema from 'effect/Schema';

import type { DeliveryProblem, Draft, OutboxEntry } from './draft-model.ts';
import type { Drafts } from './drafts.ts';
import type { SendOutcome } from './gmail-inbox.ts';
import type { ImapMailbox, Mailbox, Mailboxes } from './mailboxes.ts';
import type { OutboxCheck, OutboxSnapshotEntry } from './outbox-copy.ts';
import type { MailProvider } from './registration-snapshot.ts';
import type { Registration } from './registration.ts';

import {
  rejectionCode,
  rejectionDiagnostic,
  runLogged,
} from './diagnostics.ts';
import { assetsOf } from './draft-model.ts';
import { sendingStateOf, threadOf, unsendableAssets } from './drafts.ts';
import { imapRoleFolder } from './imap-actions.ts';
import {
  boundaryOf,
  gmailMessageLimit,
  graphMessageLimit,
  messageIdOf,
  outgoingMessage,
  sendableAddress,
} from './outgoing-message.ts';
import { mailboxesOf } from './registration-snapshot.ts';
import { canOpenInbox } from './registration.ts';

export type { OutboxCheck, OutboxSnapshotEntry } from './outbox-copy.ts';

export { outboxCopy } from './outbox-copy.ts';

// The native module's delivery claim through Convex. Native code names the Draft by an identifier
// derived from the Product Account's Product Sync keys, so Convex learns nothing about the message.
export interface NativeDeliveryClaim {
  // Claims Draft `id` for delivery from this Trusted Device. Resolves `{ owner, claimed }`, false
  // when another Trusted Device holds the claim; asking again after holding it keeps it. Rejects
  // with 'unavailable' without Product Sync keys, a session or a connection, when the claim may or
  // may not have been taken.
  readonly claimDraftDelivery: (owner: string, id: string) => Promise<unknown>;
}

const decodeClaimed = Schema.decodeUnknownOption(
  Schema.Struct({ owner: Schema.NonEmptyString, claimed: Schema.Boolean }),
);

// The default Undo Send Window.
export const undoSendWindow = 10_000;
// How long a message that reached neither Convex nor Gmail waits before trying again.
const retryDelay = 30_000;

// Why Send left a Draft in the composer: no recipients, unfinished recipient text, a sender that
// cannot send or whose mail server has no Sent folder for its copy, files not complete and verified
// on this device, a message over its provider's limit, another editor's change to the Draft, or
// storage refusing the write.
export type SendRefusal =
  | 'recipients'
  | 'entries'
  | 'addresses'
  | 'sender'
  | 'sent-folder'
  | 'assets'
  | 'too-large'
  | 'changed'
  | 'storage';

// The person's Check Again of an unknown message, for the Send it was asked about and the Product
// Account it belongs to.
type CheckRequest = Readonly<{
  sendAt: number;
  owner: string | undefined;
  check: 'checking' | 'unconfirmed';
}>;

const ownerOf = (registration: Pick<Registration, 'getSnapshot'>) => {
  const { snapshot } = registration.getSnapshot();
  return canOpenInbox(snapshot) && snapshot.kind !== 'signed-out'
    ? snapshot.productAccountId
    : undefined;
};

// An SMTP or Microsoft message names its own Message-ID, which its Sent copy keeps for replies to
// thread with and Microsoft's Sent Items are searched by; Gmail assigns one itself.
const messageOf = (draft: Draft, named: boolean) => {
  const boundary = Math.random().toString(36).slice(2, 14);
  const { segments, size } = outgoingMessage(draft, {
    date: Date.now(),
    boundary,
    ...(named
      ? {
          messageId: `${Date.now().toString(36)}.${boundary}@${draft.from.split('@').at(-1) ?? ''}`,
        }
      : {}),
  });
  const thread = threadOf(draft);
  return {
    segments,
    size,
    ...(thread === undefined ? {} : { threadId: thread }),
  };
};

// The largest message a provider takes; SMTP has no known limit, so it is held to Gmail's.
const limitOf = (provider: MailProvider | undefined) =>
  provider === 'microsoft-graph' ? graphMessageLimit : gmailMessageLimit;

const withState = (
  entry: OutboxEntry,
  state: OutboxEntry['state'],
  problem?: DeliveryProblem,
): OutboxEntry => ({
  id: entry.id,
  draft: entry.draft,
  message: entry.message,
  sendAt: entry.sendAt,
  state,
  ...(entry.claim === undefined ? {} : { claim: entry.claim }),
  ...(problem === undefined ? {} : { problem }),
});

// Handed to Gmail without a recorded answer. Another store opening meanwhile marks the entry
// unknown; the store that handed it off still records the answer it got.
const awaitingOutcome = (state: OutboxEntry['state'] | undefined) =>
  state === 'sending' || state === 'unknown';

// One Outbox step from state `from`; any other state refuses it.
const step =
  <T>(from: OutboxEntry['state'], next: (entry: OutboxEntry) => T) =>
  (entry: OutboxEntry) =>
    entry.state === from ? next(entry) : undefined;

// Sends Drafts admitted to the Outbox on this device, their Delivery Owner. After the Undo Send
// Window, a message is claimed through Convex so no other Trusted Device can send the same Draft,
// marked as handed to its provider in storage, and only then sent once, through Gmail, Microsoft
// Graph or SMTP. A message that reached neither Convex nor the provider is tried again later; one
// handed off without a confirmed answer is never sent again automatically. The Sent mailbox is checked for it when it
// becomes unknown, when this Outbox starts, when the app becomes active and when the person asks.
// A message SMTP accepted is recorded first, then its copy is filed in the Sent folder, which alone
// is tried again until it is there.
export function createOutbox({
  drafts,
  mailboxes,
  registration,
  claims,
}: Readonly<{
  drafts: Pick<
    Drafts,
    | 'getSnapshot'
    | 'getOutbox'
    | 'admit'
    | 'deliver'
    | 'restore'
    | 'readAsset'
    | 'subscribe'
  >;
  mailboxes: Pick<Mailboxes, 'getConnections' | 'subscribe'>;
  registration: Pick<Registration, 'getSnapshot' | 'subscribe'>;
  claims: NativeDeliveryClaim | undefined;
}>) {
  // When each pending message may try again; one without an entry uses its Send deadline.
  const retryAt = new Map<string, number>();
  // Outcomes Gmail gave that storage refused to record; saved again while awaiting an outcome.
  const unrecorded = new Map<string, SendOutcome>();
  // Unknown messages to look for in Gmail's Sent mailbox on the next pass, and current messages
  // already queued once by this Outbox.
  const checks = new Set<string>();
  const queuedChecks = new Set<string>();
  // Running Sent lookups, and whether a ready mailbox was published while each awaited its answer.
  const checking = new Map<string, boolean>();
  let timer: AbortController | undefined = undefined;
  let disposed = false;
  let paused = false;
  // A pause fences work already awaiting a claim or storage, even if execution resumes meanwhile.
  let execution = 0;
  const running = () => !disposed && !paused;
  const executing = (started: number, account: string | undefined) =>
    running() && started === execution && ownerOf(registration) === account;
  let owner = ownerOf(registration);
  const unsubscribeRegistration = registration.subscribe(() => {
    const next = ownerOf(registration);
    if (owner !== next) {
      owner = next;
      execution += 1;
    }
  });
  // The person's Check Again of each unknown message, shared by every window reading this Outbox.
  const asked = new Map<string, CheckRequest>();
  const listeners = new Set<() => void>();
  let listed: readonly OutboxEntry[] | undefined = undefined;
  let snapshot: readonly OutboxSnapshotEntry[] = [];
  // A check answers only the unknown Send it was asked about, never a later one of the same Draft.
  const checkOf = (entry: OutboxEntry): OutboxCheck => {
    const request = asked.get(entry.id);
    return entry.state === 'unknown' &&
      request?.sendAt === entry.sendAt &&
      request.owner === ownerOf(registration)
      ? request.check
      : 'idle';
  };
  const publish = () => {
    const outbox = drafts.getOutbox();
    for (const id of asked.keys()) {
      const entry = outbox.find((each) => each.id === id);
      if (entry === undefined || checkOf(entry) === 'idle') {
        asked.delete(id);
      }
    }
    listed = undefined;
    for (const listener of listeners) {
      listener();
    }
  };

  const entryOf = (id: string) =>
    drafts.getOutbox().find((each) => each.id === id);
  const connectionOf = (id: string): Mailbox | ImapMailbox | undefined =>
    mailboxes.getConnections().find((mailbox) => mailbox.id === id);
  // An IMAP message waits for its folder listing and requires one server-declared Sent folder.
  const sentFolderCheck = (
    draft: Draft,
  ): 'wait' | 'sent-folder' | undefined => {
    const mailbox = connectionOf(draft.connection);
    if (mailbox?.provider !== 'imap') {
      return undefined;
    }
    if (mailbox.state.kind !== 'ready') {
      return 'wait';
    }
    return imapRoleFolder(mailbox.state.folders, 'sent') === undefined
      ? 'sent-folder'
      : undefined;
  };
  const providerOf = (draft: Draft) =>
    mailboxesOf(registration.getSnapshot().snapshot).find(
      ({ id }) => id === draft.connection,
    )?.provider;
  // Both scheduling and processing use the same deadline, including a refused storage step.
  const dueAt = (entry: OutboxEntry) => {
    if (entry.state === 'waiting') {
      return Math.max(entry.sendAt, retryAt.get(entry.id) ?? 0);
    }
    return entry.state === 'queued' ||
      entry.state === 'filing' ||
      (awaitingOutcome(entry.state) && unrecorded.has(entry.id))
      ? (retryAt.get(entry.id) ?? 0)
      : Number.POSITIVE_INFINITY;
  };
  const claim = async (account: string, id: string) => {
    try {
      const claimed = decodeClaimed(
        await claims?.claimDraftDelivery(account, id),
      );
      return Option.isSome(claimed) && claimed.value.owner === account
        ? claimed.value.claimed
        : undefined;
    } catch (error) {
      if (rejectionCode(error) !== 'unavailable') {
        await runLogged(
          Effect.logError('Delivery claim failed:', rejectionDiagnostic(error)),
        );
      }
      return undefined;
    }
  };

  // The sending mailbox's problem on this device, if it can no longer send.
  const senderProblem = (draft: Draft): DeliveryProblem | undefined => {
    const sending = sendingStateOf(
      draft,
      mailboxesOf(registration.getSnapshot().snapshot),
    );
    if (sending === 'available') {
      return undefined;
    }
    return sending === 'authorization' || sending === 'password'
      ? 'authorization'
      : 'mailbox';
  };

  // Whether a queued message may be handed off now: a problem that refuses it for good, 'wait'
  // while an IMAP connection's listing has not named the Sent folder for its copy, or undefined.
  const handoffCheck = (draft: Draft): DeliveryProblem | 'wait' | undefined =>
    senderProblem(draft) ?? sentFolderCheck(draft);

  const record = (id: string, outcome: SendOutcome) => {
    if (outcome.kind === 'accepted') {
      return drafts.deliver(id, (entry) =>
        awaitingOutcome(entry.state) ? withState(entry, 'filing') : undefined,
      );
    }
    if (outcome.kind === 'sent') {
      return drafts.deliver(id, (entry) =>
        awaitingOutcome(entry.state)
          ? {
              id,
              ...(outcome.message === undefined
                ? {}
                : { message: outcome.message }),
              sentAt: Date.now(),
            }
          : undefined,
      );
    }
    return drafts.deliver(id, (entry) => {
      if (!awaitingOutcome(entry.state)) {
        return undefined;
      }
      return outcome.kind === 'unknown'
        ? withState(entry, 'unknown')
        : withState(entry, outcome.kind, outcome.problem);
    });
  };

  // Resolves true only once storage holds this device's confirmed claim on a queued message.
  const holdClaim = async (
    account: string,
    entry: OutboxEntry,
    current: () => boolean,
  ) => {
    const { id } = entry;
    if (entry.claim === 'held') {
      return true;
    }
    // Recorded first: a Draft whose claim may exist never returns under the same identifier.
    if (
      entry.claim === undefined &&
      !(await drafts.deliver(
        id,
        step('queued', (each) => ({ ...each, claim: 'requested' })),
      ))
    ) {
      return false;
    }
    if (!current()) {
      return false;
    }
    const claimed = await claim(account, id);
    if (claimed === undefined) {
      await drafts.deliver(
        id,
        step('queued', (each) => withState(each, 'queued', 'offline')),
      );
      return false;
    }
    if (!claimed) {
      await drafts.deliver(
        id,
        step('queued', (each) => withState(each, 'failed', 'claimed')),
      );
      return false;
    }
    return drafts.deliver(
      id,
      step('queued', (each) => ({ ...each, claim: 'held' })),
    );
  };

  // Records an outcome, keeping it to save again when storage refuses, so a message Gmail never
  // received does not stay 'sending' and read as unknown after a relaunch.
  const keep = async (id: string, outcome: SendOutcome) => {
    if (await record(id, outcome)) {
      unrecorded.delete(id);
    } else if (!disposed && awaitingOutcome(entryOf(id)?.state)) {
      unrecorded.set(id, outcome);
    }
  };

  // Saves an outcome storage refused earlier. Resolves whether one was waiting.
  const resave = async (entry: OutboxEntry) => {
    const outcome = unrecorded.get(entry.id);
    if (outcome === undefined) {
      return false;
    }
    unrecorded.delete(entry.id);
    if (awaitingOutcome(entry.state)) {
      await keep(entry.id, outcome);
    }
    return true;
  };

  // Invokes the current provider with the frozen message and its original envelope.
  const submit = async (entry: OutboxEntry): Promise<SendOutcome> => {
    const mailbox = connectionOf(entry.draft.connection);
    if (mailbox === undefined) {
      return { kind: 'queued', problem: 'offline' };
    }
    const { to, cc, bcc } = entry.draft;
    return mailbox.provider === 'imap'
      ? mailbox.inbox.send(
          entry.message,
          [...to, ...cc, ...bcc].map(({ address }) => address),
        )
      : mailbox.inbox.send(entry.message);
  };

  // Hands a claimed message to Gmail once, after its durable handoff.
  const handOff = async (id: string, current: () => boolean) => {
    const account = ownerOf(registration);
    // Storage holds 'sending' before Gmail sees the message, so an interruption reads as unknown.
    const handed = await drafts.deliver(id, (each) =>
      current() && each.state === 'queued' && each.claim === 'held'
        ? withState(each, 'sending')
        : undefined,
    );
    if (!handed) {
      return;
    }
    // No provider request started. Keep the held claim retryable when execution ended mid-write.
    if (!current()) {
      if (account === ownerOf(registration)) {
        await keep(id, { kind: 'queued', problem: 'offline' });
      }
      return;
    }
    const sending = entryOf(id);
    if (sending === undefined) {
      await keep(id, { kind: 'queued', problem: 'offline' });
      return;
    }
    // Claim and storage awaited meanwhile; recheck before invoking the current Inbox.
    const problem = handoffCheck(sending.draft);
    if (problem !== undefined) {
      await keep(id, {
        kind: problem === 'wait' ? 'queued' : 'failed',
        problem: problem === 'wait' ? 'offline' : problem,
      });
      return;
    }
    const outcome = await submit(sending);
    if (account === ownerOf(registration)) {
      await keep(id, outcome);
    }
  };

  // Delivery owns opening its sender even when no Inbox view has loaded it.
  const openSender = async (draft: Draft) => {
    const mailbox = connectionOf(draft.connection);
    if (mailbox !== undefined && mailbox.state.kind !== 'ready') {
      await mailbox.inbox.load();
    }
  };

  // Files an accepted message's Sent copy, and records it as sent once the copy is there. A
  // connection removed meanwhile has nowhere to keep it, so the message is recorded as sent; one
  // waiting for its password keeps the copy waiting.
  const file = async (entry: OutboxEntry, current: () => boolean) => {
    await openSender(entry.draft);
    if (!current()) {
      return;
    }
    const mailbox = connectionOf(entry.draft.connection);
    const boundary = boundaryOf(entry.message.segments);
    const sending = sendingStateOf(
      entry.draft,
      mailboxesOf(registration.getSnapshot().snapshot),
    );
    let problem: DeliveryProblem | undefined = 'offline';
    if (sending === 'removed') {
      problem = undefined;
    } else if (sending === 'password') {
      problem = 'authorization';
    } else if (mailbox?.provider === 'imap' && boundary !== undefined) {
      problem = await mailbox.inbox.fileSent(entry.message, boundary);
    }
    await drafts.deliver(
      entry.id,
      step('filing', (each) => {
        if (problem === undefined) {
          return { id: each.id, sentAt: Date.now() };
        }
        return problem === each.problem
          ? undefined
          : withState(each, 'filing', problem);
      }),
    );
  };

  // Records an unknown message as sent only when its Sent mailbox holds exactly one copy.
  const reconcile = async (id: string) => {
    const entry = entryOf(id);
    if (entry?.state !== 'unknown' || ownerOf(registration) === undefined) {
      return;
    }
    const boundary = boundaryOf(entry.message.segments);
    const mailbox = connectionOf(entry.draft.connection);
    if (boundary === undefined || mailbox === undefined) {
      return;
    }
    queuedChecks.add(id);
    const outcome =
      mailbox.provider === 'imap'
        ? await mailbox.inbox.findSent(boundary)
        : await mailbox.inbox.findSent(
            boundary,
            messageIdOf(entry.message.segments),
          );
    if (outcome === undefined) {
      // The mailbox closed or changed meanwhile; it is checked again once it is ready.
      queuedChecks.delete(id);
    } else if (outcome.kind === 'sent') {
      await keep(id, outcome);
    }
  };

  // Ends a message's Undo Send Window once it has passed. Resolves false when storage refused that.
  const release = async (entry: OutboxEntry) =>
    entry.state !== 'waiting' ||
    Date.now() < entry.sendAt ||
    drafts.deliver(
      entry.id,
      step('waiting', (each) => withState(each, 'queued')),
    );

  // Why the Draft cannot be sent as it is, checked before reading its files.
  const refusalOf = (draft: Draft): SendRefusal | undefined => {
    if (draft.to.length + draft.cc.length + draft.bcc.length === 0) {
      return 'recipients';
    }
    if (draft.entries !== undefined) {
      return 'entries';
    }
    if (
      ![
        draft.from,
        ...[...draft.to, ...draft.cc, ...draft.bcc].map(
          ({ address }) => address,
        ),
      ].every(sendableAddress)
    ) {
      return 'addresses';
    }
    if (senderProblem(draft) !== undefined) {
      return 'sender';
    }
    if (sentFolderCheck(draft) === 'sent-folder') {
      return 'sent-folder';
    }
    return unsendableAssets(draft).length > 0 ? 'assets' : undefined;
  };

  // Whether every file is on this device with bytes matching its digest.
  const verified = async (draft: Draft) => {
    for (const asset of assetsOf(draft)) {
      if (asset.state === 'complete') {
        const read = await drafts.readAsset(asset, { preview: false });
        if (read.kind !== 'verified') {
          return false;
        }
      }
    }
    return true;
  };

  // Claims a queued message and hands it off; a message SMTP accepted files its Sent copy at once.
  const sendQueued = async (
    account: string,
    entry: OutboxEntry,
    current: () => boolean,
  ) => {
    await openSender(entry.draft);
    if (!current()) {
      return;
    }
    const check = handoffCheck(entry.draft);
    if (check === 'wait') {
      return;
    }
    if (check !== undefined) {
      await drafts.deliver(
        entry.id,
        step('queued', (each) => withState(each, 'failed', check)),
      );
      return;
    }
    if ((await holdClaim(account, entry, current)) && current()) {
      await handOff(entry.id, current);
      const accepted = entryOf(entry.id);
      if (current() && accepted?.state === 'filing') {
        await file(accepted, current);
      }
    }
  };

  // Advances one message as far as it can go now; the persisted state decides what remains due.
  const advance = async (id: string) => {
    const account = ownerOf(registration);
    const waiting = entryOf(id);
    const started = execution;
    const current = () => executing(started, account);
    if (account === undefined || waiting === undefined) {
      return;
    }
    if (await resave(waiting)) {
      return;
    }
    if (!(await release(waiting)) || !current()) {
      return;
    }
    const entry = entryOf(id);
    // oxlint-disable-next-line typescript/switch-exhaustiveness-check -- Other durable states never permit automatic delivery.
    switch (entry?.state) {
      case 'filing': {
        await file(entry, current);
        break;
      }
      case 'queued': {
        await sendQueued(account, entry, current);
        break;
      }
      default: {
        break;
      }
    }
  };

  // Runs `due` when a message is next due: the end of an Undo Send Window or a retry.
  const plan = (due: () => void) => {
    timer?.abort();
    timer = undefined;
    if (!running()) {
      return;
    }
    const now = Date.now();
    let next = Number.POSITIVE_INFINITY;
    for (const entry of drafts.getOutbox()) {
      next = Math.min(next, dueAt(entry));
    }
    if (Number.isFinite(next)) {
      const pending = new AbortController();
      timer = pending;
      const wait = async () => {
        try {
          await runLogged(
            Effect.repeat(
              Effect.void,
              Schedule.duration(Math.max(0, next - now)),
            ),
            { signal: pending.signal },
          );
          if (!pending.signal.aborted && running()) {
            timer = undefined;
            due();
          }
        } catch (error) {
          if (!pending.signal.aborted) {
            await runLogged(
              Effect.logError(
                'Outbox wait failed:',
                rejectionDiagnostic(error),
              ),
            );
          }
        }
      };
      void wait();
    }
  };

  // Queues a check of every unknown message, or only those this Outbox has not checked yet.
  const checkUnknown = (all: boolean) => {
    let added = false;
    for (const entry of drafts.getOutbox()) {
      const mailbox = connectionOf(entry.draft.connection);
      // Draft storage can open before its mailbox at launch or during authorization renewal.
      if (
        mailbox?.state.kind !== 'ready' ||
        (mailbox.provider !== 'imap' && !mailbox.state.organize)
      ) {
        queuedChecks.delete(entry.id);
      } else if (entry.state === 'unknown') {
        if (checking.has(entry.id)) {
          checking.set(entry.id, true);
        } else if (all || !queuedChecks.has(entry.id)) {
          queuedChecks.add(entry.id);
          checks.add(entry.id);
          added = true;
        }
      }
    }
    return added;
  };

  // Passes run one at a time; a request during one runs another after it.
  let passing: Promise<void> | undefined = undefined;
  let requested = false;
  // A single Sent lookup owns its deduplication markers until the provider settles.
  const checkSent = async (id: string) => {
    if (!running()) {
      return;
    }
    checks.delete(id);
    checking.set(id, false);
    try {
      await reconcile(id);
    } finally {
      const refreshed = checking.get(id) === true;
      checking.delete(id);
      if (refreshed && !queuedChecks.has(id) && !disposed) {
        checkUnknown(false);
      }
    }
  };
  // An interrupted execution cannot restore backoff that a new opportunity already cleared.
  const retry = (id: string, started: number) => {
    if (started !== execution) {
      return;
    }
    const pending = entryOf(id);
    if (pending !== undefined && Number.isFinite(dueAt(pending))) {
      retryAt.set(id, Date.now() + retryDelay);
    }
  };
  const hasUnknown = () =>
    drafts.getOutbox().some((entry) => entry.state === 'unknown');
  const pass = async () => {
    // Recovery also owns opening its mailbox after a launch with no Inbox.
    for (const entry of drafts.getOutbox()) {
      if (running() && entry.state === 'unknown') {
        await openSender(entry.draft);
      }
    }
    checkUnknown(false);
    for (const id of checks) {
      await checkSent(id);
    }
    const now = Date.now();
    for (const entry of drafts.getOutbox()) {
      const { id } = entry;
      if (running() && dueAt(entry) <= now) {
        const started = execution;
        retryAt.delete(id);
        await advance(id);
        retry(id, started);
      }
    }
  };
  const process = async () => {
    if (!running()) {
      return;
    }
    requested = true;
    passing ??= (async () => {
      try {
        while (requested) {
          requested = false;
          if (running()) {
            await pass();
          }
        }
      } catch (error) {
        await runLogged(
          Effect.logError(
            'Outbox delivery failed:',
            rejectionDiagnostic(error),
          ),
        );
      } finally {
        passing = undefined;
        plan(() => void process());
      }
    })();
    await passing;
  };

  let seen = drafts.getOutbox();
  const unsubscribe = drafts.subscribe(() => {
    const outbox = drafts.getOutbox();
    if (outbox !== seen) {
      seen = outbox;
      const sending = new Set(
        outbox
          .filter((entry) => awaitingOutcome(entry.state))
          .map((entry) => entry.id),
      );
      for (const id of unrecorded.keys()) {
        if (!sending.has(id)) {
          unrecorded.delete(id);
        }
      }
      for (const id of queuedChecks) {
        if (!sending.has(id)) {
          queuedChecks.delete(id);
          checks.delete(id);
        }
      }
      publish();
      if (checkUnknown(false) || hasUnknown()) {
        void process();
      } else if (passing === undefined) {
        plan(() => void process());
      }
    }
  });
  const unsubscribeMailboxes = mailboxes.subscribe(() => {
    if (checkUnknown(false)) {
      void process();
    }
  });
  if (checkUnknown(false) || hasUnknown()) {
    void process();
  } else {
    plan(() => void process());
  }

  return {
    subscribe: (listener: () => void) => {
      listeners.add(listener);
      return () => {
        listeners.delete(listener);
      };
    },
    // The Outbox of the signed-in Product Account, oldest Send first.
    getSnapshot: (): readonly OutboxSnapshotEntry[] => {
      const outbox = drafts.getOutbox();
      if (outbox !== listed) {
        listed = outbox;
        snapshot = outbox.map((entry) => ({ ...entry, check: checkOf(entry) }));
      }
      return snapshot;
    },
    // Admits the Draft `expected` shows to the Outbox, to send once the Undo Send Window ends.
    // Resolves why it was refused, or undefined once admitted.
    send: async (expected: () => Draft): Promise<SendRefusal | undefined> => {
      const draft = expected();
      const refusal = refusalOf(draft);
      if (refusal !== undefined) {
        return refusal;
      }
      if (!(await verified(draft))) {
        return 'assets';
      }
      // The sending mailbox can change while files are read; it is checked again before admission.
      const late = refusalOf(expected());
      if (late !== undefined) {
        return late;
      }
      const provider = providerOf(draft);
      const message = messageOf(draft, provider !== 'gmail');
      if (message.size > limitOf(provider)) {
        return 'too-large';
      }
      const sendAt = Date.now() + undoSendWindow;
      // The identifier follows an editor rebound to its conflict copy; the content stays the
      // version the message was built from, so a later change is refused rather than admitted.
      const pinned = () => {
        const current = expected();
        return {
          ...draft,
          id: current.id,
          ...(current.conflict === true ? { conflict: true as const } : {}),
        };
      };
      const admitted = await drafts.admit(
        () => expected().id,
        pinned,
        (stored) => ({
          id: stored.id,
          draft: stored,
          message,
          sendAt,
          state: 'waiting',
        }),
      );
      if (admitted) {
        return undefined;
      }
      const state = drafts.getSnapshot();
      return state.kind === 'ready' &&
        state.save !== 'failed' &&
        state.save !== 'locked'
        ? 'changed'
        : 'storage';
    },
    // Returns a message to the Drafts, as Undo, after a refusal, or when the person chooses to
    // edit one whose delivery is unknown. Resolves the Draft's identifier, or false when it can no
    // longer return.
    undo: async (id: string) => {
      retryAt.delete(id);
      return drafts.restore(id);
    },
    // Looks for an unknown message in Gmail's Sent mailbox now, publishing 'checking' at once and
    // 'unconfirmed' when it stays unknown. Resolves whether it left the Outbox as sent.
    check: async (id: string) => {
      const entry = entryOf(id);
      const request: CheckRequest | undefined =
        entry?.state === 'unknown'
          ? {
              sendAt: entry.sendAt,
              owner: ownerOf(registration),
              check: 'checking',
            }
          : undefined;
      if (request !== undefined) {
        asked.set(id, request);
        publish();
      }
      // A check asked again meanwhile answers from the same running Sent lookup.
      if (!checking.has(id)) {
        checks.add(id);
      }
      await process();
      const current = entryOf(id);
      if (request !== undefined && asked.get(id) === request) {
        // Removal, another Send of the Draft or another Product Account meanwhile ends it quietly.
        if (current !== undefined && checkOf(current) === 'checking') {
          asked.set(id, { ...request, check: 'unconfirmed' });
        } else {
          asked.delete(id);
        }
        publish();
      }
      return current === undefined;
    },
    // Ends this execution opportunity without cancelling a request already handed to its provider.
    pause: () => {
      paused = true;
      execution += 1;
      timer?.abort();
      timer = undefined;
    },
    // A fresh foreground/application opportunity retries due work without changing Send deadlines.
    resume: async () => {
      paused = false;
      retryAt.clear();
      checkUnknown(true);
      await process();
    },
    // Tries every due message now and checks every unknown one within the current opportunity.
    process: async () => {
      retryAt.clear();
      checkUnknown(true);
      await process();
    },
    dispose: () => {
      disposed = true;
      timer?.abort();
      unsubscribe();
      unsubscribeMailboxes();
      unsubscribeRegistration();
      unrecorded.clear();
      checks.clear();
      queuedChecks.clear();
      asked.clear();
    },
  };
}

export type Outbox = ReturnType<typeof createOutbox>;
