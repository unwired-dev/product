import type { Translate } from '@private-email/localization';

import * as Schema from 'effect/Schema';

import type { GmailMessage } from './mailbox-message.ts';
import type { MailProvider } from './registration.ts';

// Gmail organizes mail with labels: Inbox, Trash, Spam, read state and stars are system labels
// that one message modify request adds or removes. Microsoft mail uses the same actions on its
// folders, whose IDs are URL-safe base64; native Gmail code accepts only Gmail's label IDs.
const LabelId = Schema.String.check(Schema.isPattern(/^[\w=-]{1,512}$/u));

export const GmailActionSchema = Schema.Struct({
  kind: Schema.Literals([
    'read',
    'unread',
    'star',
    'unstar',
    'archive',
    'trash',
    'spam',
    'label',
    'unlabel',
    'move',
    // Undoes a removal from the Inbox: archive, move, trash or spam.
    'restore',
  ]),
  add: Schema.Array(LabelId),
  remove: Schema.Array(LabelId),
});
export type GmailAction = typeof GmailActionSchema.Type;

export const GmailLabelSchema = Schema.Struct({
  id: LabelId,
  name: Schema.String,
});
export type GmailLabel = typeof GmailLabelSchema.Type;

export const gmailAction = {
  read: { kind: 'read', add: [], remove: ['UNREAD'] },
  unread: { kind: 'unread', add: ['UNREAD'], remove: [] },
  star: { kind: 'star', add: ['STARRED'], remove: [] },
  unstar: { kind: 'unstar', add: [], remove: ['STARRED'] },
  archive: { kind: 'archive', add: [], remove: ['INBOX'] },
  trash: { kind: 'trash', add: ['TRASH'], remove: ['INBOX'] },
  spam: { kind: 'spam', add: ['SPAM'], remove: ['INBOX'] },
  label: (label: string): GmailAction => ({
    kind: 'label',
    add: [label],
    remove: [],
  }),
  unlabel: (label: string): GmailAction => ({
    kind: 'unlabel',
    add: [],
    remove: [label],
  }),
  // Gmail's Move to: the label replaces the Inbox and every other label stays.
  move: (label: string): GmailAction => ({
    kind: 'move',
    add: [label],
    remove: ['INBOX'],
  }),
} as const satisfies Record<
  string,
  GmailAction | ((label: string) => GmailAction)
>;

// Gmail lists neither Trash nor Spam in the Inbox, whatever other labels a message keeps.
export const inInbox = (labels: readonly string[]) =>
  labels.includes('INBOX') &&
  !labels.includes('TRASH') &&
  !labels.includes('SPAM');

export const relabel = (labels: readonly string[], action: GmailAction) => [
  ...labels.filter((label) => !action.remove.includes(label)),
  ...action.add.filter((label) => !labels.includes(label)),
];

// Undo of an action that took a message out of the Inbox.
export const restoreAfter = (
  action: GmailAction,
  before: readonly string[] = ['INBOX'],
): GmailAction | undefined =>
  inInbox(relabel(['INBOX'], action))
    ? undefined
    : {
        kind: 'restore',
        add: action.remove.filter((label) => before.includes(label)),
        remove: action.add.filter((label) => !before.includes(label)),
      };

// What the Inbox says about an organizing action's outcome at `provider`, the mail provider's
// name; only unsaved changes are counted.
export const gmailActionCopy = (
  t: Translate,
  {
    kind,
    action,
    message,
    count = 1,
  }: Readonly<{
    kind: 'done' | 'rejected' | 'unsaved' | 'blocked';
    // An IMAP change uses the same kinds.
    action: Readonly<{ kind: GmailAction['kind'] }>;
    message: Readonly<{ subject: string }>;
    count?: number;
  }>,
  provider: string,
) =>
  kind === 'unsaved'
    ? t('gmailActions.unsaved', {
        context: action.kind,
        subject: message.subject,
        count,
        provider,
      })
    : t(`gmailActions.${kind}`, {
        context: action.kind,
        subject: message.subject,
        provider,
      });

// A message whose Gmail labels are not known yet, from a cache saved before labels were kept,
// offers no actions until it is listed again: Undo could not tell which labels it already had.
export const canOrganize = (message: GmailMessage) =>
  message.labels !== undefined;

// Microsoft mail has no star; its Spam is the Junk Email folder.
export const quickActions = (
  t: Translate,
  message: GmailMessage,
  {
    provider = 'gmail',
    unavailableActions = [],
  }: Readonly<{
    provider?: MailProvider;
    unavailableActions?: ReadonlyArray<GmailAction['kind']> | undefined;
  }> = {},
) =>
  (canOrganize(message)
    ? [
        message.unread ? gmailAction.read : gmailAction.unread,
        ...(provider === 'gmail'
          ? [
              message.labels?.includes('STARRED') === true
                ? gmailAction.unstar
                : gmailAction.star,
            ]
          : []),
        gmailAction.archive,
        gmailAction.trash,
        gmailAction.spam,
      ]
    : []
  )
    .filter((action) => !unavailableActions.includes(action.kind))
    .map((action) => ({
      name: action.kind,
      label: t(`gmailActions.label.${action.kind}`),
      action,
    }));
