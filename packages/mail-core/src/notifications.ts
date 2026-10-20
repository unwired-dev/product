import type { Translate } from '@private-email/localization';

import * as Effect from 'effect/Effect';
import * as Option from 'effect/Option';
import * as Schema from 'effect/Schema';

import type { GmailInbox } from './gmail-inbox.ts';
import type { GmailMessage } from './mailbox-message.ts';
import type { RegistrationSnapshot } from './registration-snapshot.ts';

import { rejectionDiagnostic, runLogged } from './diagnostics.ts';
import { gmailAction } from './gmail-actions.ts';
import { listedMessage } from './gmail-inbox.ts';
import { mailboxesOf, unavailableProfile } from './registration-snapshot.ts';
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

// A tapped notification retains its account and connection incarnation. Its Reply action opens
// the message to reply to it.
const Opened = Schema.Struct({
  ...Mailbox.fields,
  message: Schema.NonEmptyString,
  action: Schema.optional(Schema.Literal('reply')),
});
export type OpenedNotification = typeof Opened.Type;

// Archive or Mark as Read, chosen on a notification without opening the application. Native code
// finishes the system's handler once `id` completes.
const Action = Schema.Struct({
  ...Mailbox.fields,
  message: Schema.NonEmptyString,
  id: Schema.NonEmptyString,
  action: Schema.Literals(['archive', 'read']),
});

// The connection's Mail Profile groups its notifications.
type Arrival = NotificationMailbox & Readonly<{ profile: string }>;

type Posted = Omit<OpenedNotification, 'action'> &
  Readonly<{
    // Stable presentation identity; Gmail history suppresses replay before posting.
    id: string;
    title: string;
    body: string;
    previews: boolean;
    profile: string;
  }>;

// The notification actions' titles, in this device's language.
type ActionTitles = Readonly<Record<'reply' | 'archive' | 'read', string>>;

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
  // The next Archive or Mark as Read, or null once a reloaded JavaScript context replaced this
  // reader.
  readonly nextNotificationAction: () => Promise<unknown>;
  readonly completeNotificationAction: (id: string) => void;
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
  { sender, address, subject }: GmailMessage,
) =>
  previews
    ? {
        title: sender === '' ? address : sender,
        body: subject === '' ? t('notifications.noSubject') : subject,
      }
    : { title: '', body: t('notifications.newMail') };

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
      mailbox: Arrival,
      messages: readonly GmailMessage[],
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
            if (current.authorization !== 'authorized' || !eligible()) {
              return;
            }
            const t = translate();
            yield* call(() =>
              native.postNotifications(
                messages.map((message) => ({
                  id: `${mailbox.connection}.${message.id}`,
                  ...notificationContent(t, current.previews, message),
                  ...mailbox,
                  message: message.id,
                  previews: current.previews,
                })),
                {
                  reply: t('contextMenu.reply'),
                  archive: t('contextMenu.archive'),
                  read: t('contextMenu.read'),
                },
              ),
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

// Archives or marks as read each message chosen on a notification, one at a time, until a reloaded
// JavaScript context replaces this reader. Each acts once registration verifies, while the
// connection is still the one the notification named, through the same queued provider change as
// the reader's toolbar; one that cannot act is still completed.
export async function followNotificationActions(
  native: Pick<
    NativeNotifications,
    'nextNotificationAction' | 'completeNotificationAction'
  >,
  {
    snapshot,
    verify,
    inbox,
  }: Readonly<{
    snapshot: () => RegistrationSnapshot;
    verify: (
      load: () => Promise<void>,
      mailboxLoading: 'explicit',
    ) => Promise<void>;
    // The Gmail connection's open Inbox.
    inbox: (connection: string) => GmailInbox | undefined;
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
      const { id, action, ...opened } = decoded.value;
      try {
        await verify(async () => {
          // Read after verification, which restores a cold host or removes a stale connection.
          const target = openedTarget(snapshot(), opened);
          const open = target === undefined ? undefined : inbox(target.mailbox);
          if (target === undefined || open === undefined) {
            return;
          }
          await open.load();
          const state = open.getSnapshot();
          const message =
            state.kind === 'ready'
              ? listedMessage(state, target.id)
              : undefined;
          if (message !== undefined) {
            await open.organize(message, gmailAction[action]);
          }
        }, 'explicit');
      } catch (error) {
        await runLogged(
          Effect.logError(
            'Notification action failed',
            rejectionDiagnostic(error),
          ),
        );
      }
      native.completeNotificationAction(id);
    }
  }
}
