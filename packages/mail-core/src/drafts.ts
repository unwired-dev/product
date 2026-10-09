import type { Translate } from '@private-email/localization';

import * as Arr from 'effect/Array';
import * as Clock from 'effect/Clock';
import * as Effect from 'effect/Effect';
import * as Option from 'effect/Option';
import * as Order from 'effect/Order';
import * as Random from 'effect/Random';
import * as Result from 'effect/Result';
import * as Schema from 'effect/Schema';
import * as Semaphore from 'effect/Semaphore';

import type { Draft, Recipient, Synced, SyncedAsset } from './draft-model.ts';
import type { DraftStorageFailure } from './draft-native.ts';
import type {
  DraftSyncOptions,
  NativeDraftSync,
  Pulled,
} from './draft-sync.ts';
import type {
  MailboxConnection,
  Registration,
  RegistrationSnapshot,
} from './registration.ts';
import type { Asset, Selection } from './semantic-document.ts';

import { rejectionCode, runLogged } from './diagnostics.ts';
import {
  assetsOf,
  DraftSchema,
  ImportedSchema,
  SyncedSchema,
  sameContent,
  sameDrafts,
  syncedAssets,
} from './draft-model.ts';
import {
  failureOf,
  malformed,
  native,
  ownerMismatch,
  report,
} from './draft-native.ts';
import {
  createDraftSynchronizer,
  equivalentSynced,
  notifyRemoval,
  syncedDrafts,
  readRecords,
} from './draft-sync.ts';
import { withoutComments } from './message-body.ts';
import { canOpenInbox, mailboxesOf } from './registration.ts';
import {
  emptyDocument,
  clip,
  insertImage,
  withImage,
} from './semantic-document.ts';

export type { Draft, Recipient, Response, SyncedAsset } from './draft-model.ts';
export type { NativeDraftSync } from './draft-sync.ts';
export { assetsOf } from './draft-model.ts';
export type RecipientField = 'to' | 'cc' | 'bcc';

const DraftDocumentSchema = Schema.Struct({
  version: Schema.Literal(1),
  drafts: Schema.Array(DraftSchema).check(
    Schema.makeFilter(
      (drafts) => new Set(drafts.map(({ id }) => id)).size === drafts.length,
    ),
  ),
  synced: Schema.optionalKey(Schema.Array(SyncedSchema)),
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
  /^\s*(?:"(?<quoted>(?:\\.|[^"\\])*)"|(?<plain>[^"<]*?))\s*<(?<address>[^<>]*)>\s*$/u;

// One entry as a recipient, or undefined when it is not a valid address.
const recipientOf = (entry: string): Recipient | undefined => {
  // Positional captures: Hermes leaves `groups` unset on some named-group results.
  const [, quoted, plain, bracketed] = named.exec(entry) ?? [];
  const address = (bracketed ?? entry).trim();
  if (!addressPattern.test(address)) {
    return undefined;
  }
  const name = (quoted ?? plain ?? '')
    .replaceAll(/\\(?<char>.)/gu, '$1')
    .trim();
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
  let escaped = false;
  for (const ch of text) {
    if (quote === '"' && (escaped || ch === '\\')) {
      escaped = !escaped;
    } else if (quote === undefined && (ch === '"' || ch === '<')) {
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

// A group's `Display Name:` before its first member, outside any quoted name or address.
const groupLabel = /^(?:"(?:\\.|[^"\\])*"\s*|[^"<>@:]*):/u;

// The valid addresses of a received address-list header, such as To or Reply-To. A group keeps its
// members without its display name; entries that are not an address are left out.
export const recipientsOf = (header: string): readonly Recipient[] => {
  const { entries, rest } = entriesOf(
    withoutComments(header.replaceAll(/\r\n(?=[ \t])/gu, ' '), ' '),
  );
  return [...entries, rest].flatMap((entry) => {
    const recipient = recipientOf(entry.trim().replace(groupLabel, ''));
    return recipient === undefined ? [] : [recipient];
  });
};

export const recipientLabel = ({ name, address }: Recipient) =>
  name === undefined ? address : `${name} <${address}>`;

// The recipients of a Draft by role, as its list row shows and announces them: a Bcc-only Draft
// never reads as addressed To someone.
export const recipientSummary = (t: Translate, draft: Draft, limit = 300) => {
  let summary = '';
  for (const field of ['to', 'cc', 'bcc'] as const) {
    const recipients = draft[field];
    let names = '';
    let combined = summary;
    for (const [index, { name, address }] of recipients.entries()) {
      names += `${index === 0 ? '' : ', '}${(name ?? address).slice(0, limit + 1)}`;
      const group = t(`drafts.recipientGroups.${field}`, { recipients: names });
      combined = summary === '' ? group : `${summary} · ${group}`;
      // A row shows one line: stop reading recipients once it is full.
      if (combined.length > limit) {
        return clip(combined, limit);
      }
    }
    summary = combined;
  }
  return summary === '' ? t('drafts.noRecipients') : summary;
};

// Two extra code units distinguish a full prefix even when its end splits an emoji.
export const draftSummary = (t: Translate, draft: Draft) => {
  const subject = clip(draft.subject);
  const summary = recipientSummary(t, draft, 302);
  const recipients = clip(summary);
  const from = clip(draft.from);
  return {
    subject: subject || t('drafts.noSubject'),
    recipients,
    from,
    shortened:
      subject.length < draft.subject.length ||
      recipients.length < summary.length ||
      from.length < draft.from.length,
  };
};

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

// The Draft sending from `mailbox` instead, as the person chose.
export const withSender = (
  draft: Draft,
  mailbox: Pick<MailboxConnection, 'id' | 'address'>,
): Draft => ({ ...draft, connection: mailbox.id, from: mailbox.address });

// The Gmail thread a reply joins: only while it sends from the mailbox that received the message,
// as a thread belongs to that mailbox. From any other sender it keeps only its threading headers.
export const threadOf = ({ connection, response }: Draft) =>
  response !== undefined &&
  'thread' in response &&
  response.thread.connection === connection
    ? response.thread.id
    : undefined;

// The connections a Draft may send from: every one whose Gmail access is usable on this device.
export const sendingMailboxes = (mailboxes: readonly MailboxConnection[]) =>
  mailboxes.filter(({ state }) => state !== 'authorization');

// Files and images ------------------------------------------------------------------------------

// The largest file a Draft accepts, as for received attachments.
export { assetLimit } from './draft-model.ts';
// The most files one pick, paste or drop adds, so a huge selection never floods the composer.
export const pickLimit = 20;

// Assets that must not be sent: imports still running, interrupted, cancelled or failed.
export const unsendableAssets = (draft: Draft) =>
  assetsOf(draft).filter(({ state }) => state !== 'complete');

// The Draft with asset `id` replaced, wherever it is; the same Draft when it has none.
export const withAsset = (
  draft: Draft,
  id: string,
  next: (asset: Asset) => Asset,
): Draft => {
  const { attachments, quoted } = draft;
  const attached = attachments?.some((asset) => asset.id === id) === true;
  const body = withImage(draft.body, id, next);
  const quotedNext =
    quoted === undefined ? undefined : withImage(quoted, id, next);
  if (!attached && body === draft.body && quotedNext === quoted) {
    return draft;
  }
  return {
    ...draft,
    body,
    ...(quotedNext === undefined ? {} : { quoted: quotedNext }),
    ...(attachments === undefined || !attached
      ? {}
      : {
          attachments: attachments.map((asset) =>
            asset.id === id ? next(asset) : asset,
          ),
        }),
  };
};

// Where an asset's bytes come from: a picked or dropped file, pasted data as a `data:` URL, or a
// Downloaded Attachment, read through its own mailbox generation. A Draft keeps only the bytes.
export type AssetSource =
  | Readonly<{ kind: 'file' | 'data'; uri: string }>
  // A picked file over the per-file limit, which native code did not copy.
  | Readonly<{ kind: 'oversized' }>
  // A forwarded attachment that could not be downloaded.
  | Readonly<{ kind: 'unavailable' }>
  | Readonly<{
      kind: 'received';
      mailbox: Readonly<{
        connection: string;
        address: string;
        generation: string;
      }>;
      file: string;
    }>;
export type PickedFile = Readonly<{
  name: string;
  type: string;
  source: AssetSource;
}>;
// Photos and files from the system pickers, or images on the pasteboard.
export type PickSource = 'photos' | 'files' | 'paste';

// What a complete asset's bytes are on this device when read back: an image to show, bytes that
// verified without being shown, or why they are unavailable.
export type AssetPreview =
  | Readonly<{ kind: 'ready'; uri: string }>
  | Readonly<{
      // 'incomplete': another device synchronized the Draft, and this one cannot download its
      // bytes yet.
      kind: 'verified' | 'missing' | 'incomplete' | 'damaged' | 'locked';
    }>;

const PickedSchema = Schema.Array(
  Schema.Union([
    Schema.Struct({
      uri: Schema.NonEmptyString,
      name: Schema.String,
      type: Schema.String,
    }),
    // Over the per-file limit: listed so it shows as too large, with no app-owned staging copy.
    Schema.Struct({
      name: Schema.String,
      type: Schema.String,
      oversized: Schema.Literal('true'),
    }),
  ]),
);
const PreviewSchema = Schema.Struct({
  uri: Schema.NullOr(Schema.NonEmptyString),
});
const VerificationSchema = Schema.Struct({
  uri: Schema.optionalKey(Schema.NonEmptyString),
});

export const isEmptyDraft = (draft: Draft) =>
  (draft.attachments?.length ?? 0) === 0 &&
  draft.quoted === undefined &&
  draft.to.length + draft.cc.length + draft.bcc.length === 0 &&
  draft.entries === undefined &&
  !/\S/u.test(draft.subject) &&
  // Stops at the first non-whitespace character rather than joining the whole body.
  draft.body.every(({ spans }) => spans.every(({ text }) => !/\S/u.test(text)));

// How an asset fails without native code reading anything, for a source it could not copy.
const unreadable = (source: AssetSource) => {
  if (source.kind === 'oversized') {
    return { reason: 'too-large' } as const;
  }
  return source.kind === 'unavailable' ? {} : undefined;
};

// An asset still importing becomes `next`; one cancelled or removed meanwhile is left alone.
const finished =
  (next: (asset: Asset) => Asset) =>
  (asset: Asset): Asset =>
    asset.state === 'importing' ? next(asset) : asset;

// A new asset for a file, importing until its bytes are stored. Its identifier is random
// lowercase letters and digits, as native Draft storage names asset files.
const prepare = ({ name, type }: Pick<PickedFile, 'name' | 'type'>): Asset => {
  let id = '';
  while (id.length < 24) {
    id += Math.random().toString(36).slice(2);
  }
  return {
    id: id.slice(0, 24),
    name: name.trim() === '' ? 'attachment' : name.trim(),
    type,
    state: 'importing',
  };
};

// Host editors record this prepared edit in their own history, then start its imports.
export const prepareFiles = (
  draft: Draft,
  {
    selection,
    files,
    inline,
  }: Readonly<{
    selection: Selection;
    files: readonly PickedFile[];
    inline: boolean;
  }>,
) => {
  const imports = files.map((file) => ({ file, asset: prepare(file) }));
  const inlined = imports.filter(
    ({ file }) => inline && file.type.startsWith('image/'),
  );
  const attached = imports.filter((each) => !inlined.includes(each));
  let { body } = draft;
  let at = selection;
  for (const { asset } of inlined) {
    const result = insertImage(body, at, asset);
    body = result.document;
    at = result.selection ?? at;
  }
  return {
    draft: {
      ...draft,
      body,
      ...(attached.length === 0
        ? {}
        : {
            attachments: [
              ...(draft.attachments ?? []),
              ...attached.map(({ asset }) => asset),
            ],
          }),
    },
    selection: inlined.length > 0 ? at : undefined,
    imports,
  };
};

// The newest edits first; equal times keep the identifier order, so the list is stable.
const draftOrder: Order.Order<Draft> = Order.combine(
  Order.flip(Order.mapInput(Order.Number, ({ updatedAt }: Draft) => updatedAt)),
  Order.mapInput(Order.String, ({ id }: Draft) => id),
);

// A copy names the version it copies, so its editors can follow it. A copy of a long chain of copies
// restarts from the original Draft, keeping identifiers within the native bridge's 200 characters.
const copyBase = (id: string) =>
  id.length > 100 ? (id.split('-conflict-')[0] ?? id) : id;

// A conflicting version of a Draft, kept beside the stored one under a new identifier.
const conflictCopy = Effect.fnUntraced(function* (
  draft: Draft,
): Effect.fn.Return<Draft> {
  const suffix = Math.abs(yield* Random.nextInt).toString(36);
  return {
    ...draft,
    id: `${copyBase(draft.id)}-conflict-${suffix}`,
    conflict: true,
  };
});

// The same content saved by both writers keeps the later edit time, so the list order holds.
const withLaterTime = (ours: Draft, theirs: Draft | undefined): Draft => ({
  ...ours,
  updatedAt: Math.max(ours.updatedAt, theirs?.updatedAt ?? 0),
});

const indexed = (drafts: readonly Draft[]) =>
  new Map(drafts.map((draft) => [draft.id, draft]));

const rebaseDrafts = Effect.fnUntraced(function* (
  base: readonly Draft[],
  local: readonly Draft[],
  latest: readonly Draft[],
) {
  const merged: Draft[] = [];
  const moved: Array<Readonly<{ from: string; to: string }>> = [];
  // Indexed once, so a rebase stays linear in the number of Drafts.
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
        merged.push(withLaterTime(ours, theirs));
      } else {
        const copy = yield* conflictCopy(ours);
        merged.push(copy);
        moved.push({ from: ours.id, to: copy.id });
      }
    }
  }
  return { drafts: merged, moved };
});

// Indexes possible source versions by the same bounded base used when making their copies.
const indexedCopySources = (local: readonly Draft[]) => {
  const before = new Map<string, Draft[]>();
  for (const draft of local) {
    const base = copyBase(draft.id);
    const drafts = before.get(base) ?? [];
    drafts.push(draft);
    before.set(base, drafts);
  }
  return before;
};

// Finds an editor's published version copied by another device, excluding already-rebound edits.
const movesToSyncedCopies = (
  local: readonly Draft[],
  latest: readonly Draft[],
  merged: Readonly<{
    drafts: readonly Draft[];
    moved: ReadonlyArray<Readonly<{ from: string; to: string }>>;
  }>,
) => {
  const before = indexedCopySources(local);
  const surviving = indexed(merged.drafts);
  const moved = new Map(merged.moved.map(({ from, to }) => [from, to]));
  for (const copy of latest) {
    const from = copy.id.slice(
      0,
      Math.max(0, copy.id.lastIndexOf('-conflict-')),
    );
    const target = surviving.get(copy.id);
    if (copy.conflict === true && sameContent(copy, target)) {
      const sources = (before.get(from) ?? []).filter(
        (ours) =>
          !surviving.has(ours.id) &&
          sameContent({ ...ours, id: copy.id, conflict: true }, target),
      );
      const [ours] = sources;
      // shortcut: identical removed versions sharing a shortened base cannot be distinguished;
      // explicit synchronized provenance is needed before those editors can be safely rebound.
      if (sources.length === 1 && ours !== undefined && !moved.has(ours.id)) {
        moved.set(ours.id, copy.id);
      }
    }
  }
  return [...moved].map(([from, to]) => ({ from, to }));
};

// A Draft this device discarded keeps its discard when another device's edit was published first:
// that edit becomes a conflicting copy, and its record becomes the base the discard replaces.
const mergeSyncedDrafts = Effect.fnUntraced(function* (
  synced: readonly Synced[],
  local: readonly Draft[],
  latest: readonly Synced[],
) {
  const kept = new Set(local.map(({ id }) => id));
  const base = indexed(syncedDrafts(synced));
  const unconfirmed = new Set(
    synced
      .filter(({ updatedAt }) => updatedAt === undefined)
      .map(({ id }) => id),
  );
  const copies: Draft[] = [];
  for (const theirs of syncedDrafts(latest)) {
    const prior = base.get(theirs.id);
    // A competing first publication has no shared base: the normal merge preserves both authors.
    // Tombstones retain the intended base, deleting unchanged content and copying divergent edits.
    if (
      kept.has(theirs.id) &&
      unconfirmed.has(theirs.id) &&
      !sameContent(prior, theirs)
    ) {
      base.delete(theirs.id);
    }
    if (
      !kept.has(theirs.id) &&
      prior !== undefined &&
      !sameContent(prior, theirs)
    ) {
      copies.push(yield* conflictCopy(theirs));
      base.set(theirs.id, theirs);
    }
  }
  const merged = yield* rebaseDrafts(
    [...base.values()],
    [...local, ...copies],
    syncedDrafts(latest),
  );
  return {
    ...merged,
    moved: movesToSyncedCopies(local, syncedDrafts(latest), merged),
  };
});

// The first conflicting-copy identifier for `id` that no Draft uses.
const copyId = (id: string, drafts: readonly Draft[]) => {
  const used = new Set(drafts.map((draft) => draft.id));
  let index = 1;
  const base = copyBase(id);
  while (used.has(`${base}-conflict-${index}`)) {
    index += 1;
  }
  return `${base}-conflict-${index}`;
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
// content completed in another window. A same-ID version differing from the editor's expected
// content belongs to another writer, including before any rebase; a rebound copy is still owned.
const keepsTarget = (
  deleting: Draft | undefined,
  {
    onlyIfEmpty,
    intended,
  }: Readonly<{
    onlyIfEmpty: boolean;
    intended: Draft | undefined;
  }>,
) =>
  (onlyIfEmpty && deleting !== undefined && !isEmptyDraft(deleting)) ||
  (deleting !== undefined &&
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
  // `keep` names the assets the document's Drafts still use; native code removes the others'
  // bytes only after the document is stored, and never one whose import has not been committed.
  readonly commitDrafts: (
    owner: string,
    expectedRevision: number,
    commit: Readonly<{ document: string; keep: readonly string[] }>,
  ) => Promise<unknown>;
  // Copies and encrypts an asset's bytes for `owner` under `id`, before any Draft names it as
  // complete. Resolves `{ owner, size, digest }`; rejects with 'too-large' over the per-file limit
  // or the Outgoing Content Store's remaining space.
  readonly importDraftAsset: (
    owner: string,
    id: string,
    source: AssetSource,
  ) => Promise<unknown>;
  // Verifies the asset's bytes against `digest`. With `preview`, resolves `{ uri }`, a bounded PNG
  // thumbnail as a `data:` URL, or `{ uri: null }` when no thumbnail can be decoded; otherwise `{}`, so an
  // asset's full bytes never cross the bridge. Rejects with
  // 'attachment-missing' when the device has no bytes for it.
  readonly readDraftAsset: (
    owner: string,
    asset: Readonly<{
      id: string;
      digest: string;
      type: string;
      preview: boolean;
    }>,
  ) => Promise<unknown>;
  // Deletes bytes that no committed Draft names, such as a cancelled import's.
  readonly discardDraftAsset: (owner: string, id: string) => Promise<unknown>;
  // Resolves `[{ uri, name, type }]`, or `{ name, type, oversized: 'true' }` without a uri
  // for a representation over the per-file limit; empty when the person chose none.
  readonly pickDraftFiles: (source: PickSource) => Promise<unknown>;
  readonly discardPickedDraftFiles: (
    uris: readonly string[],
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

const encodeDocument = (drafts: readonly Draft[], synced: readonly Synced[]) =>
  Schema.encodeEffect(Schema.fromJsonString(DraftDocumentSchema))({
    version: 1,
    drafts,
    ...(synced.length === 0 ? {} : { synced }),
  }).pipe(Effect.mapError(malformed));
const unavailable = (
  error: Readonly<Pick<DraftStorageFailure, 'kind' | 'diagnostic'>>,
) =>
  report(error).pipe(
    Effect.as<AssetPreview>({
      kind: error.kind === 'locked' ? 'locked' : 'damaged',
    }),
  );

const ownerOf = (snapshot: RegistrationSnapshot) =>
  canOpenInbox(snapshot) && snapshot.kind !== 'signed-out'
    ? snapshot.productAccountId
    : undefined;

// The signed-in Product Account's Drafts. Every edit is in memory at once and saved in order;
// a failed save keeps it in memory, and the next edit or `save` retries. Another Product Account
// never sees these Drafts: a change of account forgets them and opens that account's own.
// With `sync`, the Drafts also synchronize through Product Sync: on opening, `delay` milliseconds
// after edits, and on `sync`.
export function createDrafts(
  storage: NativeDrafts,
  registration: Pick<Registration, 'subscribe' | 'getSnapshot'>,
  sync?: DraftSyncOptions,
) {
  const semaphore = Semaphore.makeUnsafe(1);
  // Advances with each Product Account opened; work for an earlier one never publishes.
  let generation = 0;
  let owner: string | undefined = undefined;
  let revision = 0;
  let base: readonly Draft[] = [];
  // Each Draft's Product Sync record as this device last read or wrote it.
  let synced: readonly Synced[] = [];
  // Edits in memory that storage does not hold yet.
  let dirty = false;
  let state: DraftsState = { kind: 'closed' };
  let started = false;
  // Every open editor by the version it edits, saved or not, so a version that synchronization
  // moves to a conflicting copy takes its editor along.
  const editors = new Map<string, Set<(id: string) => void>>();
  const bindEditor = (id: string, moved: (id: string) => void) => {
    for (const bindings of editors.values()) {
      bindings.delete(moved);
    }
    editors.set(id, new Set([...(editors.get(id) ?? []), moved]));
  };
  // Missing identities can keep late edits only within the account that opened them.
  const known = new Set<string>();
  // The complete assets each Draft has used in this account's session, kept in storage while that
  // Draft exists so Undo can restore a removed image or file. A relaunch forgets them.
  const held = new Map<string, Set<string>>();
  const remember = (draft: Draft) => {
    const assets = held.get(draft.id) ?? new Set<string>();
    for (const asset of assetsOf(draft)) {
      if (asset.state === 'complete') {
        assets.add(asset.id);
      }
    }
    held.set(draft.id, assets);
  };
  const keepOf = (drafts: readonly Draft[]) => {
    const keep = new Set<string>();
    for (const draft of drafts) {
      for (const id of held.get(draft.id) ?? []) {
        keep.add(id);
      }
      for (const asset of assetsOf(draft)) {
        if (asset.state === 'complete') {
          keep.add(asset.id);
        }
      }
    }
    return [...keep];
  };
  // Imports running in this account's session, which the composer offers to cancel; an
  // 'importing' asset outside it was interrupted. Replaced on change, so hosts can subscribe.
  let importing: ReadonlySet<string> = new Set<string>();
  // Imports cancelled while native code was still copying them; their bytes are discarded.
  const cancelled = new Set<string>();
  // Open editors replace an asset in their own history before the store changes it, so their
  // next edit is not mistaken for a conflicting one.
  const settling = new Set<
    (id: string, next: (asset: Asset) => Asset) => readonly Draft[]
  >();
  const listeners = new Set<() => void>();
  const publish = (next: DraftsState, notify?: () => void) => {
    state = next;
    if (next.kind === 'ready') {
      for (const draft of next.drafts) {
        known.add(draft.id);
        remember(draft);
      }
    }
    // A synchronous rebind may render immediately; the copy must already be available.
    notify?.();
    for (const listener of listeners) {
      listener();
    }
  };
  const rebindEditors = (from: string, to: string) => {
    held.set(to, new Set([...(held.get(to) ?? []), ...(held.get(from) ?? [])]));
    const bindings = editors.get(from);
    if (bindings === undefined) {
      return;
    }
    editors.delete(from);
    editors.set(to, new Set([...(editors.get(to) ?? []), ...bindings]));
    for (const moved of bindings) {
      // An earlier notification may move another editor or invalidate the account.
      if (editors.get(to)?.has(moved)) {
        moved(to);
      }
    }
  };
  const live = (current: number) => current === generation;
  // Bytes stored late, after an import or download, stay only while a Draft of this account keeps them.
  const keeps = (current: number, id: string) =>
    live(current) &&
    state.kind === 'ready' &&
    keepOf(state.drafts).includes(id);
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
      const { drafts = [], synced: latest = [] } = opened.document ?? {};
      base = drafts;
      synced = latest;
      publish({ kind: 'ready', drafts, save: 'saved' });
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
      // The other writer read or wrote Product Sync no earlier than this store's base.
      synced = opened.document?.synced ?? synced;
      publish({ ...state, drafts: merged.drafts, save: 'saving' }, () => {
        for (const { from, to } of merged.moved) {
          rebindEditors(from, to);
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
      const document = yield* encodeDocument(captured, synced);
      const expected = revision;
      const outcome = yield* Effect.result(
        native(
          () =>
            storage.commitDrafts(account, expected, {
              document,
              keep: keepOf(captured),
            }),
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
          publish({ ...state, save: 'saved' });
        }
        return live(current) && !dirty;
      }),
    );

  // Product Sync ---------------------------------------------------------------------------------

  // Merges the records Product Sync holds into this device's Drafts. A Draft changed on one side
  // only takes that side. An edit racing another device's edit or deletion keeps every version:
  // the record's under the Draft's identifier and this device's as a conflicting copy, which its
  // editors follow.
  const adopt = (current: number, account: string, pulled: Pulled) =>
    Effect.gen(function* (): Effect.fn.Return<
      ReadonlySet<string> | undefined,
      DraftStorageFailure
    > {
      yield* flush(current, account);
      if (!live(current) || state.kind !== 'ready') {
        return undefined;
      }
      const { latest, skipped } = readRecords(synced, pulled);
      const merged = yield* mergeSyncedDrafts(synced, state.drafts, latest);
      const moved = !sameDrafts(merged.drafts, state.drafts);
      if (!moved && equivalentSynced(latest, synced)) {
        return skipped;
      }
      synced = latest;
      dirty = true;
      if (moved) {
        publish({ ...state, drafts: merged.drafts, save: 'saving' }, () => {
          for (const { from, to } of merged.moved) {
            rebindEditors(from, to);
          }
        });
      }
      yield* flush(current, account);
      if (!live(current) || dirty || state.kind !== 'ready') {
        return undefined;
      }
      publish({ ...state, save: 'saved' });
      return skipped;
    }).pipe(
      // oxlint-disable-next-line promise/prefer-await-to-callbacks -- Effect's typed error channel.
      Effect.catchTag('DraftStorageFailure', (error) =>
        report(error).pipe(
          Effect.andThen(failed(current, error)),
          Effect.as(undefined),
        ),
      ),
      semaphore.withPermit,
    );

  // Stores the records this device wrote as its new base.
  const recording = (current: number, account: string, written: Synced) =>
    guarded(
      current,
      Effect.gen(function* () {
        if (!live(current) || state.kind !== 'ready') {
          return false;
        }
        synced = [...synced.filter(({ id }) => id !== written.id), written];
        dirty = true;
        yield* flush(current, account);
        // A storage CAS rebase can replace this entry with another writer's base.
        return (
          live(current) &&
          !dirty &&
          equivalentSynced(
            synced.filter(({ id }) => id === written.id),
            [written],
          )
        );
      }),
    );

  const { synchronize, background, schedule } = createDraftSynchronizer(sync, {
    context: () =>
      owner === undefined || state.kind !== 'ready'
        ? undefined
        : {
            current: generation,
            account: owner,
            drafts: state.drafts,
            synced,
          },
    live,
    adopt,
    record: recording,
  });

  // Applies an edit in memory at once, then saves it. An edit started for an earlier Product
  // Account changes nothing.
  const changing = (
    edit: (
      drafts: readonly Draft[],
      fresh: Readonly<{ now: number; id: string }>,
    ) => readonly Draft[],
    current = generation,
    notify?: () => void,
  ) =>
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
    });
  const change = async (...args: Readonly<Parameters<typeof changing>>) => {
    const changed = await runLogged(changing(...args));
    schedule();
    return changed;
  };

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
    const document = yield* encodeDocument(kept, synced);
    const retaining = keepOf(state.drafts);
    const committed = yield* native(
      () =>
        storage.commitDrafts(account, revision, {
          document,
          // A late edit may still need this target's assets in its conflict copy.
          keep: retaining,
        }),
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
    // Reconcile the final asset keep-list after late edits have their own identities.
    dirty = true;
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
          rebindEditors(id, copy.id);
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
      expected,
    }: Readonly<{
      target: () => string;
      onlyIfEmpty: boolean;
      expected: (() => Draft) | undefined;
    }>,
  ) {
    // The version this editor asked to discard: the one it shows, or what storage held first.
    let intended: Draft | undefined = undefined;
    for (
      let attempt = 0;
      live(current) && state.kind === 'ready';
      attempt += 1
    ) {
      const id = target();
      const deleting = state.drafts.find((draft) => draft.id === id);
      const wanted = expected?.() ?? intended;
      if (keepsTarget(deleting, { onlyIfEmpty, intended: wanted })) {
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
    {
      onlyIfEmpty,
      expected,
    }: Readonly<{ onlyIfEmpty: boolean; expected: (() => Draft) | undefined }>,
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
        yield* deleteTarget(current, account, {
          target,
          onlyIfEmpty,
          expected,
        });
        yield* flush(current, account);
        if (live(current) && state.kind === 'ready') {
          publish({ ...state, save: 'saved' });
        }
        return live(current);
      }),
    );

  const setImporting = (id: string, running: boolean) => {
    const next = new Set(importing);
    if (running) {
      next.add(id);
    } else {
      next.delete(id);
    }
    importing = next;
    for (const listener of listeners) {
      listener();
    }
  };

  // Replaces asset `id` in every Draft that has it: open editors first, then the store.
  const settle = (
    current: number,
    id: string,
    next: (asset: Asset) => Asset,
  ) => {
    if (live(current)) {
      for (const editor of settling) {
        const history = editor(id, next);
        if (!live(current)) {
          break;
        }
        for (const draft of history ?? []) {
          remember(draft);
        }
      }
    }
    return changing((drafts) => {
      const settled = drafts.map((draft) => withAsset(draft, id, next));
      return settled.some((draft, index) => draft !== drafts[index])
        ? settled
        : drafts;
    }, current);
  };

  const discardBytes = (account: string, id: string) =>
    Effect.tryPromise({
      try: () => storage.discardDraftAsset(account, id),
      catch: failureOf,
    }).pipe(Effect.asVoid, Effect.catchTag('DraftStorageFailure', report));

  // A failed import fails its asset, unless it was cancelled or its account left meanwhile.
  const importFailed = Effect.fnUntraced(function* (
    current: number,
    {
      asset,
      failure,
      wanted,
    }: Readonly<{
      asset: Asset;
      failure: Readonly<
        Pick<DraftStorageFailure, 'kind' | 'cause' | 'diagnostic'>
      >;
      wanted: boolean;
    }>,
  ) {
    const tooLarge = rejectionCode(failure.cause) === 'too-large';
    if (!tooLarge) {
      yield* report(failure);
    }
    if (wanted) {
      yield* settle(
        current,
        asset.id,
        finished(({ id, name, type }) => ({
          id,
          name,
          type,
          state: 'failed',
          ...(tooLarge ? { reason: 'too-large' as const } : {}),
        })),
      );
    }
  });

  // Completes the asset wherever it is still importing. Bytes no Draft then keeps complete, such
  // as those of an asset cancelled or removed meanwhile, are deleted again.
  const imported = Effect.fnUntraced(function* (
    current: number,
    account: string,
    {
      asset,
      size,
      digest,
    }: Readonly<{ asset: Asset; size: number; digest: string }>,
  ) {
    yield* settle(
      current,
      asset.id,
      finished(({ id, name, type }) => ({
        id,
        name,
        type,
        state: 'complete',
        size,
        digest,
      })),
    );
    if (!keeps(current, asset.id)) {
      yield* discardBytes(account, asset.id);
    }
  });

  // Copies an asset's bytes into Draft storage and completes it in every Draft that has it.
  const importAsset = (asset: Asset, source: AssetSource) =>
    Effect.gen(function* () {
      const current = generation;
      const account = owner;
      if (account === undefined || importing.has(asset.id)) {
        return;
      }
      const failure = unreadable(source);
      if (failure !== undefined) {
        return yield* settle(
          current,
          asset.id,
          finished(({ id, name, type }) => ({
            id,
            name,
            type,
            state: 'failed',
            ...failure,
          })),
        );
      }
      setImporting(asset.id, true);
      const outcome = yield* Effect.result(
        native(
          () => storage.importDraftAsset(account, asset.id, source),
          ImportedSchema,
        ),
      );
      const wanted = live(current) && !cancelled.delete(asset.id);
      if (live(current)) {
        setImporting(asset.id, false);
      }
      if (Result.isFailure(outcome)) {
        // Native code may have written the bytes before rejecting, as when the device locked.
        yield* discardBytes(account, asset.id);
        return yield* importFailed(current, {
          asset,
          failure: outcome.failure,
          wanted,
        });
      }
      if (!wanted || outcome.success.owner !== account) {
        return yield* discardBytes(account, asset.id);
      }
      yield* imported(current, account, { asset, ...outcome.success });
    });

  const importThenPublish = async (asset: Asset, source: AssetSource) => {
    const outcome = await runLogged(importAsset(asset, source));
    schedule();
    return outcome;
  };

  const fill = async (
    draft: string,
    edit: (draft: Draft) => Draft,
    imports: ReadonlyArray<Readonly<{ asset: Asset; source: AssetSource }>>,
  ) => {
    const current = generation;
    if (
      state.kind !== 'ready' ||
      !state.drafts.some(({ id }) => id === draft)
    ) {
      return false;
    }
    // A refused save keeps the content in memory, as for any edit; the caller opens the Draft,
    // whose composer reports the failed save, rather than leaving a hidden one behind.
    await change((drafts) =>
      drafts.map((each) => (each.id === draft ? edit(each) : each)),
    );
    if (!live(current)) {
      return false;
    }
    for (const { asset, source } of imports) {
      void importThenPublish(asset, source);
    }
    return true;
  };

  const follow = () => {
    const next = ownerOf(registration.getSnapshot().snapshot);
    if (next === owner) {
      return;
    }
    generation += 1;
    owner = next;
    revision = 0;
    base = [];
    synced = [];
    dirty = false;
    editors.clear();
    known.clear();
    held.clear();
    cancelled.clear();
    if (importing.size > 0) {
      importing = new Set();
    }
    publish(next === undefined ? { kind: 'closed' } : { kind: 'loading' });
    if (started && next !== undefined) {
      const opened = runLogged(opening(generation, next));
      void (async () => {
        await opened;
        await background();
      })();
    }
  };
  registration.subscribe(follow);
  follow();

  const readStored = Effect.fnUntraced(function* (
    account: string,
    asset: Readonly<{ id: string; digest: string; type: string }>,
    preview: boolean,
  ): Effect.fn.Return<AssetPreview, DraftStorageFailure> {
    const { uri } = yield* native(
      () =>
        storage.readDraftAsset(account, {
          id: asset.id,
          digest: asset.digest,
          type: asset.type,
          preview,
        }),
      preview ? PreviewSchema : VerificationSchema,
    );
    return uri === undefined || uri === null
      ? { kind: 'verified' }
      : { kind: 'ready', uri };
  });

  // Bytes a synchronized Draft names but this device lacks are downloaded first; until that
  // succeeds, the asset is incomplete.
  // Whether a synchronized asset's bytes arrived on this device, verified for this account.
  const fetching = Effect.fnUntraced(function* (
    { current, account }: Readonly<{ current: number; account: string }>,
    remote: NativeDraftSync,
    listed: SyncedAsset,
  ) {
    const fetched = yield* Effect.result(
      native(() => remote.downloadDraftAsset(account, listed), ImportedSchema),
    );
    if (Result.isFailure(fetched)) {
      if (live(current)) {
        notifyRemoval(fetched.failure, sync?.removed);
      }
      return false;
    }
    return (
      fetched.success.owner === account &&
      fetched.success.digest === listed.digest
    );
  });

  const download = Effect.fnUntraced(function* (
    context: Readonly<{ current: number; account: string }>,
    asset: Readonly<{ id: string; digest: string; type: string }>,
    preview: boolean,
  ): Effect.fn.Return<AssetPreview> {
    const { current, account } = context;
    const remote = sync?.native;
    const listed = syncedAssets(syncedDrafts(synced)).get(
      `${asset.id}:${asset.digest}`,
    );
    if (remote === undefined || listed === undefined) {
      return { kind: 'missing' };
    }
    if (!(yield* fetching(context, remote, listed))) {
      return { kind: 'incomplete' };
    }
    // A Draft discarded or edited while the bytes arrived may have been stored without them.
    if (!keeps(current, asset.id)) {
      // Re-entry can retain these bytes even though this read belongs to the earlier session.
      if (owner !== account || !keeps(generation, asset.id)) {
        yield* discardBytes(account, asset.id);
      }
      return { kind: 'missing' };
    }
    return yield* readStored(account, asset, preview).pipe(
      Effect.catchTag('DraftStorageFailure', unavailable),
    );
  });

  const readAsset = Effect.fnUntraced(function* (
    asset: Readonly<{ id: string; digest: string; type: string }>,
    preview: boolean,
  ): Effect.fn.Return<AssetPreview> {
    const current = generation;
    const account = owner;
    if (account === undefined) {
      return { kind: 'missing' };
    }
    return yield* readStored(account, asset, preview).pipe(
      Effect.catchTag('DraftStorageFailure', (error) =>
        rejectionCode(error.cause) === 'attachment-missing'
          ? download({ current, account }, asset, preview)
          : unavailable(error),
      ),
    );
  });

  return {
    getSnapshot: () => state,
    // Imports running now, by asset; an 'importing' asset outside it was interrupted.
    getImports: () => importing,
    // A new asset for a file, importing until its bytes are stored.
    prepare,
    // Copies a prepared asset's bytes into Draft storage; every Draft naming it then completes,
    // or fails when the bytes cannot be read or stored.
    importAsset: importThenPublish,
    // Stops an import; its asset stays in the Draft as cancelled, and is never sent.
    cancelImport: async (id: string) => {
      if (!importing.has(id)) {
        return false;
      }
      cancelled.add(id);
      setImporting(id, false);
      const settled = await runLogged(
        settle(
          generation,
          id,
          finished(({ id: each, name, type }) => ({
            id: each,
            name,
            type,
            state: 'cancelled',
          })),
        ),
      );
      schedule();
      return settled;
    },
    // Attaches files to a Draft that no editor shows yet, such as a received attachment. Resolves
    // true once the Draft holds them, false when the Draft or its account is gone.
    attach: (draft: string, files: readonly PickedFile[]) => {
      const added = files.map((file) => ({
        asset: prepare(file),
        source: file.source,
      }));
      return fill(
        draft,
        (each) => ({
          ...each,
          attachments: [
            ...(each.attachments ?? []),
            ...added.map(({ asset }) => asset),
          ],
        }),
        added,
      );
    },
    // Fills a Draft that no editor shows yet, such as a reply, then imports the prepared assets it
    // now names. Resolves as `attach` does.
    fill,
    // Editors patch their history and return its Drafts so Undo retains newly completed bytes.
    onSettle: (
      editor: (id: string, next: (asset: Asset) => Asset) => readonly Draft[],
    ) => {
      settling.add(editor);
      return () => {
        settling.delete(editor);
      };
    },
    // Checks a complete asset's bytes against its digest; with `preview`, also returns a thumbnail.
    readAsset: (
      asset: Readonly<{ id: string; digest: string; type: string }>,
      { preview = true }: Readonly<{ preview?: boolean }> = {},
    ) => runLogged(readAsset(asset, preview)),
    // Files the person chooses in the system picker, or images on the pasteboard.
    pick: (source: PickSource, current: () => boolean = () => true) =>
      runLogged(
        Effect.gen(function* () {
          const pickedGeneration = generation;
          const files = yield* native(
            () => storage.pickDraftFiles(source),
            PickedSchema,
          );
          const kept =
            live(pickedGeneration) && current()
              ? files.slice(0, pickLimit)
              : [];
          if (kept.length < files.length) {
            yield* Effect.tryPromise({
              try: () =>
                storage.discardPickedDraftFiles(
                  files
                    .slice(kept.length)
                    .flatMap((file) => ('uri' in file ? [file.uri] : [])),
                ),
              catch: failureOf,
            });
          }
          return kept;
        }).pipe(
          Effect.map((files) =>
            files.map((file): PickedFile => ({
              name: file.name,
              type: file.type,
              source:
                'uri' in file
                  ? { kind: 'file', uri: file.uri }
                  : { kind: 'oversized' },
            })),
          ),
          // oxlint-disable-next-line promise/prefer-await-to-callbacks -- Effect's typed error channel.
          Effect.catchTag('DraftStorageFailure', (error) =>
            report(error).pipe(Effect.as<readonly PickedFile[]>([])),
          ),
        ),
      ),
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
        void background();
      }
    },
    // Merges Product Sync into this device's Drafts and publishes this device's changes;
    // resolves once no pass is running, rejecting unexpected defects to the caller.
    sync: synchronize,
    // Automatic foreground/background requests consume and log unexpected defects.
    syncInBackground: background,
    // A retry that stores edits whose synchronization failed meanwhile synchronizes them too.
    save: async () => {
      const saved = await runLogged(saving(generation));
      if (saved) {
        schedule();
      }
      return saved;
    },
    // Starts a Draft sending from `mailbox`; resolves its identifier, or undefined when Draft
    // storage is not open, the mailbox cannot send for the current Product Account, or that
    // account changes before creation finishes.
    // `finish`, when supplied, completes an open editor within the request's account fence.
    create: async (
      mailbox: Pick<MailboxConnection, 'id' | 'address'>,
      finish?: () => Promise<boolean>,
    ) => {
      const creating = generation;
      // Bind the request before finishing an open editor; another account can expose the same
      // Gmail connection and address, and sign-out/re-entry also invalidates this request.
      if (finish !== undefined && !(await finish())) {
        return undefined;
      }
      if (!live(creating)) {
        return undefined;
      }
      // The sender may have been chosen before an earlier composer finished saving; it must still
      // be one this Product Account can send from now.
      const usable = sendingMailboxes(
        mailboxesOf(registration.getSnapshot().snapshot),
      ).some(
        ({ id, address }) => id === mailbox.id && address === mailbox.address,
      );
      if (!usable) {
        return undefined;
      }
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
      }, creating);
      // A Draft started before the Product Account changed belongs to no open store now.
      return live(creating) ? created.id : undefined;
    },
    // Removes an empty Draft nobody opened, at once in memory, so the next successful save drops it
    // even when storage refuses this one. A Draft that gained content is kept.
    abandon: (id: string) =>
      change((drafts) => {
        const abandoned = drafts.find((draft) => draft.id === id);
        return abandoned === undefined || !isEmptyDraft(abandoned)
          ? drafts
          : drafts.filter((draft) => draft !== abandoned);
      }),
    // Replaces a Draft's content; resolves true once it is saved. When another editor changed the
    // Draft since `previous`, its newer version keeps the identifier and this edit becomes a
    // conflicting copy: `moved` learns the copy's identifier at once and again if storage
    // recovery moves it before saving, so the caller keeps editing its own version.
    update: (draft: Draft, previous?: Draft, moved?: (id: string) => void) => {
      let copy: string | undefined = undefined;
      return change(
        (drafts, { now }) => {
          // An editor that changed nothing writes nothing, even where the stored Draft moved on.
          if (previous !== undefined && sameContent(draft, previous)) {
            return drafts;
          }
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
            bindEditor(id, moved);
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
    // Stops moving an editor that unmounted; its unsaved edits stay in memory for the next save.
    release: (moved: (id: string) => void) => {
      for (const [id, bindings] of editors) {
        bindings.delete(moved);
        if (bindings.size === 0) {
          editors.delete(id);
        }
      }
    },
    // Deletes the Draft named by `target`, which a function resolves once earlier saves land.
    // `expected` is the version the discarding editor shows; another editor's newer content under
    // the same identifier is kept rather than deleted.
    discard: async (
      target: string | (() => string),
      {
        onlyIfEmpty = false,
        expected,
      }: Readonly<{ onlyIfEmpty?: boolean; expected?: () => Draft }> = {},
    ) => {
      const removed = await runLogged(
        removing(
          typeof target === 'string' ? () => target : target,
          generation,
          {
            onlyIfEmpty,
            expected,
          },
        ),
      );
      schedule();
      return removed;
    },
  };
}

export type Drafts = ReturnType<typeof createDrafts>;

export const draftsOf = (state: DraftsState) =>
  state.kind === 'ready' ? Arr.sort(state.drafts, draftOrder) : [];

const draftId = Schema.decodeUnknownOption(Schema.NonEmptyString);
export const draftOf = (state: DraftsState, id: unknown) => {
  const decoded = Option.getOrUndefined(draftId(id));
  return state.kind === 'ready' && decoded !== undefined
    ? state.drafts.find((draft) => draft.id === decoded)
    : undefined;
};
