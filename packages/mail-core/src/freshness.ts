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

// A wake hint the host received, and the routes it may name: each route's connection, and whether
// every usable connection holds a current route.
const Wake = Schema.Struct({ id: Schema.NonEmptyString, hint: Schema.Unknown });
const Routes = Schema.Struct({
  routes: Schema.Record(Schema.String, Schema.String),
  complete: Schema.Boolean,
});
const decodeRoutes = Schema.decodeUnknownPromise(Routes);

// The host's queue of APNs wake hints and its native route lookup.
export interface NativeWakes {
  // The next wake, or null once a reloaded JavaScript context replaced this reader.
  readonly nextWake: () => Promise<unknown>;
  readonly mailboxRoutes: () => Promise<unknown>;
  // Completes the system's handler for the wake.
  readonly completeWake: (
    id: string,
    result: 'synchronized' | 'ignored' | 'failed',
  ) => void;
}

// Whether wakes alone can keep every usable mailbox fresh; unknown reads as not.
export async function pushCovers(wakes: NativeWakes) {
  try {
    const { complete } = await decodeRoutes(await wakes.mailboxRoutes());
    return complete;
  } catch {
    return false;
  }
}

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
    // Synchronizes every `minutes` until stopped, skipping an interval that `covered` reports wakes
    // already handle; quitting the application stops it with the process.
    keepAlive: (minutes: number, covered?: () => Promise<boolean>) => {
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
            const coveredByPush = (await covered?.()) ?? false;
            if (!controller.signal.aborted && !coveredByPush) {
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
      route: (
        routeId: string,
      ) => string | undefined | Promise<string | undefined>,
    ): Promise<'synchronized' | 'ignored'> => {
      const decoded = Schema.decodeUnknownOption(WakeHint)(hint);
      if (Option.isNone(decoded)) {
        return 'ignored';
      }
      const { routeId } = decoded.value;
      const connection = await route(routeId);
      if (connection === undefined) {
        return 'ignored';
      }
      let woke = false;
      await verify(async () => {
        // Read after verification, which can remove the mailbox.
        const mailbox = mailboxes
          .getSnapshot()
          .find(({ id }) => id === connection);
        if (mailbox !== undefined && (await route(routeId)) === connection) {
          woke = true;
          await mailbox.inbox.load();
        }
      }, 'explicit');
      return woke ? 'synchronized' : 'ignored';
    },
  };
}

// Settles each wake the host receives, one at a time, until a reloaded JavaScript context replaces
// this reader. A wake that fails still completes, so the system's handler always finishes.
export async function followWakes(
  freshness: Pick<ReturnType<typeof createFreshness>, 'wake'>,
  wakes: NativeWakes,
) {
  for (;;) {
    let received: unknown = null;
    try {
      received = await wakes.nextWake();
    } catch {
      // A host without the wake queue, such as a test renderer, has nothing to follow.
    }
    const next = Schema.decodeUnknownOption(Wake)(received);
    if (Option.isNone(next)) {
      return;
    }
    const { id, hint } = next.value;
    try {
      wakes.completeWake(
        id,
        await freshness.wake(hint, async (route) => {
          const { routes } = await decodeRoutes(await wakes.mailboxRoutes());
          return Object.hasOwn(routes, route) ? routes[route] : undefined;
        }),
      );
    } catch (error) {
      await runLogged(
        Effect.logError('Gmail wake failed', rejectionDiagnostic(error)),
      );
      wakes.completeWake(id, 'failed');
    }
  }
}
