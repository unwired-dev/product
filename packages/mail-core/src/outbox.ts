import * as Effect from 'effect/Effect';
import * as Option from 'effect/Option';
import * as Schedule from 'effect/Schedule';
import * as Schema from 'effect/Schema';

import type { DeliveryProblem, Draft, OutboxEntry } from './draft-model.ts';
import type { Drafts } from './drafts.ts';
import type { SendOutcome } from './gmail-inbox.ts';
import type { Mailboxes } from './mailboxes.ts';
import type { Registration } from './registration.ts';

import {
  rejectionCode,
  rejectionDiagnostic,
  runLogged,
} from './diagnostics.ts';
import { assetsOf } from './draft-model.ts';
import { sendingStateOf, threadOf, unsendableAssets } from './drafts.ts';
import { gmailMessageLimit, outgoingMessage } from './outgoing-message.ts';
import { canOpenInbox, mailboxesOf } from './registration.ts';

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
// cannot send, files not complete and verified on this device, a message over Gmail's limit,
// another editor's change to the Draft, or storage refusing the write.
export type SendRefusal =
  | 'recipients'
  | 'entries'
  | 'sender'
  | 'assets'
  | 'too-large'
  | 'changed'
  | 'storage';

const ownerOf = (registration: Pick<Registration, 'getSnapshot'>) => {
  const { snapshot } = registration.getSnapshot();
  return canOpenInbox(snapshot) && snapshot.kind !== 'signed-out'
    ? snapshot.productAccountId
    : undefined;
};

const messageOf = (draft: Draft) => {
  const { segments, size } = outgoingMessage(draft, {
    date: Date.now(),
    boundary: Math.random().toString(36).slice(2, 14),
  });
  const thread = threadOf(draft);
  return {
    segments,
    size,
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
  ...(problem === undefined ? {} : { problem }),
});

// One Outbox step from state `from`; any other state refuses it.
const step =
  <T>(from: OutboxEntry['state'], next: (entry: OutboxEntry) => T) =>
  (entry: OutboxEntry) =>
    entry.state === from ? next(entry) : undefined;

// Sends Drafts admitted to the Outbox on this device, their Delivery Owner. After the Undo Send
// Window, a message is claimed through Convex so no other Trusted Device can send the same Draft,
// marked as handed to Gmail in storage, and only then sent once. A message that reached neither
// Convex nor Gmail is tried again later; one handed to Gmail without a confirmed answer is never
// sent again automatically.
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
  mailboxes: Pick<Mailboxes, 'getSnapshot'>;
  registration: Pick<Registration, 'getSnapshot'>;
  claims: NativeDeliveryClaim | undefined;
}>) {
  // When each pending message may try again; one without an entry uses its Send deadline.
  const retryAt = new Map<string, number>();
  let timer: AbortController | undefined = undefined;
  let disposed = false;

  const entryOf = (id: string) =>
    drafts.getOutbox().find((each) => each.id === id);
  // Both scheduling and processing use the same deadline, including a refused storage step.
  const dueAt = (entry: OutboxEntry) => {
    if (entry.state === 'waiting') {
      return Math.max(entry.sendAt, retryAt.get(entry.id) ?? 0);
    }
    return entry.state === 'queued'
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
    return sending === 'authorization' ? 'authorization' : 'mailbox';
  };

  const record = (id: string, outcome: SendOutcome) => {
    if (outcome.kind === 'sent') {
      return drafts.deliver(
        id,
        step('sending', () => ({
          id,
          ...(outcome.message === undefined
            ? {}
            : { message: outcome.message }),
          sentAt: Date.now(),
        })),
      );
    }
    return drafts.deliver(
      id,
      step('sending', (entry) =>
        outcome.kind === 'unknown'
          ? withState(entry, 'unknown')
          : withState(entry, outcome.kind, outcome.problem),
      ),
    );
  };

  // Resolves true only once storage holds this device's confirmed claim on a queued message.
  const holdClaim = async (account: string, entry: OutboxEntry) => {
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

  // Hands a claimed message to Gmail once, after its durable handoff.
  const handOff = async (id: string) => {
    // Storage holds 'sending' before Gmail sees the message, so an interruption reads as unknown.
    const handed = await drafts.deliver(id, (each) =>
      each.state === 'queued' && each.claim === 'held'
        ? withState(each, 'sending')
        : undefined,
    );
    if (!handed) {
      return;
    }
    const sending = entryOf(id);
    const inbox = mailboxes
      .getSnapshot()
      .find((mailbox) => mailbox.id === sending?.draft.connection)?.inbox;
    const outcome: SendOutcome =
      sending === undefined || inbox === undefined
        ? { kind: 'queued', problem: 'offline' }
        : await inbox.send(sending.message);
    await record(id, outcome);
  };

  // Advances one message as far as it can go now; the persisted state decides what remains due.
  const advance = async (id: string) => {
    const account = ownerOf(registration);
    const waiting = entryOf(id);
    if (account === undefined || waiting === undefined) {
      return;
    }
    if (
      waiting.state === 'waiting' &&
      Date.now() >= waiting.sendAt &&
      !(await drafts.deliver(
        id,
        step('waiting', (each) => withState(each, 'queued')),
      ))
    ) {
      return;
    }
    const entry = entryOf(id);
    if (entry?.state !== 'queued') {
      return;
    }
    const problem = senderProblem(entry.draft);
    if (problem !== undefined) {
      await drafts.deliver(
        id,
        step('queued', (each) => withState(each, 'failed', problem)),
      );
      return;
    }
    if (await holdClaim(account, entry)) {
      await handOff(id);
    }
  };

  // Runs `due` when a message is next due: the end of an Undo Send Window or a retry.
  const plan = (due: () => void) => {
    timer?.abort();
    timer = undefined;
    if (disposed) {
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
          if (!pending.signal.aborted && !disposed) {
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

  // Passes run one at a time; a request during one runs another after it.
  let passing: Promise<void> | undefined = undefined;
  let requested = false;
  const pass = async () => {
    const now = Date.now();
    for (const entry of drafts.getOutbox()) {
      const { id } = entry;
      if (dueAt(entry) <= now) {
        retryAt.delete(id);
        await advance(id);
        const pending = entryOf(id);
        if (pending !== undefined && Number.isFinite(dueAt(pending))) {
          retryAt.set(id, Date.now() + retryDelay);
        }
      }
    }
  };
  const process = async () => {
    requested = true;
    passing ??= (async () => {
      try {
        while (requested) {
          requested = false;
          if (!disposed) {
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
      if (passing === undefined) {
        plan(() => void process());
      }
    }
  });
  plan(() => void process());

  return {
    // Admits the Draft `expected` shows to the Outbox, to send once the Undo Send Window ends.
    // Resolves why it was refused, or undefined once admitted.
    send: async (expected: () => Draft): Promise<SendRefusal | undefined> => {
      const draft = expected();
      if (draft.to.length + draft.cc.length + draft.bcc.length === 0) {
        return 'recipients';
      }
      if (draft.entries !== undefined) {
        return 'entries';
      }
      if (senderProblem(draft) !== undefined) {
        return 'sender';
      }
      if (unsendableAssets(draft).length > 0) {
        return 'assets';
      }
      for (const asset of assetsOf(draft)) {
        // Every file must be on this device with bytes matching its digest.
        if (asset.state === 'complete') {
          const verified = await drafts.readAsset(asset, { preview: false });
          if (verified.kind !== 'verified') {
            return 'assets';
          }
        }
      }
      const message = messageOf(draft);
      if (message.size > gmailMessageLimit) {
        return 'too-large';
      }
      const sendAt = Date.now() + undoSendWindow;
      const admitted = await drafts.admit(draft.id, expected, (stored) => ({
        id: stored.id,
        draft: stored,
        message,
        sendAt,
        state: 'waiting',
      }));
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
    // Returns a message not yet handed to Gmail to the Drafts, as Undo or after a refusal.
    // Resolves the Draft's identifier, or false when it can no longer return.
    undo: async (id: string) => {
      retryAt.delete(id);
      return drafts.restore(id);
    },
    // Tries every due message now, as when the app becomes active.
    process: async () => {
      retryAt.clear();
      await process();
    },
    dispose: () => {
      disposed = true;
      timer?.abort();
      unsubscribe();
    },
  };
}

export type Outbox = ReturnType<typeof createOutbox>;
