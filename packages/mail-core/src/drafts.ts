import * as Arr from 'effect/Array';
import * as Clock from 'effect/Clock';
import * as Effect from 'effect/Effect';
import * as Option from 'effect/Option';
import * as Order from 'effect/Order';
import * as Random from 'effect/Random';
import * as Result from 'effect/Result';
import * as Schema from 'effect/Schema';
import * as Semaphore from 'effect/Semaphore';

import type {
  MailboxConnection,
  Registration,
  RegistrationSnapshot,
} from './registration.ts';

import {
  decodeDiagnostic,
  rejectionDiagnostic,
  runLogged,
} from './diagnostics.ts';
import { canOpenInbox } from './registration.ts';
import {
  emptyDocument,
  plainText,
  SemanticDocumentSchema,
} from './semantic-document.ts';

const RecipientSchema = Schema.Struct({
  name: Schema.optionalKey(Schema.NonEmptyString),
  address: Schema.NonEmptyString,
});
export type Recipient = typeof RecipientSchema.Type;

// An unsent outgoing message kept on this device until it is discarded. It names the Mailbox
// Connection it sends from and that connection's address when chosen, so a later removal never
// silently substitutes another sender.
const DraftSchema = Schema.Struct({
  id: Schema.NonEmptyString,
  connection: Schema.NonEmptyString,
  from: Schema.NonEmptyString,
  to: Schema.Array(RecipientSchema),
  cc: Schema.Array(RecipientSchema),
  bcc: Schema.Array(RecipientSchema),
  // Cc and Bcc stay shown once revealed or holding a recipient.
  copies: Schema.optionalKey(Schema.Literal(true)),
  // Text still being typed in To, Cc or Bcc, kept so an interruption never loses it.
  entries: Schema.optionalKey(
    Schema.Struct({
      to: Schema.optionalKey(Schema.NonEmptyString),
      cc: Schema.optionalKey(Schema.NonEmptyString),
      bcc: Schema.optionalKey(Schema.NonEmptyString),
    }),
  ),
  conflict: Schema.optionalKey(Schema.Literal(true)),
  subject: Schema.String,
  body: SemanticDocumentSchema,
  // Milliseconds since 1970 of the last edit.
  updatedAt: Schema.Finite,
});
export type Draft = typeof DraftSchema.Type;
const equivalentDraft = Schema.toEquivalence(DraftSchema);
const sameContent = (left: Draft | undefined, right: Draft | undefined) =>
  left === undefined || right === undefined
    ? left === right
    : equivalentDraft({ ...left, updatedAt: 0 }, { ...right, updatedAt: 0 });
export type RecipientField = 'to' | 'cc' | 'bcc';

const DraftDocumentSchema = Schema.Struct({
  version: Schema.Literal(1),
  drafts: Schema.Array(DraftSchema).check(
    Schema.makeFilter(
      (drafts) => new Set(drafts.map(({ id }) => id)).size === drafts.length,
    ),
  ),
});
const OpenedSchema = Schema.Struct({
  owner: Schema.NonEmptyString,
  revision: Schema.Int.check(Schema.isGreaterThanOrEqualTo(0)),
  document: Schema.NullOr(Schema.fromJsonString(DraftDocumentSchema)),
});
const CommittedSchema = Schema.Struct({
  owner: Schema.NonEmptyString,
  revision: Schema.Int.check(Schema.isGreaterThanOrEqualTo(1)),
});

// Recipients ------------------------------------------------------------------------------------

// A pragmatic addr-spec: one @, a dotted domain, and no spaces, quotes, brackets or separators.
const addressPattern =
  /^[^\s@<>()[\]\\,;:"]+@(?:[A-Za-z0-9-]+\.)+[A-Za-z0-9-]{2,}$/u;
// A quoted or plain display name, then the address in angle brackets.
const named =
  /^\s*(?:"(?<quoted>[^"]*)"|(?<plain>[^"<]*?))\s*<(?<address>[^<>]*)>\s*$/u;

// One entry as a recipient, or undefined when it is not a valid address.
const recipientOf = (entry: string): Recipient | undefined => {
  // Positional captures: Hermes leaves `groups` unset on some named-group results.
  const [, quoted, plain, bracketed] = named.exec(entry) ?? [];
  const address = (bracketed ?? entry).trim();
  if (!addressPattern.test(address)) {
    return undefined;
  }
  const name = (quoted ?? plain ?? '').trim();
  return name === '' ? { address } : { name, address };
};

// Entries end at a comma, semicolon or line break outside a quoted name or angle brackets.
const separators = new Set([',', ';', '\n']);
// fallow-ignore-next-line complexity -- One scan keeps separators inside quoted names and addresses.
const entriesOf = (text: string) => {
  const entries: string[] = [];
  let current = '';
  // Inside a quoted name or angle-bracketed address, which a separator never ends.
  let quote: '"' | '<' | undefined = undefined;
  for (const ch of text) {
    if (quote === undefined && (ch === '"' || ch === '<')) {
      quote = ch;
    } else if ((quote === '"' && ch === '"') || (quote === '<' && ch === '>')) {
      quote = undefined;
    }
    if (quote === undefined && separators.has(ch)) {
      entries.push(current);
      current = '';
    } else {
      current += ch;
    }
  }
  return { entries, rest: current };
};

export const recipientLabel = ({ name, address }: Recipient) =>
  name === undefined ? address : `${name} <${address}>`;

export type RecipientNotice = 'invalid' | 'duplicate';

// The text still being typed in a recipient field.
export const entryOf = (draft: Draft, field: RecipientField) =>
  draft.entries?.[field] ?? '';

// The Draft keeping `text` as the field's unfinished entry; the same Draft when nothing changes.
const withEntry = (
  draft: Draft,
  field: RecipientField,
  text: string,
): Draft => {
  if (entryOf(draft, field) === text) {
    return draft;
  }
  const { entries: previous, ...rest } = draft;
  const { [field]: _replaced, ...others } = previous ?? {};
  const entries = text === '' ? others : { ...others, [field]: text };
  return Object.keys(entries).length === 0 ? rest : { ...rest, entries };
};

// Turns finished entries of a recipient field's text into recipients. With `all`, as when the
// field is left or Return is pressed, the unfinished entry is finished too. Invalid text stays in
// the field; an address already in To, Cc or Bcc is not added again.
export function addRecipients(
  draft: Draft,
  {
    field,
    text,
    all = false,
  }: Readonly<{ field: RecipientField; text: string; all?: boolean }>,
): Readonly<{ draft: Draft; text: string; notice?: RecipientNotice }> {
  const { entries, rest: unfinished } = entriesOf(text);
  // The entry still being typed, without the space that followed the last separator.
  const rest = entries.length === 0 ? unfinished : unfinished.trimStart();
  const pending = (all ? [...entries, rest] : entries).filter(
    (entry) => entry.trim() !== '',
  );
  const present = new Set(
    [...draft.to, ...draft.cc, ...draft.bcc].map(({ address }) =>
      address.toLowerCase(),
    ),
  );
  const added: Recipient[] = [];
  const invalid: string[] = [];
  let duplicate = false;
  for (const entry of pending) {
    const recipient = recipientOf(entry);
    if (recipient === undefined) {
      invalid.push(entry.trim());
    } else if (present.has(recipient.address.toLowerCase())) {
      duplicate = true;
    } else {
      present.add(recipient.address.toLowerCase());
      added.push(recipient);
    }
  }
  const unfinishedText = all ? '' : rest;
  // Invalid entries stay for correction, ahead of the entry still being typed.
  const kept =
    invalid.length === 0
      ? unfinishedText
      : [...invalid, unfinishedText].filter((entry) => entry !== '').join(', ');
  const notice = invalid.length > 0 ? 'invalid' : undefined;
  const reported = duplicate ? 'duplicate' : undefined;
  const shown = notice ?? reported;
  const withAdded =
    added.length === 0
      ? draft
      : { ...draft, [field]: [...draft[field], ...added] };
  return {
    draft: withEntry(withAdded, field, kept),
    text: kept,
    ...(shown === undefined ? {} : { notice: shown }),
  };
}

export const recipientCopy: Record<RecipientNotice, string> = {
  invalid: 'Enter a valid email address.',
  duplicate: 'Already added',
};

// Sending identity ------------------------------------------------------------------------------

// The Draft's sending connection on this device: usable, waiting for Gmail authorization, or
// removed. Only a usable connection can be chosen as the sender.
export type SendingState = 'available' | 'authorization' | 'removed';

export const sendingStateOf = (
  draft: Pick<Draft, 'connection'>,
  mailboxes: readonly MailboxConnection[],
): SendingState => {
  const connection = mailboxes.find(({ id }) => id === draft.connection);
  if (connection === undefined) {
    return 'removed';
  }
  return connection.state === 'authorization' ? 'authorization' : 'available';
};

export const sendingCopy: Record<Exclude<SendingState, 'available'>, string> = {
  authorization:
    'This mailbox needs Gmail access again before it can send. Allow access or choose another mailbox.',
  removed:
    'This mailbox was removed from this account. Choose another mailbox to send from.',
};

export const isEmptyDraft = (draft: Draft) =>
  draft.to.length + draft.cc.length + draft.bcc.length === 0 &&
  draft.entries === undefined &&
  draft.subject.trim() === '' &&
  plainText(draft.body).trim() === '';

// The newest edits first; equal times keep the identifier order, so the list is stable.
const draftOrder: Order.Order<Draft> = Order.combine(
  Order.flip(Order.mapInput(Order.Number, ({ updatedAt }: Draft) => updatedAt)),
  Order.mapInput(Order.String, ({ id }: Draft) => id),
);

// A conflicting version of a Draft, kept beside the stored one under a new identifier.
const conflictCopy = Effect.fnUntraced(function* (
  draft: Draft,
): Effect.fn.Return<Draft> {
  const suffix = Math.abs(yield* Random.nextInt).toString(36);
  return { ...draft, id: `${draft.id}-conflict-${suffix}`, conflict: true };
});

const rebaseDrafts = Effect.fnUntraced(function* (
  base: readonly Draft[],
  local: readonly Draft[],
  latest: readonly Draft[],
) {
  const merged: Draft[] = [];
  const moved: Array<Readonly<{ from: string; to: string }>> = [];
  // Indexed once, so a rebase stays linear in the number of Drafts.
  const indexed = (drafts: readonly Draft[]) =>
    new Map(drafts.map((draft) => [draft.id, draft]));
  const [baseById, localById, latestById] = [base, local, latest].map(indexed);
  const ids = new Set([...base, ...local, ...latest].map(({ id }) => id));
  for (const id of ids) {
    const before = baseById?.get(id);
    const ours = localById?.get(id);
    const theirs = latestById?.get(id);
    // Only one side changed it: that side wins. Otherwise an edit racing another edit or a
    // deletion retains every authored version.
    const oursOnly = sameContent(before, theirs) || sameContent(ours, theirs);
    if (sameContent(before, ours) || !oursOnly) {
      merged.push(...(theirs === undefined ? [] : [theirs]));
    }
    if (!sameContent(before, ours) && ours !== undefined) {
      if (oursOnly) {
        merged.push(ours);
      } else {
        const copy = yield* conflictCopy(ours);
        merged.push(copy);
        moved.push({ from: ours.id, to: copy.id });
      }
    }
  }
  return { drafts: merged, moved };
});

// The first conflicting-copy identifier for `id` that no Draft uses.
const copyId = (id: string, drafts: readonly Draft[]) => {
  const used = new Set(drafts.map((draft) => draft.id));
  let index = 1;
  while (used.has(`${id}-conflict-${index}`)) {
    index += 1;
  }
  return `${id}-conflict-${index}`;
};

// The saved version is gone or both the saved version and this editor changed since its baseline.
const conflictsWith = (
  current: Draft | undefined,
  draft: Draft,
  previous?: Draft,
) =>
  current === undefined ||
  (previous !== undefined &&
    !sameContent(current, previous) &&
    !sameContent(current, draft));

// Whether a deletion stops and keeps its target. Closing an untouched window cannot delete
// content completed in another window, and after a rebase the same Draft with other content is
// another writer's later edit; a rebind to a copy is still the deleting editor's own version.
const keepsTarget = (
  deleting: Draft | undefined,
  {
    onlyIfEmpty,
    rebased,
    intended,
  }: Readonly<{
    onlyIfEmpty: boolean;
    rebased: boolean;
    intended: Draft | undefined;
  }>,
) =>
  (onlyIfEmpty && deleting !== undefined && !isEmptyDraft(deleting)) ||
  (rebased &&
    deleting !== undefined &&
    deleting.id === intended?.id &&
    !sameContent(deleting, intended));

// Store -----------------------------------------------------------------------------------------

// The native module's Draft storage for the Product Account signed in on this device. Native code
// keeps the document encrypted for that account and replaces it only from the revision read.
export interface NativeDrafts {
  // Resolves `{ owner, revision, document }`; the document is null before the account's first save.
  readonly openDrafts: () => Promise<unknown>;
  // Resolves `{ owner, revision }`; rejects with 'conflict' when the revision moved on and with
  // 'mailbox-invalidated' when `owner` is no longer the signed-in Product Account.
  readonly commitDrafts: (
    owner: string,
    expectedRevision: number,
    document: string,
  ) => Promise<unknown>;
}

// 'saving' while an edit waits for storage; 'failed' and 'locked' keep unsaved edits in memory
// until a later save succeeds.
export type DraftSave = 'saved' | 'saving' | 'failed' | 'locked';

export type DraftsState =
  // No Product Account with an open Inbox on this device.
  | { readonly kind: 'closed' }
  | { readonly kind: 'loading' | 'locked' | 'failed' }
  | {
      readonly kind: 'ready';
      readonly drafts: readonly Draft[];
      readonly save: DraftSave;
    };

class DraftStorageFailure extends Schema.TaggedError<DraftStorageFailure>()(
  'DraftStorageFailure',
  {
    kind: Schema.Literals(['locked', 'conflict', 'failed']),
    cause: Schema.Defect(),
    // Logged instead of the cause; see rejectionDiagnostic.
    diagnostic: Schema.String,
  },
) {}

const storageCode = Schema.decodeUnknownOption(
  Schema.Struct({ code: Schema.Literals(['locked', 'conflict']) }),
);
const failureOf = (cause: unknown) =>
  new DraftStorageFailure({
    kind: Option.match(storageCode(cause), {
      onNone: () => 'failed' as const,
      onSome: ({ code }) => code,
    }),
    cause,
    diagnostic: rejectionDiagnostic(cause),
  });
const malformed = (error: Schema.SchemaError) =>
  new DraftStorageFailure({
    kind: 'failed',
    cause: error,
    diagnostic: decodeDiagnostic(error),
  });
const ownerMismatch = () =>
  new DraftStorageFailure({
    kind: 'failed',
    cause: undefined,
    diagnostic: 'owner mismatch',
  });

const native = Effect.fnUntraced(function* <S extends Schema.Top>(
  operation: () => Promise<unknown>,
  schema: S,
) {
  const value = yield* Effect.tryPromise({ try: operation, catch: failureOf });
  return yield* Schema.decodeUnknownEffect(schema)(value).pipe(
    Effect.mapError(malformed),
  );
});

const encodeDocument = (drafts: readonly Draft[]) =>
  Schema.encodeEffect(Schema.fromJsonString(DraftDocumentSchema))({
    version: 1,
    drafts,
  }).pipe(Effect.mapError(malformed));

// Locked storage is expected while the device is locked; any other failure is logged.
const report = (
  error: Readonly<Pick<DraftStorageFailure, 'kind' | 'diagnostic'>>,
) =>
  error.kind === 'locked'
    ? Effect.void
    : Effect.logError('Draft storage failed:', error.diagnostic);

const ownerOf = (snapshot: RegistrationSnapshot) =>
  canOpenInbox(snapshot) && snapshot.kind !== 'signed-out'
    ? snapshot.productAccountId
    : undefined;

// The signed-in Product Account's Drafts. Every edit is in memory at once and saved in order;
// a failed save keeps it in memory, and the next edit or `save` retries. Another Product Account
// never sees these Drafts: a change of account forgets them and opens that account's own.
export function createDrafts(
  storage: NativeDrafts,
  registration: Pick<Registration, 'subscribe' | 'getSnapshot'>,
) {
  const semaphore = Semaphore.makeUnsafe(1);
  // Advances with each Product Account opened; work for an earlier one never publishes.
  let generation = 0;
  let owner: string | undefined = undefined;
  let revision = 0;
  let base: readonly Draft[] = [];
  // Edits in memory that storage does not hold yet.
  let dirty = false;
  let state: DraftsState = { kind: 'closed' };
  let started = false;
  // Only unsaved versions can move during CAS recovery or an in-flight deletion.
  // Every editor bound to an unsaved version follows it, and each editor is bound to one version.
  const pendingMoves = new Map<string, Set<(id: string) => void>>();
  const bindPending = (id: string, moved: (id: string) => void) => {
    for (const bindings of pendingMoves.values()) {
      bindings.delete(moved);
    }
    pendingMoves.set(id, new Set([...(pendingMoves.get(id) ?? []), moved]));
  };
  // Missing identities can keep late edits only within the account that opened them.
  const known = new Set<string>();
  const listeners = new Set<() => void>();
  const publish = (next: DraftsState, notify?: () => void) => {
    state = next;
    if (next.kind === 'ready') {
      for (const draft of next.drafts) {
        known.add(draft.id);
      }
    }
    // A synchronous rebind may render immediately; the copy must already be available.
    notify?.();
    for (const listener of listeners) {
      listener();
    }
  };
  const rebindPending = (from: string, to: string) => {
    const bindings = pendingMoves.get(from);
    if (bindings === undefined) {
      return;
    }
    pendingMoves.delete(from);
    pendingMoves.set(
      to,
      new Set([...(pendingMoves.get(to) ?? []), ...bindings]),
    );
    for (const moved of bindings) {
      // An earlier notification may move another editor or invalidate the account.
      if (pendingMoves.get(to)?.has(moved)) {
        moved(to);
      }
    }
  };
  const live = (current: number) => current === generation;
  const failed = (
    current: number,
    error: Readonly<Pick<DraftStorageFailure, 'kind'>>,
  ) =>
    Effect.sync(() => {
      if (!live(current)) {
        return;
      }
      if (state.kind === 'ready') {
        dirty = true;
        publish({
          ...state,
          save: error.kind === 'locked' ? 'locked' : 'failed',
        });
      } else {
        publish({ kind: error.kind === 'locked' ? 'locked' : 'failed' });
      }
    });

  const opening = (current: number, account: string) =>
    Effect.gen(function* () {
      // An open account keeps its in-memory Drafts; a reload only follows a failure.
      if (!live(current) || state.kind === 'ready') {
        return;
      }
      publish({ kind: 'loading' });
      const opened = yield* native(storage.openDrafts, OpenedSchema);
      if (!live(current)) {
        return;
      }
      if (opened.owner !== account) {
        return yield* ownerMismatch();
      }
      ({ revision } = opened);
      base = opened.document?.drafts ?? [];
      publish({
        kind: 'ready',
        drafts: opened.document?.drafts ?? [],
        save: 'saved',
      });
    }).pipe(
      // oxlint-disable-next-line promise/prefer-await-to-callbacks -- Effect's typed error channel.
      Effect.catchTag('DraftStorageFailure', (error) =>
        report(error).pipe(Effect.andThen(failed(current, error))),
      ),
      semaphore.withPermit,
    );

  // Rebases the Drafts in memory onto the revision another writer stored.
  const rebase = Effect.fnUntraced(function* (
    current: number,
    account: string,
  ) {
    const opened = yield* native(storage.openDrafts, OpenedSchema);
    if (opened.owner !== account) {
      return yield* ownerMismatch();
    }
    if (live(current) && state.kind === 'ready') {
      ({ revision } = opened);
      const latest = opened.document?.drafts ?? [];
      const merged = yield* rebaseDrafts(base, state.drafts, latest);
      base = latest;
      publish({ ...state, drafts: merged.drafts, save: 'saving' }, () => {
        for (const { from, to } of merged.moved) {
          rebindPending(from, to);
        }
      });
    }
  });

  // Runs one storage operation alone; a failure keeps edits in memory and resolves false.
  const guarded = (
    current: number,
    operation: Effect.Effect<boolean, DraftStorageFailure>,
  ) =>
    operation.pipe(
      // oxlint-disable-next-line promise/prefer-await-to-callbacks -- Effect's typed error channel.
      Effect.catchTag('DraftStorageFailure', (error) =>
        report(error).pipe(
          Effect.andThen(failed(current, error)),
          Effect.as(false),
        ),
      ),
      semaphore.withPermit,
    );

  // One bounded rebase preserves independent edits, additions and conflicting versions.
  const commit = Effect.fnUntraced(function* (
    current: number,
    account: string,
  ) {
    for (
      let attempt = 0;
      live(current) && state.kind === 'ready';
      attempt += 1
    ) {
      dirty = false;
      const captured = state.drafts;
      const document = yield* encodeDocument(captured);
      const expected = revision;
      const outcome = yield* Effect.result(
        native(
          () => storage.commitDrafts(account, expected, document),
          CommittedSchema,
        ),
      );
      if (Result.isSuccess(outcome)) {
        if (outcome.success.owner !== account) {
          return yield* ownerMismatch();
        }
        if (live(current)) {
          ({ revision } = outcome.success);
          base = captured;
        }
        return;
      }
      dirty = true;
      if (outcome.failure.kind !== 'conflict' || attempt > 0) {
        return yield* outcome.failure;
      }
      yield* rebase(current, account);
    }
  });

  // Commits until storage holds every edit made so far.
  const flush = Effect.fnUntraced(function* (current: number, account: string) {
    const pending = () => live(current) && dirty;
    while (pending()) {
      yield* commit(current, account);
    }
  });

  // Saves every edit made so far; succeeds with true once storage holds them all.
  const saving = (current: number) =>
    guarded(
      current,
      Effect.gen(function* () {
        const account = owner;
        if (account === undefined) {
          return false;
        }
        yield* flush(current, account);
        if (live(current) && state.kind === 'ready' && !dirty) {
          pendingMoves.clear();
          publish({ ...state, save: 'saved' });
        }
        return live(current) && !dirty;
      }),
    );

  // Applies an edit in memory at once, then saves it. An edit started for an earlier Product
  // Account changes nothing.
  const change = (
    edit: (
      drafts: readonly Draft[],
      fresh: Readonly<{ now: number; id: string }>,
    ) => readonly Draft[],
    current = generation,
    notify?: () => void,
  ) =>
    runLogged(
      Effect.gen(function* () {
        if (!live(current) || state.kind !== 'ready') {
          return false;
        }
        const now = yield* Clock.currentTimeMillis;
        const id = `${Math.abs(yield* Random.nextInt).toString(36)}${Math.abs(yield* Random.nextInt).toString(36)}`;
        const drafts = edit(state.drafts, { now, id });
        // An edit that changes nothing leaves storage alone.
        if (drafts === state.drafts) {
          return yield* saving(current);
        }
        dirty = true;
        publish({ kind: 'ready', drafts, save: 'saving' }, notify);
        return yield* saving(current);
      }),
    );

  // Stores the Drafts without `id`. An edit made to it while that was stored survives as a
  // conflicting copy.
  const deleted = Effect.fnUntraced(function* (
    current: number,
    account: string,
    { id, draft: deleting }: Readonly<{ id: string; draft: Draft | undefined }>,
  ) {
    if (state.kind !== 'ready') {
      return;
    }
    publish({ ...state, save: 'saving' });
    const kept = state.drafts.filter((draft) => draft.id !== id);
    const document = yield* encodeDocument(kept);
    const committed = yield* native(
      () => storage.commitDrafts(account, revision, document),
      CommittedSchema,
    );
    if (committed.owner !== account) {
      return yield* ownerMismatch();
    }
    if (!live(current) || state.kind !== 'ready') {
      return;
    }
    ({ revision } = committed);
    base = kept;
    const edited = state.drafts.find((draft) => draft.id === id);
    const changed = edited !== undefined && !sameContent(edited, deleting);
    dirty ||= changed;
    const copy = changed ? yield* conflictCopy(edited) : undefined;
    publish(
      {
        ...state,
        drafts: [
          ...state.drafts.filter((draft) => draft.id !== id),
          ...(copy === undefined ? [] : [copy]),
        ],
      },
      () => {
        if (copy !== undefined) {
          rebindPending(id, copy.id);
        }
      },
    );
  });

  // Deletes the target's Draft from the current revision, keeping completed content for an
  // empty-only removal. When another store wrote first, it rebases
  // onto that revision once and resolves the target again before retrying.
  const deleteTarget = Effect.fnUntraced(function* (
    current: number,
    account: string,
    {
      target,
      onlyIfEmpty,
    }: Readonly<{ target: () => string; onlyIfEmpty: boolean }>,
  ) {
    // The version this editor asked to discard.
    let intended: Draft | undefined = undefined;
    for (
      let attempt = 0;
      live(current) && state.kind === 'ready';
      attempt += 1
    ) {
      const id = target();
      const deleting = state.drafts.find((draft) => draft.id === id);
      if (
        keepsTarget(deleting, { onlyIfEmpty, rebased: attempt > 0, intended })
      ) {
        return;
      }
      intended = deleting;
      const outcome = yield* Effect.result(
        deleted(current, account, { id, draft: deleting }),
      );
      if (Result.isSuccess(outcome)) {
        return;
      }
      if (outcome.failure.kind !== 'conflict' || attempt > 0) {
        return yield* outcome.failure;
      }
      yield* rebase(current, account);
      yield* flush(current, account);
    }
  });

  // Keep a Draft visible until its deletion is durable, so a refused discard can be retried.
  // `target` names the Draft when deletion runs, after earlier saves that may move its editor.
  const removing = (
    target: () => string,
    current: number,
    onlyIfEmpty: boolean,
  ) =>
    guarded(
      current,
      Effect.gen(function* () {
        const account = owner;
        if (account === undefined) {
          return false;
        }
        yield* flush(current, account);
        if (!live(current) || state.kind !== 'ready') {
          return false;
        }
        yield* deleteTarget(current, account, { target, onlyIfEmpty });
        yield* flush(current, account);
        if (live(current) && state.kind === 'ready') {
          pendingMoves.clear();
          publish({ ...state, save: 'saved' });
        }
        return live(current);
      }),
    );

  const follow = () => {
    const next = ownerOf(registration.getSnapshot().snapshot);
    if (next === owner) {
      return;
    }
    generation += 1;
    owner = next;
    revision = 0;
    base = [];
    dirty = false;
    pendingMoves.clear();
    known.clear();
    publish(next === undefined ? { kind: 'closed' } : { kind: 'loading' });
    if (started && next !== undefined) {
      void runLogged(opening(generation, next));
    }
  };
  registration.subscribe(follow);
  follow();

  return {
    getSnapshot: () => state,
    subscribe: (listener: () => void) => {
      listeners.add(listener);
      return () => {
        listeners.delete(listener);
      };
    },
    load: async () => {
      started = true;
      if (owner !== undefined) {
        await runLogged(opening(generation, owner));
      }
    },
    save: () => runLogged(saving(generation)),
    // Starts a Draft sending from `mailbox`; resolves its identifier, or undefined when Draft
    // storage is not open or the Product Account changes before creation finishes.
    create: async (mailbox: Pick<MailboxConnection, 'id' | 'address'>) => {
      const creating = generation;
      const created: { id?: string } = {};
      await change((drafts, { now, id }) => {
        created.id = id;
        return [
          ...drafts,
          {
            id,
            connection: mailbox.id,
            from: mailbox.address,
            to: [],
            cc: [],
            bcc: [],
            subject: '',
            body: emptyDocument,
            updatedAt: now,
          },
        ];
      });
      // A Draft started before the Product Account changed belongs to no open store now.
      return live(creating) ? created.id : undefined;
    },
    // Replaces a Draft's content; resolves true once it is saved. When another editor changed the
    // Draft since `previous`, its newer version keeps the identifier and this edit becomes a
    // conflicting copy: `moved` learns the copy's identifier at once and again if storage
    // recovery moves it before saving, so the caller keeps editing its own version.
    update: (draft: Draft, previous?: Draft, moved?: (id: string) => void) => {
      let copy: string | undefined = undefined;
      return change(
        (drafts, { now }) => {
          // Decide against the same snapshot this edit changes, before notifying any editor.
          const current = drafts.find((each) => each.id === draft.id);
          // An edit arriving after its Draft was deleted keeps any authored content as a copy.
          if (
            current === undefined &&
            (!known.has(draft.id) || isEmptyDraft(draft))
          ) {
            return drafts;
          }
          const conflict = conflictsWith(current, draft, previous);
          const id = conflict ? copyId(draft.id, drafts) : draft.id;
          if (moved !== undefined) {
            bindPending(id, moved);
          }
          if (conflict) {
            copy = id;
            return [
              ...drafts,
              { ...draft, id, updatedAt: now, conflict: true as const },
            ];
          }
          return drafts.map((each) =>
            each.id === id ? { ...draft, updatedAt: now } : each,
          );
        },
        generation,
        () => {
          if (copy !== undefined) {
            moved?.(copy);
          }
        },
      );
    },
    // Deletes the Draft named by `target`, which a function resolves once earlier saves land.
    discard: (target: string | (() => string), { onlyIfEmpty = false } = {}) =>
      runLogged(
        removing(
          typeof target === 'string' ? () => target : target,
          generation,
          onlyIfEmpty,
        ),
      ),
  };
}

export type Drafts = ReturnType<typeof createDrafts>;

// The connections a Draft may send from: every one whose Gmail access is usable on this device.
export const sendingMailboxes = (mailboxes: readonly MailboxConnection[]) =>
  mailboxes.filter(({ state }) => state !== 'authorization');

export const draftsOf = (state: DraftsState) =>
  state.kind === 'ready' ? Arr.sort(state.drafts, draftOrder) : [];

const draftId = Schema.decodeUnknownOption(Schema.NonEmptyString);
export const draftOf = (state: DraftsState, id: unknown) => {
  const decoded = Option.getOrUndefined(draftId(id));
  return state.kind === 'ready' && decoded !== undefined
    ? state.drafts.find((draft) => draft.id === decoded)
    : undefined;
};
