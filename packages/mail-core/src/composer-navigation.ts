import type { Drafts } from './drafts.ts';
import type { GmailInbox } from './gmail-inbox.ts';
import type { MailboxConnection } from './registration.ts';

import { sendingMailboxes } from './drafts.ts';

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
    prepare?: (id: string) => Promise<boolean>,
  ) => Promise<string | undefined>;
  readonly attachReceived: (
    drafts: Pick<Drafts, 'create' | 'abandon' | 'attach'>,
    attachment: Readonly<{
      mailbox: string | undefined;
      mailboxes: readonly MailboxConnection[];
      saved: Readonly<NonNullable<ReturnType<GmailInbox['attachmentFile']>>>;
    }>,
  ) => Promise<string | undefined>;
}

export function createComposerNavigation(): ComposerNavigation {
  let finish: (() => Promise<boolean>) | undefined = undefined;
  let pending = false;
  let navigations = 0;
  let selectedDraft: string | undefined = undefined;
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
  const create: ComposerNavigation['create'] = async (
    drafts,
    mailbox,
    prepare,
  ) => {
    let turn = navigations;
    const id = await drafts.create(mailbox, async () => {
      const allowed = await leave();
      turn = navigations;
      return allowed;
    });
    if (id === undefined) {
      return id;
    }
    if (prepare !== undefined && !(await prepare(id))) {
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
    attachReceived: async (drafts, { mailbox, mailboxes, saved }) => {
      const senders = sendingMailboxes(mailboxes);
      const sender = senders.find(({ id }) => id === mailbox) ?? senders[0];
      if (sender === undefined || mailbox === undefined) {
        return undefined;
      }
      return create(drafts, sender, (id) =>
        drafts.attach(id, [
          {
            name: saved.name,
            type: saved.type,
            source: {
              kind: 'received',
              mailbox: {
                connection: mailbox,
                address: saved.address,
                generation: saved.generation,
              },
              file: saved.file,
            },
          },
        ]),
      );
    },
  };
}
