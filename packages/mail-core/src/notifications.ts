import type { Translate } from '@private-email/localization';

import * as Effect from 'effect/Effect';
import * as Option from 'effect/Option';
import * as Schema from 'effect/Schema';

import type { GmailMessage } from './mailbox-message.ts';
import type { RegistrationSnapshot } from './registration-snapshot.ts';

import { rejectionDiagnostic, runLogged } from './diagnostics.ts';
import { mailboxesOf, unavailableProfile } from './registration-snapshot.ts';

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

// A tapped notification retains its account and connection incarnation.
const Opened = Schema.Struct({
  ...Mailbox.fields,
  message: Schema.NonEmptyString,
});
export type OpenedNotification = typeof Opened.Type;

type Posted = OpenedNotification &
  Readonly<{
    // Stable presentation identity; Gmail history suppresses replay before posting.
    id: string;
    title: string;
    body: string;
    previews: boolean;
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

// Generic content unless this device chose previews.
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
    : { title: t('notifications.newMail'), body: '' };

// This device's notification settings for Settings, and the New Mail Notifications it posts once
// a connection's synchronization commits new Inbox mail. The caller has already checked that the
// connection's policy is on; content is decided here, on the device.
export function createNotifications(
  native: Omit<
    NativeNotifications,
    | 'nextOpenedNotification'
    | 'stopOpenedNotifications'
    | 'restoreOpenedNotification'
  >,
  translate: () => Translate,
) {
  // Unknown until the first read settles.
  let settings: NotificationSettings | undefined = undefined;
  const listeners = new Set<() => void>();
  const publish = (next: NotificationSettings) => {
    settings = next;
    for (const listener of listeners) {
      listener();
    }
  };
  const update = (request: () => Promise<unknown>, failure: string) =>
    runLogged(
      logged(
        failure,
        settingsOf(request).pipe(
          Effect.tap((next) =>
            Effect.sync(() => {
              publish(next);
            }),
          ),
        ),
      ),
    );
  return {
    getSnapshot: () => settings,
    subscribe: (listener: () => void) => {
      listeners.add(listener);
      return () => {
        listeners.delete(listener);
      };
    },
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
      mailbox: NotificationMailbox,
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
  { account: owner, connection, epoch, message }: OpenedNotification,
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
// replaces this reader. A malformed reply ends nothing: it is skipped.
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
    ) => void;
  }>,
) {
  nextReader += 1;
  const reader = String(nextReader);
  let stopped = false;
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
        if (stopped) {
          await native.restoreOpenedNotification(decoded.value);
          return;
        }
        if (openedTarget(snapshot(), decoded.value) !== undefined) {
          const allowed = await leave();
          if (stopped) {
            await native.restoreOpenedNotification(decoded.value);
            return;
          }
          const target = allowed
            ? openedTarget(snapshot(), decoded.value)
            : undefined;
          if (target !== undefined) {
            open(target);
          }
        }
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
