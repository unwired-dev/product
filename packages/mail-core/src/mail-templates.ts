import * as Effect from 'effect/Effect';
import * as Option from 'effect/Option';
import * as Schema from 'effect/Schema';
import * as Semaphore from 'effect/Semaphore';

import type { DraftStorageFailure } from './draft-native.ts';
import type { Registration } from './registration.ts';
import type { SemanticDocument, Selection } from './semantic-document.ts';

import {
  rejectionCode,
  rejectionDiagnostic,
  runLogged,
} from './diagnostics.ts';
import { malformed, native, ownerMismatch } from './draft-native.ts';
import { notifyRemoval, PushedSchema } from './draft-sync.ts';
import { ownerOf } from './drafts.ts';
import {
  imagesOf,
  insertDocument,
  SemanticDocumentSchema,
} from './semantic-document.ts';

// A Mail Template: a reusable name, subject and body. It never carries recipients, attachments,
// Inline Images, signatures or placeholders, and never sends anything.
export const MailTemplateSchema = Schema.Struct({
  name: Schema.String.check(Schema.makeFilter((name) => name.trim() !== '')),
  subject: Schema.String,
  body: SemanticDocumentSchema.check(
    Schema.makeFilter((body) => imagesOf(body).length === 0),
  ),
});
export type MailTemplate = typeof MailTemplateSchema.Type;

// Applies a template to a Draft as one edit: its body goes after the selection without replacing
// authored text, and its subject fills only a Draft without one. Applied to an empty Draft, it
// gives the template's subject and body.
export const applyTemplate = (
  draft: Readonly<{ subject: string; body: SemanticDocument }>,
  selection: Selection,
  template: MailTemplate,
) => ({
  subject: draft.subject.trim() === '' ? template.subject : draft.subject,
  edit: insertDocument(draft.body, selection, template.body),
});

// A stored Mail Template: its identifier and the Mail Profile that owns it. A conflict copy keeps
// this device's edit of a template another device changed first.
export const StoredMailTemplateSchema = Schema.Struct({
  id: Schema.NonEmptyString,
  profile: Schema.NonEmptyString,
  ...MailTemplateSchema.fields,
  conflict: Schema.optionalKey(Schema.Literal(true)),
});
export type StoredMailTemplate = typeof StoredMailTemplateSchema.Type;

const Version = Schema.Int.check(Schema.isGreaterThanOrEqualTo(1));
const NullableTemplate = Schema.NullOr(StoredMailTemplateSchema);
// A template's Private Sync record as this device last read or wrote it: the record's write count,
// its Convex revision, the template, null once removed, and the random identifier of the write
// that made it.
const SyncedSchema = Schema.Struct({
  id: Schema.NonEmptyString,
  version: Version,
  updatedAt: Schema.Finite,
  template: NullableTemplate,
  write: Schema.NonEmptyString,
});
type Synced = typeof SyncedSchema.Type;
const SentSchema = Schema.Struct({
  id: Schema.NonEmptyString,
  version: Version,
  write: Schema.NonEmptyString,
});
type Sent = typeof SentSchema.Type;
const StoredDocumentSchema = Schema.Struct({
  templates: Schema.Array(StoredMailTemplateSchema),
  // Each template's base: a template that differs from it has a change to publish.
  synced: Schema.optionalKey(Schema.Array(SyncedSchema)),
  // Each write sent and not yet known to have landed or lost, so reading one back after a lost
  // reply is no conflict.
  sent: Schema.optionalKey(Schema.Array(SentSchema)),
});
type Templates = typeof StoredDocumentSchema.Type;
const DocumentSchema = Schema.fromJsonString(StoredDocumentSchema);
const OpenedSchema = Schema.Struct({
  owner: Schema.NonEmptyString,
  revision: Schema.Int.check(Schema.isGreaterThanOrEqualTo(0)),
  document: Schema.NullOr(DocumentSchema),
});
const CommittedSchema = Schema.Struct({
  owner: Schema.NonEmptyString,
  revision: Schema.Int.check(Schema.isGreaterThanOrEqualTo(1)),
});
const PulledSchema = Schema.Struct({
  owner: Schema.NonEmptyString,
  records: Schema.Array(
    Schema.Struct({
      id: Schema.NonEmptyString,
      version: Version,
      updatedAt: Schema.Finite,
      // Decoded one by one, so a record this device cannot read changes nothing.
      template: Schema.NullOr(Schema.String),
    }),
  ),
  unreadable: Schema.Array(Schema.NonEmptyString),
});
// What a record seals: the template, null once removed, and its write's identifier, so this device
// tells its own writes from another device's identical one.
const RecordJsonSchema = Schema.fromJsonString(
  Schema.Struct({ template: NullableTemplate, write: Schema.NonEmptyString }),
);
const decodeRecord = Schema.decodeUnknownOption(RecordJsonSchema);
const isStored = Schema.is(StoredMailTemplateSchema);
// Native code accepts a Private Sync record identifier of at most 200 characters.
const publishable = (id: string) => id.length <= 200;
const sameTemplate = Schema.toEquivalence(NullableTemplate);
const sameDocument = Schema.toEquivalence(StoredDocumentSchema);

// The signed-in Product Account's Mail Templates on this device: one document native code keeps
// encrypted for the account that wrote it, like its Drafts. Every call rejects with 'locked' while
// the device is locked.
export interface NativeMailTemplates {
  // Resolves `{ owner, revision, document }`; `document` is null when the account has none.
  readonly openMailTemplates: () => Promise<unknown>;
  // Replaces the document only from `expectedRevision` and resolves `{ owner, revision }`.
  readonly commitMailTemplates: (
    owner: string,
    expectedRevision: number,
    document: string,
  ) => Promise<unknown>;
}

// The account's Mail Templates in Private Sync, one record per template.
// Native code seals each record to the account and an opaque identifier derived from the
// template's, so Convex holds only ciphertext. Every call rejects with 'unavailable' while this
// device holds no keys or Product Sign-In session.
export interface NativeMailTemplateSync {
  // Resolves `{ owner, records: [{ id, version, updatedAt, template }], unreadable }`, `template`
  // being the JSON the record seals. `unreadable` names the templates of `known` whose record
  // exists but does not open here.
  readonly pullMailTemplates: (
    owner: string,
    known: readonly string[],
  ) => Promise<unknown>;
  // Writes template `id`'s record, sealing `template` (the template or its removal, as JSON), only
  // while it is still at `expectedUpdatedAt` (absent: while there is none). Resolves
  // `{ owner, committed, updatedAt? }`.
  readonly pushMailTemplate: (
    owner: string,
    record: Readonly<{
      id: string;
      version: number;
      template: string | null;
      expectedUpdatedAt?: number;
    }>,
  ) => Promise<unknown>;
}

// Locked storage is expected while the device is locked, and Private Sync is expected to be
// unavailable without keys or a session or after a removal moved the key epoch; anything else is
// logged.
const report = (
  error: Readonly<Pick<DraftStorageFailure, 'kind' | 'cause' | 'diagnostic'>>,
) =>
  error.kind === 'locked' ||
  ['unavailable', 'key-rotation-required'].includes(
    rejectionCode(error.cause) ?? '',
  )
    ? Effect.void
    : Effect.logError('Mail Template storage failed:', error.diagnostic);

const byId = <T extends Readonly<{ id: string }>>(items: readonly T[] = []) =>
  new Map(items.map((item) => [item.id, item]));

// Another Profile's template is never replaced or removed.
const ownedElsewhere = (
  templates: readonly StoredMailTemplate[],
  profile: string,
  id: string,
) =>
  templates.some(
    (template) => template.id === id && template.profile !== profile,
  );

// `templates` with `stored` added, or in place of the template with its id; undefined while
// another Profile owns that id.
const withTemplate = (
  templates: readonly StoredMailTemplate[],
  stored: StoredMailTemplate,
) => {
  if (ownedElsewhere(templates, stored.profile, stored.id)) {
    return undefined;
  }
  return templates.some(({ id }) => id === stored.id)
    ? templates.map((item) => (item.id === stored.id ? stored : item))
    : [...templates, stored];
};

// `templates` without `profile`'s template `id`, the same array when there is none, or undefined
// while another Profile owns it.
const withoutTemplate = (
  templates: readonly StoredMailTemplate[],
  profile: string,
  id: string,
) => {
  if (ownedElsewhere(templates, profile, id)) {
    return undefined;
  }
  return templates.some((template) => template.id === id)
    ? templates.filter((template) => template.id !== id)
    : templates;
};

const withTemplates = (
  document: Templates,
  templates: readonly StoredMailTemplate[] | undefined,
) => {
  if (templates === undefined) {
    return undefined;
  }
  return templates === document.templates
    ? document
    : { ...document, templates };
};

// Each template whose content differs from the record it was made from, with that record: a
// change, or a removal, to publish.
const pendingOf = ({ templates, synced }: Templates) => {
  const live = byId(templates);
  const bases = byId(synced);
  return [...new Set([...live.keys(), ...bases.keys()])].flatMap((id) => {
    const template = live.get(id) ?? null;
    const base = bases.get(id);
    return sameTemplate(base?.template ?? null, template)
      ? []
      : [{ id, template, base }];
  });
};

// A random identifier for one write, as Draft assets are named.
const writeId = () => {
  let id = '';
  while (id.length < 24) {
    id += Math.random().toString(36).slice(2);
  }
  return id.slice(0, 24);
};

// The first conflict copy identifier for `id` that no template or record uses, short enough for
// native code to publish.
const copyId = (id: string, used: ReadonlySet<string>) => {
  const base = id.replace(/-conflict-\d+$/u, '').slice(0, 100);
  let index = 1;
  while (used.has(`${base}-conflict-${index}`)) {
    index += 1;
  }
  return `${base}-conflict-${index}`;
};

// The writes `sent` holds that may still land after `known`, a record of the same template.
const unsettled = (sent: readonly Sent[], known: Readonly<Synced>) =>
  sent.filter(({ id, version }) => id !== known.id || version > known.version);

// Takes one record newer than the one this device read. This device's own write read back, as
// after a lost reply, changes no template; another device's identical write is not its own. A template without a change to publish takes the
// record; a pending removal yields to an edit, a pending edit outlives a removal, and a pending
// edit of a template another device changed first stays as a conflict copy, the record keeping
// the id.
// fallow-ignore-next-line complexity -- Each condition is one merge rule above.
const adoptRecord = (
  {
    live,
    bases,
    sent,
    pulled,
  }: Readonly<{
    live: Map<string, StoredMailTemplate>;
    bases: Map<string, Synced>;
    sent: Set<Sent>;
    pulled: ReadonlySet<string>;
  }>,
  record: Synced,
) => {
  const base = bases.get(record.id);
  const local = live.get(record.id) ?? null;
  const own = [...sent].some(
    ({ id, write }) => id === record.id && write === record.write,
  );
  bases.set(record.id, record);
  for (const item of sent) {
    if (item.id === record.id && item.version <= record.version) {
      sent.delete(item);
    }
  }
  if (own) {
    return;
  }
  if (local === null || sameTemplate(base?.template ?? null, local)) {
    if (record.template === null) {
      live.delete(record.id);
    } else {
      live.set(record.id, record.template);
    }
  } else if (
    record.template !== null &&
    !sameTemplate(record.template, local)
  ) {
    const id = copyId(
      record.id,
      new Set([...live.keys(), ...bases.keys(), ...pulled]),
    );
    live.set(record.id, record.template);
    live.set(id, { ...local, id, conflict: true });
  }
};

// Merges records another device wrote. A version authenticates one immutable record, so an older
// or replayed one changes nothing.
const adopt = (document: Templates, records: readonly Synced[]) => {
  const live = byId(document.templates);
  const bases = byId(document.synced);
  const sent = new Set(document.sent);
  const pulled = new Set(records.map(({ id }) => id));
  for (const record of records.filter(
    ({ id, version }) => version > (bases.get(id)?.version ?? 0),
  )) {
    adoptRecord({ live, bases, sent, pulled }, record);
  }
  const next = {
    templates: [...live.values()],
    synced: [...bases.values()],
    sent: [...sent],
  };
  return sameDocument(document, next) ? document : next;
};

// The records this device can read; one that does not decode, or names another template, is
// unreadable and changes nothing.
const readable = (pulled: typeof PulledSchema.Type) => {
  const unreadable = new Set(pulled.unreadable);
  const records = pulled.records.flatMap(({ template: json, ...record }) => {
    const sealed = Option.getOrUndefined(decodeRecord(json ?? ''));
    if (
      sealed === undefined ||
      (sealed.template !== null && sealed.template.id !== record.id)
    ) {
      unreadable.add(record.id);
      return [];
    }
    return [{ ...record, ...sealed }];
  });
  return { records, unreadable };
};

// `document` knowing a committed write, unless it already knows one as new.
const settled = (document: Templates, written: Synced) => {
  const base = document.synced?.find(({ id }) => id === written.id);
  if (base !== undefined && base.version >= written.version) {
    return document;
  }
  return {
    ...document,
    synced: [
      ...(document.synced ?? []).filter(({ id }) => id !== written.id),
      written,
    ],
    sent: unsettled(document.sent ?? [], written),
  };
};

// Each Mail Profile's Mail Templates, stored on this device without network access. With `sync`,
// they also synchronize through Private Sync: after each change and on `synchronize`.
export function createMailTemplates(
  storage: NativeMailTemplates,
  registration: Pick<Registration, 'getSnapshot'>,
  sync?: Readonly<{
    native: NativeMailTemplateSync;
    // Called when native code purged the account because this device was removed.
    removed?: () => void;
    // Adopts a key epoch another device's removal moved the account to.
    adoptKeyRotation?: () => Promise<unknown>;
  }>,
) {
  const semaphore = Semaphore.makeUnsafe(1);
  const signedIn = () => ownerOf(registration.getSnapshot().snapshot);
  // The templates of `account`, the Product Account signed in when the action was called, so an
  // action that waited, or whose read finished, while another account signed in reads and writes
  // nothing of it.
  const opened = (account: string | undefined) =>
    Effect.gen(function* () {
      const { owner, revision, document } = yield* native(
        storage.openMailTemplates,
        OpenedSchema,
      );
      if (owner !== account || signedIn() !== account) {
        return yield* ownerMismatch();
      }
      return { owner, revision, document: document ?? { templates: [] } };
    });

  // Stores what `change` makes of `account`'s stored templates and resolves it. It refuses with
  // undefined, and returning the document unchanged writes nothing.
  const changed = (
    account: string | undefined,
    change: (document: Templates) => Templates | undefined,
  ) =>
    Effect.gen(function* () {
      const { owner, revision, document } = yield* opened(account);
      const next = change(document);
      if (next === undefined || next === document) {
        return next;
      }
      const encoded = yield* Schema.encodeEffect(DocumentSchema)(next).pipe(
        Effect.mapError(malformed),
      );
      const committed = yield* native(
        () => storage.commitMailTemplates(owner, revision, encoded),
        CommittedSchema,
      );
      if (committed.owner !== owner) {
        return yield* ownerMismatch();
      }
      return next;
    }).pipe(semaphore.withPermit);

  // Resolves whether storage holds what `change` makes of the stored templates.
  const changing = (change: (document: Templates) => Templates | undefined) =>
    runLogged(
      changed(signedIn(), change).pipe(
        Effect.map((next) => next !== undefined),
        // oxlint-disable-next-line promise/prefer-await-to-callbacks -- Effect's typed error channel.
        Effect.catchTag('DraftStorageFailure', (error) =>
          report(error).pipe(Effect.as(false)),
        ),
      ),
    );

  // Publishes one change by compare-and-set from the record it was made from, remembering the
  // write first so reading it back after a lost reply is no conflict. Its version is above every
  // write of the template that may still land, so each write is told apart. Resolves whether
  // another device's write won.
  const publish = Effect.fnUntraced(function* (
    remote: NativeMailTemplateSync,
    account: string,
    {
      id,
      template,
      base,
      sent,
    }: Readonly<
      ReturnType<typeof pendingOf>[number] & { sent: readonly Sent[] }
    >,
  ) {
    const version =
      Math.max(
        base?.version ?? 0,
        ...sent.filter((item) => item.id === id).map((item) => item.version),
      ) + 1;
    const write = writeId();
    const json = yield* Schema.encodeEffect(RecordJsonSchema)({
      template,
      write,
    }).pipe(Effect.mapError(malformed));
    yield* changed(account, (stored) => ({
      ...stored,
      sent: [...(stored.sent ?? []), { id, version, write }],
    }));
    const pushed: typeof PushedSchema.Type = yield* native(
      () =>
        remote.pushMailTemplate(account, {
          id,
          version,
          template: json,
          ...(base === undefined ? {} : { expectedUpdatedAt: base.updatedAt }),
        }),
      PushedSchema,
    );
    if (pushed.owner !== account) {
      return yield* ownerMismatch();
    }
    if (!pushed.committed) {
      return true;
    }
    const written = {
      id,
      version,
      updatedAt: pushed.updatedAt,
      template,
      write,
    };
    yield* changed(account, (stored) => settled(stored, written));
    return false;
  });

  // One pass: adopts what other devices wrote, then publishes each change it can. A change to a
  // template whose record does not open here waits, and one stored before identifiers were bounded
  // stays on this device. Resolves whether another device's write won meanwhile.
  const pass = Effect.fnUntraced(function* (remote: NativeMailTemplateSync) {
    const account = signedIn();
    if (account === undefined) {
      return false;
    }
    const { document } = yield* opened(account);
    const pulled = yield* native(
      () =>
        remote.pullMailTemplates(
          account,
          (document.synced ?? []).map(({ id }) => id),
        ),
      PulledSchema,
    );
    if (pulled.owner !== account) {
      return yield* ownerMismatch();
    }
    const { records, unreadable } = readable(pulled);
    const adopted = yield* changed(account, (stored) => adopt(stored, records));
    const current = adopted ?? document;
    let conflicted = false;
    for (const change of pendingOf(current).filter(
      ({ id }) => !unreadable.has(id) && publishable(id),
    )) {
      conflicted =
        (yield* publish(remote, account, {
          ...change,
          sent: current.sent ?? [],
        })) || conflicted;
    }
    return conflicted;
  });

  // Passes run one at a time; a request during one runs another after it. A pass another device's
  // write overtook runs again, at most three times.
  let passing: Promise<void> | undefined = undefined;
  let requested = false;
  const passes = async (remote: NativeMailTemplateSync) => {
    requested = true;
    passing ??= (async () => {
      try {
        while (requested) {
          requested = false;
          for (let attempt = 0; attempt < 3; attempt += 1) {
            let needsAdoption = false;
            const conflicted = await runLogged(
              pass(remote).pipe(
                Effect.catchTag('DraftStorageFailure', (error) => {
                  notifyRemoval(error, sync?.removed);
                  needsAdoption =
                    rejectionCode(error.cause) === 'key-rotation-required';
                  return report(error).pipe(Effect.as(false));
                }),
              ),
            );
            // Registration owns its Effect run; adopt outside this pass's run, then pass again.
            if (needsAdoption) {
              await sync?.adoptKeyRotation?.();
            } else if (!conflicted) {
              break;
            }
          }
        }
      } finally {
        passing = undefined;
      }
    })();
    await passing;
  };
  // Logs an unexpected defect rather than rejecting, so lifecycle and change requests need no handler.
  const synchronize = async () => {
    if (sync === undefined) {
      return;
    }
    try {
      await passes(sync.native);
    } catch (error) {
      await runLogged(
        Effect.logError(
          'Mail Template synchronization failed:',
          rejectionDiagnostic(error),
        ),
      );
    }
  };
  const changingThenPublishing = async (
    change: (document: Templates) => Templates | undefined,
  ) => {
    const stored = await changing(change);
    if (stored) {
      void synchronize();
    }
    return stored;
  };

  return {
    // `profile`'s templates, each saying whether it has a change Private Sync does not hold yet, or
    // undefined while storage cannot read them.
    templates: (profile: string) =>
      runLogged(
        opened(signedIn()).pipe(
          Effect.map(({ document }) => {
            const pending = new Set(pendingOf(document).map(({ id }) => id));
            return document.templates
              .filter((template) => template.profile === profile)
              .map((template) => ({
                ...template,
                pending: pending.has(template.id),
              }));
          }),
          // oxlint-disable-next-line promise/prefer-await-to-callbacks -- Effect's typed error channel.
          Effect.catchTag('DraftStorageFailure', (error) =>
            report(error).pipe(Effect.as(undefined)),
          ),
        ),
      ),
    // Adds a template to `profile`, or replaces its template with the same id. Resolves whether
    // storage holds it; a template the model refuses, or whose id native code could not publish,
    // is never stored.
    save: (
      profile: string,
      template: MailTemplate & Readonly<{ id: string }>,
    ) => {
      const stored = { ...template, profile };
      return isStored(stored) && publishable(stored.id)
        ? changingThenPublishing((document) =>
            withTemplates(document, withTemplate(document.templates, stored)),
          )
        : Promise.resolve(false);
    },
    // Removes `profile`'s template `id`. Resolves whether storage no longer holds it.
    remove: (profile: string, id: string) =>
      changingThenPublishing((document) =>
        withTemplates(
          document,
          withoutTemplate(document.templates, profile, id),
        ),
      ),
    // Merges Private Sync into this device's templates and publishes this device's changes;
    // resolves once no pass is running.
    synchronize,
  };
}
