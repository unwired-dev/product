import * as Duration from 'effect/Duration';
import * as Effect from 'effect/Effect';
import * as Option from 'effect/Option';
import * as Pull from 'effect/Pull';
import * as Schedule from 'effect/Schedule';
import * as Schema from 'effect/Schema';

import { rejectionDiagnostic, runLogged } from './diagnostics.ts';

// A content-free push wake hint. Only its opaque route is read: Gmail's history ID and any address
// it carries are never decoded, kept or logged, because each mailbox's committed checkpoint
// already says where its synchronization resumes.
const WakeHint = Schema.Struct({
  provider: Schema.Literal('gmail'),
  routeId: Schema.NonEmptyString,
});

type Synchronized = Readonly<{
  getSnapshot: () => ReadonlyArray<
    Readonly<{ id: string; inbox: Readonly<{ load: () => Promise<void> }> }>
  >;
  load: () => Promise<void>;
}>;

// Keeps every open mailbox fresh for the life of the application, whether or not a window or
// screen shows it. Every opportunity resumes from the mailbox's committed checkpoint, so one that
// the operating system suspends, ends or never delivers loses nothing: the next one catches up.
export function createFreshness(
  mailboxes: Synchronized,
  // Verifies registration before running `load`, as `Registration.refreshInbox` does.
  verify: (
    load: () => Promise<void>,
    mailboxLoading?: 'automatic' | 'explicit',
  ) => Promise<void>,
) {
  const refresh = () => verify(mailboxes.load);
  return {
    // Foreground catch-up, and each background opportunity the operating system grants.
    refresh,
    // Synchronizes every `minutes` until stopped; quitting the application stops it with the process.
    keepAlive: (minutes: number) => {
      const controller = new AbortController();
      const poll = async () => {
        const step = await runLogged(
          Schedule.toStepWithSleep(Schedule.spaced(Duration.minutes(minutes))),
        );
        while (!controller.signal.aborted) {
          try {
            // The scheduler owns only its wait. Store actions retain their own runtime boundaries.
            await runLogged(
              step(undefined).pipe(Pull.catchDone(() => Effect.never)),
              {
                signal: controller.signal,
              },
            );
            if (!controller.signal.aborted) {
              await refresh();
            }
          } catch (error) {
            if (!controller.signal.aborted) {
              await runLogged(
                Effect.logError(
                  'Gmail freshness failed',
                  rejectionDiagnostic(error),
                ),
              );
            }
          }
        }
      };
      void poll();
      // Stops future opportunities; a store action already started settles normally.
      return () => {
        controller.abort();
      };
    },
    // Synchronizes only the mailbox a wake hint's route names, once registration verifies. A route
    // this device does not know, or whose mailbox was removed or lost its grant, wakes nothing.
    wake: async (
      hint: unknown,
      route: (routeId: string) => string | undefined,
    ): Promise<'synchronized' | 'ignored'> => {
      const decoded = Schema.decodeUnknownOption(WakeHint)(hint);
      if (Option.isNone(decoded)) {
        return 'ignored';
      }
      const { routeId } = decoded.value;
      const connection = route(routeId);
      if (connection === undefined) {
        return 'ignored';
      }
      let woke = false;
      await verify(async () => {
        // Read after verification, which can remove the mailbox.
        const mailbox = mailboxes
          .getSnapshot()
          .find(({ id }) => id === connection);
        if (mailbox !== undefined && route(routeId) === connection) {
          woke = true;
          await mailbox.inbox.load();
        }
      }, 'explicit');
      return woke ? 'synchronized' : 'ignored';
    },
  };
}
