import type { Drafts } from './drafts.ts';
import type { GmailInbox } from './inbox-store.ts';
import type { MailboxConnection } from './registration-snapshot.ts';

import { newMessageSender, profileOf } from './drafts.ts';

// Navigation away from an open composer: the composer registers how it finishes (completing
// recipients and saving), and every other destination asks to leave first. One request runs at a
// time, and a composer that cannot finish, or fails to, stays open for a later attempt.
export interface ComposerNavigation {
  readonly register: (finish: () => Promise<boolean>) => () => void;
  readonly leave: (draft?: string) => Promise<boolean>;
  // Starts a Draft only after leaving, and returns it only if no later destination was chosen.
  readonly create: (
    drafts: Pick<Drafts, 'create' | 'abandon'>,
    mailbox: Pick<MailboxConnection, 'id' | 'address'>,
    preparation?: Readonly<{
      prepare?: (id: string) => Promise<boolean>;
      // Preparation before creation, within the initiating account and navigation lifetime.
      before?: () => Promise<boolean>;
    }>,
  ) => Promise<string | undefined>;
  // How many Draft creations have finished, or undefined while one is pending: a creation owns the
  // next composer, whose route may commit only after it finishes.
  readonly creations: () => number | undefined;
  readonly attachReceived: (
    drafts: Pick<Drafts, 'create' | 'abandon' | 'attach'>,
    attachment: Readonly<{
      // The reader's Mailbox Connection, which the Downloaded Attachment is read through.
      mailbox: string;
      mailboxes: readonly MailboxConnection[];
      // Resolves the Downloaded Attachment after leaving, so a later destination still wins.
      saved: () => Promise<
        | Readonly<NonNullable<ReturnType<GmailInbox['attachmentFile']>>>
        | undefined
      >;
    }>,
  ) => Promise<string | undefined>;
}

export function createComposerNavigation(): ComposerNavigation {
  let finish: (() => Promise<boolean>) | undefined = undefined;
  let pending = false;
  let navigations = 0;
  let selectedDraft: string | undefined = undefined;
  let creating = 0;
  let created = 0;
  const leave = async (draft?: string) => {
    if (pending) {
      return false;
    }
    pending = true;
    try {
      const allowed = (await finish?.()) ?? true;
      if (allowed) {
        navigations += 1;
        selectedDraft = draft;
      }
      return allowed;
    } catch {
      // A composer that failed to finish stays open; a later attempt can leave again.
      return false;
    } finally {
      pending = false;
    }
  };
  const starting: ComposerNavigation['create'] = async (
    drafts,
    mailbox,
    { prepare, before } = {},
  ) => {
    let turn = navigations;
    const id = await drafts.create(mailbox, async () => {
      const allowed = await leave();
      turn = navigations;
      return allowed && ((await before?.()) ?? true) && navigations === turn;
    });
    if (id === undefined) {
      return id;
    }
    if (prepare !== undefined && !(await prepare(id))) {
      // An empty Draft nobody opened is removed; one that gained content is kept.
      if (selectedDraft !== id) {
        await drafts.abandon(id);
      }
      return undefined;
    }
    if (navigations === turn) {
      return id;
    }
    // Selecting the new row while creation waits already opened this Draft; it is not abandoned.
    // Locked storage keeps the removal for the next successful save.
    if (selectedDraft !== id) {
      await drafts.abandon(id);
    }
    return undefined;
  };
  const create: ComposerNavigation['create'] = async (...request) => {
    creating += 1;
    try {
      return await starting(...request);
    } finally {
      creating -= 1;
      created += 1;
    }
  };
  return {
    leave,
    register: (next) => {
      finish = next;
      return () => {
        if (finish === next) {
          finish = undefined;
        }
      };
    },
    create,
    creations: () => (creating > 0 ? undefined : created),
    attachReceived: async (drafts, { mailbox, mailboxes, saved }) => {
      // The new Draft sends from the reader's Mail Profile, never moving the file into another.
      const sender = newMessageSender(
        mailboxes,
        profileOf(mailbox, mailboxes),
        mailbox,
      );
      if (sender === undefined) {
        return undefined;
      }
      let file: Awaited<ReturnType<typeof saved>> = undefined;
      return create(drafts, sender, {
        before: async () => {
          file = await saved();
          return file !== undefined;
        },
        prepare: (id) => {
          const chosen = file;
          return chosen === undefined
            ? Promise.resolve(false)
            : drafts.attach(id, [
                {
                  name: chosen.name,
                  type: chosen.type,
                  source: {
                    kind: 'received',
                    mailbox: {
                      connection: mailbox,
                      address: chosen.address,
                      generation: chosen.generation,
                    },
                    file: chosen.file,
                  },
                },
              ]);
        },
      });
    },
  };
}
