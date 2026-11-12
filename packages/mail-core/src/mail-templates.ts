import * as Schema from 'effect/Schema';

import type { SemanticDocument, Selection } from './semantic-document.ts';

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
