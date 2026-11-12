import * as Effect from 'effect/Effect';
import * as Schema from 'effect/Schema';
import * as Semaphore from 'effect/Semaphore';

import type { DraftStorageFailure } from './draft-native.ts';
import type { Registration } from './registration.ts';
import type { SemanticDocument, Selection } from './semantic-document.ts';

import { runLogged } from './diagnostics.ts';
import { malformed, native, ownerMismatch } from './draft-native.ts';
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

// A stored Mail Template: its identifier and the Mail Profile that owns it.
export const StoredMailTemplateSchema = Schema.Struct({
  id: Schema.NonEmptyString,
  profile: Schema.NonEmptyString,
  ...MailTemplateSchema.fields,
});
export type StoredMailTemplate = typeof StoredMailTemplateSchema.Type;

const DocumentSchema = Schema.fromJsonString(
  Schema.Struct({ templates: Schema.Array(StoredMailTemplateSchema) }),
);
const OpenedSchema = Schema.Struct({
  owner: Schema.NonEmptyString,
  revision: Schema.Int.check(Schema.isGreaterThanOrEqualTo(0)),
  document: Schema.NullOr(DocumentSchema),
});
const CommittedSchema = Schema.Struct({
  owner: Schema.NonEmptyString,
  revision: Schema.Int.check(Schema.isGreaterThanOrEqualTo(1)),
});
const isStored = Schema.is(StoredMailTemplateSchema);

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

// Locked storage is expected while the device is locked; any other failure is logged.
const report = (
  error: Readonly<Pick<DraftStorageFailure, 'kind' | 'diagnostic'>>,
) =>
  error.kind === 'locked'
    ? Effect.void
    : Effect.logError('Mail Template storage failed:', error.diagnostic);

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

// Each Mail Profile's Mail Templates, stored on this device without network access. They are not
// synchronized yet.
export function createMailTemplates(
  storage: NativeMailTemplates,
  registration: Pick<Registration, 'getSnapshot'>,
) {
  const semaphore = Semaphore.makeUnsafe(1);
  // The templates of `account`, the Product Account signed in when the action was called, so an
  // action that waited while another account signed in reads and writes nothing of it.
  const opened = (account: string | undefined) =>
    Effect.gen(function* () {
      const { owner, revision, document } = yield* native(
        storage.openMailTemplates,
        OpenedSchema,
      );
      if (owner !== account) {
        return yield* ownerMismatch();
      }
      return { owner, revision, templates: document?.templates ?? [] };
    });
  const signedIn = () => ownerOf(registration.getSnapshot().snapshot);

  // Stores what `change` makes of the stored templates. It refuses with undefined, and returning
  // them unchanged writes nothing. Resolves whether storage holds the result.
  const changing = (
    change: (
      templates: readonly StoredMailTemplate[],
    ) => readonly StoredMailTemplate[] | undefined,
  ) => {
    const account = signedIn();
    return runLogged(
      Effect.gen(function* () {
        const { owner, revision, templates } = yield* opened(account);
        const next = change(templates);
        if (next === undefined) {
          return false;
        }
        if (next === templates) {
          return true;
        }
        const document = yield* Schema.encodeEffect(DocumentSchema)({
          templates: next,
        }).pipe(Effect.mapError(malformed));
        const committed = yield* native(
          () => storage.commitMailTemplates(owner, revision, document),
          CommittedSchema,
        );
        if (committed.owner !== owner) {
          return yield* ownerMismatch();
        }
        return true;
      }).pipe(
        // oxlint-disable-next-line promise/prefer-await-to-callbacks -- Effect's typed error channel.
        Effect.catchTag('DraftStorageFailure', (error) =>
          report(error).pipe(Effect.as(false)),
        ),
        semaphore.withPermit,
      ),
    );
  };

  return {
    // `profile`'s templates, or undefined while storage cannot read them.
    templates: (profile: string) =>
      runLogged(
        opened(signedIn()).pipe(
          Effect.map(({ templates }) =>
            templates.filter((template) => template.profile === profile),
          ),
          // oxlint-disable-next-line promise/prefer-await-to-callbacks -- Effect's typed error channel.
          Effect.catchTag('DraftStorageFailure', (error) =>
            report(error).pipe(Effect.as(undefined)),
          ),
        ),
      ),
    // Adds a template to `profile`, or replaces its template with the same id. Resolves whether
    // storage holds it; a template the model refuses is never stored.
    save: (
      profile: string,
      template: MailTemplate & Readonly<{ id: string }>,
    ) => {
      const stored = { ...template, profile };
      return isStored(stored)
        ? changing((templates) => withTemplate(templates, stored))
        : Promise.resolve(false);
    },
    // Removes `profile`'s template `id`. Resolves whether storage no longer holds it.
    remove: (profile: string, id: string) =>
      changing((templates) => withoutTemplate(templates, profile, id)),
  };
}
