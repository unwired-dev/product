import type { Translate } from '@private-email/localization';

import * as Effect from 'effect/Effect';
import * as Option from 'effect/Option';
import * as Schema from 'effect/Schema';
import * as Semaphore from 'effect/Semaphore';

import type { Draft, OutboxEntry } from './draft-model.ts';
import type { Drafts, DraftsState } from './drafts.ts';
import type { ImapInbox } from './imap-inbox.ts';
import type { ImapAction } from './imap-model.ts';
import type { GmailInbox } from './inbox-store.ts';
import type { GmailMessage } from './mailbox-message.ts';
import type {
  MailboxConnection,
  MailGrantProvider,
  RegistrationSnapshot,
} from './registration-snapshot.ts';
import type { Registration } from './registration.ts';

import { logNote, rejectionDiagnostic, runLogged } from './diagnostics.ts';
import { draftOf, draftSaveProblem, isEmptyDraft } from './drafts.ts';
import { gmailAction } from './gmail-actions.ts';
import { imapRoleFolder } from './imap-actions.ts';
import { listedMessage } from './inbox-store.ts';
import { mailboxesOf, unavailableProfile } from './registration-snapshot.ts';
import { canOpenInbox } from './registration.ts';
import { typedBody, typedReply } from './responses.ts';
import { createSubscribable } from './subscribable.ts';

// What the operating system lets this device show, whether a New Mail Notification may show its
// sender and subject, what the App Icon Badge counts and the sound a shown New Mail Notification
// plays, and the Mail Profiles whose Badge and sound switch is off: their mail adds nothing to the
// badge and their notifications play no sound. Native code keeps the choices as Device-Local
// Preferences; previews and the badge start off, the sound at the system's default and every
// Profile's switch on.
const Settings = Schema.Struct({
  authorization: Schema.Literals(['undetermined', 'denied', 'authorized']),
  previews: Schema.Boolean,
  badge: Schema.Literals(['off', 'inbox']),
  sound: Schema.Literals(['default', 'none']),
  badgeSoundOff: Schema.Array(Schema.NonEmptyString).pipe(
    Schema.withDecodingDefaultKey(Effect.succeed([])),
  ),
});
export type NotificationSettings = typeof Settings.Type;
export type BadgeChoice = NotificationSettings['badge'];
export type SoundChoice = NotificationSettings['sound'];
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

// Archive or Mark as Read, a reply typed into the Reply field, Undo or Open Draft on that reply's
// own notification, chosen without opening the application, or a tap on a Send Reminder, which
// names its Draft and the Product Account that owns it. Native code finishes the system's handler
// once `id` completes.
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
  Schema.Struct({
    id: Schema.NonEmptyString,
    account: Schema.NonEmptyString,
    action: Schema.Literal('open-reminder'),
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
    // The Reply field's placeholder, which names the receiving address.
    reply: string;
  }>;

// The notification actions' titles, in this device's language; `send` titles the Reply field's
// button.
type ActionTitles = Readonly<
  Record<'reply' | 'send' | 'archive' | 'read', string>
>;

// A reply typed into a notification, after Send: `sending` offers Undo while the Undo Send Window
// runs, `saved` says the text waits in Drafts and offers Open Draft, and `failed`, with no Draft,
// says it could not be kept.
type ReplyPosted = Omit<OpenedNotification, 'action'> &
  Readonly<{
    id: string;
    kind: 'sending' | 'saved' | 'failed';
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
  readonly setNotificationBadge: (badge: BadgeChoice) => Promise<unknown>;
  readonly setNotificationSound: (sound: SoundChoice) => Promise<unknown>;
  // Turns one of the Product Account `owner`'s Mail Profiles' Badge and sound switch on or off;
  // after that account is gone, nothing changes.
  readonly setNotificationProfile: (
    owner: string,
    profile: string,
    on: boolean,
  ) => Promise<unknown>;
  // Shows `count` on the application's icon; 0 removes the badge.
  readonly setBadgeCount: (count: number) => Promise<unknown>;
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
  // Removes every typed reply's sending notification from Notification Center.
  readonly withdrawSendingReplies: () => Promise<unknown>;
}

// A native call that failed; its cause is logged only as a diagnostic.
class NotificationNativeFailure extends Schema.TaggedError<
  NotificationNativeFailure,
  { readonly brand: unique symbol }
>()('NotificationNativeFailure', { cause: Schema.Defect() }) {}

const call = <A>(request: () => Promise<A>) =>
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

// What the App Icon Badge counts: Registration, and every connection whose Inbox can open.
type BadgeSources = Readonly<{
  registration: Pick<Registration, 'getSnapshot' | 'subscribe'>;
  mailboxes: Readonly<{
    getConnections: () => ReadonlyArray<
      Readonly<{
        profile: string;
        state: Readonly<{
          kind: string;
          messages?: ReadonlyArray<Readonly<{ unread: boolean }>>;
        }>;
      }>
    >;
    subscribe: (listener: () => void) => () => void;
  }>;
}>;

// The unread messages this device lists in the Inbox of every open connection, as the sidebar's
// Inbox rows count them, or undefined while saved registration or an Inbox has not opened yet.
// Without an Inbox to open, after sign-out or the last removal, nothing is unread. Connections of
// the Profiles in `off` are left out.
const inboxUnread = (
  { registration, mailboxes }: BadgeSources,
  off: readonly string[],
) => {
  const { snapshot, restoring, locked } = registration.getSnapshot();
  if (restoring === true || locked === true) {
    return undefined;
  }
  if (!canOpenInbox(snapshot)) {
    return 0;
  }
  const connections = mailboxes.getConnections();
  // A mailbox whose Profile this device cannot read may be in one switched off.
  if (
    off.length > 0 &&
    connections.some(({ profile }) => profile === unavailableProfile)
  ) {
    return undefined;
  }
  let unread = 0;
  for (const { state } of connections.filter(
    ({ profile }) => !off.includes(profile),
  )) {
    if (state.kind === 'loading' || state.kind === 'locked') {
      return undefined;
    }
    unread += state.messages?.filter((message) => message.unread).length ?? 0;
  }
  return unread;
};

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
    | 'withdrawSendingReplies'
  >,
  translate: () => Translate,
) {
  // Unknown until the first read settles.
  const settings = createSubscribable<NotificationSettings | undefined>(
    undefined,
  );
  // One settings request runs at a time, so each publishes in the order it was made: a read
  // cannot settle after a later read or a later saved choice and bring back what it found.
  // A request made before the Product Account changed publishes nothing, and one that belongs to
  // that Product Account does not run either.
  const requests = Semaphore.makeUnsafe(1);
  let account = 0;
  const queued = (
    request: () => Promise<unknown>,
    failure: string,
    owned = false,
  ) => {
    const made = account;
    return logged(
      failure,
      requests.withPermit(
        Effect.suspend(() =>
          !owned || made === account
            ? settingsOf(request).pipe(
                Effect.tap((next) =>
                  Effect.sync(() => {
                    if (made === account) {
                      settings.set(next);
                    }
                  }),
                ),
              )
            : Effect.void,
        ),
      ),
    );
  };
  const update = (request: () => Promise<unknown>, failure: string) =>
    runLogged(queued(request, failure));
  const read = () =>
    queued(
      () => native.notificationSettings(),
      'Notification settings could not be read:',
    );
  const load = () => runLogged(read());
  return {
    getSnapshot: settings.getSnapshot,
    subscribe: settings.subscribe,
    // Also after activation: the person can change permission in the system's settings.
    load,
    // The system prompt waits for the person, so it holds no request back; the settings are read
    // once it settles.
    request: () =>
      runLogged(
        logged(
          'Notification permission could not be requested:',
          call(() => native.requestNotifications()),
        ).pipe(Effect.andThen(Effect.suspend(read))),
      ),
    setPreviews: (previews: boolean) =>
      update(
        () => native.setNotificationPreviews(previews),
        'Notification previews could not be saved:',
      ),
    setBadge: (badge: BadgeChoice) =>
      update(
        () => native.setNotificationBadge(badge),
        'The App Icon Badge choice could not be saved:',
      ),
    setSound: (sound: SoundChoice) =>
      update(
        () => native.setNotificationSound(sound),
        'The New Mail Sound choice could not be saved:',
      ),
    setProfileBadgeSound: (owner: string, profile: string, on: boolean) =>
      runLogged(
        queued(
          () => native.setNotificationProfile(owner, profile, on),
          'A Profile Badge and sound choice could not be saved:',
          true,
        ),
      ),
    // Keeps the App Icon Badge on the unread Inbox count of the Profiles whose Badge and sound
    // switch is on while the badge counts it and the system allows notifications, and removes it
    // otherwise. A count is applied only once every source
    // has settled, so while it counts, a launch that has not opened saved registration or an
    // Inbox yet keeps the badge it found.
    followBadge: (sources: BadgeSources) => {
      // What the icon shows once the system applied it, and the count it should show. One write
      // runs at a time and ends on the latest count; a refused count is tried again at the next
      // change.
      let shown: number | undefined = undefined;
      let wanted: number | undefined = undefined;
      let writing = false;
      // Whether the last count was taken without an Inbox to open, as after sign-out.
      let signedOut = false;
      const apply = (count: number) =>
        logged(
          'The App Icon Badge could not be set:',
          call(() => native.setBadgeCount(count)).pipe(
            Effect.andThen(
              Effect.sync(() => {
                shown = count;
              }),
            ),
          ),
        );
      const write = Effect.gen(function* () {
        let attempted: number | undefined = undefined;
        for (
          let count = wanted;
          count !== undefined && count !== shown && count !== attempted;
          count = wanted
        ) {
          attempted = count;
          yield* apply(count);
        }
      }).pipe(
        Effect.ensuring(
          Effect.sync(() => {
            writing = false;
          }),
        ),
      );
      const countOf = (current: NotificationSettings | undefined) => {
        if (current === undefined) {
          // Until the settings are known, only nothing unread, as after sign-out, is counted.
          return inboxUnread(sources, []) === 0 ? 0 : undefined;
        }
        return current.authorization === 'authorized' &&
          current.badge === 'inbox'
          ? inboxUnread(sources, current.badgeSoundOff)
          : 0;
      };
      const follow = () => {
        const count = countOf(settings.getSnapshot());
        if (count !== undefined) {
          signedOut = !canOpenInbox(
            sources.registration.getSnapshot().snapshot,
          );
        }
        // Until it can count, no queued count is applied either, except the clear without an Inbox
        // to open: after sign-out it stays queued while the next Product Account's settings and
        // Inbox open.
        wanted = count ?? (signedOut ? 0 : undefined);
        if (count === undefined) {
          return;
        }
        if (!writing && wanted !== shown) {
          writing = true;
          void runLogged(write);
        }
      };
      // A purge removes the Profiles' Badge and sound choices, whose ids another Product Account
      // reuses, so the settings are read again whenever the Product Account changes.
      const owner = () => {
        const { snapshot } = sources.registration.getSnapshot();
        return snapshot.kind === 'signed-out'
          ? undefined
          : snapshot.productAccountId;
      };
      let following = owner();
      settings.subscribe(follow);
      sources.registration.subscribe(() => {
        if (owner() !== following) {
          following = owner();
          // The previous Product Account's choices are not this one's.
          account += 1;
          settings.set(undefined);
          void load();
        }
        follow();
      });
      sources.mailboxes.subscribe(follow);
      void load();
    },
    openSettings: () =>
      runLogged(
        logged(
          'Notification settings could not be opened:',
          call(() => native.openNotificationSettings()),
        ),
      ),
    // After the settings are read and `settle` has finished, `eligible` is asked about the Profile
    // the connection is in then, in the same step that posts: the connection may have been
    // removed, turned off, hidden or moved meanwhile.
    arrived: (
      { profile: currentProfile, address, ...mailbox }: Arrival,
      messages: readonly ArrivedMessage[],
      {
        settle,
        eligible,
      }: Readonly<{
        settle: () => Promise<void>;
        eligible: (profile: string) => boolean;
      }>,
    ) =>
      runLogged(
        logged(
          'New mail notifications could not be posted:',
          Effect.gen(function* () {
            // Read again: a background launch has not loaded Settings.
            const current = yield* settingsOf(() =>
              native.notificationSettings(),
            );
            if (current.authorization !== 'authorized') {
              return yield* notPosted(`authorization ${current.authorization}`);
            }
            yield* call(settle);
            const profile = currentProfile();
            if (profile === undefined) {
              return yield* notPosted('Mail Profile unknown');
            }
            if (!eligible(profile)) {
              return yield* notPosted(
                'connection closed, turned off or hidden meanwhile',
              );
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
  // The Outbox's admission, Undo and entries; resolving undefined admits, and false refuses Undo.
  outbox: Readonly<{
    send: (expected: () => Draft) => Promise<unknown>;
    undo: (id: string, only: OutboxEntry['state']) => Promise<unknown>;
    getSnapshot: () => readonly OutboxEntry[];
  }>;
  translate: () => Translate;
  // Opens a Draft in `profile`; `current` names its Profile again later, undefined once it no
  // longer belongs to the notification's connection.
  openDraft: (
    draft: string,
    profile: string,
    current: () => string | undefined,
  ) => void;
  // A typed reply the Outbox admitted, which iPhone and iPad give background delivery time.
  admitted: () => void;
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

type ReplyNative = Pick<
  NativeNotifications,
  'notificationSettings' | 'postReplyNotification' | 'withdrawNotification'
>;

// The typed replies whose notifications offer Undo, by notification: each posts its notification
// again with the time left, until the Undo Send Window ends.
type Sending = Map<string, () => Promise<void>>;

const postReply = (
  native: ReplyNative,
  t: Translate,
  notification: Parameters<NativeNotifications['postReplyNotification']>[0],
) =>
  runLogged(
    logged(
      'Notification reply notification could not be posted:',
      call(() =>
        native.postReplyNotification(notification, {
          undo: t('notifications.undo'),
          openDraft: t('notifications.openDraft'),
        }),
      ),
    ),
  );

// A Draft from `sender` holding only `text`: a reply to the message when its body was read, and
// the text alone otherwise. `sendable` is the reply as prepared, unset when it is not one or did not save;
// `unsaved` says the text is not stored: storage refused it, which the Draft's composer then
// reports, or another editor changed the new Draft first, whose content is kept.
async function savedReply(
  drafts: Replies['drafts'],
  t: Translate,
  // oxlint-disable-next-line typescript/prefer-readonly-parameter-types -- The message body document is shared read-only state.
  {
    source,
    sender,
    identities,
    text,
  }: Readonly<{
    source: Awaited<ReturnType<typeof answered>>;
    sender: Pick<MailboxConnection, 'id' | 'address'>;
    identities: readonly string[];
    text: string;
  }>,
) {
  const draft = await drafts.create(sender);
  if (draft === undefined) {
    return undefined;
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
  const typed =
    reply ?? ((each: Draft) => ({ ...each, body: typedBody(text) }));
  let prepared: Draft | undefined = undefined;
  const filled = await drafts.fill(
    draft,
    (each) => {
      prepared = isEmptyDraft(each) ? typed(each) : undefined;
      return prepared ?? each;
    },
    [],
  );
  const unsaved =
    prepared === undefined ||
    draftSaveProblem(drafts.getSnapshot()) !== undefined;
  return {
    draft,
    unsaved,
    sendable: filled && !unsaved && reply !== undefined ? prepared : undefined,
  };
}

// Says a typed reply waits to send, offering Undo until its admitted send time, counted from the
// Outbox entry, then withdraws the notification. Undo that cannot be saved posts it again.
async function announceSending(
  native: ReplyNative,
  {
    outbox,
    t,
    sending,
  }: Readonly<{
    outbox: Replies['outbox'];
    t: Translate;
    sending: Sending;
  }>,
  {
    notification,
    address,
  }: Readonly<{
    notification: Omit<ReplyPosted, 'kind' | 'body'>;
    address: string;
  }>,
) {
  const { id, draft } = notification;
  const left = () => {
    const entry = outbox
      .getSnapshot()
      .find((each) => each.id === draft && each.state === 'waiting');
    return entry === undefined ? 0 : entry.sendAt - Date.now();
  };
  const withdraw = () =>
    runLogged(
      logged(
        'Notification reply notification could not be withdrawn:',
        call(() => native.withdrawNotification(id)),
      ),
    );
  // An offer posted again after the window ended is withdrawn as it lands.
  const post = async () => {
    const seconds = Math.ceil(left() / 1000);
    if (seconds > 0) {
      await postReply(native, t, {
        ...notification,
        kind: 'sending',
        body: t('notifications.replySending', { seconds, address }),
      });
      if (sending.get(id) !== post) {
        await withdraw();
      }
    }
  };
  sending.set(id, post);
  await post();
  setTimeout(
    () => {
      sending.delete(id);
      void withdraw();
    },
    Math.max(0, left()),
  );
}

// The sending notification's title: the replied sender, only with previews on.
const sendingTitle = (
  t: Translate,
  previews: boolean,
  replied: Pick<GmailMessage, 'sender' | 'address'> | undefined,
) =>
  previews && replied !== undefined
    ? t('notifications.replyTo', {
        sender:
          replied.sender === '' ? (replied.address ?? '') : replied.sender,
      })
    : '';

// Admits a saved reply to the Outbox as prepared, refused once another editor changed it; a
// connection replaced meanwhile gets it back in Drafts.
// Resolves whether it waits to send.
async function queuedReply(
  outbox: Replies['outbox'],
  {
    draft,
    sendable,
    current,
  }: Readonly<{
    draft: string;
    sendable: Draft | undefined;
    current: () => boolean;
  }>,
) {
  if (
    sendable === undefined ||
    (await outbox.send(() => sendable)) !== undefined
  ) {
    return false;
  }
  return current() || (await outbox.undo(draft, 'waiting')) === false;
}

// Queues `text` alone as a reply to the notified message, from the connection that received it,
// through the Outbox and its Undo Send Window, and says so on a notification offering Undo until
// the window ends. A message no longer listed or unreadable, or a Send the Outbox refuses, keeps
// the text in Drafts and offers Open Draft instead. Nothing is saved or sent once `current` says
// the connection is no longer the one the notification named.
async function replyTyped(
  native: ReplyNative,
  { drafts, outbox, translate, admitted }: Replies,
  // oxlint-disable-next-line typescript/prefer-readonly-parameter-types -- Inbox stores and the sending map are mutable; only their actions are called.
  {
    open,
    named,
    current,
    sending,
    profile,
    sender,
    identities,
    text,
  }: Readonly<{
    open: OpenInbox;
    named: Omit<OpenedNotification, 'action'>;
    current: () => boolean;
    sending: Sending;
    profile: string;
    sender: Pick<MailboxConnection, 'id' | 'address'>;
    identities: readonly string[];
    text: string;
  }>,
) {
  const t = translate();
  const source = await answered(open, named.message);
  const saved = current()
    ? await savedReply(drafts, t, { source, sender, identities, text })
    : undefined;
  if (!current()) {
    await runLogged(logNote('Notification reply not saved or not sent'));
    return;
  }
  // Drafts that cannot open keep nothing; the person learns the text is gone. It shows no mail,
  // so it needs no preview choice.
  if (saved === undefined) {
    await postReply(native, t, {
      ...named,
      id: `${named.connection}.reply.${named.message}`,
      draft: '',
      profile,
      previews: false,
      kind: 'failed',
      title: t('notifications.replyFailed'),
      body: t('notifications.replyLost'),
    });
    return;
  }
  const { draft, unsaved, sendable } = saved;
  // Admitted before anything else is awaited, so no other editor's change is sent.
  const queued = await queuedReply(outbox, { draft, sendable, current });
  if (queued) {
    admitted();
  }
  const { previews } = await runLogged(
    settingsOf(() => native.notificationSettings()).pipe(
      Effect.orElseSucceed(() => ({ previews: false })),
    ),
  );
  const base = {
    ...named,
    id: `${named.connection}.reply.${draft}`,
    draft,
    profile,
    previews,
  };
  if (queued) {
    await announceSending(
      native,
      { outbox, t, sending },
      {
        notification: {
          ...base,
          title: sendingTitle(t, previews, source?.message),
        },
        address: sender.address,
      },
    );
    return;
  }
  const kept =
    source === undefined
      ? 'notifications.replyDeleted'
      : 'notifications.replySaved';
  await postReply(native, t, {
    ...base,
    kind: 'saved',
    title: t('notifications.replyFailed'),
    body: t(unsaved ? 'notifications.replyUnsaved' : kept),
  });
}

// Returns a connection's typed reply still waiting in the Outbox to Drafts and withdraws its
// notification; one whose return could not be saved keeps offering Undo while its window runs. A
// reply already handed to its provider stays for the Outbox, which warns before editing an
// uncertain one.
async function undoReply(
  native: ReplyNative,
  outbox: Replies['outbox'],
  {
    sending,
    connection,
    draft,
  }: Readonly<{ sending: Sending; connection: string; draft: string }>,
) {
  const id = `${connection}.reply.${draft}`;
  const waiting = outbox
    .getSnapshot()
    .some(
      (each) =>
        each.id === draft &&
        each.state === 'waiting' &&
        each.draft.connection === connection,
    );
  if (waiting && (await outbox.undo(draft, 'waiting')) === false) {
    await sending.get(id)?.();
    return;
  }
  sending.delete(id);
  await native.withdrawNotification(id);
}

// Replies with `text` from the notified connection, while it is still the one the notification named.
async function replyFrom(
  native: ReplyNative,
  replies: Replies,
  // oxlint-disable-next-line typescript/prefer-readonly-parameter-types -- Inbox stores and the sending map are mutable; only their actions are called.
  {
    open,
    named,
    snapshot,
    sending,
    text,
  }: Readonly<{
    open: OpenInbox;
    named: Omit<OpenedNotification, 'action'>;
    snapshot: () => RegistrationSnapshot;
    sending: Sending;
    text: string;
  }>,
) {
  const current = () => openedTarget(snapshot(), named);
  const target = current();
  const listed = mailboxesOf(snapshot());
  const sender = listed.find(({ id }) => id === target?.mailbox);
  if (target === undefined || sender === undefined || text.trim() === '') {
    return;
  }
  await replyTyped(native, replies, {
    open,
    named,
    current: () => current() !== undefined,
    sending,
    profile: target.profile,
    sender,
    // Only the sending Mail Profile's own addresses leave the recipients.
    identities: listed
      .filter(({ profile }) => profile === target.profile)
      .map(({ address }) => address),
    text,
  });
}

// The Mail Profile a Send Reminder's Draft opens in: its connection's current one, while the
// Product Account the notification named lists the Draft and the connection is available.
const reminderProfile = (
  account: RegistrationSnapshot,
  drafts: DraftsState,
  { account: owner, draft }: Readonly<{ account: string; draft: string }>,
) => {
  if (account.kind === 'signed-out' || account.productAccountId !== owner) {
    return undefined;
  }
  const connection = draftOf(drafts, draft)?.connection;
  const mailbox = mailboxesOf(account).find(({ id }) => id === connection);
  return mailbox === undefined || mailbox.profile === unavailableProfile
    ? undefined
    : mailbox.profile;
};

// Acts on one action chosen on a notification while the connection is still the one it named.
// Undo and Open Draft change only this device's Drafts and Outbox, so they need no open Inbox.
async function act(
  native: ReplyNative,
  {
    snapshot,
    mailbox,
    showSaved,
    replies,
    sending,
  }: Readonly<{
    snapshot: () => RegistrationSnapshot;
    mailbox: (connection: string) => OpenInbox | undefined;
    showSaved: () => Promise<void>;
    replies: Replies;
    sending: Sending;
  }>,
  chosen: typeof Action.Type,
) {
  if (chosen.action === 'open-reminder') {
    // A tap can launch the application before its Drafts open.
    await replies.drafts.load();
    const profile = () =>
      reminderProfile(snapshot(), replies.drafts.getSnapshot(), chosen);
    const opened = profile();
    if (opened !== undefined) {
      replies.openDraft(chosen.draft, opened, profile);
    }
    return;
  }
  const { account, connection, epoch, message } = chosen;
  const named = { account, connection, epoch, message };
  // An action can launch the application before its Drafts and Outbox open; the connection is
  // checked once they have.
  await replies.drafts.load();
  const target = openedTarget(snapshot(), named);
  if (target === undefined) {
    return;
  }
  if (chosen.action === 'undo') {
    await undoReply(native, replies.outbox, {
      sending,
      connection: target.mailbox,
      draft: chosen.draft,
    });
    return;
  }
  if (chosen.action === 'open-draft') {
    // The Profile the Draft opens in while it still belongs to this connection, asked again
    // once an open composer has left.
    const profile = () => {
      const now = openedTarget(snapshot(), named);
      return now !== undefined &&
        draftOf(replies.drafts.getSnapshot(), chosen.draft)?.connection ===
          now.mailbox
        ? now.profile
        : undefined;
    };
    const opened = profile();
    if (opened !== undefined) {
      replies.openDraft(chosen.draft, opened, profile);
    }
    return;
  }
  const open = mailbox(target.mailbox);
  if (open === undefined) {
    return;
  }
  if (chosen.action === 'reply') {
    await replyFrom(native, replies, {
      open,
      named,
      snapshot,
      sending,
      text: chosen.text,
    });
    return;
  }
  await organizeListed(open, target.id, chosen.action);
  // The other connections show their saved listings, so the App Icon Badge counts every Inbox.
  await showSaved();
}

// Acts on each action chosen on a notification, one at a time except typed replies, until a
// reloaded JavaScript context replaces this reader. Each acts once registration verifies, while the
// connection is still the one the notification named: Archive and Mark as Read through the same
// queued provider change as the reader's toolbar, a typed reply through the Outbox. One that cannot
// act is still completed. Sending notifications an earlier context left are withdrawn first, since
// nothing counts them down any more.
export async function followNotificationActions(
  native: Pick<
    NativeNotifications,
    | 'nextNotificationAction'
    | 'completeNotificationAction'
    | 'notificationSettings'
    | 'postReplyNotification'
    | 'withdrawNotification'
    | 'withdrawSendingReplies'
  >,
  {
    snapshot,
    verify,
    mailbox,
    showSaved,
    replies,
  }: Readonly<{
    snapshot: () => RegistrationSnapshot;
    verify: (
      work: () => Promise<void>,
      loading: 'automatic' | 'explicit',
    ) => Promise<void>;
    // The connection's open Inbox.
    mailbox: (connection: string) => OpenInbox | undefined;
    // Shows each saved Inbox listing no synchronization has opened yet.
    showSaved: () => Promise<void>;
    replies: Replies;
  }>,
) {
  await runLogged(
    logged(
      'Sending reply notifications could not be withdrawn:',
      call(() => native.withdrawSendingReplies()),
    ),
  );
  const sending: Sending = new Map();
  const handle = async (chosen: typeof Action.Type) => {
    try {
      // Read after verification, which restores a cold host or removes a stale connection.
      await verify(
        () =>
          act(
            native,
            { snapshot, mailbox, showSaved, replies, sending },
            chosen,
          ),
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
  };
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
      const handled = handle(decoded.value);
      // A reply reads its message first; an Undo chosen meanwhile cannot wait for that.
      if (decoded.value.action !== 'reply') {
        await handled;
      }
    }
  }
}
