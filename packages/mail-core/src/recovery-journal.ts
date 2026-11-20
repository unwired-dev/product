import * as Effect from 'effect/Effect';

import type { Drafts, Recovery } from './drafts.ts';

import { runLogged } from './diagnostics.ts';

// How long after an edit its composer recovery record is written: the most typing that ending the
// app can lose (ADR 0077).
const journalDelay = '2 seconds';

// One open composer's recovery journal (ADR 0077). It keeps the editor's unsaved version and the
// stored version it started from, which `unsaved` returns, in a composer recovery record a few
// seconds after an edit, retrying a record locked storage refused. The records it wrote go once the
// version is unchanged again; a removal storage refused is tried again on the next write, and only
// the latest write or removal of a Draft retires it. The host reports its own lifecycle events.
export interface RecoveryJournal {
  // Counts the version unsaved from the start, as a restored recovery record, as written.
  readonly adopt: () => void;
  // Schedules a write unless one is already scheduled, so later edits keep its time.
  readonly edited: () => void;
  // Journals at once, as after a save that keeps the editor open; once closed, retries removals.
  readonly write: () => void;
  // Journals at once unless closed, as on return to the foreground.
  readonly resume: () => void;
  // Journals at once, unless unsaved edits have a write scheduled.
  readonly settle: () => void;
  // Closes the journal, removing its records and that of Draft `id` the editor closes on, which
  // another editor's journal may have written; resolves once storage answered every removal.
  readonly close: (id: string) => Promise<void>;
  // Cancels a scheduled write, leaving the records for the next launch.
  readonly dispose: () => void;
}

export function createRecoveryJournal(
  drafts: Pick<Drafts, 'journal' | 'forget'>,
  unsaved: () => Recovery | undefined,
  // The editor that closing removes records for; another editor open on a Draft keeps its record.
  editor: (id: string) => void,
): RecoveryJournal {
  const journaled = new Map<string, object>();
  let scheduled: AbortController | undefined = undefined;
  let closed = false;
  const cancel = () => {
    scheduled?.abort();
    scheduled = undefined;
  };
  const forget = async () => {
    await Promise.allSettled(
      [...journaled.keys()].map(async (id) => {
        const attempt = {};
        journaled.set(id, attempt);
        if (
          (await drafts.forget(id, editor)) &&
          journaled.get(id) === attempt
        ) {
          journaled.delete(id);
        }
      }),
    );
  };
  const write = () => {
    cancel();
    const kept = closed ? undefined : unsaved();
    if (kept === undefined) {
      void forget();
      return;
    }
    journaled.set(kept.version.id, {});
    void drafts.journal(kept.version, kept.base);
  };
  return {
    adopt: () => {
      const restored = unsaved();
      if (restored !== undefined) {
        journaled.set(restored.version.id, {});
      }
    },
    edited: () => {
      if (scheduled !== undefined || closed) {
        return;
      }
      const wait = new AbortController();
      scheduled = wait;
      void (async () => {
        try {
          await runLogged(Effect.sleep(journalDelay), { signal: wait.signal });
        } catch {
          // Cancelled by a write, Close or disposal.
          return;
        }
        if (scheduled === wait) {
          write();
        }
      })();
    },
    write,
    resume: () => {
      if (!closed) {
        write();
      }
    },
    settle: () => {
      if (scheduled === undefined || unsaved() === undefined) {
        write();
      }
    },
    close: (id) => {
      closed = true;
      cancel();
      journaled.set(id, {});
      return forget();
    },
    dispose: cancel,
  };
}
