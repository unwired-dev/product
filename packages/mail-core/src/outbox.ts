import * as Arr from 'effect/Array';
import * as Clock from 'effect/Clock';
import * as Effect from 'effect/Effect';
import * as Option from 'effect/Option';
import * as Schema from 'effect/Schema';
import * as Semaphore from 'effect/Semaphore';

import type { DeliveryProblem, Draft, OutboxEntry } from './draft-model.ts';
import type { AssetPreview, Drafts } from './drafts.ts';
import type { SendOutcome } from './inbox-store.ts';
import type { InvitationAnswer } from './invitation-record.ts';
import type { ImapMailbox, Mailbox, Mailboxes } from './mailboxes.ts';
import type { OutboxCheck, OutboxSnapshotEntry } from './outbox-copy.ts';
import type {
  MailboxConnection,
  MailProvider,
} from './registration-snapshot.ts';
import type { Registration } from './registration.ts';
import type { Block, SemanticDocument } from './semantic-document.ts';
import type { Unsubscribe, UnsubscribeOffer } from './unsubscribe.ts';

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
  draftFiles,
  gmailMessageLimit,
  graphDraftLimit,
  graphMessageLimit,
  messageIdOf,
  outgoingMessage,
  sendableAddress,
} from './outgoing-message.ts';
import { mailboxesOf } from './registration-snapshot.ts';
import { canOpenInbox } from './registration.ts';
import { imageCharacter } from './semantic-document.ts';
import { unsubscribeOfferReturnsAfter } from './unsubscribe.ts';

export type { OutboxCheck, OutboxSnapshotEntry } from './outbox-copy.ts';

export { outboxCopy } from './outbox-copy.ts';

// The native module's delivery claim through Convex. Native code names the Draft by an identifier
// derived from the Product Account's Product Sync keys, so Convex learns nothing about the message.
export interface NativeDeliveryClaim {
  // Claims Draft `id` for delivery from this Trusted Device. Resolves `{ owner, claimed }`, false
  // when another Trusted Device holds the claim; asking again after holding it keeps it. Rejects
  // with 'unavailable' without Product Sync keys, device proof or a connection, when the claim may or
  // may not have been taken.
  readonly claimDraftDelivery: (owner: string, id: string) => Promise<unknown>;
}

const decodeClaimed = Schema.decodeUnknownOption(
  Schema.Struct({ owner: Schema.NonEmptyString, claimed: Schema.Boolean }),
);

// A delivery claim that did not settle; whether it was taken is unknown.
class ClaimFailure extends Schema.TaggedError<
  ClaimFailure,
  { readonly brand: unique symbol }
>()('ClaimFailure', { cause: Schema.Defect() }) {}

// Only an explicit native release permits another hold; denied, expired or malformed replies stop it.
export const deliveryTimeReleased = Schema.is(Schema.Literal(true));

// The default Undo Send Window.
export const undoSendWindow = 10_000;
// How long a message that reached neither Convex nor Gmail waits before trying again.
const retryDelay = 30_000;
// Both maintained hosts have one JavaScript runtime. Keep preparation and its handoff together
// across local stores so a competing writer cannot replace the draft another is about to send.
const microsoftDelivery = Semaphore.makeUnsafe(1);

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

// The files Send is checking, by identifier: undefined while a file is read, then what the read
// found. The check stops at the first file that does not verify.
export type SendCheck = ReadonlyMap<string, AssetPreview['kind'] | undefined>;

// Where a confirmed `mailto:` unsubscribe request stands: waiting out the Undo Send Window in the
// Outbox as `id`, or already confirmed sent as `id`; not sent because its receiving connection
// only receives or needs authorization again; or not admitted, as when the connection is gone or
// storage refused it.
export type MailtoUnsubscribe =
  | Readonly<{ kind: 'waiting'; id: string }>
  | Readonly<{ kind: 'receive-only' | 'authorization' | 'failed' }>;

// Why `mailbox`, the connection that received a `mailto:` offer, cannot send its request: it
// receives only or needs authorization again.
export const unsendable = (
  mailbox: MailboxConnection,
): 'receive-only' | 'authorization' | undefined => {
  if (mailbox.provider === 'imap' && mailbox.smtp === undefined) {
    return 'receive-only';
  }
  return mailbox.state === 'authorization' ? 'authorization' : undefined;
};

// The newest `mailto:` unsubscribe request `connection`, in its incarnation `epoch`, holds in
// `outbox` for the list with `identity`, or for `message` when the list has none, which the reader
// shows until it leaves the Outbox, across relaunches; an unknown one a confirmed retry answers no
// longer stands for it, though its mark may not hold yet, and one from before the connection was
// added again never does. A request confirmed for another message stands for one the list sent at
// `receivedAt` only within the list's 14 days, as a recorded request does, and not while that time
// is unknown, as does a request whose retried request was confirmed; one confirmed for `message`
// itself stands for it before a newer one for the list. `delivered` tells when a request was
// confirmed though storage does not hold that time yet.
export const pendingUnsubscribe = <
  E extends Pick<OutboxEntry, 'id' | 'draft' | 'unsubscribe' | 'epoch'>,
>(
  outbox: readonly E[],
  connection: string,
  {
    identity,
    message,
    epoch,
    receivedAt,
    delivered,
  }: Readonly<{
    identity?: string;
    message: string;
    epoch?: string;
    receivedAt?: number | undefined;
    delivered?: (id: string) => Readonly<{ at: number }> | undefined;
  }>,
) => {
  const sentAtOf = ({ id, unsubscribe }: E) =>
    unsubscribe?.sentAt ?? delivered?.(id)?.at;
  const answered = new Set(
    outbox.flatMap((each) =>
      sentAtOf(each) === undefined ? [] : (each.unsubscribe?.retries ?? []),
    ),
  );
  const held = Arr.reverse(outbox).filter((each) => {
    const { id, draft, unsubscribe, epoch: incarnation } = each;
    const sentAt =
      sentAtOf(each) ??
      (unsubscribe?.retries ?? [])
        .map((retried) => delivered?.(retried)?.at)
        .find((at) => at !== undefined);
    return (
      unsubscribe !== undefined &&
      unsubscribe.answered !== true &&
      !answered.has(id) &&
      (unsubscribe.message === message ||
        sentAt === undefined ||
        (receivedAt !== undefined &&
          receivedAt <= sentAt + unsubscribeOfferReturnsAfter)) &&
      draft.connection === connection &&
      (incarnation ?? 'legacy') === (epoch ?? 'legacy') &&
      (identity === undefined
        ? unsubscribe.identity === undefined && unsubscribe.message === message
        : unsubscribe.identity === identity)
    );
  });
  return (
    held.find(
      (each) =>
        each.unsubscribe?.message === message && sentAtOf(each) !== undefined,
    ) ?? held[0]
  );
};

// The message that offered a `mailto:` unsubscribe request, and the requests already made for it,
// which answer in place of another once one is confirmed; with `epoch`, the connection's
// incarnation it was confirmed for, which a connection added again since refuses.
type UnsubscribeSource = Readonly<{
  message: string;
  retrying?: readonly string[] | undefined;
  epoch?: string | undefined;
  // When the message arrived.
  receivedAt?: number | undefined;
}>;

// Where the Outbox keeps a confirmed unsubscribe request by the Product Account, Mail Profile,
// connection and message that offered it.
const messageKey = (
  account: string,
  {
    profile,
    connection,
    message,
  }: Readonly<{ profile: string; connection: string; message: string }>,
) => [account, profile, connection, message].join('\n');

// The unknown requests a retry of `held` tries again: those `held` tried again, also through a
// refused retry, and `held` itself when its delivery is unknown; none `unconfirmed` says was
// confirmed since, as one whose 14 days ended.
const retriesOf = (
  held: OutboxEntry | undefined,
  unconfirmed: (id: string) => boolean,
) => {
  const retries = [
    ...(held?.unsubscribe?.retries ?? []),
    ...(held?.state === 'unknown' || held?.state === 'failed' ? [held.id] : []),
  ].filter(unconfirmed);
  return retries.length === 0 ? {} : { retries };
};

// One paragraph per line of a `mailto:` body; a span never holds a line break or an image's
// character.
const paragraph = (line: string): Block => ({
  kind: 'paragraph',
  spans: line === '' ? [] : [{ text: line }],
});
const paragraphsOf = (text: string): SemanticDocument => {
  const [first = '', ...rest] = text
    .replaceAll(imageCharacter, '')
    .split(/\r\n?|\n/u);
  return [paragraph(first), ...rest.map(paragraph)];
};

// The recipient, subject and body of an unsubscribe request: a held request's again, so trying it
// again never sends another message's offer for the same list, else the offer's.
const requestOf = (
  held: Pick<Draft, 'to' | 'subject' | 'body'> | undefined,
  offer: Extract<UnsubscribeOffer, { kind: 'mailto' }>,
): Pick<Draft, 'to' | 'subject' | 'body'> =>
  held === undefined
    ? {
        to: [{ address: offer.address }],
        subject: offer.subject ?? '',
        body: paragraphsOf(offer.body ?? ''),
      }
    : { to: held.to, subject: held.subject, body: held.body };

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

// The largest message a provider takes; SMTP has no known limit, so it is held to Gmail's.
const limitOf = (provider: MailProvider | undefined) =>
  provider === 'microsoft-graph' ? graphDraftLimit : gmailMessageLimit;

// The message admitted for a Draft, or undefined when it is over its provider's limit. A Microsoft
// message too large for one Graph request keeps only its MIME without files, which becomes an
// Outlook draft that its files are attached to; its size stays the whole message's.
const messageOf = (draft: Draft, provider: MailProvider | undefined) => {
  const date = Date.now();
  const boundary = Math.random().toString(36).slice(2, 14);
  const options = {
    date,
    boundary,
    // Gmail assigns its Message-ID; SMTP and Microsoft keep ours for replies and Sent lookup.
    ...(provider === 'gmail'
      ? {}
      : {
          messageId: `${date.toString(36)}.${boundary}@${draft.from.split('@').at(-1) ?? ''}`,
        }),
  };
  const whole = outgoingMessage(draft, options);
  const drafted =
    provider === 'microsoft-graph' && whole.size > graphMessageLimit;
  const sent = drafted
    ? outgoingMessage(draft, { ...options, withoutFiles: true })
    : whole;
  if (
    whole.size > limitOf(provider) ||
    (drafted && sent.size > graphMessageLimit)
  ) {
    return undefined;
  }
  const thread = threadOf(draft);
  return {
    segments: sent.segments,
    size: whole.size,
    ...(thread === undefined ? {} : { threadId: thread }),
  };
};

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
  ...(entry.epoch === undefined ? {} : { epoch: entry.epoch }),
  ...(problem === undefined ? {} : { problem }),
  ...(entry.invitation === undefined ? {} : { invitation: entry.invitation }),
  ...(entry.unsubscribe === undefined
    ? {}
    : { unsubscribe: entry.unsubscribe }),
});

// Handed to Gmail without a recorded answer. Another store opening meanwhile marks the entry
// unknown; the store that handed it off still records the answer it got.
const awaitingOutcome = (state: OutboxEntry['state'] | undefined) =>
  state === 'sending' || state === 'unknown';

// A message admitted with an Undo Send Window waits it out; Send Now's, of 0, is queued at once.
const admittedState = (delay: number) =>
  delay > 0 ? ('waiting' as const) : ('queued' as const);

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
  requests,
}: Readonly<{
  drafts: Pick<
    Drafts,
    | 'getSnapshot'
    | 'getOutbox'
    | 'getSent'
    | 'admit'
    | 'enqueue'
    | 'deliver'
    | 'restore'
    | 'readAsset'
    | 'subscribe'
    | 'getDeliveryCleanup'
    | 'prepareDelivery'
    | 'completeDeliveryCleanup'
  >;
  mailboxes: Pick<Mailboxes, 'getConnections' | 'subscribe'>;
  registration: Pick<Registration, 'getSnapshot' | 'subscribe' | 'resume'>;
  claims: NativeDeliveryClaim | undefined;
  // Records each confirmed `mailto:` unsubscribe request for its Mail Profile.
  requests?: Pick<Unsubscribe, 'record'>;
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
  // A confirmed request survives retirement without retaining retired sends.
  const confirmedChecks = new WeakSet<CheckRequest>();
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
    for (const [id, request] of asked) {
      const entry = outbox.find((each) => each.id === id);
      // A pending caller retires its request after learning why the entry disappeared.
      if (
        request.owner !== ownerOf(registration) ||
        (entry === undefined
          ? request.check !== 'checking'
          : checkOf(entry) === 'idle')
      ) {
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
  const listedOf = (draft: Draft) =>
    mailboxesOf(registration.getSnapshot().snapshot).find(
      ({ id }) => id === draft.connection,
    );
  const providerOf = (draft: Draft) => listedOf(draft)?.provider;
  // The sending connection's incarnation; one listed before epochs is the legacy one.
  const epochOf = (draft: Draft) => listedOf(draft)?.epoch ?? 'legacy';
  // Both scheduling and processing use the same deadline, including a refused storage step.
  // The outcome storage refused to save for `entry`, also a confirmed unsubscribe request whose
  // record waited for storage before a relaunch.
  const unrecordedOf = (entry: OutboxEntry): SendOutcome | undefined =>
    unrecorded.get(entry.id) ??
    (entry.unsubscribe?.sentAt === undefined ? undefined : { kind: 'sent' });
  const dueAt = (entry: OutboxEntry) => {
    if (entry.state === 'waiting') {
      return Math.max(entry.sendAt, retryAt.get(entry.id) ?? 0);
    }
    return entry.state === 'queued' ||
      entry.state === 'filing' ||
      (awaitingOutcome(entry.state) && unrecordedOf(entry) !== undefined)
      ? (retryAt.get(entry.id) ?? 0)
      : Number.POSITIVE_INFINITY;
  };
  const claim = Effect.fnUntraced(
    function* (account: string, id: string) {
      const claimed = decodeClaimed(
        yield* Effect.tryPromise({
          try: async () => claims?.claimDraftDelivery(account, id),
          catch: (cause) => new ClaimFailure({ cause }),
        }),
      );
      return Option.isSome(claimed) && claimed.value.owner === account
        ? claimed.value.claimed
        : undefined;
    },
    Effect.catchTag('ClaimFailure', ({ cause }) =>
      (rejectionCode(cause) === 'unavailable'
        ? Effect.void
        : Effect.logError('Delivery claim failed:', rejectionDiagnostic(cause))
      ).pipe(Effect.as(undefined)),
    ),
  );
  // An Outbox step, applied and held by the Drafts store that owns the durable Outbox.
  const write = (
    id: string,
    change: Parameters<typeof drafts.deliver>[1],
  ): Effect.Effect<boolean> => Effect.promise(() => drafts.deliver(id, change));

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
  // A connection added again since Send is another incarnation, refused as a removed one.
  const handoffCheck = ({
    draft,
    epoch,
  }: OutboxEntry): DeliveryProblem | 'wait' | undefined =>
    epoch !== undefined && epoch !== epochOf(draft)
      ? 'mailbox'
      : (senderProblem(draft) ?? sentFolderCheck(draft));

  // Records the Invitation Response a message carries as sent in its IMAP mailbox. Resolves
  // 'offline' when it could not; nothing for any other message
  // or a mailbox that is gone, including one added again since Send.
  const answer = Effect.fnUntraced(function* ({
    draft,
    invitation,
    epoch,
  }: OutboxEntry) {
    const mailbox = connectionOf(draft.connection);
    if (
      invitation === undefined ||
      mailbox?.provider !== 'imap' ||
      (epoch !== undefined && epoch !== epochOf(draft))
    ) {
      return undefined;
    }
    const { summary: _title, ...revision } = invitation;
    const at = yield* Clock.currentTimeMillis;
    const recorded = yield* Effect.promise(() =>
      mailbox.inbox.recordResponse(revision, { kind: 'sent', ...revision, at }),
    );
    return recorded ? undefined : ('offline' as const);
  });

  // The unsubscribe requests confirmed this session, when and to whom, which the capped Sent
  // history may forget, by Outbox identifier and by the Product Account, Mail Profile, connection
  // and message that offered them.
  const confirmedRequests = new Map<string, { at: number; to?: string }>();
  // The requests that answer with a confirmed request they tried again, never sent themselves.
  const supersededRequests = new Set<string>();
  const confirmedMessages = new Map<string, { at: number; to?: string }>();
  // When the message `id` was confirmed as sent, and to whom for an unsubscribe request confirmed
  // this session or still waiting for its record; otherwise only among the latest sends.
  const deliveredOf = (
    id: string,
  ): Readonly<{ at: number; to?: string }> | undefined => {
    const known = confirmedRequests.get(id);
    const held = entryOf(id);
    const kept = held?.unsubscribe?.sentAt;
    const to = held?.draft.to[0]?.address;
    const at = drafts.getSent().find((sent) => sent.id === id)?.sentAt;
    if (known !== undefined || kept !== undefined) {
      return known ?? { at: kept ?? 0, ...(to === undefined ? {} : { to }) };
    }
    return at === undefined ? undefined : { at };
  };
  // The first of the unknown requests an unsubscribe request tries again that was confirmed since,
  // with its identifier.
  const retriedOf = (entry: OutboxEntry | undefined) =>
    (entry?.unsubscribe?.retries ?? [])
      .map((id) => ({ id, delivered: deliveredOf(id) }))
      .find(({ delivered }) => delivered !== undefined);
  // Takes the unsubscribe request `id` out of the Outbox unsent once an unknown request it tries
  // again was confirmed, answering as that one did. Resolves whether it did.
  const superseded = Effect.fnUntraced(function* (id: string) {
    const retried = retriedOf(entryOf(id));
    if (retried?.delivered === undefined) {
      return false;
    }
    confirmedRequests.set(id, retried.delivered);
    supersededRequests.add(id);
    yield* Effect.promise(() => drafts.restore(id, 'queued'));
    return true;
  });
  // Whether the unsubscribe request `id` a retry tried again still stands for its list.
  const unanswered = (id: string) => {
    const request = entryOf(id)?.unsubscribe;
    return request !== undefined && request.answered !== true;
  };
  // Takes the refused request `id` a confirmed retry tried again out of the Outbox, or marks the
  // unknown one answered.
  const answerFor = (id: string) =>
    entryOf(id)?.state === 'failed'
      ? Effect.promise(() => drafts.restore(id, 'failed'))
      : write(id, (each) =>
          each.unsubscribe === undefined || each.unsubscribe.answered === true
            ? undefined
            : { ...each, unsubscribe: { ...each.unsubscribe, answered: true } },
        );
  // Whether the unsubscribe request `entry` leaves without its own record: true once it was
  // answered, or a retry confirmed sent for it waits in the Outbox, answering for it though its mark
  // may not hold yet; 'waiting' while storage refuses that retry's confirmed time.
  const answeredOf = ({ id, unsubscribe: request }: OutboxEntry) => {
    const retry = drafts
      .getOutbox()
      .find(
        ({ id: each, unsubscribe }) =>
          unsubscribe?.retries?.includes(id) === true &&
          (unsubscribe.sentAt !== undefined ||
            (confirmedRequests.has(each) && !supersededRequests.has(each))),
      );
    if (
      request?.answered === true ||
      retry?.unsubscribe?.sentAt !== undefined
    ) {
      return true;
    }
    return retry === undefined ? false : ('waiting' as const);
  };
  // A confirmed unsubscribe request is recorded before it leaves the Outbox, so a relaunch cannot
  // lose it. Resolves false while storage refuses the record, so the confirmed outcome is saved
  // again later rather than retiring the entry without it.
  const recordRequest = Effect.fnUntraced(function* (
    entry: OutboxEntry | undefined,
  ) {
    const request = entry?.unsubscribe;
    if (entry === undefined || request === undefined) {
      return true;
    }
    const { account, profile, list, identity, message } = request;
    // An unknown request found sent after its retry answered for the list leaves without
    // restarting the list's 14 days; while storage refuses the retry's confirmed time, it waits.
    const answered = answeredOf(entry);
    if (answered !== false) {
      return answered === true;
    }
    // A record saved again keeps the time the provider first confirmed the request.
    const sentAt =
      request.sentAt ??
      confirmedRequests.get(entry.id)?.at ??
      (yield* Clock.currentTimeMillis);
    const to = entry.draft.to[0]?.address;
    const sent = { at: sentAt, ...(to === undefined ? {} : { to }) };
    const { connection } = entry.draft;
    confirmedRequests.set(entry.id, sent);
    confirmedMessages.set(
      messageKey(account, { profile, connection, message }),
      sent,
    );
    publish();
    // Kept with the entry first, so neither a refused step nor a relaunch loses when it was
    // confirmed, nor files an IMAP request's copy again; while storage refuses that, it waits.
    if (
      request.sentAt === undefined &&
      !(yield* write(entry.id, (each) =>
        each.unsubscribe === undefined
          ? undefined
          : {
              ...each,
              unsubscribe: {
                ...each.unsubscribe,
                sentAt: each.unsubscribe.sentAt ?? sentAt,
              },
            },
      ))
    ) {
      return false;
    }
    // The unknown requests it tried again no longer stand for the list, though they stay for
    // Check Again, and a refused one still held leaves. It stays in the Outbox until each one is
    // marked or gone.
    for (const id of (request.retries ?? []).filter(unanswered)) {
      yield* answerFor(id);
    }
    const recorded =
      !(request.retries ?? []).some(unanswered) &&
      (identity === undefined ||
        requests === undefined ||
        (yield* Effect.promise(() =>
          requests.record(account, {
            profile,
            identity,
            list,
            sentAt,
            ...(to === undefined ? {} : { to }),
          }),
        )));
    return recorded;
  });

  const record = Effect.fnUntraced(function* (
    id: string,
    outcome: SendOutcome,
  ) {
    if (outcome.kind === 'accepted') {
      return yield* write(id, (entry) =>
        awaitingOutcome(entry.state) ? withState(entry, 'filing') : undefined,
      );
    }
    if (outcome.kind === 'sent') {
      // The response stays awaiting its outcome until its mailbox holds it.
      const awaiting = entryOf(id);
      if (awaiting !== undefined && (yield* answer(awaiting)) !== undefined) {
        return false;
      }
      if (!(yield* recordRequest(awaiting))) {
        return false;
      }
      // Read on each compare-and-set attempt, so a retried step keeps a current time.
      const clock = yield* Clock.Clock;
      return yield* write(id, (entry) =>
        awaitingOutcome(entry.state)
          ? {
              id,
              ...(outcome.message === undefined
                ? {}
                : { message: outcome.message }),
              sentAt: clock.currentTimeMillisUnsafe(),
            }
          : undefined,
      );
    }
    return yield* write(id, (entry) => {
      if (!awaitingOutcome(entry.state)) {
        return undefined;
      }
      return outcome.kind === 'unknown'
        ? withState(entry, 'unknown')
        : withState(entry, outcome.kind, outcome.problem);
    });
  });

  // Resolves true only once storage holds this device's confirmed claim on a queued message.
  const holdClaim = Effect.fnUntraced(function* (
    account: string,
    entry: OutboxEntry,
    current: () => boolean,
  ) {
    const { id } = entry;
    if (entry.claim === 'held') {
      return true;
    }
    // Recorded first: a Draft whose claim may exist never returns under the same identifier.
    if (
      entry.claim === undefined &&
      !(yield* write(
        id,
        step('queued', (each) => ({ ...each, claim: 'requested' })),
      ))
    ) {
      return false;
    }
    if (!current()) {
      return false;
    }
    const claimed = yield* claim(account, id);
    if (claimed === undefined) {
      yield* write(
        id,
        step('queued', (each) => withState(each, 'queued', 'offline')),
      );
      return false;
    }
    if (!claimed) {
      yield* write(
        id,
        step('queued', (each) => withState(each, 'failed', 'claimed')),
      );
      return false;
    }
    return yield* write(
      id,
      step('queued', (each) => ({ ...each, claim: 'held' })),
    );
  });

  // Records an outcome, keeping it to save again when storage refuses, so a message Gmail never
  // received does not stay 'sending' and read as unknown after a relaunch.
  const keep = Effect.fnUntraced(function* (id: string, outcome: SendOutcome) {
    if (yield* record(id, outcome)) {
      unrecorded.delete(id);
      const request = asked.get(id);
      if (outcome.kind === 'sent' && request !== undefined) {
        confirmedChecks.add(request);
      }
    } else if (!disposed && awaitingOutcome(entryOf(id)?.state)) {
      unrecorded.set(id, outcome);
    }
  });

  // Ends a Check Again once its lookup finishes, unless another ask replaced it meanwhile.
  const settle = (id: string, request: CheckRequest) => {
    if (asked.get(id) !== request) {
      return;
    }
    const current = entryOf(id);
    // Removal, another Send of the Draft or another Product Account meanwhile ends it quietly.
    if (current !== undefined && checkOf(current) === 'checking') {
      asked.set(id, { ...request, check: 'unconfirmed' });
    } else {
      asked.delete(id);
    }
    publish();
  };
  // Whether this ask saved the Sent outcome, within the execution and account it began in.
  const confirmed = (id: string, request: CheckRequest, started: number) =>
    confirmedChecks.has(request) &&
    started === execution &&
    request.owner === ownerOf(registration) &&
    entryOf(id) === undefined;

  // Saves an outcome storage refused earlier. Resolves whether one was waiting.
  const resave = Effect.fnUntraced(function* (entry: OutboxEntry) {
    const outcome = unrecordedOf(entry);
    if (outcome === undefined) {
      return false;
    }
    unrecorded.delete(entry.id);
    // A confirmed request still filing its Sent copy files it again, which finds the copy.
    if (!awaitingOutcome(entry.state)) {
      return false;
    }
    yield* keep(entry.id, outcome);
    return true;
  });

  // Invokes the current provider with the frozen message and its original envelope, or sends the
  // Outlook draft it was kept as.
  const submit = async (
    entry: OutboxEntry,
    draft: string | undefined,
  ): Promise<SendOutcome> => {
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
      : mailbox.inbox.send(
          draft === undefined ? entry.message : { ...entry.message, draft },
        );
  };

  // A Microsoft message too large for one Graph request first becomes an Outlook draft with its
  // files, before its durable handoff. Nothing is delivered yet, so a refusal or an interruption
  // only leaves the message queued, and the next attempt replaces the draft it left. Resolves the
  // draft's ID, undefined for any other message, or false when the message waits or failed.
  const prepare = Effect.fnUntraced(function* (
    id: string,
    current: () => boolean,
  ) {
    const entry = entryOf(id);
    const mailbox = entry && connectionOf(entry.draft.connection);
    if (
      entry === undefined ||
      mailbox?.provider !== 'microsoft-graph' ||
      entry.message.size <= graphMessageLimit
    ) {
      return undefined;
    }
    const prepared = yield* Effect.promise(() =>
      mailbox.inbox.prepare(entry.message, draftFiles(entry.draft)),
    );
    if (prepared.kind === 'prepared') {
      return current() && prepared.draft;
    }
    yield* write(
      id,
      step('queued', (each) =>
        withState(each, prepared.kind, prepared.problem),
      ),
    );
    return false;
  });

  // Hands a claimed message to Gmail once, after its durable handoff, or the Outlook draft it was
  // kept as.
  const handOff = Effect.fnUntraced(function* (
    id: string,
    current: () => boolean,
    draft: string | undefined,
  ) {
    const account = ownerOf(registration);
    // An unsubscribe request never follows the unknown request it tries again once that one was
    // confirmed; it leaves the Outbox, answering as that one did.
    if (yield* superseded(id)) {
      return;
    }
    // Storage holds 'sending' before Gmail sees the message, so an interruption reads as unknown.
    const handed = yield* write(id, (each) =>
      current() &&
      each.state === 'queued' &&
      each.claim === 'held' &&
      retriedOf(each) === undefined
        ? withState(each, 'sending')
        : undefined,
    );
    if (!handed) {
      yield* superseded(id);
      return;
    }
    // No provider request started. Keep the held claim retryable when execution ended mid-write.
    if (!current()) {
      if (account === ownerOf(registration)) {
        yield* keep(id, { kind: 'queued', problem: 'offline' });
      }
      return;
    }
    const sending = entryOf(id);
    if (sending === undefined) {
      yield* keep(id, { kind: 'queued', problem: 'offline' });
      return;
    }
    // Claim and storage awaited meanwhile; recheck before invoking the current Inbox.
    const problem = handoffCheck(sending);
    if (problem !== undefined) {
      yield* keep(id, {
        kind: problem === 'wait' ? 'queued' : 'failed',
        problem: problem === 'wait' ? 'offline' : problem,
      });
      return;
    }
    // Storage was awaited meanwhile, so the unknown request a retry tries again may be confirmed.
    if (retriedOf(sending) !== undefined) {
      yield* keep(id, { kind: 'queued', problem: 'offline' });
      yield* superseded(id);
      return;
    }
    const outcome = yield* Effect.promise(() => submit(sending, draft));
    if (account === ownerOf(registration)) {
      yield* keep(id, outcome);
    }
  });

  // Keeps a large Microsoft message as an Outlook draft first; only a prepared one is handed off.
  const deliver = Effect.fnUntraced(function* (
    id: string,
    current: () => boolean,
  ) {
    const entry = entryOf(id);
    const messageId = entry && messageIdOf(entry.message.segments);
    if (
      entry !== undefined &&
      providerOf(entry.draft) === 'microsoft-graph' &&
      entry.message.size > graphMessageLimit
    ) {
      yield* Effect.gen(function* () {
        // This CAS also refreshes a stale local store before any provider preparation.
        if (
          messageId === undefined ||
          !(yield* Effect.promise(() =>
            drafts.prepareDelivery(id, messageId),
          )) ||
          !current() ||
          entryOf(id)?.state !== 'queued'
        ) {
          return;
        }
        const draft = yield* prepare(id, current);
        if (draft !== false) {
          yield* handOff(id, current, draft);
        }
      }).pipe(microsoftDelivery.withPermit);
      return;
    }
    yield* handOff(id, current, undefined);
  });

  // Delivery owns opening its sender even when no Inbox view has loaded it.
  const openSender = async (draft: Pick<Draft, 'connection'>) => {
    const cached = mailboxesOf(registration.getSnapshot().snapshot).some(
      (mailbox) =>
        mailbox.id === draft.connection && mailbox.state === 'cached',
    );
    if (cached) {
      try {
        await registration.resume();
      } catch (error) {
        await runLogged(
          Effect.logError(
            'Mailbox verification failed:',
            rejectionDiagnostic(error),
          ),
        );
        return false;
      }
      if (
        mailboxesOf(registration.getSnapshot().snapshot).some(
          (mailbox) =>
            mailbox.id === draft.connection && mailbox.state === 'cached',
        )
      ) {
        return false;
      }
    }
    const mailbox = connectionOf(draft.connection);
    if (mailbox !== undefined && (cached || mailbox.state.kind !== 'ready')) {
      await mailbox.inbox.load();
    }
    return true;
  };

  // Files an accepted message's Sent copy, and records it as sent once the copy is there. A
  // connection removed meanwhile has nowhere to keep it, so the message is recorded as sent; one
  // waiting for its password keeps the copy waiting.
  const file = Effect.fnUntraced(function* (
    entry: OutboxEntry,
    current: () => boolean,
  ) {
    // A confirmed request whose record storage refused filed its copy already, which this session
    // may know before storage does; filing again could put back a copy the person moved or deleted
    // since, so only its record is saved again, without opening its mailbox.
    const filed =
      entry.unsubscribe?.sentAt !== undefined ||
      confirmedRequests.has(entry.id);
    if (
      (!filed && !(yield* Effect.promise(() => openSender(entry.draft)))) ||
      !current()
    ) {
      return;
    }
    const mailbox = connectionOf(entry.draft.connection);
    const messageId = messageIdOf(entry.message.segments);
    const sending = sendingStateOf(
      entry.draft,
      mailboxesOf(registration.getSnapshot().snapshot),
    );
    let problem: DeliveryProblem | undefined = 'offline';
    if (sending === 'removed' || filed) {
      problem = undefined;
    } else if (sending === 'password') {
      problem = 'authorization';
    } else if (mailbox?.provider === 'imap' && messageId !== undefined) {
      // An accepted response leaves the Outbox only once its mailbox records it.
      problem =
        (yield* Effect.promise(() =>
          mailbox.inbox.fileSent(entry.message, messageId),
        )) ?? (yield* answer(entry));
    }
    if (
      problem === undefined &&
      !(yield* recordRequest(entryOf(entry.id) ?? entry))
    ) {
      problem = 'offline';
    }
    const clock = yield* Clock.Clock;
    yield* write(
      entry.id,
      step('filing', (each) => {
        if (problem === undefined) {
          return { id: each.id, sentAt: clock.currentTimeMillisUnsafe() };
        }
        return problem === each.problem
          ? undefined
          : withState(each, 'filing', problem);
      }),
    );
  });

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
    const outcome = await mailbox.inbox.findSent(
      boundary,
      messageIdOf(entry.message.segments),
    );
    if (outcome === undefined) {
      // The mailbox closed or changed meanwhile; it is checked again once it is ready.
      queuedChecks.delete(id);
    } else if (outcome.kind === 'sent') {
      await runLogged(keep(id, outcome));
    }
  };

  // Ends a message's Undo Send Window once it has passed. Resolves false when storage refused that.
  const release = Effect.fnUntraced(function* (entry: OutboxEntry) {
    return (
      entry.state !== 'waiting' ||
      (yield* Clock.currentTimeMillis) < entry.sendAt ||
      (yield* write(
        entry.id,
        step('waiting', (each) => withState(each, 'queued')),
      ))
    );
  });

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
  const verified = async (
    draft: Draft,
    report: ((check: SendCheck) => void) | undefined,
  ) => {
    const complete = assetsOf(draft).filter(
      (asset) => asset.state === 'complete',
    );
    let check: SendCheck = new Map(
      complete.map((asset) => [asset.id, undefined]),
    );
    report?.(check);
    for (const asset of complete) {
      const read = await drafts.readAsset(asset, { preview: false });
      check = new Map(check).set(asset.id, read.kind);
      report?.(check);
      if (read.kind !== 'verified') {
        return false;
      }
    }
    return true;
  };

  // Claims a queued message and hands it off; a message SMTP accepted files its Sent copy at once.
  const sendQueued = Effect.fnUntraced(function* (
    account: string,
    entry: OutboxEntry,
    current: () => boolean,
  ) {
    const opened = yield* Effect.promise(() => openSender(entry.draft));
    if (!current()) {
      return;
    }
    if (!opened) {
      yield* write(
        entry.id,
        step('queued', (each) =>
          current() ? withState(each, 'queued', 'offline') : undefined,
        ),
      );
      return;
    }
    const check = handoffCheck(entry);
    if (check === 'wait') {
      return;
    }
    if (check !== undefined) {
      yield* write(
        entry.id,
        step('queued', (each) => withState(each, 'failed', check)),
      );
      return;
    }
    if (yield* holdClaim(account, entry, current)) {
      yield* deliver(entry.id, current);
      const accepted = entryOf(entry.id);
      if (current() && accepted?.state === 'filing') {
        yield* file(accepted, current);
      }
    }
  });

  // Advances one message as far as it can go now, as one Effect program over the Drafts store and
  // the providers; the persisted state decides what remains due.
  const advance = Effect.fn('Outbox.advance')(function* (id: string) {
    const account = ownerOf(registration);
    const waiting = entryOf(id);
    const started = execution;
    const current = () => executing(started, account);
    if (account === undefined || waiting === undefined) {
      return;
    }
    if (yield* resave(waiting)) {
      return;
    }
    if (!(yield* release(waiting)) || !current()) {
      return;
    }
    const entry = entryOf(id);
    // oxlint-disable-next-line typescript/switch-exhaustiveness-check -- Other durable states never permit automatic delivery.
    switch (entry?.state) {
      case 'filing': {
        yield* file(entry, current);
        break;
      }
      case 'queued': {
        yield* sendQueued(account, entry, current);
        break;
      }
      default: {
        break;
      }
    }
  });

  // Runs `due` when a message is next due: the end of an Undo Send Window, a retry or a pending
  // cleanup. The wait sleeps on Effect's Clock until that deadline; replanning, pausing and
  // disposing abort it, so a wake planned before a pause never runs after the Outbox resumes.
  const plan = (due: () => void) => {
    timer?.abort();
    timer = undefined;
    if (!running()) {
      return;
    }
    let next = Number.POSITIVE_INFINITY;
    for (const entry of drafts.getOutbox()) {
      next = Math.min(next, dueAt(entry));
    }
    for (const { id } of drafts.getDeliveryCleanup()) {
      next = Math.min(next, retryAt.get(id) ?? 0);
    }
    if (Number.isFinite(next)) {
      const pending = new AbortController();
      timer = pending;
      const wait = async () => {
        try {
          await runLogged(
            Effect.gen(function* () {
              const now = yield* Clock.currentTimeMillis;
              yield* Effect.sleep(Math.max(0, next - now));
            }),
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
  const checkSent = async (id: string, deferred: boolean) => {
    if (deferred) {
      // No lookup ran; retire its request and let a later opportunity retry.
      checks.delete(id);
      queuedChecks.delete(id);
      asked.delete(id);
      publish();
      return;
    }
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
  const cleanPrepared = async () => {
    for (const pending of drafts.getDeliveryCleanup()) {
      if (
        running() &&
        ownerOf(registration) !== undefined &&
        (retryAt.get(pending.id) ?? 0) <= Date.now()
      ) {
        const started = execution;
        const account = ownerOf(registration);
        await runLogged(
          Effect.promise(async () => {
            if (
              !(await openSender(pending)) ||
              !executing(started, account) ||
              !drafts.getDeliveryCleanup().some(({ id }) => id === pending.id)
            ) {
              return;
            }
            const mailbox = connectionOf(pending.connection);
            if (
              mailbox?.provider === 'microsoft-graph' &&
              mailbox.address === pending.address &&
              (await mailbox.inbox.discardPrepared(pending.messageId)) &&
              executing(started, account)
            ) {
              await drafts.completeDeliveryCleanup(pending.id);
            }
          }).pipe(microsoftDelivery.withPermit),
        );
        if (executing(started, account)) {
          retryAt.set(pending.id, Date.now() + retryDelay);
        }
      }
    }
  };
  const pass = async () => {
    await cleanPrepared();
    const deferred = new Set<string>();
    // Recovery also owns opening its mailbox after a launch with no Inbox.
    for (const entry of drafts.getOutbox()) {
      if (
        running() &&
        entry.state === 'unknown' &&
        !(await openSender(entry.draft))
      ) {
        deferred.add(entry.id);
      }
    }
    checkUnknown(false);
    for (const id of checks) {
      await checkSent(id, deferred.has(id));
    }
    const now = Date.now();
    for (const entry of drafts.getOutbox()) {
      const { id } = entry;
      if (running() && dueAt(entry) <= now) {
        const started = execution;
        retryAt.delete(id);
        await runLogged(advance(id));
        retry(id, started);
      }
    }
    await cleanPrepared();
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

  // The answer a held unsubscribe request gives in place of another: itself while it may still be
  // sent, else the first of it and the unknown requests it tries again confirmed meanwhile, and
  // for another message than `source` only within the 14 days before the list sent it, at
  // `receivedAt`. The requests the reader showed for the message, `retrying`, answer too once
  // confirmed, as when Check Again confirmed the held one before its retry was admitted.
  const standingOf = (
    held: OutboxEntry | undefined,
    retrying: readonly string[],
    { message: source, receivedAt }: UnsubscribeSource,
  ): MailtoUnsubscribe | undefined => {
    if (
      held !== undefined &&
      held.state !== 'failed' &&
      held.state !== 'unknown'
    ) {
      return { kind: 'waiting', id: held.id };
    }
    const stands = (id: string) => {
      const delivered = deliveredOf(id);
      return (
        delivered !== undefined &&
        (held?.unsubscribe?.message === source ||
          (receivedAt !== undefined &&
            receivedAt <= delivered.at + unsubscribeOfferReturnsAfter))
      );
    };
    const sent =
      retrying.find((id) => deliveredOf(id) !== undefined) ??
      (held === undefined
        ? undefined
        : [held.id, ...(held.unsubscribe?.retries ?? [])].find(stands));
    return sent === undefined ? undefined : { kind: 'waiting', id: sent };
  };
  // One unsubscribe admission at a time, so two confirmations cannot both admit a request.
  const admissions = Semaphore.makeUnsafe(1);
  const admitUnsubscribe = async (
    connection: string,
    offer: Extract<UnsubscribeOffer, { kind: 'mailto' }>,
    from: UnsubscribeSource,
  ): Promise<MailtoUnsubscribe> => {
    const { message: source, retrying = [], epoch, receivedAt } = from;
    const mailbox = mailboxesOf(registration.getSnapshot().snapshot).find(
      ({ id }) => id === connection,
    );
    if (epoch !== undefined && (mailbox?.epoch ?? 'legacy') !== epoch) {
      return { kind: 'failed' };
    }
    const held = pendingUnsubscribe(drafts.getOutbox(), connection, {
      ...offer,
      message: source,
      receivedAt,
      delivered: deliveredOf,
      ...(mailbox?.epoch === undefined ? {} : { epoch: mailbox.epoch }),
    });
    const standing = standingOf(held, retrying, from);
    if (standing !== undefined) {
      return standing;
    }
    const account = ownerOf(registration);
    if (mailbox === undefined || account === undefined) {
      return { kind: 'failed' };
    }
    const refused = unsendable(mailbox);
    if (refused !== undefined) {
      return { kind: refused };
    }
    const at = Date.now();
    const draft: Draft = {
      id: `${at.toString(36)}.${Math.random().toString(36).slice(2, 14)}`,
      connection,
      from: mailbox.address,
      cc: [],
      bcc: [],
      ...requestOf(held?.draft, offer),
      updatedAt: at,
    };
    const message =
      refusalOf(draft) === undefined
        ? messageOf(draft, mailbox.provider)
        : undefined;
    const admitted =
      message !== undefined &&
      (await drafts.enqueue({
        id: draft.id,
        draft,
        message,
        sendAt: at + undoSendWindow,
        state: 'waiting',
        epoch: epochOf(draft),
        unsubscribe: {
          account,
          profile: mailbox.profile,
          list: offer.list,
          message: source,
          ...(offer.identity === undefined ? {} : { identity: offer.identity }),
          ...retriesOf(held, (id) => deliveredOf(id) === undefined),
        },
      }));
    if (!admitted) {
      return { kind: 'failed' };
    }
    // A refused request leaves once its retry is admitted; an unknown one stays, since it may
    // have been sent.
    if (held?.state === 'failed') {
      retryAt.delete(held.id);
      await drafts.restore(held.id, 'failed');
    }
    return { kind: 'waiting', id: draft.id };
  };

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
    // Why Send would refuse the Draft before reading its files, so the composer can say so first.
    refusal: refusalOf,
    // Admits the Draft `expected` shows to the Outbox, to send once its Undo Send Window of `delay`
    // milliseconds ends; Send Now's is 0. Resolves why it was refused, or undefined once admitted.
    // `report` follows the file check.
    send: async (
      expected: () => Draft,
      report?: (check: SendCheck) => void,
      delay = undoSendWindow,
    ): Promise<SendRefusal | undefined> => {
      const draft = expected();
      const epoch = epochOf(draft);
      const refusal = refusalOf(draft);
      if (refusal !== undefined) {
        return refusal;
      }
      if (!(await verified(draft, report))) {
        return 'assets';
      }
      // The sending mailbox can change while files are read; it is checked again before admission.
      const late = refusalOf(expected());
      if (late !== undefined) {
        return late;
      }
      const message = messageOf(draft, providerOf(draft));
      if (message === undefined) {
        return 'too-large';
      }
      const sendAt = Date.now() + delay;
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
          state: admittedState(delay),
          epoch,
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
    // Admits an Invitation Response, which is never a Draft, from `draft`'s connection to the
    // Outbox, to send once the Undo Send Window ends. Resolves why it was refused, or undefined once
    // admitted.
    respond: async ({
      draft,
      message,
      invitation,
    }: Readonly<{
      draft: Draft;
      message: OutboxEntry['message'];
      invitation: InvitationAnswer;
    }>): Promise<SendRefusal | undefined> => {
      const refusal = refusalOf(draft);
      if (refusal !== undefined) {
        return refusal;
      }
      return (await drafts.enqueue({
        id: draft.id,
        draft,
        message,
        sendAt: Date.now() + undoSendWindow,
        state: 'waiting',
        epoch: epochOf(draft),
        invitation,
      }))
        ? undefined
        : 'storage';
    },
    // Admits the confirmed `mailto:` unsubscribe request `offer` makes, an ordinary message that is
    // never a Draft, from `connection`, the Mailbox Connection that received it, to the offer's
    // one address with only its subject and body. It waits out the Undo Send Window like any
    // message; Undo only takes it out of the Outbox. Admissions run one at a time, and a request
    // the Outbox holds for the same connection and list, or for the same message without a list
    // identity, answers in place of another, one confirmed for another message only within the
    // list's 14 days; only a refused or unknown one may be tried again, and
    // trying it again sends that same request, taking a refused one out once it is admitted. An
    // unknown one confirmed before its retry is handed off answers in place of the retry.
    unsubscribe: (
      connection: string,
      offer: Extract<UnsubscribeOffer, { kind: 'mailto' }>,
      from: UnsubscribeSource,
    ): Promise<MailtoUnsubscribe> =>
      Effect.runPromise(
        admissions.withPermit(
          Effect.promise(() => admitUnsubscribe(connection, offer, from)),
        ),
      ),
    // When the message `id` left the Outbox confirmed as sent, and to whom for an unsubscribe
    // request confirmed this session; otherwise only among the latest sends.
    delivered: deliveredOf,
    // When this session confirmed an unsubscribe request `connection` sent in `profile` for
    // `message`, the message that offered it, and to whom; the reader may never have seen its
    // Outbox identifier.
    emailedUnsubscribe: (
      connection: string,
      { profile, message }: Readonly<{ profile: string; message: string }>,
    ) => {
      const account = ownerOf(registration);
      return account === undefined
        ? undefined
        : confirmedMessages.get(
            messageKey(account, { profile, connection, message }),
          );
    },
    // Returns a message to the Drafts, as Undo, after a refusal, or when the person chooses to
    // edit one whose delivery is unknown; only while it is `only` when given. An Invitation
    // Response or an unsubscribe request only leaves the Outbox. Resolves the Draft's identifier,
    // or false when it can no longer return.
    undo: async (id: string, only?: OutboxEntry['state']) => {
      retryAt.delete(id);
      const restored = await drafts.restore(id, only);
      if (restored !== false && drafts.getDeliveryCleanup().length > 0) {
        void process();
      }
      return restored;
    },
    // Looks for an unknown message in Gmail's Sent mailbox now, publishing 'checking' at once and
    // 'unconfirmed' when it stays unknown after a lookup, or idle when preparation deferred it.
    // Resolves true only for the request owning the saved Sent outcome, once across overlapping asks.
    check: async (id: string) => {
      const started = execution;
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
      if (request === undefined) {
        return false;
      }
      settle(id, request);
      return confirmed(id, request, started);
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
