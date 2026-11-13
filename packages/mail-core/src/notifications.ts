import type { Translate } from '@private-email/localization';

import * as Effect from 'effect/Effect';
import * as Option from 'effect/Option';
import * as Schema from 'effect/Schema';

import type { Drafts } from './drafts.ts';
import type { ImapInbox } from './imap-inbox.ts';
import type { ImapAction } from './imap-model.ts';
import type { GmailInbox } from './inbox-store.ts';
import type { GmailMessage } from './mailbox-message.ts';
import type { Outbox } from './outbox.ts';
import type {
  MailboxConnection,
  MailGrantProvider,
  RegistrationSnapshot,
} from './registration-snapshot.ts';

import { logNote, rejectionDiagnostic, runLogged } from './diagnostics.ts';
import { draftOf } from './drafts.ts';
import { gmailAction } from './gmail-actions.ts';
import { imapRoleFolder } from './imap-actions.ts';
import { listedMessage } from './inbox-store.ts';
import { undoSendWindow } from './outbox.ts';
import { mailboxesOf, unavailableProfile } from './registration-snapshot.ts';
import { typedBody, typedReply } from './responses.ts';
import { createSubscribable } from './subscribable.ts';

// What the operating system lets this device show, and whether a New Mail Notification may show
// its sender and subject. Native code keeps both as Device-Local Preferences; previews start off.
const Settings = Schema.Struct({
  authorization: Schema.Literals(['undetermined', 'denied', 'authorized']),
  previews: Schema.Boolean,
});
export type NotificationSettings = typeof Settings.Type;
const decodeSettings = Schema.decodeUnknownEffect(Settings);

const Mailbox = Schema.Struct({
  account: Schema.NonEmptyString,
  connection: Schema.NonEmptyString,
  epoch: Schema.NonEmptyString,
});
export type NotificationMailbox = typeof Mailbox.Type;

// What a notification shows of a newly arrived message from any provider.
export type ArrivedMessage = Pick<
  GmailMessage,
  'id' | 'sender' | 'address' | 'subject'
>;

// A tapped notification retains its account and connection incarnation. Its Reply action opens
// the message to reply to it.
const Opened = Schema.Struct({
  ...Mailbox.fields,
  message: Schema.NonEmptyString,
  action: Schema.optional(Schema.Literal('reply')),
});
export type OpenedNotification = typeof Opened.Type;

// Archive or Mark as Read, a reply typed into the Reply field, or Undo or Open Draft on that
// reply's own notification, chosen without opening the application. Native code finishes the
// system's handler once `id` completes.
const Chosen = {
  ...Mailbox.fields,
  message: Schema.NonEmptyString,
  id: Schema.NonEmptyString,
};
const Action = Schema.Union([
  Schema.Struct({ ...Chosen, action: Schema.Literals(['archive', 'read']) }),
  Schema.Struct({
    ...Chosen,
    action: Schema.Literal('reply'),
    text: Schema.String,
  }),
  Schema.Struct({
    ...Chosen,
    action: Schema.Literals(['undo', 'open-draft']),
    draft: Schema.NonEmptyString,
  }),
]);

// The connection's current Mail Profile groups its notifications; it is read just before posting,
// since the connection can move to another Profile meanwhile. Its address names the Reply field.
type Arrival = NotificationMailbox &
  Readonly<{ address: string; profile: () => string | undefined }>;

type Posted = Omit<OpenedNotification, 'action'> &
  Readonly<{
    // Stable presentation identity; Gmail history suppresses replay before posting.
    id: string;
    title: string;
    body: string;
    previews: boolean;
    profile: string;
    // The Mac's Reply field placeholder, which names the receiving address.
    reply: string;
  }>;

// The notification actions' titles, in this device's language; `send` titles the Reply field's
// button.
type ActionTitles = Readonly<
  Record<'reply' | 'send' | 'archive' | 'read', string>
>;

// A reply typed into a notification, after Send: `sending` offers Undo while the Undo Send Window
// runs, and `saved` says the text waits in Drafts and offers Open Draft.
type ReplyPosted = Omit<OpenedNotification, 'action'> &
  Readonly<{
    id: string;
    kind: 'sending' | 'saved';
    title: string;
    body: string;
    previews: boolean;
    profile: string;
    draft: string;
  }>;

// The native host's notification permission, preview choice, posting and taps.
export interface NativeNotifications {
  readonly notificationSettings: () => Promise<unknown>;
  // Asks the operating system for alert permission and resolves the settings afterwards.
  readonly requestNotifications: () => Promise<unknown>;
  readonly setNotificationPreviews: (previews: boolean) => Promise<unknown>;
  // Opens this application's notification settings in the system's settings.
  readonly openNotificationSettings: () => Promise<unknown>;
  readonly postNotifications: (
    notifications: readonly Posted[],
    actions: ActionTitles,
  ) => Promise<unknown>;
  // The next tapped notification, or null once a reloaded JavaScript context replaced this
  // reader. On the Mac, `window` names the window asking; the key window's reader goes first.
  readonly nextOpenedNotification: (
    window: string,
    reader: string,
  ) => Promise<unknown>;
  readonly stopOpenedNotifications: (
    window: string,
    reader: string,
  ) => Promise<unknown>;
  readonly restoreOpenedNotification: (
    opened: OpenedNotification,
  ) => Promise<unknown>;
  // The next action chosen on a notification, or null once a reloaded JavaScript context replaced
  // this reader.
  readonly nextNotificationAction: () => Promise<unknown>;
  readonly completeNotificationAction: (id: string) => void;
  // Posts the notification a reply typed into a notification leaves; `actions` titles Undo and
  // Open Draft.
  readonly postReplyNotification: (
    notification: ReplyPosted,
    actions: Readonly<Record<'undo' | 'openDraft', string>>,
  ) => Promise<unknown>;
  // Removes the notification `id` from Notification Center.
  readonly withdrawNotification: (id: string) => Promise<unknown>;
}

// A native call that failed; its cause is logged only as a diagnostic.
class NotificationNativeFailure extends Schema.TaggedError<NotificationNativeFailure>()(
  'NotificationNativeFailure',
  { cause: Schema.Defect() },
) {}

const call = (request: () => Promise<unknown>) =>
  Effect.tryPromise({
    try: request,
    catch: (cause) => new NotificationNativeFailure({ cause }),
  });
const settingsOf = (request: () => Promise<unknown>) =>
  call(request).pipe(
    Effect.flatMap((reply) =>
      decodeSettings(reply).pipe(
        Effect.mapError((cause) => new NotificationNativeFailure({ cause })),
      ),
    ),
  );
const logged = (
  message: string,
  effect: Effect.Effect<unknown, NotificationNativeFailure>,
) =>
  effect.pipe(
    Effect.asVoid,
    Effect.catchTag('NotificationNativeFailure', ({ cause }) =>
      Effect.logError(message, rejectionDiagnostic(cause)),
    ),
  );

// Generic content unless this device chose previews. Without a title the system shows the
// application's name.
export const notificationContent = (
  t: Translate,
  previews: boolean,
  { sender, address, subject }: ArrivedMessage,
) =>
  previews
    ? {
        title: sender === '' ? address : sender,
        body: subject === '' ? t('notifications.noSubject') : subject,
      }
    : { title: '', body: t('notifications.newMail') };

// Why New Mail Notifications were not posted, without the mail or its connection.
const notPosted = (reason: string) =>
  logNote('New mail notifications not posted:', reason);

// This device's notification settings for Settings, and the New Mail Notifications it posts once
// a connection's synchronization commits new Inbox mail. The caller has already checked that the
// connection's policy is on; content is decided here, on the device.
export function createNotifications(
  native: Omit<
    NativeNotifications,
    | 'nextOpenedNotification'
    | 'stopOpenedNotifications'
    | 'restoreOpenedNotification'
    | 'nextNotificationAction'
    | 'completeNotificationAction'
    | 'postReplyNotification'
    | 'withdrawNotification'
  >,
  translate: () => Translate,
) {
  // Unknown until the first read settles.
  const settings = createSubscribable<NotificationSettings | undefined>(
    undefined,
  );
  const update = (request: () => Promise<unknown>, failure: string) =>
    runLogged(
      logged(
        failure,
        settingsOf(request).pipe(
          Effect.tap((next) =>
            Effect.sync(() => {
              settings.set(next);
            }),
          ),
        ),
      ),
    );
  return {
    getSnapshot: settings.getSnapshot,
    subscribe: settings.subscribe,
    // Also after activation: the person can change permission in the system's settings.
    load: () =>
      update(
        () => native.notificationSettings(),
        'Notification settings could not be read:',
      ),
    request: () =>
      update(
        () => native.requestNotifications(),
        'Notification permission could not be requested:',
      ),
    setPreviews: (previews: boolean) =>
      update(
        () => native.setNotificationPreviews(previews),
        'Notification previews could not be saved:',
      ),
    openSettings: () =>
      runLogged(
        logged(
          'Notification settings could not be opened:',
          call(() => native.openNotificationSettings()),
        ),
      ),
    // `eligible` is checked again after reading the settings, just before posting: the
    // connection may have been removed or turned off meanwhile.
    arrived: (
      { profile: currentProfile, address, ...mailbox }: Arrival,
      messages: readonly ArrivedMessage[],
      eligible: () => boolean,
    ) =>
      runLogged(
        logged(
          'New mail notifications could not be posted:',
          Effect.gen(function* () {
            // Read again: a background launch has not loaded Settings.
            const current = yield* settingsOf(() =>
              native.notificationSettings(),
            );
            const profile = currentProfile();
            if (current.authorization !== 'authorized') {
              return yield* notPosted(`authorization ${current.authorization}`);
            }
            if (!eligible()) {
              return yield* notPosted(
                'connection closed or turned off meanwhile',
              );
            }
            if (profile === undefined) {
              return yield* notPosted('Mail Profile unknown');
            }
            const t = translate();
            yield* call(() =>
              native.postNotifications(
                messages.map((message) => ({
                  id: `${mailbox.connection}.${message.id}`,
                  ...notificationContent(t, current.previews, message),
                  ...mailbox,
                  profile,
                  message: message.id,
                  previews: current.previews,
                  reply: t('notifications.replyFrom', { address }),
                })),
                {
                  reply: t('contextMenu.reply'),
                  send: t('drafts.send'),
                  archive: t('contextMenu.archive'),
                  read: t('contextMenu.read'),
                },
              ),
            );
            yield* logNote(
              'New mail notifications handed to the host:',
              messages.length,
            );
          }),
        ),
      ),
  };
}

// Where a tapped notification opens: its message in the connection's current Mail Profile, while
// this device still holds that connection. A removed connection, or one whose Profile is unknown,
// opens nothing.
export const openedTarget = (
  account: RegistrationSnapshot,
  {
    account: owner,
    connection,
    epoch,
    message,
  }: Omit<OpenedNotification, 'action'>,
) => {
  if (account.kind === 'signed-out' || account.productAccountId !== owner) {
    return undefined;
  }
  const mailbox = mailboxesOf(account).find(({ id }) => id === connection);
  return mailbox === undefined ||
    (mailbox.epoch ?? 'legacy') !== epoch ||
    mailbox.profile === unavailableProfile
    ? undefined
    : { id: message, mailbox: connection, profile: mailbox.profile };
};

// Hands each tapped notification to `open`, one at a time, until a reloaded JavaScript context
// replaces this reader; `reply` asks the opened message for a reply. A malformed reply ends
// nothing: it is skipped.
let nextReader = 0;
export function followOpenedNotifications(
  native: Pick<
    NativeNotifications,
    | 'nextOpenedNotification'
    | 'stopOpenedNotifications'
    | 'restoreOpenedNotification'
  >,
  window: string,
  {
    snapshot,
    leave,
    open,
  }: Readonly<{
    snapshot: () => RegistrationSnapshot;
    leave: () => Promise<boolean>;
    open: (
      target: Readonly<NonNullable<ReturnType<typeof openedTarget>>>,
      reply: boolean,
      current: () => boolean,
    ) => void;
  }>,
) {
  nextReader += 1;
  const reader = String(nextReader);
  let stopped = false;
  // One tap: a retired reader hands it back; otherwise the composer may leave first, and the
  // target must still be valid afterwards.
  const handle = async (opened: OpenedNotification) => {
    if (!stopped && openedTarget(snapshot(), opened) !== undefined) {
      const allowed = await leave();
      const target =
        allowed && !stopped ? openedTarget(snapshot(), opened) : undefined;
      if (target !== undefined) {
        open(
          target,
          opened.action === 'reply',
          () => openedTarget(snapshot(), opened) !== undefined,
        );
      }
    }
    if (stopped) {
      await native.restoreOpenedNotification(opened);
    }
  };
  const follow = async () => {
    for (;;) {
      if (stopped) {
        return;
      }
      let received: unknown = null;
      try {
        received = await native.nextOpenedNotification(window, reader);
      } catch {
        // A host without notifications, such as a test renderer, has nothing to follow.
        return;
      }
      if (received === null) {
        return;
      }
      const decoded = Schema.decodeUnknownOption(Opened)(received);
      if (Option.isSome(decoded)) {
        await handle(decoded.value);
      }
    }
  };
  void follow();
  const stop = async () => {
    try {
      await native.stopOpenedNotifications(window, reader);
    } catch {
      /* The native host may already be gone. */
    }
  };
  return () => {
    stopped = true;
    void stop();
  };
}

// A connection's open Inbox, from any provider.
type OpenInbox =
  | Readonly<{ provider: MailGrantProvider; inbox: GmailInbox }>
  | Readonly<{ provider: 'imap'; inbox: ImapInbox }>;

// An IMAP notification's change: Mark as Read, or a move to the folder the server declares for
// archive when it moves without expunging other messages.
const imapChange = (
  state: ReturnType<ImapInbox['getSnapshot']>,
  action: 'archive' | 'read',
): ImapAction | undefined => {
  if (action === 'read') {
    return { kind: 'read' };
  }
  const destination =
    state.kind === 'ready' && state.capabilities?.moves === true
      ? imapRoleFolder(state.folders, 'archive')
      : undefined;
  return destination === undefined
    ? undefined
    : { kind: 'archive', destination };
};

// Archives or marks as read a listed message through the reader toolbar's queued change; a message
// no longer listed changes nothing.
async function organizeListed(
  // oxlint-disable-next-line typescript/prefer-readonly-parameter-types -- Inbox stores are mutable; only their actions are called.
  open: OpenInbox,
  id: string,
  action: 'archive' | 'read',
) {
  await open.inbox.load();
  if (open.provider === 'imap') {
    const message = open.inbox.message(id);
    const change = imapChange(open.inbox.getSnapshot(), action);
    if (message !== undefined && change !== undefined) {
      await open.inbox.organize(message, change);
    }
    return;
  }
  const state = open.inbox.getSnapshot();
  const message = state.kind === 'ready' ? listedMessage(state, id) : undefined;
  if (message !== undefined) {
    await open.inbox.organize(message, gmailAction[action]);
  }
}

// What a reply typed into a notification needs: the Draft store, the Outbox, this device's
// language, and how the host opens a Draft in its own New Message window.
type Replies = Readonly<{
  drafts: Pick<Drafts, 'load' | 'create' | 'fill' | 'getSnapshot' | 'prepare'>;
  outbox: Pick<Outbox, 'send' | 'undo' | 'getSnapshot'>;
  translate: () => Translate;
  openDraft: (draft: string, profile: string) => void;
}>;

// The listed message `id`, with the body and headers a reply starts from once its body reads.
async function answered(
  // oxlint-disable-next-line typescript/prefer-readonly-parameter-types -- Inbox stores are mutable; only their actions are called.
  open: OpenInbox,
  id: string,
) {
  await open.inbox.load();
  let message:
    | (Pick<GmailMessage, 'id' | 'subject' | 'sender' | 'address'> &
        Readonly<{ threadId?: string }>)
    | undefined = undefined;
  if (open.provider === 'imap') {
    message = open.inbox.message(id);
  } else {
    const state = open.inbox.getSnapshot();
    message = state.kind === 'ready' ? listedMessage(state, id) : undefined;
  }
  if (message === undefined) {
    return undefined;
  }
  const release = open.inbox.retainMessage(id);
  try {
    await open.inbox.readMessage(id);
    return { message, document: open.inbox.responseSource(id) };
  } finally {
    release();
  }
}

// Queues `text` alone as a reply to the notified message, from the connection that received it,
// through the Outbox and its Undo Send Window, and says so on a notification offering Undo until
// the window ends. A message no longer listed or unreadable, or a Send the Outbox refuses, keeps
// the text in Drafts and offers Open Draft instead.
async function replyTyped(
  native: Pick<
    NativeNotifications,
    'notificationSettings' | 'postReplyNotification' | 'withdrawNotification'
  >,
  { drafts, outbox, translate }: Replies,
  // oxlint-disable-next-line typescript/prefer-readonly-parameter-types -- Inbox stores are mutable; only their actions are called.
  {
    open,
    named,
    profile,
    sender,
    identities,
    text,
  }: Readonly<{
    open: OpenInbox;
    named: Omit<OpenedNotification, 'action'>;
    profile: string;
    sender: Pick<MailboxConnection, 'id' | 'address'>;
    identities: readonly string[];
    text: string;
  }>,
) {
  const t = translate();
  const source = await answered(open, named.message);
  // An action can launch the application before its Drafts open.
  await drafts.load();
  const draft = await drafts.create(sender);
  if (draft === undefined) {
    await runLogged(logNote('Notification reply not saved: Drafts closed'));
    return;
  }
  const reply =
    source?.document === undefined
      ? undefined
      : typedReply(
          t,
          {
            message: source.message,
            document: source.document,
            connection: sender.id,
            from: sender.address,
            identities,
            received: '',
            prepare: drafts.prepare,
          },
          text,
        );
  const filled = await drafts.fill(
    draft,
    reply ?? ((each) => ({ ...each, body: typedBody(text) })),
    [],
  );
  const saved = draftOf(drafts.getSnapshot(), draft);
  const queued =
    filled &&
    reply !== undefined &&
    saved !== undefined &&
    (await outbox.send(() => draftOf(drafts.getSnapshot(), draft) ?? saved)) ===
      undefined;
  const { previews } = await runLogged(
    settingsOf(() => native.notificationSettings()).pipe(
      Effect.orElseSucceed(() => ({ previews: false })),
    ),
  );
  const id = `${named.connection}.reply.${draft}`;
  const replied = source?.message;
  await runLogged(
    logged(
      'Notification reply notification could not be posted:',
      call(() =>
        native.postReplyNotification(
          {
            ...named,
            id,
            draft,
            profile,
            previews,
            ...(queued
              ? {
                  kind: 'sending' as const,
                  title:
                    previews && replied !== undefined
                      ? t('notifications.replyTo', {
                          sender:
                            replied.sender === ''
                              ? (replied.address ?? '')
                              : replied.sender,
                        })
                      : '',
                  body: t('notifications.replySending', {
                    seconds: undoSendWindow / 1000,
                    address: sender.address,
                  }),
                }
              : {
                  kind: 'saved' as const,
                  title: t('notifications.replyFailed'),
                  body: t(
                    source === undefined
                      ? 'notifications.replyDeleted'
                      : 'notifications.replySaved',
                  ),
                }),
          },
          {
            undo: t('notifications.undo'),
            openDraft: t('notifications.openDraft'),
          },
        ),
      ),
    ),
  );
  if (queued) {
    setTimeout(() => {
      void runLogged(
        logged(
          'Notification reply notification could not be withdrawn:',
          call(() => native.withdrawNotification(id)),
        ),
      );
    }, undoSendWindow);
  }
}

// Acts on one action chosen on a notification while the connection is still the one it named.
async function act(
  native: Pick<
    NativeNotifications,
    'notificationSettings' | 'postReplyNotification' | 'withdrawNotification'
  >,
  {
    snapshot,
    mailbox,
    replies,
  }: Readonly<{
    snapshot: () => RegistrationSnapshot;
    mailbox: (connection: string) => OpenInbox | undefined;
    replies: Replies;
  }>,
  chosen: typeof Action.Type,
) {
  const { account, connection, epoch, message } = chosen;
  const named = { account, connection, epoch, message };
  const target = openedTarget(snapshot(), named);
  const open = target === undefined ? undefined : mailbox(target.mailbox);
  if (target === undefined || open === undefined) {
    return;
  }
  if (chosen.action === 'archive' || chosen.action === 'read') {
    await organizeListed(open, target.id, chosen.action);
  } else if (chosen.action === 'reply') {
    const listed = mailboxesOf(snapshot());
    const sender = listed.find(({ id }) => id === target.mailbox);
    if (sender !== undefined && chosen.text.trim() !== '') {
      await replyTyped(native, replies, {
        open,
        named,
        profile: target.profile,
        sender,
        // Only the sending Mail Profile's own addresses leave the recipients.
        identities: listed
          .filter(({ profile }) => profile === target.profile)
          .map(({ address }) => address),
        text: chosen.text,
      });
    }
  } else if (chosen.action === 'undo') {
    // Only this connection's reply still waiting in the Outbox returns to Drafts.
    if (
      replies.outbox
        .getSnapshot()
        .some(
          ({ id, draft }) =>
            id === chosen.draft && draft.connection === target.mailbox,
        )
    ) {
      await replies.outbox.undo(chosen.draft);
    }
    await native.withdrawNotification(
      `${target.mailbox}.reply.${chosen.draft}`,
    );
  } else if (
    chosen.action === 'open-draft' &&
    draftOf(replies.drafts.getSnapshot(), chosen.draft)?.connection ===
      target.mailbox
  ) {
    replies.openDraft(chosen.draft, target.profile);
  }
}

// Acts on each action chosen on a notification, one at a time, until a reloaded JavaScript context
// replaces this reader. Each acts once registration verifies, while the connection is still the one
// the notification named: Archive and Mark as Read through the same queued provider change as the
// reader's toolbar, a typed reply through the Outbox. One that cannot act is still completed.
export async function followNotificationActions(
  native: Pick<
    NativeNotifications,
    | 'nextNotificationAction'
    | 'completeNotificationAction'
    | 'notificationSettings'
    | 'postReplyNotification'
    | 'withdrawNotification'
  >,
  {
    snapshot,
    verify,
    mailbox,
    replies,
  }: Readonly<{
    snapshot: () => RegistrationSnapshot;
    verify: (
      work: () => Promise<void>,
      loading: 'automatic' | 'explicit',
    ) => Promise<void>;
    // The connection's open Inbox.
    mailbox: (connection: string) => OpenInbox | undefined;
    replies: Replies;
  }>,
) {
  for (;;) {
    let received: unknown = null;
    try {
      received = await native.nextNotificationAction();
    } catch {
      // A host without notifications, such as a test renderer, has nothing to follow.
    }
    if (received === null) {
      return;
    }
    // Native code finishes a malformed action's handler at its deadline.
    const decoded = Schema.decodeUnknownOption(Action)(received);
    if (Option.isSome(decoded)) {
      const chosen = decoded.value;
      try {
        // Read after verification, which restores a cold host or removes a stale connection.
        await verify(
          () => act(native, { snapshot, mailbox, replies }, chosen),
          'explicit',
        );
      } catch (error) {
        await runLogged(
          Effect.logError(
            'Notification action failed',
            rejectionDiagnostic(error),
          ),
        );
      }
      native.completeNotificationAction(chosen.id);
    }
  }
}
